# Step 4 Feature 模块迁移预初始化 PRD v0

状态：step-4b-accepted
日期：2026-07-05
来源级别：product and architecture pre-plan

> For agentic workers: Step 4B 的实现入口是 `PRD-Step4B-PermissionStore-v0.md`，不是本文。本文保留 Step 4A rebaseline 和后续切片候选边界。

**Goal:** 基于 Step 3 accepted 后的真实代码基线，确定 Step 4A rebaseline 结果、Step 4B 最小可开发切片候选、进入条件和验收边界。

**Architecture:** Step 4 继续采用低风险 facade 迁移。先让 Screenshot、Permission、Shortcut 和 Settings shell 建立清晰边界，再根据 Step 3 实际结果决定是否纳入 Clipboard hardening。`AppState` 保留 app shell / coordinator 职责，不新增 feature 事实源。

**Tech Stack:** SwiftUI, AppKit, Combine, ScreenCaptureKit, Accessibility, macOS permission flows, BlocksCore, Python verification scripts, xcodebuild.

---

## 0. 当前定位

本文是 Step 4 的预初始化 / rebaseline 文档，不是开发派单。

Step 4 进入开发前必须先满足：

- Step 3 开发完成并回调主 agent。状态：已完成。
- Step 3 测试/质量验收完成。状态：已完成，结论为 `accepted`。
- Step 3 App 架构师最终实现复审完成。状态：已完成，结论为 `approve-for-acceptance`。
- 主 agent 明确 Step 3 接受、返工、降级接受或暂停。状态：已完成，结论为 `accepted`。
- 本文根据 Step 3 实际产物完成 rebaseline，并已拆出独立 Step 4B PermissionStore PRD。
- Step 4 至少拆成 Step 4A rebaseline 和一个最小可开发 Step 4B；不得一次性把 4B 到 4F 全部作为同一开发派单。

当前本文的 Step 4A rebaseline 已完成第一轮回写；Step 4B 已收敛为独立 PermissionStore 单切片 PRD：`docs/项目管理库/003_架构升级/step_4/PRD-Step4B-PermissionStore-v0.md`。Step 4B 已完成开发、复审、验收和主 agent 最终接受。本文不用于直接派发开发。

## 1. 背景

Step 1 已提出目标结构：按 AppShell、Features、Core、Platform 重新明确依赖方向。Step 2 已完成 Clipboard 第一阶段迁移，`ClipboardStore` 成为 feature store 先例。Step 3 正在开发 Provider / Translation store 与 route/runtime 契约统一。

Step 4 原先定义为 Feature 模块迁移。由于 Step 3 已经覆盖 Provider / Translation，本阶段预初始化时不再默认重复处理 Provider / Translation，而是优先考虑以下剩余高耦合区域：

- Screenshot：截图启动、权限检查、ScreenCaptureKit 调用、结果展示、AI action route preview 仍由 `AppState` 串起。
- Permission：权限 snapshot、刷新、辅助面板、重启提示和自动粘贴重试是跨 feature 逻辑。
- Shortcut：快捷键注册、配置、诊断和 Settings 行为仍由 `AppState` 与 `ShortcutController` 直接协调。
- Settings shell：`SettingsView` 仍是大型聚合 View，承载 Clipboard、Shortcut、Permission、Provider、Translation、General、Agent/CLI 等多域设置。
- Clipboard hardening：Step 2 留下的 `repositoryUnavailable` 产品化和 redacted list + lazy payload 仍需要进入后续阶段，但是否放进 Step 4 要看 Step 3 余量和风险。

## 2. 当前事实与待验证项

### 2.1 当前事实

以下事实来自 2026-07-05 Step 4 预初始化时的本地代码读取。Step 3 accepted 后的真实基线见第 11 节。

- `apps/Blocks/BlocksApp/Stores/AppState.swift` 当前约 2342 行，仍包含 screenshot、permission、shortcut、clipboard panel、status 和若干跨 feature 编排。
- `apps/Blocks/BlocksApp/Views/SettingsView.swift` 当前约 2260 行，是最大的设置聚合 View。
- `apps/Blocks/BlocksApp/Views/ScreenshotHomeView.swift` 当前约 103 行，通过 `appState.startScreenshot(mode:)` 触发截图。
- `apps/Blocks/BlocksApp/Views/ScreenshotResultView.swift` 当前约 279 行，通过 `appState.routeSummaryForScreenshotAIAction(_:)` 展示 AI action route preview。
- `apps/Blocks/BlocksApp/Services/ScreenshotCaptureService.swift` 当前约 322 行，直接使用 ScreenCaptureKit / AppKit 完成 region、window 和 fullscreen capture。
- `apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift` 当前约 799 行，承载权限辅助体验。
- `apps/Blocks/BlocksApp/Services/ShortcutController.swift` 当前约 559 行，承载快捷键注册和配置相关类型。
- 当前已有 P3/P6/P7/P8/P9 相关 verification，可作为 Step 4 回归基础。

