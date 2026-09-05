# Step 4B PermissionStore 单切片 PRD v0

状态：accepted
日期：2026-07-05
来源级别：product and architecture implementation plan

> 本文是 Step 4B 的独立 PRD / 实施方案。App 架构师、安全合规、测试/质量、UI/交互方案复审均已完成；开发、测试/质量补充复验、App 架构师实现复审、安全合规实现复审和主 agent 最终接受均已完成。

## 0. 决策摘要

Step 4B 选择 `PermissionStore` 单切片，不与 `ScreenshotStore`、`ShortcutStore`、Settings shell 或 Clipboard hardening 同批开发。

选择理由：

- Permission 是 Screenshot、Clipboard auto-paste retry 和 Settings permissions pane 的共同输入，先抽出能降低后续 feature store 对 `AppState` 的依赖。
- 单独迁移权限状态与权限辅助，比同时迁移 Screenshot Result、AI route preview 和 ScreenCaptureKit 结果展示风险更小。
- Step 4 预审中 UI、测试、安全、架构均要求补齐 Permission Assist、权限设置和实物证据边界；先做 PermissionStore 能把这些门槛变成可执行切片。

本切片完成后，`AppState` 仍可作为 AppShell / coordinator 保留 facade 和跨 feature 编排，但不再直接持有 `permissionSnapshot` 事实源。

## 1. 背景与事实基线

Step 3 已完成开发、测试/质量独立验收、App 架构师最终实现复审和主 agent 最终接受。Step 4 预初始化的四份预审均为 `approve-with-changes`，相关必改项已回写 `PRD-Feature模块迁移预初始化-v0.md`。

Step 3 accepted 后的权限相关事实：

- `apps/Blocks/BlocksApp/Stores/AppState.swift` 当前 1921 行，仍直接声明 `@Published var permissionSnapshot: PermissionStateSnapshot = PermissionStateService.snapshot()`。
- `AppState.refreshPermissionState()` 当前直接调用 `PermissionStateService.snapshot()`，随后调用 `retryPendingClipboardPasteIfPossible()`。
- `AppState.requestScreenRecordingPermissionAssist()` 和 `requestAccessibilityPermissionAssist()` 当前直接触发系统权限请求，再调用 `PermissionAssistPanelPresenter.present(...)`。
- `AppState.openScreenRecordingSettings()`、`revealCurrentAppInFinder()`、`restartForPermissionRefresh()` 当前直接调用 `NSWorkspace` / `NSApp`。
- `SettingsView.permissionsSettingsContent` 读取 `appState.permissionSnapshot`，并通过 `appState` 调用 refresh、restart、request assist、Show in Finder。
- `ScreenshotHomeView` 仍通过 `appState.openScreenRecordingSettings()` 暴露 Screen Recording 设置入口。
- `PermissionStateService`、`PermissionStateSnapshot`、`PermissionDiagnosticSnapshot` 目前位于 `apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift`，该文件约 799 行。

以上是本 PRD 的当前事实，不代表这些结构已经合理完成。

## 2. 用户目标

用户需要：

- 在 Settings 的 Permissions 区域继续清楚看到 Screen Recording 和 Accessibility 的授权、签名、bundle ID、app path、推荐动作和刷新状态。
- 只有在点击明确按钮时，App 才请求权限、打开系统设置、Show in Finder 或重启 App。
- 截图入口在缺少 Screen Recording 权限时继续给出可理解提示和辅助路径。
- Clipboard auto-paste 因 Accessibility 缺失而等待时，授权后刷新仍能触发既有重试逻辑。
- 权限辅助面板继续保留拖拽 / Show in Finder / restart / refresh / 手动 fallback，不因为架构迁移被削弱。

开发和后续 agent 需要：

- 一个稳定的 `PermissionStore` 作为权限状态事实源。
- 一组窄接口包住系统权限读取、系统动作和辅助面板展示。
- 明确知道权限 store 不负责 Clipboard retry、Screenshot capture、Shortcut 注册或 Settings shell 路由。

## 3. 范围

### 3.1 新增文件

必须新增：

- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift`

允许按需要新增，但不得扩大行为范围：

- `apps/Blocks/BlocksApp/Features/Permissions/PermissionReadable.swift`
- `apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPresenting.swift`
- `apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift`
- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStateSnapshot.swift`

如果移动 `PermissionStateSnapshot` / `PermissionDiagnosticSnapshot` 等纯类型，必须保持字段和语义不变，并避免顺手重写 `PermissionAssistPanelPresenter` 的状态机。

### 3.2 PermissionStore 职责

`PermissionStore` 必须承担：

- `permissionSnapshot` 的唯一事实源。
- `refreshPermissionState()` 对应的权限 snapshot 刷新能力。
- `requestScreenRecordingPermissionAssist(...)` 对应的用户触发式 Screen Recording 请求与辅助面板展示。
- `requestAccessibilityPermissionAssist(...)` 对应的用户触发式 Accessibility 请求与辅助面板展示。
- `openScreenRecordingSettings()` 对应的用户触发式系统设置跳转。
- `revealCurrentAppInFinder()` 对应的用户触发式手动 fallback。
- `restartForPermissionRefresh()` 对应的用户触发式重启确认动作。

`PermissionStore` 必须是主线程可观察 store，并加入 Blocks app target。

### 3.3 窄接口建议

实现可以使用 protocol 或 closure，但必须表达以下边界：

```swift
protocol PermissionSnapshotProviding {
    func snapshot() -> PermissionStateSnapshot
}

protocol PermissionAccessRequesting {
    @discardableResult func requestScreenRecordingAccess() -> Bool
    @discardableResult func requestAccessibilityAccess() -> Bool
}

protocol PermissionAssistPresenting {
    func present(kind: PermissionAssistKind, onRefresh: @escaping () -> Void)
}

protocol PermissionSystemActioning {
    func openScreenRecordingSettings()
    func revealCurrentAppInFinder()
    func restartForPermissionRefresh()
}
```

命名不强制一致，但职责必须等价。系统 API 调用可以保留在现有 `PermissionStateService`、`PermissionAssistPanelPresenter` 或新的窄 platform adapter 中；普通 View、Settings pane 和 `PermissionStore` 不应散落敏感系统 API 调用。

### 3.4 AppState facade

`AppState` 必须改为持有 `PermissionStore`，并绑定 `objectWillChange`。

`AppState` 应继续保留现有 public facade，保护 View 层和现有调用点：

- `permissionSnapshot`
- `refreshPermissionState()`
- `openScreenRecordingSettings()`
- `revealCurrentAppInFinder()`
- `restartForPermissionRefresh()`
- `requestScreenRecordingPermissionAssist()`
- `requestAccessibilityPermissionAssist()`

其中 `permissionSnapshot` 应为 computed facade，不再是 `@Published` 事实源。

`refreshPermissionState()` facade 必须继续在刷新权限后调用 `retryPendingClipboardPasteIfPossible()`。`PermissionStore` 本身不得直接执行 Clipboard retry。

权限 assist 的 refresh callback 也必须保留 Clipboard retry 语义：可以由 `PermissionStore` 支持 `afterRefresh` closure，或由 `AppState` facade 在 store refresh 后调用 retry；但不能把 Clipboard retry 搬进 PermissionStore。

### 3.5 View 层策略

本切片默认不要求大改 `SettingsView` 或 `ScreenshotHomeView`。

允许的低风险路径：

- Settings 和 Screenshot Home 继续通过 `AppState` facade 调用权限能力。
- 如有必要，可以把局部只读数据改为显式传入 `PermissionStateSnapshot`，但不得引入 Settings shell 拆分。
- 不新增或改名 setting key。
- 不改变 `SettingsViewMode` 路由。
- 不改变 `clipboardPrivacy` 返回语义。

## 4. 非目标

本切片不做：

- 不创建 `ScreenshotStore`。
- 不创建 `ShortcutStore`。
- 不拆完整 Settings shell。
- 不做 Clipboard hardening、redacted list 或 lazy payload。
- 不重写 `PermissionAssistPanelPresenter` 的完整体验和状态机。
- 不改变 TCC、签名、bundle ID、entitlement、Info.plist 权限描述或分发策略。
- 不新增真实 OCR、截图图片上传、provider call、外部 CLI provider 或 agent 自动化。
- 不新增读取前台 UI 内容、抓取选中文本、发送键鼠事件、AppleScript 或任意 shell 执行能力。
- 不保存、读取或输出真实敏感凭据。

