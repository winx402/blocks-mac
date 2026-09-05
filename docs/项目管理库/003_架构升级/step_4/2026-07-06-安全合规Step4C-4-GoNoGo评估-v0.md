# Step 4C-4 Clipboard hardening 启动前安全合规 Go/No-Go 评估 v0

## 结论

- 结论：`go-for-4c4-development`
- 口径：允许 conditional Step 4C-4 留在 Step 4C 进入开发，但必须作为独立安全切片处理；本结论不是 4C-4 验收通过。
- 进入开发前 P0：0
- 进入开发前 P1：0
- 进入开发前 P2：2

判断理由：PRD 已把 Clipboard hardening 定义为 conditional 4C-4，并给出完整 payload allowlist / denylist、UX contract 和 P11E 最低清单。当前代码风险点集中在 `ClipboardStore` read model、Clipboard panel list/card/detail preview 和 verifier 事实源，边界可以在一个独立子批次内闭合；暂不需要直接拆 Step 4D。若开发中发现 P11E、payload read model、UX contract 或低敏输出无法 fail-closed，则必须立即停止 4C-4，拆为 Step 4D 并写 handoff record。

本评估未触发真实剪贴板读取、权限请求、系统设置、provider call、Keychain、网络或 TCC 操作。

## 事实依据

1. Step 4C PRD 已定义 4C-4 为 conditional。
   - 进入 4C-4 前必须完成 go/no-go；若 P11E、payload allowlist / denylist、UX contract 或安全/质量门禁无法闭合，则拆 Step 4D。
   - PRD 明确默认列表、普通面板渲染、Settings summary、CLI 默认输出禁止读取完整 payload。
   - PRD 明确 paste、copy、hover detail、translation preview 可作为完整 payload allowlist，但必须是明确用户动作或明确业务用例。

2. 最新 Stop/Go 只接受 Step 4C-3，不接受 4C-4。
   - `主会Stop-Go-Step4C-3-SettingsShell-v0.md` 明确 4C-4 未启动，允许进入 go/no-go 评估。
   - 当前基线提交为 `10d7766 feat: complete step 4c settings shell slice`，工作区在评估前无未提交改动。

3. 当前代码存在 4C-4 必须修复的 payload read model 缺口。
   - `ClipboardStore.loadRepositoryState(limit:)` 当前在加载 recent records 后调用 `loadPayloads(for:repository:)`，并循环 `repository.readPayload(recordID:)`。
   - `AppState.clipboardPayload(for:)` 直接返回 `clipboardStore.payload(for:)`。
   - `ClipboardFloatingPanelView` 的 bottom tray、普通 record list、hover overlay 构建路径会对每条 record 传入 `appState.clipboardPayload(for: record.id)`。
   - `ClipboardRecordPreview` 当前会使用 payload text/url/fileURL/base64 生成默认 preview；`ClipboardDirectContentPreview` 会优先显示 `payload?.text` 或 `payload?.urlString`。
   - 这些现状与 Step 4C-4 目标冲突，必须在 4C-4 开发中关闭。

4. 当前 CLI 默认输出未发现 clipboard payload 入口。
   - `apps/Blocks/BlocksCLI/main.swift` 当前只暴露 `blocks.screenshot.capture` 相关 list/run/help。
   - 4C-4 不得新增 CLI 默认读取完整 clipboard payload。

5. 当前没有 `p11e_clipboard_hardening_checks.py`。
   - 这是 4C-4 第一优先级交付物，不是接受后补项。
   - 旧 P7L 等 verifier 仍有检查“preview uses real payload / panel passes payload”的历史事实；4C-4 必须迁移这些旧断言，不能让旧 verifier 继续要求不安全行为。

## 是否留在 Step 4C

可以留在 Step 4C，条件如下：

1. 4C-4 只处理 Clipboard hardening，不顺手开启 helper 生产写库、App Group、CLI 完整 payload、OCR、provider call、网络外发、Keychain 或任意自动化能力。
2. 开发顺序必须先建 P11E，并让它在当前基线下红灯暴露默认 payload 预读 / 普通渲染读取问题，再修代码到绿灯。
3. 4C-4 接受前必须同时有开发记录、安全复审、测试/质量验收和主会 stop/go；P11E 不得缺席。
4. 若默认 read model 需要大范围重构、无法在本切片稳定验证、或必须推翻 PRD allowlist / denylist，立即拆 Step 4D。

## 4C-4 必须关闭的验收阻断项

这些不是启动前 no-go，但任何一项在 4C-4 结束时未关闭，都应作为 P1 阻断验收。

### P1-A 默认加载不得预读完整 payload

- `loadRepositoryState(limit:)` 不得对 recent records 批量调用 `repository.readPayload(recordID:)`。
- `ClipboardStore` 默认状态应加载 records、pinboards、pinned metadata、repository availability、format summary、source、timestamp、pin state、redacted preview 等低敏数据。
- 完整 payload 读取必须经过显式 purpose / use case，而不是从 `payloads` 全局缓存隐式取。

### P1-B 默认列表 / 普通面板渲染不得接收或显示完整 payload

- `ClipboardFloatingPanelView` bottom tray 和普通 list 不得向 record card / row 传入 `ClipboardRecorderPayload`。
- `ClipboardFloatingRecordCard` / `ClipboardFloatingRecordRow` 默认展示只能使用 metadata-first preview。
- `ClipboardContentThumbnail` 默认不得从 image base64 构造真实图片缩略图；图片类只能展示类型、尺寸、字节数或 redacted image placeholder。
- `ClipboardDirectContentPreview` 不得在默认 card/list 路径显示 `payload?.text`、`payload?.urlString` 或 base64 解码图片。