### 2.2 待验证项

Step 3 完成后需要重新核验：

- `AppState.swift` 的实际行数、剩余 `@Published` 事实源和 facade 方法。
- `ProviderStore` / `TranslationStore` 是否已稳定进入 target；如果未接受，Step 4 不能基于它们设计 Settings pane 边界。
- `routeSummaryForScreenshotAIAction(_:)` 是否仍由 `AppState` 提供，或已被 ProviderStore facade 改写。
- P10A / P10B 是否通过；如果未通过，Step 4 必须先暂停或降级范围。
- 开发是否更新了 `index.md` / `step.md`，避免主会话和开发线程对阶段状态写入冲突。

## 3. 推荐范围

Step 4 建议按切片推进，而不是一次性迁移所有剩余 feature。

Rebaseline 结论：Step 4A 是强制入口；Step 4B 只能选择一个最小实现切片。当前已选择 `PermissionStore` 单切片；`PermissionStore + ScreenshotStore` 最小组合降为后续备选，不进入 Step 4B。ShortcutStore、Settings shell 和 Clipboard hardening 不应默认与首个实现切片同批开发。

### Slice 4A: Step 3 Rebaseline

目标：把 Step 3 实际产物转成 Step 4 的事实基线。

产物：

- 更新本文状态和范围。
- 记录 Step 3 后 `AppState`、`SettingsView`、主要 store / service 的行数。
- 列出 Step 4 不再处理的 Provider / Translation 项。
- 标注 Step 3 遗留但必须阻断 Step 4 的问题。

### Deferred Candidate: ScreenshotStore

目标：后续把截图状态和截图动作从 `AppState` 迁到 `ScreenshotStore`，`AppState` 只保留跨 feature 协调和兼容 facade。本候选不进入当前 Step 4B。

候选职责：

- `lastCaptureSummary`
- `recentCaptures`
- `startScreenshot(mode:)`
- `startRegionScreenshot()`
- screenshot status result mapping
- recent capture list management
- result presenter 调用入口
- AI action route preview 的 screenshot 侧输入组织

边界：

- `ScreenshotStore` 可以依赖 `ScreenshotCaptureService` 或 `ScreenshotCapturing` protocol，但不直接读取 Keychain、不发 provider 网络请求。
- 结果展示优先留在 AppState / AppShell facade；如果注入 presenter，必须通过 `ScreenshotResultPresenting` 窄协议，不让 `ScreenshotStore` 扩大成窗口协调器。
- Screen Recording 权限判断通过 `PermissionReadable` / closure / AppState facade 输入，不在 `ScreenshotStore` 内部直接读取、请求或扩散权限策略。
- AI action route preview 通过闭包或 route resolver protocol 注入，不让 `ScreenshotStore` 直接持有 `ProviderStore` 或 `TranslationStore`。
- AI action route 只做 preview，不上传截图图片，不新增真实 OCR / image LLM 外发。
- Screenshot Home 必须保留 app 状态标题/详情、last capture summary、region/window/fullscreen 三个入口、Screen Recording Settings 入口、recent captures 空态和列表态。
- Screenshot Result 必须保留 copy、save as、retake、close、copy/save/cancel/failure outcome banner、AI route preview、blocked detail 和 no-upload/provider-not-called 用户可见文案。

### Step 4B: PermissionStore

目标：把权限 snapshot、刷新、辅助请求和状态投射从 `AppState` 抽出。

候选职责：

- `permissionSnapshot`
- `refreshPermissionState()`
- `requestScreenRecordingPermissionAssist()`
- `requestAccessibilityPermissionAssist()`
- `openScreenRecordingSettings()`
- `restartForPermissionRefresh()`
- permission assist panel presenter 的窄接口

边界：

- `PermissionStore` 不负责自动粘贴重试本身；自动粘贴重试仍是 Clipboard / AppShell 协调。
- `PermissionStore` 不擅自触发系统设置跳转，必须由用户动作触发。
- 权限状态只能来自系统 snapshot 或明确的辅助流程，不用 UserDefaults 假造授权状态。
- 如果 ScreenshotStore 先做，权限输入必须是 `PermissionReadable` / closure / AppState facade；如果 PermissionStore 先做，不得把 paste retry 编排搬进去。
- 权限诊断和动作入口必须保持同屏可理解；不能只保留按钮而移除授权状态、app path、签名、bundle ID、建议操作或确认语义。
- Screen Recording、Accessibility、Show in Finder、Restart Blocks 都必须由显式用户按钮触发。
- 必须保留“请求权限 -> 用户在系统设置完成 -> 回到 App 刷新/确认”的双阶段语义，以及 drag app icon / Show in Finder 的手动 fallback。

### Slice 4D: ShortcutStore

目标：把快捷键注册状态、诊断和配置动作从 `AppState` 抽出。

候选职责：

