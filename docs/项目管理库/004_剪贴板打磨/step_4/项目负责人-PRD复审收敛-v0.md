# 004_剪贴板打磨 Step 4 PRD 复审收敛 v0

## 结论

结论：`prd-revision-required`。

Step 4 PRD v0 范围正确，未提前进入 Step 5 / Step 6，也未重开 Step 1 / Step 2 / Step 3。四个角色复审均未发现 P0；但 App 架构师和测试/质量提出的 P1 会影响技术方案边界、数据模型、保存事务和验收门禁，不能直接进入技术方案。需要产品经理产出 `step_4/产品经理-PRD-v1.md`。

不需要回用户澄清。当前问题可以由 PRD v1、项目负责人取舍和后续技术方案收敛。

## 复审结论汇总

| 角色 | 文档 | 结论 | P0 | P1 |
| --- | --- | --- | --- | --- |
| UI/交互设计师 | `UI-交互设计师-PRD复审-v0.md` | `approve-with-changes` | 0 | 0 |
| App 架构师 | `App架构师-PRD复审-v0.md` | `approve-with-changes` | 0 | 多项 |
| 开发 | `开发-PRD复审-v0.md` | `approve-with-changes` | 0 | 0 |
| 测试/质量 | `测试-质量-PRD复审-v0.md` | `approve-with-changes` | 0 | 多项 |

## PRD v1 必须吸收的 P1

### P1-1 富文本格式保留与降级口径

问题：PRD v0 已写“尽量保留格式，不静默丢格式”，但还不足以支撑技术方案拆解。

PRD v1 必须明确：

- 富文本编辑的首选语义是保持 `rich_text` kind 和用户可见格式，不静默降级为 plain text。
- 技术方案必须验证最低格式保留范围；至少需要覆盖链接、段落 / 换行、基础 inline style 或列表中的代表项。
- 如果技术方案确认无法可靠保留格式，富文本编辑不得作为普通可编辑类型直接进入开发；必须由项目负责人单独接受降级、暂缓或只读方案。
- P13D 或等价门禁必须能证明“富文本未静默丢格式”或存在当前项目负责人接受记录。

### P1-2 保存事务与索引失败的一致性合同

问题：保存后需要更新 payload / 派生字段 / 摘要 / 搜索索引 / 更新时间，但 PRD v0 仍把同步事务、异步队列或混合模型留作待确认。

PRD v1 必须明确：

- Step 4 保存是用户级单一 mutation。
- 保存成功后，详情正文、面板摘要、搜索命中、更新时间和当前详情 read model 必须进入同一版本语义。
- 首选口径：payload、record summary、search document、FTS、updatedAt 在同一 repository transaction 内提交。
- 如技术方案必须采用异步 reindex，PRD v1 必须定义 `saved-index-pending` / `reindex-failed` 或等价可见状态、恢复机制和验收口径。
- 保存失败时保留草稿，已保存事实源不得出现用户可见部分提交。

### P1-3 系统剪贴板不更新的低敏证据

问题：PRD v0 已写不更新系统剪贴板，但缺少可验收证据口径。

PRD v1 必须明确：

- 保存动作不得调用系统 pasteboard 写入路径。
- 验收使用 fake pasteboard、adapter spy、static call-site scan 或等价低敏证据，不读取真实系统剪贴板内容。
- P13D 或等价门禁需要输出 `pasteboard_write_attempts=0` 或等价字段。
- plain text、URL、富文本文本、OCR 文本四类保存都需要覆盖。

### P1-4 OCR 用户编辑文本与 retry 冲突策略

问题：OCR 文本可编辑，但用户保存后的 OCR 文本与后续 OCR retry / late completion 的冲突策略仍不够硬。

PRD v1 必须明确：

- Step 4 默认只允许 `ocrState == succeeded` 且已有 OCR 文本的图片记录编辑 OCR 文本。
- pending / running / failed 不提供普通文本编辑入口；failed 只保留失败和 retry 状态。
- done empty 必须明确是只读空态、允许手动新增，还是留待后续；不能留给实现自由发挥。
- 用户保存编辑后的 OCR 文本成为 user-edited / override / locked source 等价语义。
- OCR retry 或 late completion 不得静默覆盖 user-edited 文本；如允许覆盖，必须有确认或候选结果路径。
- P13D 需要覆盖 user-edited OCR 后 retry 不覆盖的低敏 fixture。

### P1-5 URL record kind、合法性和标准化