## 5. 体验契约

### 5.1 Settings Permissions

必须保持：

- Screen Recording 和 Accessibility 两条诊断仍同时可见。
- 每条诊断保留授权状态、bundle ID、app path、签名类型、team ID、usage description、recommended action、matching running app path 和 identity issue。
- Refresh / Completed 按钮继续刷新当前状态。
- Screen Recording 需要重启时继续显示 restart 入口。
- Request Screen Recording、Request Accessibility、Show in Finder 均由用户点击触发。
- 未授权或无法验证时，不得在 UI 中写成已授权。

### 5.2 Permission Assist

必须保持：

- 请求权限与诊断、后续动作同屏可理解。
- Screen Recording 和 Accessibility 的辅助入口仍区分清楚。
- 辅助窗口等待、拖拽隔离、关闭条件、刷新检查、失败 / 超时 / 取消语义不丢失。
- 手动 fallback 仍存在：Show in Finder、拖拽 app、打开系统设置、重启 App。
- 已授权状态下不能继续误导用户重复请求。

### 5.3 Screenshot 与 Clipboard 依赖

必须保持：

- `startScreenshot(mode:)` 在截图前仍刷新权限并检查 Screen Recording。
- 缺少 Screen Recording 时仍设置 `permissionMissing` 状态并展示辅助路径。
- Screenshot Home 的 Screen Recording Settings 入口仍可用。
- Clipboard auto-paste 因 Accessibility 缺失进入 pending 后，授权并刷新仍可触发既有 retry。

## 6. 安全与隐私边界

所有权限动作必须由用户明确动作触发。不得在 View 初始化、store 初始化、`onAppear`、定时器或后台刷新中静默请求权限、打开系统设置、Show in Finder 或重启 App。

`PermissionStore.swift` 和新增 permission feature 文件不得直接出现以下 token，除非该文件是明确的 platform adapter，且 P11B 对它做白名单解释：

```text
URLSession
SecItem
Authorization
Bearer
Process(
getenv(
NSAppleScript
SCShareableContent.current
SCScreenshotManager
SCContentFilter
CGWindowListCopyWindowInfo
NSPasteboard.general
CGEvent
CGEventPost
AXUIElement
RegisterEventHotKey
UnregisterEventHotKey
```

`AXIsProcessTrustedWithOptions`、`CGRequestScreenCaptureAccess`、`SecStaticCodeCreateWithPath`、`SecCodeCopySigningInformation` 只能存在于 `PermissionStateService` 或明确命名的 permission platform adapter 中，不得散落到 View 或 Settings pane。

以下系统动作 token 只能存在于明确命名的 system action adapter、既有 permission presenter / service，或经过 P11B 白名单解释的单一文件中；不得出现在 `PermissionStore`、普通 View、初始化路径、`onAppear`、timer、`objectWillChange` 绑定或 refresh callback 中：

```text
NSWorkspace.shared.open
NSWorkspace.shared.activateFileViewerSelecting
NSWorkspace.shared.openApplication
NSApp.terminate
```

P11B 必须验证这些系统动作只来自用户明确动作。允许的例外只有用户触发 clipboard paste 后因 Accessibility 缺失进入的辅助流程；该例外仍不得自动打开系统设置、Show in Finder 或重启 App。

开发记录、测试 JSON、audit 和验收记录禁止输出：

- 真实用户主目录、完整本地文件路径、完整窗口标题、屏幕文本、选中文本、剪贴板正文。
- 真实 API key、secret hash、Authorization header、完整 request body、provider raw response。
- 真实截图图片、base64、OCR 原文或任何图片内容。

权限验收记录只允许记录：

- 权限枚举状态、触发入口、是否用户动作、bundle ID 是否存在、签名类型枚举、team ID 是否存在、错误码、门禁命令结果、低敏截图或文字描述。

## 7. 验证门禁

### 7.1 新增 P11B 专项门禁

新增：

```bash
python3 tools/verification/p11b_permission_store_checks.py
```