- `shortcutRegistrationResults`
- `registeredShortcutCount`
- `disabledShortcutCount`
- `failedShortcutCount`
- `registerDefaultShortcuts(force:)`
- `shortcutBinding(for:)`
- `shortcutRegistrationResult(for:)`
- `shortcutBindingSource(for:)`
- `hasCustomShortcutBinding(for:)`
- `globalShortcutModifierPreset()`
- `setGlobalShortcutModifierPreset(_:)`
- `saveShortcutBinding(_:)`
- `setShortcutEnabled(_:for:)`
- `restoreShortcutDefault(for:)`
- `restoreDefaultShortcuts()`
- `refreshShortcutRegistrations()`

边界：

- `ShortcutStore` 注册 command 时只能接收由 AppShell 注入的动作闭包，不能直接持有完整 `AppState`。
- 快捷键回调可以调用 AppShell coordinator 暴露的窄动作，例如 screenshot、clipboard panel、translation panel。
- Shortcut 配置仍可使用现有 `ShortcutBindingStore`，不在本阶段更换持久化策略。
- `ShortcutStore` 只负责注册状态、绑定配置和诊断，不直接知道 feature 内部状态，不引入任意 shell、AppleScript、CGEvent 或外部 CLI 执行能力。

### Slice 4E: Settings Shell Split

目标：在不重写 Settings 体验的前提下，把 `SettingsView` 拆成更稳定的 shell + pane 结构。

候选结构：

```text
apps/Blocks/BlocksApp/Features/Settings/
  SettingsShellView.swift
  SettingsSectionList.swift
  GeneralSettingsPane.swift
  ClipboardSettingsPane.swift
  ShortcutSettingsPane.swift
  PermissionSettingsPane.swift
  ProviderSettingsPane.swift
  TranslationSettingsPane.swift
  AgentCLISettingsPane.swift
```

边界：

- 本阶段不重新设计所有设置页面视觉。
- 本阶段不改变已有设置 key。
- Pane 拆分必须保持现有 `SettingsViewMode` 路由能力。
- Provider / Translation pane 是否拆出，取决于 Step 3 是否已被接受。
- Clipboard pane 拆分不得引入新的 clipboard payload 读取路径。
- 拆分后必须保持现有布局密度、section / row / action row 语义、固定 trailing column 和辅助说明文案；视觉和信息架构调整另立 UX spec。
- `clipboardPrivacy` 独立页必须保留返回 Clipboard 设置的语义，不得降级为关闭窗口或回到全部设置。
- Pane 级临时状态必须保持生命周期：Shortcut 录制仍只能一次录一个命令；Provider secret 输入、外发确认和 test connection 状态留在 Provider pane 范围；Permission snapshot、重启提示和 request assist 入口留在同一信息上下文。

Settings shell UX contract：

| Mode | 必须保持的行为 |
| --- | --- |
| `all` | 作为聚合入口显示现有主要设置分组，不改变可见顺序和敏感动作 gate。 |
| `general` | 显示语言和通用诊断设置，保持既有 setting key。 |
| `clipboard` | 显示 Clipboard policy、panel display、filter、pinboard、privacy entry、diagnostics 等现有 sections。 |
| `clipboardPrivacy` | 作为独立隐私页渲染，返回目标必须是 Clipboard 设置。 |
| `translation` | 继续显示 Translation 相关设置；是否拆 pane 取决于 Step 3 接受状态。 |
| `shortcuts` | 继续使用单一 `shortcutRecorderState`，不允许每行各自进入录制状态。 |
| `providers` | 继续保持 secret 输入、外发确认、连接测试和 route check 的局部状态。 |
| `agentCLI` | 只描述现有 Agent/CLI 边界，不承诺完整 payload 默认读取。 |
| `hooks` | 保留现有入口语义；如果当前只作为占位或诊断入口，不得写成已实现生产能力。 |
| `dataAudit` | 保留现有审计/数据说明入口语义，不新增敏感数据读取。 |
| `permissions` | 保持授权状态、推荐操作、刷新确认、重启提示、request assist、Show in Finder 和 drag fallback 同屏可理解。 |

### Slice 4F: Clipboard Hardening Candidate

目标：如果 Step 4 容量允许，开始处理 Step 2 遗留的 repository 降级和 read model 问题。

候选内容：

- `repositoryUnavailable` 的用户可见降级策略。
- 默认列表 read model 逐步转向 redacted list。
- 完整 payload 只允许 paste、hover detail、copy、translation preview 等明确用例读取。

边界：

- 如果当前 Step 4B 或后续 Screenshot / Shortcut / Settings 切片已经触碰较多 UI 和 AppShell，Slice 4F 应拆到后续 Step。
- 不启用 App Group、helper 生产写库或 CLI 读取完整 payload。

## 4. 非目标

Step 4 预案默认不做：

