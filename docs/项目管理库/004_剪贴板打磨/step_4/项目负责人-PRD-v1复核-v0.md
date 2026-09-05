# 004_剪贴板打磨 Step 4 PRD v1 复核 v0

## 结论

结论：`prd-accepted`。

产品经理已产出 `step_4/产品经理-PRD-v1.md`。项目负责人复核认为：PRD v1 已吸收 PRD 复审收敛中的 P1，Step 4 阶段范围清楚，验收口径足以进入技术方案阶段。

不需要回用户澄清。

## P1 关闭判断

### 富文本格式保留与降级口径

状态：关闭。

PRD v1 已明确：

- 富文本编辑首选保持 `rich_text` kind 和用户可见格式。
- 链接、段落 / 换行、基础 inline style、列表代表项进入最低格式保留验证范围。
- 无法保真时不得作为普通可编辑类型直接开发，必须有项目负责人接受降级、暂缓或只读。
- P13D 需要证明未静默丢格式或存在当前接受记录。

### 保存事务与索引失败一致性

状态：关闭。

PRD v1 已明确：

- Step 4 保存是用户级单一 mutation。
- 保存成功后 payload / 派生字段、detail read model、summary、search document、FTS、updatedAt 进入同一版本语义。
- 首选同一 repository transaction；如异步 reindex，必须定义 `saved-index-pending` / `reindex-failed` 状态和恢复路径。
- 保存失败保留草稿，不产生用户可见部分提交。

### 系统剪贴板不更新证据

状态：关闭。

PRD v1 已明确：

- 保存动作不得调用系统 pasteboard 写入路径。
- 使用 fake pasteboard、adapter spy、static scan 或等价低敏 instrumentation。
- P13D 输出 `pasteboard_write_attempts=0` 或等价字段，并覆盖四类保存。
- 不读取 / 不写真实系统剪贴板。

### OCR 用户编辑与 retry 冲突

状态：关闭。

PRD v1 已明确：

- 仅 `succeeded with text` 默认可编辑。
- pending / running / failed / succeeded empty 均不提供普通编辑入口。
- 用户保存后的 OCR 文本成为 user-edited / override / locked source 等价语义。
- retry / late completion 不得静默覆盖 user-edited 文本。
- P13D 覆盖 `detail_ocr_user_edited_retry_004`。

### URL kind、合法性和标准化

状态：关闭。

PRD v1 已明确：

- URL 编辑不改变 record kind。
- 只做本地解析，不发网络请求。
- 首版只接受 absolute URL，保留 scheme，不自动补 `https://`。
- `http`、`https`、`mailto` 为默认成功路径；custom scheme 需 allowlist / denylist 和项目负责人接受。
- `file:` URL 不作为普通 URL 编辑成功路径。
- 非法 URL inline validation 阻止保存或失败后保留 dirty 草稿。

### Repository / bounded read model / P13D

状态：关闭。

PRD v1 已明确：

- 技术方案必须提供 bounded detail read model。
- 默认详情和元数据布局不为展示读取不必要大 payload。
- 完整 payload read、edit draft、save mutation 使用明确 purpose，不复用 hover / paste / copy / translation / provider purpose。
- 保存通过单一 Store / Repository command 或等价窄 API。
- P13D 是进入开发前硬门禁，不再是建议。

## 接受边界

PRD v1 已接受，但不代表以下事项已经技术闭合：

- 富文本格式保留能力。
- 同事务或异步 reindex 的具体实现方式。
- OCR user-edited 标记的模型位置。
- fake pasteboard / adapter spy 的具体实现。
- P13D 的脚本结构。

这些必须在 Step 4 技术方案中回答。

## 下一步

- 派发 App 架构师产出 `step_4/App架构师-技术方案-v0.md`。
- 技术方案不得扩大到 Step 5 / Step 6。
- 技术方案完成后，项目负责人先做预审，再决定角色复审范围。
