# 004_剪贴板打磨 Step 4 开发 PRD 复审 v0

复审角色：开发

复审对象：
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-PRD预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-PRD派发-Step4-v0.md`

复审范围：仅 Step 4 详情编辑与元数据组织。不进入 Step 5/6，不做技术方案，不改业务代码，不触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

## 结论

结论：`approve-with-changes`

P0：0

P1：0

P2：7

开发视角判断：PRD v0 的范围控制整体可进入下一轮修订和技术方案拆解；编辑类型、状态流、保存/取消、系统剪贴板不回写、低敏 fixture 和 P13D 方向都已覆盖到关键问题。当前不需要退回重写。

但 PRD v1 进入技术方案前建议补清若干可执行边界，主要集中在编辑承载面、保存事务、富文本格式保真、OCR 用户编辑与重试的优先级，以及 metadata 是否允许读取完整 payload。这些问题不构成 PRD 阻断，但如果保持含糊，开发阶段容易扩大范围或返工。

## 当前可落地性判断

### SwiftUI / Store / Repository 落点

当前代码中 Clipboard 详情主要以 hover detail 卡片形式存在，`ClipboardFloatingDetailCard` 会通过 `ClipboardStore.readPayload(recordID:purpose: .hoverDetail)` 读取详情 payload，并以只读方式展示内容与元数据。Step 4 的 dirty、保存中、失败回滚和 dirty navigation 不适合直接挂在瞬时 hover 预览上。

建议 PRD v1 明确：Step 4 的编辑承载面必须是稳定详情编辑面，而不是普通 hover preview 本身。hover detail 可以继续只读，也可以提供进入编辑的显式入口；如果产品决定直接在 hover detail 内编辑，则必须同步定义 hover leave、re-enter、close、panel 切换时的 dirty navigation 行为。

Repository 层当前已有插入、payload 读取、search document / FTS 投影、redaction、OCR/search document 相关路径，但 PRD 所需的“编辑后同时更新 payload、derived plain text、visible summary、search document、FTS、updated time”的保存命令不是现成 facade。技术方案需要新增一个窄的 detail edit command，而不是让 View 分散调用 payload/search/record 多条 API。

推荐 PRD 口径：

> Step 4 编辑保存必须通过单一 detail edit save command 进入 Store/Repository；View 不直接拼接 payload、summary、search document、FTS 或 OCR 状态更新。保存成功后 UI 只消费保存结果和重新加载后的 bounded detail snapshot。

### 保存 / 取消 / Dirty Navigation

PRD v0 已列出 read-only、edit-clean、dirty、saving、success、failed、cancel、dirty-navigation，方向正确。建议补充三类边界，避免实现时临时做选择：

- 保存中禁止重复保存、取消、切换记录；如允许排队，需要 PRD 明确。
- 记录在编辑期间被删除、prune、外部刷新或 payload 不可用时，dirty navigation 使用“记录已不可用 / 保留草稿不可保存”的失败状态，而不是静默回列表。
- 保存失败后 draft 保留，错误低敏展示；再次保存应基于当前 draft，而不是重新读取旧 payload 覆盖用户输入。

推荐 PRD 口径：

> dirty-navigation 仅负责用户主动离开当前编辑面；repository unavailable、record missing、payload missing、save conflict 属于保存失败或记录不可用状态，必须保留低敏错误和可恢复动作，不自动丢弃 draft。

### 富文本编辑风险

PRD v0 已意识到“富文本编辑但不静默丢格式”的风险。开发视角看，这是 Step 4 最大实现风险：如果 rich text payload 当前只以 plain text 派生字段参与 search/preview，而保存时需要保留 attributes/attachments/link ranges，技术方案必须先确认存储格式和转换边界。

建议 PRD v1 把 rich text 写成 architecture-gated acceptance，不要既写成默认可编辑，又把保真留到开发时判断。

推荐 PRD 口径：

> 富文本编辑在技术方案确认可保留现有格式信息后进入 Step 4 实现；若无法保真，Step 4 仅允许编辑富文本的搜索/预览 plain text 派生副本，或将富文本编辑降级为只读，并由项目负责人单独确认。任何方案都不得静默把富文本 payload 降级成纯文本 payload。

### URL 编辑风险

URL 编辑可落地，但 PRD 应明确三点：

- 验证只做本地 URL 解析，不发网络请求。
- URL kind 不因编辑而改变；从 URL 记录不能保存成 plain text 记录。
- invalid URL save 不更新 payload、summary、search document、updated time。

推荐 PRD 口径：

> URL 编辑仅接受本地解析为 absolute URL 的字符串；保存不访问网络、不探测可达性、不自动改写 record kind。校验失败时不提交任何 repository mutation。

### OCR 文本编辑风险

PRD v0 对 image OCR done/pending/failed 有区分，方向正确。需要补充用户编辑文本与后续 OCR retry 的冲突规则，否则 Step 1C 的 OCR queue 可能覆盖用户修正结果。

推荐 PRD 口径：

> 用户编辑后的 OCR text 标记为 user-edited；默认优先级高于后续自动 OCR retry 结果。若用户从详情页主动发起重新识别，必须提示会覆盖当前用户编辑文本，确认后才可写入新 OCR 结果。

### Metadata 组织和低敏边界

两列短项、长项单行的规则可实现。需要补充 metadata 读取边界：metadata view 默认应使用 record/search/bounded snapshot，不为展示 metadata 而读取完整 payload。长 URL、file path、source title、OCR text、rich text body 等只在用户显式展开、复制或进入编辑时按 purpose 读取，且 evidence / verifier / 开发记录仍保持低敏。

推荐 PRD 口径：

> Metadata 默认展示 bounded metadata snapshot；完整正文、完整 URL、完整 file path、OCR 原文、rich text plain text 不进入默认 metadata 布局。复制或展开完整值必须是显式用户动作，并沿用既有 payload purpose / sanitizer 边界。

## 建议写入 PRD v1 的变更

1. 明确编辑承载面：稳定 detail editor / sheet / pane 承载 dirty state；hover preview 不默认承载编辑状态。

2. 明确 Store/Repository 保存入口：新增单一保存命令或等价 narrow API；禁止 View 分散写 payload、summary、search document、FTS、OCR 状态。

3. 明确保存原子性：payload、derived plain text、visible summary、search document、FTS、updated time 要么同事务成功，要么 rollback；若技术方案选择异步 search projection，PRD 必须允许并定义 pending-index 状态。

4. 明确 rich text fallback：保真可行才编辑原 rich text；不可行时降级必须经项目负责人确认，不允许静默转纯文本。

5. 明确 OCR user-edited 优先级：用户编辑 OCR text 后，自动 retry 不覆盖；主动 retry 覆盖需要确认。

6. 明确 URL 保存不发网络、不改 kind、不提交 invalid mutation。

7. 明确 metadata 读取不扩大 payload access；完整值展示/复制是显式动作，低敏 evidence 不输出真实正文、完整路径、OCR 原文或 URL 全文。

## P13D 门禁建议

建议新增独立 `P13D`，不要只沿用 P13A/P13B/P13C。理由是 Step 4 关注 detail edit/save/rollback/metadata，和 Step 1 search/OCR、Step 2 tag、Step 3 panel interaction 的验收维度不同。P13A/B/C 可作为回归辅助，不应替代 Step 4 acceptance。

P13D 最低断言建议：

- `current_evidence` 使用 Step 4 当前 PRD、开发记录、代码路径和低敏 fixtures；旧 story/archive 只能进入 `baseline_reference`。
- 详情编辑保存路径可追踪到单一 Store/Repository command。
- 默认 metadata/detail snapshot 不读取完整 payload；编辑/复制/展开使用显式 purpose。
- plain text 保存后 payload、summary、search document、FTS、updated time 一致。
- URL invalid save 不产生 mutation；URL valid save 不访问网络、不改 kind。
- rich text 不静默丢格式；若降级为只读或 plain derived edit，必须有当前决策文档证据。
- image OCR text edit 不修改图片 payload，不输出 OCR 原文，不被自动 retry 静默覆盖。
- 保存失败 rollback：payload、summary、search document、FTS、updated time 均保持旧值，draft 留在 UI。
- cancel / dirty navigation 不提交 mutation。
- editor 布局约束：默认 2 行、最多 4 行、内部滚动；不被列表字号设置影响。
- metadata 布局约束：短项两列、长项单行；长值不挤压编辑器。
- verification JSON/stdout/stderr 不包含真实正文、完整本地路径、OCR 原文、URL 全文、图片/base64、邮箱、secret。

低敏 fixture 建议保留 PRD v0 列表，并补充两个事务 fixture：

- `detail_save_atomic_failure_004`：模拟保存中 search document 写入失败，断言 payload/summary/updated time 不部分提交。
- `detail_record_missing_during_save_004`：模拟编辑期间记录被删除或 prune，断言进入 record unavailable/save failed，draft 不被写入新记录。

## 可后续优化

- Settings / DataAudit 中是否展示“最近编辑时间”不必在 Step 4 做，可留到 Step 5 或后续信息架构整理。
- 富文本全功能编辑器、附件级富文本编辑、图片标注、文件内容编辑、系统剪贴板同步都应保持非目标。
- OCR failed 状态是否允许用户手动录入 OCR text 是产品策略问题；当前 PRD 可以先保持不默认开放，技术方案仅保留扩展点。
- 真实 UI/VoiceOver 验收可以在开发后作为人工或低敏 evidence checklist，不应要求自动化读取真实剪贴板或真实屏幕文本。

## 是否需要回用户澄清

当前没有必须回用户澄清的 P0/P1。建议由项目负责人在 PRD v1 内部收敛以下口径即可：

- 编辑承载面是否明确不是 hover preview。
- rich text 不可保真时的降级策略。
- 用户编辑 OCR text 后是否默认阻止自动 OCR retry 覆盖。

如果项目负责人认为这三项属于产品体验承诺而非技术实现取舍，再统一向用户澄清。