- 不重写整个 App。
- 不把 Step 3 未验收的 Provider / Translation 结果当作事实。
- 不新增真实 OCR、图片外发、multimodal LLM 或截图内容上传。
- 不改变 API key / secret 存储策略。
- 不启用 helper 生产写库、App Group 共享容器或 CLI 默认读取完整剪贴板 payload。
- 不改变商业模式、发布渠道或完整 V1 范围承诺。
- 不为了目录好看做无行为验收的批量搬文件。
- 不把大型 `SettingsView` 拆分与视觉重设计绑定。

## 5. 安全与隐私边界

Step 4 涉及截图、权限、快捷键和设置入口，必须守住以下边界：

- 截图图片是敏感运行态数据。不得进入日志、provider audit、开发记录、测试 JSON 或持久化存储，除非用户明确执行保存动作。
- Screenshot AI action preview 不等于 provider call。没有独立 PRD 和安全复审前，不允许上传截图图片。
- Permission 操作必须由用户动作触发，不静默打开系统设置，不静默请求 Accessibility 操作。
- Shortcut 回调只执行项目已声明动作，不扩大为任意自动化能力。
- Settings pane、普通 View 和 feature store 不直接出现敏感 API token。相关能力必须通过既有 service / presenter / controller 或新建 platform adapter 暴露的窄接口调用。
- 任何 agent/CLI 相关设置只能描述现有能力，不得把完整 payload 默认读取写成已启用能力。
- Step 4 若拆 Provider / Translation settings pane，必须继承 Step 3 安全复审结论：Keychain 读取后置、外部 provider 默认 HTTPS、route ready 不等于执行授权、真实 secret 不输出原文或 hash、翻译正文 runtime 不进入 audit / 测试 JSON / 开发记录。
- Accessibility 相关能力只允许迁移权限辅助和状态投射，不新增读取前台 UI 内容、抓取选中文本、发送键鼠事件或 AppleScript 自动化。

禁止直接出现在新 store / View / Settings pane 的 token：

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
AXIsProcessTrustedWithOptions
RegisterEventHotKey
UnregisterEventHotKey
```

实物验收、日志、audit、开发记录和测试 JSON 禁止输出：

- 真实截图图片、base64、OCR 原文、完整窗口标题、屏幕文本、真实选中文本、完整剪贴板内容。
- 真实 URL、真实文件路径、用户主目录、真实 API key、secret hash、Authorization header、完整 request body、provider raw response、外部 CLI raw output。
- Permission Assist 只记录状态枚举、触发入口、是否用户动作、audit id 和错误码。
- Shortcut 验收只记录 action id、binding 摘要、注册状态、错误码和是否用户触发。

## 6. 候选文件结构

Step 4 可能新增：

- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift`
- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotCapturing.swift`
- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotResultPresenting.swift`
- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift`
- `apps/Blocks/BlocksApp/Features/Permissions/PermissionReadable.swift`
- `apps/Blocks/BlocksApp/Features/Shortcuts/ShortcutStore.swift`
- `apps/Blocks/BlocksApp/Features/Settings/SettingsShellView.swift`
- `apps/Blocks/BlocksApp/Features/Settings/SettingsSectionList.swift`
- `apps/Blocks/BlocksApp/Features/Settings/GeneralSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Settings/ShortcutSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift`
- `tools/verification/p11a_screenshot_store_boundary_checks.py`
- `tools/verification/p11b_permission_store_checks.py`
- `tools/verification/p11c_settings_pane_split_checks.py`

Step 4 可能修改：

- `apps/Blocks/BlocksApp/Stores/AppState.swift`
- `apps/Blocks/BlocksApp/Views/ScreenshotHomeView.swift`
- `apps/Blocks/BlocksApp/Views/ScreenshotResultView.swift`
- `apps/Blocks/BlocksApp/Views/SettingsView.swift`
- `apps/Blocks/BlocksApp/Views/MenuBarCommandsView.swift`
- `apps/Blocks/BlocksApp/Services/ScreenshotCaptureService.swift`
- `apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift`
- `apps/Blocks/BlocksApp/Services/ShortcutController.swift`
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
- `tools/verification/p3c_screenshot_checks.py`
- `tools/verification/p3d_screenshot_ai_action_entry_checks.py`
- `tools/verification/p3e_screenshot_result_polish_checks.py`
- `tools/verification/p3f_screenshot_ai_route_ready_checks.py`
- `tools/verification/p6a_shortcut_panel_interaction_checks.py`
- `tools/verification/p6b_shortcut_customization_panel_polish_checks.py`
- `tools/verification/p6c_shortcut_acceptance_gate_checks.py`
- `tools/verification/p7e_permission_assist_flow_checks.py`
- `tools/verification/p7f_permission_state_refresh_checks.py`
- `tools/verification/p7g_permission_settings_interaction_checks.py`
- `tools/verification/p8g_settings_shell_redesign_checks.py`

## 7. 验证方向

Step 4 最终 PRD 不能只列脚本名。每个新增 P11 门禁必须绑定切片、检查内容、旧门禁联动和最小实物证据。

### 7.1 P11 门禁契约

`p11a_screenshot_store_boundary_checks.py` 应聚焦 ScreenshotStore：

- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift` 存在并加入 Blocks app target。
- `ScreenshotStore` 是主线程可观察 store。
- `AppState` 不再直接持有本切片迁出的截图事实源，只保留 facade / AppShell 协调。
- `ScreenshotHomeView`、`ScreenshotResultView` 继续通过 facade 或明确 store 输入工作，不直接访问 `ScreenCaptureKit`、Keychain、`URLSession` 或 provider runtime。
- `ScreenshotStore` 可以调用 `ScreenshotCaptureService` 或 `ScreenshotCapturing` protocol；如果涉及结果展示，只能通过 `ScreenshotResultPresenting` 窄协议或继续留在 AppShell。
- `ScreenshotStore` 不直接持有 `ProviderStore` / `TranslationStore` / `AppState`，不能上传截图、不能读取 secret、不能执行 provider call。
- `routeSummaryForScreenshotAIAction` 仍是 route preview，不把图片内容写入日志、audit、JSON、测试输出或持久化存储。
- Screenshot Home 的状态标题/详情、last capture summary、recent captures 空态/列表态和 Screen Recording Settings 入口不丢失。
- Screenshot Result 的 copy/save/retake/close、outcome banner、blocked localized detail、`image_not_uploaded` / provider-not-called 文案不丢失。