P11B 执行入口统一为 `tools/verification/p11b_permission_store_checks.py`。不得使用旧脚本名、临时脚本或只在开发记录中口头替代。

P11B 必须 fail closed：

- 脚本不存在或不可执行时失败。
- Blocks app target membership 无法解析时失败。
- 预期文件路径缺失时失败。
- 发现旧脚本名、旧验收记录路径、旧归档路径或旧 `AppState` 直接字段字符串仍被当作事实源时失败。
- 任一检查项因解析失败被跳过且没有明确低风险解释时失败。

P11B 输出必须包含已检查文件路径、target membership 事实源、规则命中 / 未命中摘要和失败原因。

P11B 必须检查：

- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift` 存在并加入 Blocks app target。
- `PermissionStore` 是主线程可观察 store。
- `AppState` 持有 `PermissionStore` 并绑定 `objectWillChange`。
- `AppState` 不再直接声明 `@Published var permissionSnapshot`。
- `AppState.permissionSnapshot` 仍作为 computed facade 存在。
- `AppState` 仍保留第 3.4 节列出的 public facade 方法。
- `AppState.refreshPermissionState()` 刷新 store 后仍调用 `retryPendingClipboardPasteIfPossible()`。
- `PermissionStore` 文件不包含 Clipboard retry、`pendingClipboardPasteRecordID`、`NSPasteboard.general` 或 Clipboard 业务 token。
- `PermissionStore` 不持有完整 `AppState`。
- `PermissionStore` 不持有 `ProviderStore`、`TranslationStore`、`ScreenshotStore` 或 `ShortcutStore`。
- `SettingsView` 和 `ScreenshotHomeView` 不直接调用第 6 节禁止的敏感系统 API。
- 新 permission feature 文件不包含未白名单的敏感 API token。
- 若移动 permission snapshot 类型，字段语义不缺失。
- `PermissionStore.init`、View `onAppear`、timer、background refresh、permission assist refresh callback、`objectWillChange` 绑定路径中不会调用 request access、open settings、Show in Finder 或 restart。
- `NSWorkspace.shared.open`、`NSWorkspace.shared.activateFileViewerSelecting`、`NSWorkspace.shared.openApplication`、`NSApp.terminate` 只存在于明确白名单的 system action adapter 或既有 presenter / service 中。
- 如果引入 `PermissionSystemActioning`，它是唯一可触达 `NSWorkspace` / `NSApp.terminate` 的系统动作接口。
- 如果引入 `PermissionAssistPresenting.present(...)` 的触发来源参数，应只记录低敏枚举，例如 `userAction` 或 `clipboardPasteUserFlow`，不记录 app path、窗口标题或用户文本。

### 7.2 当前切片阻断门禁

开发完成后必须运行并记录：

```bash
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p7e_permission_assist_flow_checks.py
python3 tools/verification/p7f_permission_state_refresh_checks.py
python3 tools/verification/p7f_permission_assist_position_drag_checks.py
python3 tools/verification/p7g_permission_settings_interaction_checks.py
python3 tools/verification/p7k_permission_identity_gate_checks.py
python3 tools/verification/p7r_permission_assist_ux_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

作为 Step 4B 阻断门禁的旧 P7 / P10 脚本必须先确认事实源仍然有效：若脚本仍依赖旧验收记录、旧路径、旧归档或 `AppState` 直接声明旧字段字符串，必须更新后才能作为阻断门禁；否则只能在开发记录中标为 baseline 辅助证据，不得写成 Step 4B acceptance gate。

`p10b_core_state_split_checks.py` 在本切片中是 Step 3 regression guard，不是 PermissionStore 本身的验收替代。PermissionStore 的结构接受以 P11B、代码事实和实物证据为准。

如果触碰 signing / TCC identity、Info.plist、bundle ID、code signing 或 permission identity 诊断，额外运行：

```bash
python3 tools/verification/p7h_stable_signing_permission_identity_checks.py
```

如果触碰 Screenshot capture、Screenshot Result 或 ScreenCaptureKit service，当前切片必须暂停并重新确认是否扩大到 ScreenshotStore；不得静默加入截图迁移。

### 7.3 Baseline / release gate

以下脚本不是 Step 4B 默认阻断项，除非本切片实际修改对应路径：

