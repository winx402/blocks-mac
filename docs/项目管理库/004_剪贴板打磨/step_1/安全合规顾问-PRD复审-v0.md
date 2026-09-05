# Step 1 安全合规顾问 PRD 复审 v0

状态：role-review-complete
日期：2026-07-07
复审角色：安全合规顾问
复审对象：`产品经理-PRD-v0.md`
复审范围：Step 1 明文展示、搜索底座与系统 Vision OCR

## 结论

结论：`approve-with-changes`

Step 1 PRD 可以继续进入修订和技术方案准备，但进入开发前需要补强若干安全边界表达。当前 PRD 已正确限定 Step 1 不做标签、详情编辑、隐私页全量 App 管理、CLI 广义对象管理，也已明确 OCR 使用 macOS Vision、不做外部 provider OCR、不上传图片；这些方向成立。

需要修改的重点不是恢复 Step 4D 的默认 payload 保护，而是把“真实内容可访问，交互输出可控”写成可执行、可验收的边界，避免被实现方误读为后台静默外发、无限制日志/CLI 输出、外部 OCR 上传，或把真实凭据写进样例和验收记录。

## 已确认符合 Step 1 安全边界的内容

1. 阶段范围控制正确。
   - PRD 将 Step 1 限定为面板明文展示、搜索底座、系统 Vision OCR、设置页冲突 UI 移除和第一阶段输出边界。
   - 标签/收藏、详情编辑、隐私页真实 App 清单、CLI 广义对象管理、面板专项交互打磨都被列为非目标。

2. OCR provider 边界基本正确。
   - PRD 明确 OCR 使用 macOS 系统 Vision。
   - PRD 明确只处理剪贴板中已有图片 payload。
   - PRD 明确不做自研 OCR、不使用外部 provider OCR、不上传图片。

3. Provider / 自动化静默外发已有原则性限制。
   - PRD 写明不因面板打开、搜索或 OCR 索引而后台静默上传剪贴板图片或全文。
   - PRD 写明外发或系统状态变更需要明确用户动作或 agent 指令触发。

4. 验收样例低敏方向正确。
   - PRD 要求验收使用 synthetic / fixture 内容。
   - PRD 已禁止真实凭据、API key、Authorization header、provider secret、私钥、验证码进入日志样例、验收文档或仓库文件。

## 必须修改的问题

### 1. 日志正文片段不能只交给技术方案自由决定

当前 PRD 第 8.2 节写到：新增 OCR、搜索或索引日志时，优先记录状态、长度、类型、耗时、错误码和低歧义 id；“是否记录正文片段由技术方案按性能和可排查性决定”。

风险：

- 这容易被实现方理解为日志可以按调试方便写入真实剪贴板正文、URL、file path、OCR 文本或图片识别结果。
- 需求澄清虽然确认“内容保护整体取消”，但日志是落盘、复制、提交、粘贴到 issue 或验收记录的高扩散面，不能等同于 App 内交互明文展示。

PRD 需要改成可验收边界：

- 普通运行日志、verification JSON、开发记录、验收记录默认不写完整正文、完整 URL、完整 file path、完整 OCR 文本、图片 base64 或 provider request/response。
- 如技术方案确需正文片段用于本地调试，必须显式声明：仅本地 debug、长度上限、默认关闭或仅 fixture、不得进入仓库文档、不得进入 CI / 验收记录。
- 状态、长度、类型、耗时、错误码、hash / 短 id、队列状态可以作为默认日志字段。
- 凭据类内容继续绝对禁止：API key、Authorization header、provider secret、私钥、验证码不因“明文优先”而放开。

### 2. CLI 输出边界需要从原则改为最小规则

当前 PRD 第 8.3 节已写明 CLI 可以在明确命令下读取真实内容，长正文或批量结果应通过截断、分页、结构化字段或显式参数控制。这个方向正确，但进入开发前还需要把“明确命令”和“默认输出”写清楚。

风险：

- Step 1 不做 CLI 全量改造，但搜索底座或调试工具可能顺手接入 CLI。
- 若默认帮助、错误输出、批量搜索结果、调试 dump 直接输出全文，会污染 agent 上下文、shell scrollback、日志和验收记录。

PRD 需要补充：

- Step 1 若触及 CLI，默认列表、默认搜索、help、错误输出不得无限制打印大段 payload。
- 完整 payload 输出必须是显式命令或显式参数，例如 full / raw / limit / format 这类语义清晰的开关；具体命名由技术方案决定。
- 批量输出必须有 limit、分页、截断或结构化字段边界。
- CLI 输出样例只能使用 synthetic / fixture 内容，不使用真实用户剪贴板。