`p11b_permission_store_checks.py` 应聚焦当前 Step 4B PermissionStore，不得复用为 Permission / Shortcut 合并门禁。

PermissionStore 检查：

- `apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift` 存在并加入 Blocks app target。
- 权限 snapshot、刷新、Screen Recording assist、Accessibility assist、打开设置和重启提示由 store 或窄接口承接。
- `AppState` 仅保留 facade / 跨 feature 协调。
- 权限状态只能来自系统 snapshot 或明确辅助流程；不得用 `UserDefaults` 假造授权状态。
- 系统设置跳转和 Accessibility 请求必须由用户动作触发。
- Permission Assist state machine、窗口等待、拖拽隔离、关闭条件仍保留。
- 权限诊断、推荐操作、刷新确认、重启提示、request assist、Show in Finder 和 drag fallback 保持在同一体验上下文。
- `PermissionStore` 不执行自动粘贴重试，不发送键鼠事件，不读取前台 UI 内容。

后续 ShortcutStore PRD 必须另行定义独立 P11 门禁，至少覆盖：

- `apps/Blocks/BlocksApp/Features/Shortcuts/ShortcutStore.swift` 存在并加入 Blocks app target。
- 注册结果、统计、启用/禁用、自定义绑定、恢复默认、全局 modifier preset、刷新注册由 store 或窄接口承接。
- `ShortcutStore` 不持有完整 `AppState`；快捷键命令只接收 AppShell 注入的窄动作闭包。
- 仍使用现有 `ShortcutBindingStore`，不改变持久化策略。
- Settings 中快捷键配置和诊断仍显示正确。
- `ShortcutStore` 不出现任意 shell、AppleScript、CGEvent、外部 CLI 执行或未声明动作分发能力。

`p11c_settings_pane_split_checks.py` 应聚焦 Settings shell：

- `apps/Blocks/BlocksApp/Features/Settings/` 下 shell、section list、pane 文件存在并加入 Blocks app target。
- `SettingsViewMode` 路由能力保持，旧入口仍能打开对应 pane。
- `SettingsViewMode` 至少覆盖 `all`、`general`、`clipboard`、`clipboardPrivacy`、`translation`、`shortcuts`、`providers`、`agentCLI`、`hooks`、`dataAudit`、`permissions`。
- `clipboardPrivacy` 返回路径仍回到 Clipboard 设置。
- 现有设置 key 不改名、不迁移、不丢失。
- Pane 级局部状态不被错误拆散，尤其是 `shortcutRecorderState` 只能保持单一录制状态。
- Provider / Translation pane 是否拆分必须以 Step 3 接受状态为前提。
- Pane 不直接出现第 5 节列出的敏感 API token。
- `SettingsView.swift` 行数下降不是唯一目标；更重要的是职责变清楚、路由和设置项不丢失。
- 新增或移动后的可见文案保持 String Catalog 覆盖。
- Agent/CLI pane 仍保持 preview-only 和现有边界说明，不新增完整 payload、截图图片、provider secret、hook runtime 或外部 CLI provider 执行能力。

### 7.2 切片运行矩阵

Step 4 所有切片共同门禁：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

Slice 4A Rebaseline：

```bash
python3 tools/verification/p10a_provider_translation_contract_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
```

如果 P10 门禁未通过，主 agent 必须先接受、降级接受或返工 Step 3，不能直接进入 Step 4 开发。

Deferred Candidate ScreenshotStore：

```bash
python3 tools/verification/p11a_screenshot_store_boundary_checks.py
python3 tools/verification/p3c_screenshot_checks.py
python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py
python3 tools/verification/p3e_screenshot_result_polish_checks.py
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py
```