- `p3c_screenshot_checks.py`
- `p3d_screenshot_ai_action_entry_checks.py`
- `p3e_screenshot_result_polish_checks.py`
- `p3f_screenshot_ai_route_ready_checks.py`
- `p6a_shortcut_panel_interaction_checks.py`
- `p6b_shortcut_customization_panel_polish_checks.py`
- `p6c_shortcut_acceptance_gate_checks.py`
- `p8g_settings_shell_redesign_checks.py`
- `p9a_clipboard_repository_storage_smoke.py`
- `p9b_clipboard_appstate_repository_integration_checks.py`
- `p9c_no_reset_fixtures_ui_checks.py`

如果旧脚本依赖旧归档、旧路径、旧验收记录或旧 `AppState` 直接字段字符串，只能作为 baseline 参考；要作为阻断项，必须先迁移到当前代码事实和 `docs/项目管理库/003_架构升级/step_4/` 证据路径，并在开发记录中说明事实源。

## 8. 最小实物验收证据

开发记录和测试/质量验收记录必须写明环境、构建路径、权限状态、操作步骤、观察结果、未覆盖项和证据位置。

最低证据：

- Settings Permissions 页面能稳定打开，Screen Recording / Accessibility 两条诊断均可见。
- Refresh / Completed 后状态刷新，且不会伪造授权状态。
- Request Screen Recording 按钮由用户触发；触发后辅助面板和系统引导仍可理解。
- Request Accessibility 按钮由用户触发；触发后辅助面板和系统引导仍可理解。
- Show in Finder 由用户触发，目标是当前 app bundle。
- Restart Blocks 只在用户点击时触发；若测试环境不能真的重启，记录为受限验证。
- 截图缺少 Screen Recording 权限的路径未回归；如果当前环境已授权且无法撤权，明确写成未覆盖，不得写成通过。
- Clipboard pending paste retry 语义未被迁入 `PermissionStore`；如果不能做真实全局 paste 触发，至少由自动化或代码检查证明 retry 仍在 AppState / Clipboard 协调层。
- 已授权状态下 Permission Assist 不误导用户重复请求；如果无法覆盖已授权和未授权双状态，逐项标记。
- Settings Permissions 在窄宽度、长 app path、长 bundle ID、长 recommended action、中文 / 英文 / 日文长句、固定 trailing column 下无明显重叠、截断不可理解或控件丢失。
- team ID、usage description、matching running app path、identity issue 的诊断层级必须明确：直接显示、可展开显示或等价 UI 可见均可；如果实现只保留数据字段而不展示，必须在开发记录中说明并等待 UI / 测试确认。
- Refresh / Completed、Restart Blocks、Request Screen Recording、Request Accessibility、Show in Finder，以及使用 hidden label 的 permission Toggle / Button / diagnostic control 必须通过可访问性 label 检查；不得只读出空标签或泛化控件名。
- Permission Assist 实际触碰的 opening、waiting、guiding、checking、granted、failed、cancelled、timedOut 状态必须记录；未触碰状态明确标为未覆盖。
- Clipboard pending paste retry 的用户反馈必须保留准备完成、缺少 Accessibility 权限、授权后重试成功或重试失败的可理解结果；实现上 retry 仍留在 AppState / Clipboard 协调层。

实物证据不得包含真实截图内容、真实剪贴板正文、完整本地文件路径或敏感凭据。

## 9. 可接受标准

Step 4B 可接受必须同时满足：

- 四方方案复审完成，P0/P1 阻断项为 0；`approve-with-changes` 的必改项已回写 PRD 或开发派单。
- `PermissionStore` 已作为权限事实源进入 feature boundary 和 app target。
- `AppState` 不再直接声明 `@Published permissionSnapshot`。
- `AppState` facade 兼容现有 View 调用，且 `objectWillChange` 绑定不破坏 UI 更新。
- 权限刷新后 Clipboard pending retry 语义保留，但 `PermissionStore` 不直接处理 Clipboard。
- Settings Permissions、Permission Assist、Screenshot permission missing path、Show in Finder、Restart、Screen Recording Settings 入口不回归。
- 新增 P11B 和第 7.2 节阻断门禁通过。
- P11B 使用 `tools/verification/p11b_permission_store_checks.py` 统一入口并 fail closed；旧 P7 / P10 阻断门禁已确认使用当前事实源。
- App / CLI build、`blocks --help`、`git diff --check` 通过。
- 开发记录、测试/质量验收记录和最终复审记录均不输出敏感数据。