### 3. OCR 权限与数据流需要写成硬边界

当前 PRD 明确不上传图片、不接外部 OCR provider，但还需要补充权限和数据流边界，避免实现时把 OCR 与截图、屏幕读取或外部图片处理混在一起。

PRD 需要补充：

- Step 1 OCR 只处理已经进入剪贴板历史的图片 payload，不新增 ScreenCaptureKit、屏幕录制权限、Accessibility 权限、Automation 权限、Full Disk Access、TCC reset 或系统设置跳转。
- OCR 队列不得扫描本地文件系统图片，也不得根据 file URL 自动读取文件本体做 OCR；file URL 搜索在 Step 1 只要求文件名或路径摘要。
- OCR 文本进入搜索索引后，应适用同一输出控制边界：可以用于 App 内搜索命中和图片条目状态展示，但不默认进入普通日志、verification JSON 或 provider 外发。
- OCR 失败详情应记录错误类别、状态、耗时或图片尺寸等低敏字段，不记录图片内容、base64 或识别出的长文本。

### 4. Provider / 自动化边界需要保留为 Step 1 验收项

当前 PRD 第 8.4 和第 9.5 已有“不会因为面板打开、搜索或 OCR 索引而静默接收剪贴板全文或图片”的表达，建议把它保持为硬验收，而不是只作为说明文字。

PRD 需要明确：

- Step 1 不新增 provider call、外部 OCR、图片上传、多模态 provider 分析、自动化执行器、shell / AppleScript / CGEvent / Accessibility 操作路径。
- 面板打开、搜索输入、OCR 入队、OCR 完成、OCR 失败重试都不得触发 provider 或自动化外发。
- 若技术实现中已有 provider / agent route 相关代码，Step 1 不应绕过既有 gate 或 runtime policy。

### 5. 验收证据需要明确低敏保存范围

PRD 已要求 synthetic / fixture 内容，但建议进一步写清验收证据边界。

PRD 需要补充：

- 截图、录屏、verification JSON、开发记录和验收记录只使用 fixture 内容。
- OCR fixture 可以包含短 token，例如 `VISION-004`，但不得使用真实身份证件、账单、聊天记录、邮件、网页 cookie、二维码、验证码或密钥截图。
- 如果为了手工体验临时使用真实剪贴板，验收记录只能写行为结果，不保存真实内容截图或正文。

## 可接受残余风险

1. App 内面板默认明文展示真实内容。
   - 这是用户已确认的产品方向，属于本项目显式风险接受。
   - Step 1 不需要恢复遮挡或默认 metadata-only 展示。

2. 搜索索引会保存或派生可搜索文本，包括 OCR 文本。
   - 这是“搜得到内容”的必要条件。
   - 可接受前提是索引生命周期、删除、裁剪和失败重试由技术方案处理，并且日志/验收输出不默认 dump 索引全文。

3. 长文本摘要、截断、多行预览会展示部分真实内容。
   - 这是明文展示目标的一部分。
   - Step 1 只需保证交互可读和性能可控，不需要设计复杂权限开关或过滤规则。

4. OCR 准确率和语言覆盖存在不确定性。
   - PRD 已把语言支持交给 App 架构师基于 macOS Vision 能力确认。
   - 这不阻塞 PRD，但验收样例应使用可稳定识别的 fixture。

5. CLI、provider、自动化的完整产品设计留到后续阶段。
   - Step 1 只需写清不会因明文展示、搜索或 OCR 自动扩大外发和自动化执行面。
   - Step 5 / Step 6 仍需继续补完整 CLI 广义对象管理和集成回扫。

## 不建议纳入 Step 1 的内容

为避免范围膨胀，安全合规不建议把以下内容塞回 Step 1：

- 标签、收藏、标签搜索字段和标签管理。
- 详情编辑、OCR 文本编辑、保存/取消、富文本编辑。
- 隐私页真实 App 全量清单和 CLI 广义对象管理。
- 任意系统自动化执行器、权限请求中心、复杂隐私开关或全局过滤策略。
- 外部 OCR provider、多模态图片分析、provider 上传确认流。

## 建议给项目负责人的回写摘要

建议项目负责人要求产品经理在 PRD v0 中补强日志、CLI、OCR 权限/数据流、provider/自动化验收和低敏验收证据边界。补齐后，安全合规可接受 Step 1 进入技术方案；当前无 `reject` 级问题。