问题：URL 编辑规则已有方向，但技术方案需要更明确的 pass/fail。

PRD v1 必须明确：

- URL record 保存后仍保持 URL kind；Step 4 不支持 URL record 转 text record。
- URL 校验只做本地解析，不发网络请求，不验证远端可达性。
- 首版只接受 absolute URL，并保留 scheme。
- 不自动补 `https://`。
- `file:` URL 不作为 URL 文本编辑的普通成功路径；file URL 仍按文件本体不可编辑边界处理。
- 非法 URL 优先 inline validation 并阻止保存；若实现采用保存后校验失败，也必须停留 dirty 状态并保留草稿。
- 保存成功时 `urlString`、派生纯文本、URL tokens、summary 和 search document 必须同源。

### P1-6 Repository / read model / P13D 门禁

问题：PRD v0 将 P13D 写成建议，但 Step 4 修改核心剪贴板事实源，门禁必须成为进入开发前的硬要求。

PRD v1 必须明确：

- Step 4 技术方案必须提供 P13D 或等价 fail-closed verifier。
- 详情默认展示和元数据布局基于 bounded detail read model，不为布局一次性读取不必要大 payload。
- 完整 payload read、edit draft、save mutation 必须通过明确 purpose，例如 `detailEditRead`、`detailEditSave` 或等价命名；不得复用 hover / paste / copy / translation purpose。
- 编辑保存必须通过单一 Store / Repository command 或等价窄 API；View 不直接分散写 payload、summary、search document、FTS 或 OCR 状态。

## PRD v1 应吸收的 UI / 开发推荐口径

这些不是 P1，但产品经理应尽量吸收，减少技术方案分歧：

1. 首版默认阅读态 + 显式 `Edit` 入口；不默认直接编辑。
2. 编辑承载面应是稳定 detail editor / sheet / pane；hover preview 不默认承载 dirty state。
3. 固定底部 action bar；read-only / edit-clean / dirty / saving / failed 共用稳定布局位。
4. dirty-navigation 使用确认 sheet：Save and Continue / Discard Changes / Continue Editing。
5. 状态反馈分层：字段级错误靠近字段，事务状态固定在操作区，toast 只能补充。
6. 保存中禁止重复保存和并发切换；记录缺失、payload 缺失、保存冲突进入低敏错误状态，不静默丢 draft。
7. 编辑区 2 行默认 / 4 行上限按详情字体和 line height 计算；状态变化不改变编辑区高度。
8. 元数据常规宽度短项两列、长项单行；窄宽度降级为单列；长项提供 copy full value 或等价完整值路径。
9. 元数据默认展示 bounded metadata snapshot；完整正文、完整 URL、完整 file path、OCR 原文、rich text body 的展开 / 复制必须是显式动作。
10. 可访问性补键盘路径和 VoiceOver 验收：Edit、编辑区、Save、Cancel、错误反馈、dirty-navigation、metadata copy、OCR 状态。

## PRD v1 推荐新增 / 调整 fixture

保留 PRD v0 的 `detail_*_004` fixture，并补充：

- `detail_save_atomic_failure_004`：模拟 search document 或 FTS 写入失败，断言 payload / summary / updatedAt 不部分提交。
- `detail_record_missing_during_save_004`：编辑期间记录被删除或裁剪，断言进入 record unavailable / save failed，draft 不写入其他记录。
- `detail_ocr_user_edited_retry_004`：用户编辑 OCR 文本后 retry / late completion 不静默覆盖。
- `detail_rich_text_degrade_blocked_004`：富文本无法保真时必须有项目负责人降级接受记录，否则 fail。
- `detail_url_custom_scheme_004`：明确 custom scheme 是否允许；如不允许则 fail/pass 规则清楚。
- `detail_pasteboard_spy_004`：四类保存后系统剪贴板写入次数为 0。

## 不需要产品经理处理的内容

- 不需要在 PRD v1 写技术方案实现细节。
- 不需要决定最终数据库字段名、Swift type 名或 verifier 脚本名。
- 不需要启动 Step 5 / Step 6。
- 不需要解决 Step 3 真实 UI / VoiceOver P2 residual；只需不要把它写成已实测。

## 下一步

- 派发产品经理产出 `step_4/产品经理-PRD-v1.md`。
- PRD v1 落盘后，项目负责人先做复核。
- 如果 P1 全部关闭，再进入技术方案派发；否则继续 PRD 修订。