如果触碰 window / fullscreen / region capture 或 result presenter，增加：

```bash
python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py
```

Step 4B PermissionStore：

```bash
python3 tools/verification/p11b_permission_store_checks.py
python3 tools/verification/p7f_permission_state_refresh_checks.py
python3 tools/verification/p7f_permission_assist_position_drag_checks.py
python3 tools/verification/p7g_permission_settings_interaction_checks.py
python3 tools/verification/p7k_permission_identity_gate_checks.py
python3 tools/verification/p7r_permission_assist_ux_checks.py
```

如果触碰 signing / TCC identity，增加：

```bash
python3 tools/verification/p7h_stable_signing_permission_identity_checks.py
```

Slice 4D ShortcutStore：

后续进入 ShortcutStore 开发前，必须先在 ShortcutStore PRD 中定义独立 P11 门禁；不得复用 Step 4B 的 `p11b_permission_store_checks.py`。

```bash
python3 tools/verification/p6a_shortcut_panel_interaction_checks.py
python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py
python3 tools/verification/p7c_shortcut_global_modifier_checks.py
python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py
```

如果触碰 Clipboard / Translation panel focus 行为，按影响范围增加对应 P7 clipboard / translation panel 门禁。

Slice 4E Settings shell：

```bash
python3 tools/verification/p11c_settings_pane_split_checks.py
python3 tools/verification/p8g_settings_shell_redesign_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p8j_settings_alignment_picker_checks.py
python3 tools/verification/p8k_settings_fullscreen_section_clipboard_height_checks.py
```

如果触碰历史 settings route / scroll / menu 问题，增加：

```bash
python3 tools/verification/p7b_settings_sidebar_stability_checks.py
python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py
python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py
python3 tools/verification/p7e_settings_visual_scroll_checks.py
python3 tools/verification/p7f_settings_menu_dedup_checks.py
python3 tools/verification/p7g_permission_settings_interaction_checks.py
```

如果 Slice 4F 纳入范围，还需要保留或扩展：

```bash
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
python3 tools/verification/p8m_clipboard_modularization_checks.py
python3 tools/verification/p8n_clipboard_capture_font_settings_checks.py
```

如果触碰 Clipboard panel / hover / paste / auto-paste，增加 `p7l_clipboard_experience_gate_checks.py` 或当前项目视图下的替代门禁。

### 7.3 最小实物证据

自动化门禁不能替代以下实物证据。开发记录或验收记录必须写明环境、构建路径、权限状态、操作步骤、观察结果、未覆盖项和证据位置。

Screenshot 最小证据：

- Region、Window、Fullscreen 至少各一条低敏实测记录；如果环境只覆盖单屏，必须记录多屏未覆盖。
- Window hover、Esc cancel、无候选窗口路径。
- Screen Recording 未授权或不可用时的错误提示路径。
- Screenshot AI action preview 显示 route，不上传图片。

Permission 最小证据：

- 当前稳定 app 身份下的 Screen Recording / Accessibility existing gate 结果。
- 已授权状态下 Permission Assist 不误导用户。
- 未授权或无法验证时，记录环境限制，不写成通过。
- 如果触碰 revoked-flow，必须有撤权后重新检查 / 重新引导证据；否则明确列为未覆盖。

Shortcut 最小证据：

- 默认三工具快捷键注册状态。
- 启用/禁用、修改、恢复默认、全局 modifier preset。
- 快捷键触发时 panel show / focus / exclusivity 不回归。
- 不能伪造全局系统按键触发结果；若只做静态或诊断验证，必须明确标记未覆盖真实按键路径。

Settings shell 最小证据：

- Settings 主要 route 逐项打开：General、Clipboard、Shortcuts、Permissions、Providers、Translation、Agent/CLI，以及仍存在的子 route。
- `all`、`general`、`clipboard`、`clipboardPrivacy`、`translation`、`shortcuts`、`providers`、`agentCLI`、`hooks`、`dataAudit`、`permissions` 均可从现有入口或测试入口稳定渲染。
- `clipboardPrivacy` 能返回 Clipboard 设置，且不会在 `all` 模式下造成重复或迷路。
- Shortcut 录制切换行、切换 pane、关闭 Settings 后能停止监听并恢复 idle。
- 宽度较窄、全屏、滚动到底部时无重叠、无丢控件。
- 关键设置修改后关闭重开仍保持。
- 不要求本阶段重做视觉，但拆分后不能把原有布局问题重新引入。
- 使用 hidden label 的 Toggle / Picker 必须通过可访问性验收，不能只读出空标签或泛化控件名。

Screenshot / Permission 体验证据补充：

- Permission Assist 覆盖 opening、waiting、guiding、checking、granted、failed、cancelled、timedOut 中实际触碰的状态；未触碰状态必须记录为未覆盖。
- Screenshot Result 验证 copy/save/retake/close、outcome banner、recent captures 更新、AI preview ready/blocked、provider profile、confirmation level、localized status detail 和 no-upload 文案。
- 长路径、shortcut conflict、provider readiness、中文/英文/日文长句在固定 trailing column 和窄宽度下不出现明显退化。