### P1-C hover detail 必须是 lazy explicit read

- hover detail 可以属于 allowlist，但必须在某条 record 实际进入 hover detail 时按目的读取。
- 不得像当前 overlay 一样为所有 filtered records 预先构造带 payload 的 `itemsByID`。
- hover detail 输出和验收证据只能记录 read purpose、record id 类低敏标识、kind、length/byte count、truncated/redacted 状态，不得写正文、URL 全文、file path 全文或 image base64。

### P1-D paste / copy / translation preview allowlist 必须显式化

- paste、copy plain text、record translation preview 仍可读取完整 payload，但必须通过显式 API，例如 `readPayload(recordID:purpose:)` 或等价枚举。
- 允许 purpose 建议限定为：`paste`、`copyPlainText`、`hoverDetail`、`translationPreview`。
- 新增 purpose 必须先更新 PRD/开发记录、P11E 和验收矩阵。
- 用户主动 copy / paste 的既有行为不得被误判为日志或默认展示，但执行前后只记录低敏状态。

### P1-E Settings / DataAudit / AgentCLI / CLI 默认输出不得读取完整 payload

- Settings summary 只能展示 count、policy、pinboard count、repository degraded/read model 状态。
- DataAudit 只能展示索引、计数、低敏状态，不展示正文。
- Agent/CLI 默认输出不得读取或返回完整 payload；如未来设计完整 payload agent access，必须另开独立安全切片和显式授权 gate。

### P1-F P11E 必须 fail-closed

P11E 至少检查：

- 当前事实源：PRD、4C-4 开发记录、当前代码；旧 story/archive/acceptance 只能作为 `baseline_reference`，不得参与 `ok`。
- 默认 denylist 路径不得出现 `clipboardPayload(for:)`、`readPayload(recordID:)`、`ClipboardRecorderPayload?`、`payload?.text`、`payload?.urlString`、`pngDataBase64`、`Data(base64Encoded:)`、`previewImage(payload:)`。
- 允许完整 payload 的路径必须有显式 purpose，并只落在 paste/copy/hover detail/translation preview。
- 输出必须包含 read model allowlist / denylist 摘要，不能只输出 PASS/FAIL。
- 输出不得包含剪贴板正文、URL 全文、file path 全文、图片/base64、OCR 原文、窗口标题、屏幕文本、真实凭据、Authorization header、request body 或 provider raw response。
- P11E 本身不得触发真实剪贴板读取；必须使用静态检查或 fixture。

## 安全审计与低敏输出规则

4C-4 开发记录、verification JSON、验收记录和审计输出只能记录：

- read purpose：`defaultListDenied`、`settingsDenied`、`cliDefaultDenied`、`pasteAllowed`、`copyAllowed`、`hoverDetailAllowed`、`translationPreviewAllowed` 等。
- record id 类低敏标识：建议 hash / fixture id / synthetic id，不写真实剪贴板正文。
- kind、source app bundle id、timestamp bucket、text length、byte count、truncated、redacted、repository availability、state transition。
- PASS/FAIL、失败代码、相对文件路径、sanitized command。

禁止记录：

- 剪贴板正文、选中文本正文、URL 全文、file path 全文。
- 图片/base64、OCR 原文、窗口标题、屏幕文本。
- 真实凭据、Authorization header、request body、provider raw response。
- 真实用户主目录或完整本地路径。

## P0 / P1 / P2

### 进入开发前 P0

- 无。

### 进入开发前 P1

- 无。当前默认 payload 预读和普通渲染读取是 4C-4 的目标缺口；只要按本文 P11E-first 和 read model 边界开发，不构成启动前阻断。

### 4C-4 验收 P1

- P1-A 到 P1-F 任一项未关闭，都应阻断 4C-4 接受。
- 若 P11E 缺失、只输出 PASS/FAIL、未覆盖 denylist / allowlist，或旧 verifier 继续要求默认真实 payload preview，应阻断接受。

### P2

1. Translation panel 打开时读取当前 pasteboard 文本是既有即时剪贴板读取路径，不等同于 repository 默认列表 payload；4C-4 应在文档中分开说明，避免混淆。
2. 若 hover detail 改成 lazy read，真实 hover 交互、延迟、退出清理和可访问性反馈需要测试/质量补低敏实物验收。

## 建议开发边界

建议 4C-4 开发任务按以下顺序执行：

1. 新增 `tools/verification/p11e_clipboard_hardening_checks.py`，先在当前基线红灯。
2. 引入 metadata-first preview / redacted preview 与 explicit payload read purpose。
3. 移除 `loadRepositoryState` 默认批量 payload 读取。
4. 改造 Clipboard panel 默认 row/card/list/tray/search/Settings/DataAudit/CLI 为 denylist 路径。
5. 对 paste/copy/hover detail/translation preview 走 allowlist API，并确保日志和验收输出低敏。
6. 迁移 P7L/P8I/P4/P9 等相关 verifier，避免旧门禁继续断言“默认 preview 使用真实 payload”。
7. 最终运行 P11E、相关 clipboard verifier、`git diff --check`，并由安全和测试/质量分别复审。

## No-Go 触发条件

开发中出现任一情况，应停止 4C-4 并拆 Step 4D：

- 需要开启 helper 生产写库、App Group、CLI 默认完整 payload、provider call、OCR、网络或 Keychain 才能完成目标。
- 无法让默认列表 / 普通面板 / Settings / CLI 默认输出从完整 payload 中解耦。
- P11E 无法对 denylist / allowlist fail-closed。
- 验收证据不可避免会包含真实剪贴板正文、URL 全文、file path 全文、图片/base64 或其他敏感内容。