## 10. 残余风险

以下风险不阻断本 PRD 进入开发，但开发记录和后续验收必须诚实记录：

- `PermissionStateService` 当前仍在 `PermissionAssistPanelPresenter.swift`，如果只新增 store 而不整理纯类型，文件仍会偏大；这是可接受残余，不应扩大为 presenter 重写。
- TCC 行为受签名、bundle path、历史授权状态和系统设置影响，实物验收可能无法覆盖授权 / 未授权 / revoked 全矩阵；未覆盖项必须诚实记录。
- `AppState` 行数不会因为本切片显著下降；本切片目标是权限事实源迁移，不是 AppState 全量瘦身。
- ScreenshotStore 仍未创建；截图 capture 和结果展示仍会通过 AppState facade 协调。
- Settings shell 仍未拆；Permissions pane 只通过 facade 受益，不做结构性拆分。

## 11. 角色流程协议

### 11.1 方案复审

PRD 产出后并行派发：

- App 架构师：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-App架构师Step4B方案复审-v0.md`，重点看 store 边界、AppState facade、窄接口、是否会制造新耦合。
- 安全合规顾问：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-安全合规Step4B方案复审-v0.md`，重点看权限请求用户触发、敏感 API token、日志/audit/证据低敏边界。
- 测试/质量：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-测试质量Step4B方案复审-v0.md`，重点看 P11B 可执行性、P7 门禁矩阵、实物验收证据和旧门禁事实源。
- UI/交互设计师：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-UI交互Step4B方案复审-v0.md`，重点看 Settings Permissions、Permission Assist、刷新/重启/Show in Finder/manual fallback 是否不退化。

主 agent 汇总复审意见后，更新本文或派生开发版 PRD。若存在 P0/P1，先返工文档，不派开发。

当前已收到：

- App 架构师 Step 4B 方案复审：`approve-for-development`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-App架构师Step4B方案复审-v0.md`。未发现 P0/P1；P2 建议已与安全、测试意见合并回写。
- 安全合规 Step 4B 方案复审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-安全合规Step4B方案复审-v0.md`。P1-1 / P1-2 已回写第 6 节、第 7.1 节和第 8 节。
- 测试/质量 Step 4B 方案复审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-测试质量Step4B方案复审-v0.md`。P1 关于 P11B 统一入口、fail closed 和旧 P7 / P10 事实源处理已回写第 7 节、第 9 节。
- UI/交互 Step 4B 方案复审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-UI交互Step4B方案复审-v0.md`。未发现 P0/P1；Settings Permissions 窄宽度、长文本、可访问性、诊断层级和 Permission Assist 状态证据建议已回写第 8 节。

当前开发派发状态：`accepted`。开发线程：`019f32ab-05cc-76e0-ad7a-61d8abb7a760`。开发记录：`docs/项目管理库/003_架构升级/step_4/开发记录-Step4B-PermissionStore-v0.md`。最终接受记录：`docs/项目管理库/003_架构升级/step_4/最终接受记录-Step4B-PermissionStore-v0.md`。

### 11.2 开发回调

PRD 进入开发派发状态后，开发线程按本文实施；当前开发已完成并回调主会话。开发回调必须提供：

- 开发记录路径。
- 实际改动文件列表。
- 运行过的命令和 PASS / FAIL 结果。
- 未运行命令和原因。
- 实物验收证据位置。
- 敏感数据处理声明。
- 残余风险。

开发线程无需等待主会话在线；完成后回调即可。

### 11.3 验收与最终接受

开发回调后：

- 测试/质量做独立验收。
- 如果实现触碰 store 边界、AppState facade 或 platform adapter，App 架构师做最终实现复审。
- 如果实现触碰权限请求、TCC、签名、系统设置跳转或日志证据，安全合规顾问做最终安全复审。
- 主 agent 只在开发记录、测试/质量验收、必要复审均完成后写最终接受记录。