### 7.4 旧门禁事实源处理

Step 4 最终 PRD 必须标注旧 P7/P8/P9 门禁的事实源：

- 如果脚本仍依赖旧归档验收记录或旧项目路径，只能作为 baseline gate。
- 如果脚本要作为 Step 4 阻断门禁，必须先迁移到当前 `docs/项目管理库/003_架构升级/step_4/` 证据路径或更新为当前项目视图。
- 不允许因为旧脚本路径不匹配而静默跳过；要么修脚本，要么在开发记录和验收记录中说明它不属于当前切片阻断项。

## 8. 预备验收标准

Step 4 未来可接受的最低标准：

- `AppState` 不再直接持有本阶段迁出的 feature 事实源。
- 现有 View 可继续通过 AppState facade 或明确 feature store 工作。
- AppState 可以保留 `selectedSection`、global `status`、window / panel presenter orchestration 和跨 feature 协调；facade method 必须薄转发，状态投射要写明如何映射到 `AppStatus`。
- 每个新增 store 的 `objectWillChange` 绑定方式与 Step 2 / Step 3 保持一致。
- 本阶段新增 store 不互相强持有，不持有完整 `AppState`；跨域动作通过 protocol / closure / AppShell coordinator。
- Screenshot、Permission、Shortcut、Settings shell 的依赖方向清楚，View 不直接调用系统敏感 API。
- 截图、权限辅助、快捷键、设置导航的用户可见路径不回归。
- Settings shell 拆分不改变 `SettingsViewMode` 路由、setting key、`clipboardPrivacy` 返回路径、pane 局部状态和当前分组顺序，除非另有单独 UX 决策记录。
- Permission pane 保留授权状态、推荐操作、刷新确认、重启提示、request assist、Show in Finder 和 drag fallback。
- Screenshot Result 保留 copy/save/retake/close、outcome banner、AI route preview、blocked detail 和 no-upload/provider-not-called 文案。
- 新增 P11 门禁通过。
- 相关 P3/P6/P7/P8/P9 回归通过。
- App / CLI build 通过。
- `blocks --help` 通过。
- `git diff --check` 通过。
- 安全合规预审、测试预审、App 架构师预审和 UI/交互预审的问题已处理或记录为明确残余风险。
- P11A / P11B / P11C 的检查内容、切片运行矩阵、旧门禁事实源处理方式和实物验收最低证据已写入最终 PRD。
- Step 4A / Step 4B 已明确拆分，且首个开发切片只包含一个最小可验收范围。

## 9. 角色并行预审协议

Step 4 预初始化后，可以并行派发以下角色预审：

- App 架构师：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-App架构师预审-v0.md`，重点看范围拆分、依赖方向、AppState 边界和 facade 策略。
- 安全合规顾问：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-安全合规预审-v0.md`，重点看截图图片、权限辅助、快捷键、agent/CLI 和 settings 风险。
- 测试/质量：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-测试质量预审-v0.md`，重点看自动化门禁、实物验收和回归范围。
- UI/交互设计师：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-05-UI交互预审-v0.md`，重点看 Settings shell 拆分、权限辅助和截图结果路径的体验稳定性。

主 agent 已汇总这些独立文档，只把与 Step 4 范围、风险和验收直接相关的意见回写本文。后续 Step 4B 独立 PRD 仍需按角色流程复审。

当前已收到：

- App 架构师预审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-App架构师预审-v0.md`。切片拆分、store 依赖方向、AppState facade 硬规则和 Step 3-dependent 项已回写本文第 0 节、第 3 节、第 7 节和第 8 节。
- 安全合规预审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-安全合规预审-v0.md`。敏感 API token、preview-only、no-call、低敏实物验收和禁止输出项已回写本文第 5 节、第 7 节和第 8 节。
- 测试/质量预审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-测试质量预审-v0.md`。核心必改项已回写本文第 7 节和第 8 节。
- UI/交互预审：`approve-with-changes`，文档为 `docs/项目管理库/003_架构升级/step_4/2026-07-05-UI交互预审-v0.md`。Settings shell UX contract、Permission Assist 和 Screenshot Result / AI preview 体验门槛已回写本文第 3 节、第 7 节和第 8 节。

## 10. Step 4B 开发前剩余待补

Step 3 回调后的事实基线已补入第 11 节。Step 4B 独立 PRD 已产出并选择 `PermissionStore` 单切片。进入 Step 4B 开发前仍需补齐：

- Step 4B 方案复审意见及主 agent 回写。
- 每个新增 store 的最终输入 / 输出 protocol 或 closure 形态。
- P11B 或 Step 4B 专项门禁的最终可执行检查内容。
- P3/P6/P7/P8/P9 旧门禁哪些作为当前切片阻断项，哪些只作为 baseline / release gate。
- Permission Assist 实物验收证据模板和实际可执行环境。
- Step 4B 方案复审和开发派单范围。

## 11. Step 3 后 Rebaseline v0

### 11.1 Step 3 接受状态

Step 3 已完成最终接受：

- 开发记录：`docs/项目管理库/003_架构升级/step_3/开发记录-v0.md`，结论 `DONE`。
- 测试/质量验收：`docs/项目管理库/003_架构升级/step_3/验收记录-v0.md`，结论 `accepted`。
- App 架构师最终实现复审：`docs/项目管理库/003_架构升级/step_3/2026-07-05-App架构师复审-v0.md`，结论 `approve-for-acceptance`。
- 主 agent 最终接受：`docs/项目管理库/003_架构升级/step_3/最终接受记录-v0.md`，结论 `accepted`。

### 11.2 真实代码基线

Step 3 accepted 后的本地代码行数：

| 文件 | 行数 | 观察 |
| --- | ---: | --- |
| `apps/Blocks/BlocksApp/Stores/AppState.swift` | 1921 | Provider / Translation 事实源已改为 facade；仍持有 screenshot、permission、shortcut、global status、window / panel presenter、clipboard panel / paste 等协调入口。 |
| `apps/Blocks/BlocksApp/Views/SettingsView.swift` | 2265 | 仍是大型设置聚合 View；Step 3 只调整 route/runtime context，没有拆 Settings shell。 |
| `apps/Blocks/BlocksApp/Features/Provider/ProviderStore.swift` | 596 | ProviderStore 已承接 provider route、audit、Keychain gate、connection test、LLM mock adapter。后续 provider 类型增加时应考虑 use case / adapter protocol。 |
| `apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift` | 479 | TranslationStore 已承接 translation selection、preview、mock result、runtime result 和 route；通过闭包与 Provider audit / secret read 协作。 |
| `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift` | 414 | Clipboard Store 是 Step 2 先例，后续 hardening 不默认纳入 Step 4B。 |
| `apps/Blocks/BlocksApp/Services/ScreenshotCaptureService.swift` | 322 | ScreenCaptureKit / AppKit capture 仍集中在 service。 |
| `apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift` | 799 | Permission assist 仍是大型 presenter，Step 4 若触碰应优先封装窄接口。 |
| `apps/Blocks/BlocksApp/Services/ShortcutController.swift` | 559 | Shortcut 注册和配置相关类型仍集中在 controller。 |

`AppState` 当前仍直接声明的 non-Provider / non-Translation `@Published` 事实源：

- `selectedSection`
- `status`
- `lastCaptureSummary`
- `recentCaptures`
- `shortcutRegistrationResults`
- `permissionSnapshot`

这些构成 Step 4 的主要候选迁移对象。

### 11.3 Provider / Translation 对 Step 4 的影响

Step 4 不再默认处理 Provider / Translation store 创建或 `.llmBacked` 契约统一，这些已属于 Step 3 accepted 范围。

Step 4 仍可能处理 Provider / Translation settings pane，但必须满足：

- 以 Step 3 accepted 的 `ProviderStore` / `TranslationStore` 为事实基线。
- 继续通过 runtime context 传入 base URL、model、alias 和 external gate。
- 不回退到无 context 的 `ProviderRouteRequest(profile:)`。
- 明确 `providerRouteResolution` 在 Settings / Translation UI 中的显示归属，避免 ProviderStore 和 TranslationStore route state 长期重复。

### 11.4 首个 Step 4B 切片决策

当前决策：Step 4B 选择 `PermissionStore` 单切片；不纳入 ScreenshotStore、ShortcutStore、完整 Settings shell 和 Clipboard hardening。

理由：

- Permission 是 Screenshot、Clipboard auto-paste retry、Settings permission pane 的共同输入，先抽出能降低后续 store 对 AppState 的依赖。
- ScreenshotStore 若先做，仍需要权限输入；但把 ScreenshotStore 与 PermissionStore 同批会同时触碰截图结果展示和 AI route preview，首个 Step 4B 切片风险偏大。
- ShortcutStore 触发跨 feature 动作，需要 AppShell narrow action protocol，适合作为后续独立切片。
- Settings shell 依赖多个 store 边界稳定，不应在首个切片中同时拆。
- Clipboard hardening 涉及敏感数据 read model 和生产降级策略，建议独立小阶段。

### 11.5 Step 4B 开发前仍需补齐

- Step 4B 已收敛为独立 PRD / 实施方案：`PRD-Step4B-PermissionStore-v0.md`。
- Step 4B 已选择 `PermissionStore` 单切片，不纳入 ScreenshotStore。
- 方案复审后，为 `PermissionStore` 最终确认输入 / 输出协议和 AppState facade。
- 方案复审后，把 P11B 检查内容转成可执行 verification。
- 开发派单前确认实物验收模板：权限状态、用户触发动作、未覆盖状态、证据位置和禁止输出项。
