# Step 4C 剩余 Feature 收口 PRD v0

状态：approved-for-development
日期：2026-07-06
来源级别：product and architecture implementation plan

> 本文是 Step 4C 的统一 PRD / 方案，用于把 Step 4 剩余切片纳入同一阶段收口。四方方案复审第一轮已完成，P0 为 0，P1 已在本文回写；四方 P1 回写轻量复审结论均为 `p1-closed-with-notes`，无新增 P0/P1。本文可以进入 PRD 阶段提交；提交后再按子批次派开发。

## 0. 范围评估结论

用户目标是把 Step 4 剩余切片一起完成。主 agent 评估结论：

- 可以把剩余切片放进一个 Step 4C 收口 PRD，统一目标、边界、门禁和角色流程。
- 不应把所有代码改动压成无检查点的一次性开发；Screenshot、Shortcut、Settings shell、Clipboard hardening 触碰的状态源、UI、权限、快捷键和敏感数据边界不同。
- Step 4C 开发必须按子批次推进，每个子批次有独立开发记录、测试/质量验收记录、必要角色复审和主 agent stop/go 记录；前一子批次 P0/P1 未关闭前，不得启动后一子批次开发。
- 若任一子批次出现 P0/P1，Step 4C 暂停在该子批次，不继续扩大后续切片。
- Step 4C core scope 是 ScreenshotStore、ShortcutStore、Settings shell split；Clipboard hardening 是 conditional 4C-4。进入 4C-4 前必须完成 go/no-go 评估；若 P11E、payload allowlist / denylist、UX contract 或安全/质量门禁无法闭合，则拆为 Step 4D，并写 Step 4D handoff record，不阻断 Step 4C core closeout。

Step 4C core 包含：

1. ScreenshotStore：迁移截图状态和截图动作。
2. ShortcutStore：迁移快捷键注册状态、配置、诊断和动作注入。
3. Settings shell split：拆分大型 SettingsView，保持路由、setting key 和 pane 状态。

Step 4C conditional 4C-4 包含：

4. Clipboard hardening：把 `repositoryUnavailable` 产品化，并收紧默认列表 read model / 完整 payload 读取边界。只有 go/no-go 通过时才留在 Step 4C；否则转入 Step 4D。

Step 4C 不包含：

- 真实 OCR、图片上传、多模态 provider call。
- App Group、helper 生产写库、CLI 默认读取完整剪贴板 payload。
- 商业模式、发布渠道、完整 V1 范围。
- 视觉重设计或营销式设置页重做。
- TCC 权限重置自动化。

## 1. 当前事实基线

Step 4B PermissionStore 已最终接受，工作区已提交，当前基线为：

- `AppState.swift`：1928 行。
- `SettingsView.swift`：2265 行。
- `ScreenshotHomeView.swift`：103 行。
- `ScreenshotResultView.swift`：279 行。
- `ScreenshotCaptureService.swift`：322 行。
- `ShortcutController.swift`：559 行。
- 已有 feature store：
  - `Features/Clipboard/ClipboardStore.swift`
  - `Features/Provider/ProviderStore.swift`
  - `Features/Translation/TranslationStore.swift`
  - `Features/Permissions/PermissionStore.swift`

仍在 `AppState` 直接持有或协调的关键事实源 / 行为：

- `@Published var lastCaptureSummary`
- `@Published var recentCaptures`
- `@Published var shortcutRegistrationResults`
- `startScreenshot(mode:)`
- `routeSummaryForScreenshotAIAction(_:)`
- `registerDefaultShortcuts(force:)`
- `shortcutBinding(for:)`
- `restoreDefaultShortcuts()`
- Settings 路由与 `SettingsViewMode`
- Clipboard `repositoryUnavailable` 和 payload read model 的产品化残余

当前仍不存在：

- `Features/Screenshot/ScreenshotStore.swift`
- `Features/Shortcuts/ShortcutStore.swift`
- `Features/Settings/SettingsShellView.swift`
- `Features/Settings/*Pane.swift`

## 2. 用户目标

用户需要：

- 截图入口、截图结果、recent captures、AI action route preview 不因状态迁移退化。
- 快捷键设置、注册状态、禁用 / 失败 / 自定义绑定 / 恢复默认等行为不退化。
- Settings 不再由单个大型 View 承载所有 pane，但现有入口、路由、setting key 和局部状态保持稳定。
- Clipboard repository 不可用时有清晰降级；默认列表展示不无意读取或暴露完整 payload。
- 后续 agent 能围绕清晰 feature store / pane 边界继续迭代，而不是继续向 `AppState` 和 `SettingsView` 堆逻辑。

## 3. 开发批次

### 3.1 Step 4C-1 ScreenshotStore

目标：把截图状态和截图动作从 `AppState` 迁到 `ScreenshotStore`，`AppState` 保留 AppShell / coordinator facade。

必须新增：

- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift`

允许新增：

- `ScreenshotCapturing.swift`
- `ScreenshotResultPresenting.swift`
- `ScreenshotRouteResolving.swift`

职责：

- `lastCaptureSummary`
- `recentCaptures`
- `startScreenshot(mode:)`
- `startRegionScreenshot()`
- 截图前权限刷新与 Screen Recording snapshot 检查
- screenshot status result mapping
- recent capture list management
- result presenter 调用入口或 presenter 窄接口
- AI action route preview 的 screenshot 侧输入组织

边界：

- `ScreenshotStore` 不直接读取 Keychain、不发 provider 网络请求。
- `ScreenshotStore` 不上传截图图片，不新增 OCR / image LLM 外发。
- `ScreenshotStore` 不持有完整 `AppState`。
- `ScreenshotStore` 不成为全局 status owner；它可以产出 screenshot event / status intent，由 `AppState` 作为 window-level coordinator 发布 status banner。
- 权限输入通过 `PermissionStore` / `PermissionReadable` / closure / AppState facade。
- AI route preview 只能通过 route resolver protocol / closure 取得 preview-only 结果，不直接持有 `ProviderStore`，不把图片内容写入 audit / JSON / 开发记录。
- `ScreenshotResultView` 的 copy/save/retake/close、outcome banner、blocked detail、no-upload/provider-not-called 文案不丢失。
- 截图图片生命周期必须明确：内存态 result 仅用于当前用户可见结果；用户显式 save/copy 是导出动作；recent captures 只能保存低敏 summary；verification / 开发记录 / 验收记录不得保存真实图片、base64、窗口标题或屏幕文本。

### 3.2 Step 4C-2 ShortcutStore

目标：把快捷键注册状态、配置动作、诊断指标从 `AppState` 抽出。

必须新增：

- `apps/Blocks/BlocksApp/Features/Shortcuts/ShortcutStore.swift`

允许新增：

- `ShortcutActionDispatching.swift`
- `ShortcutRegistrationManaging.swift`

职责：

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

- `ShortcutStore` 不持有完整 `AppState`。
- 快捷键命令只接收 AppShell 注入的窄动作闭包，例如截图、剪贴板面板、翻译面板。
- 仍使用现有 `ShortcutBindingStore`，不改变持久化策略。
- 不新增任意 shell、AppleScript、CGEvent、外部 CLI 执行或未声明动作分发能力。
- Settings 中快捷键配置、录制状态和诊断仍保持一致；`shortcutRecorderState` 仍只能同时录一个命令。

声明动作 allowlist：

| `ShortcutCommand` | 允许触发动作 | 禁止解释 |
| --- | --- | --- |
| `screenshotRegion` | 用户触发区域截图入口。 | 不得变成任意截图脚本、OCR、provider call 或系统自动化。 |
| `clipboardHistory` | 打开/聚焦剪贴板历史面板。 | 不得读取完整 payload、执行 paste、运行 helper 或 CLI。 |
| `translationPanel` | 打开/聚焦翻译面板。 | 不得直接读取 provider secret、发网络请求或读取剪贴板正文。 |

任何新增 `ShortcutCommand` 必须先更新本文、P11C 和测试矩阵，再进入开发。

### 3.3 Step 4C-3 Settings Shell Split

目标：在不重写 Settings 视觉设计的前提下，把 `SettingsView` 拆成 shell + pane 结构。

必须新增：

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
  HooksSettingsPane.swift
  DataAuditSettingsPane.swift
```

允许按现有结构保留少量兼容 wrapper，但 `SettingsView.swift` 不能继续承载所有 pane 主体。

必须保持：

- `SettingsViewMode` 路由。
- `all`、`general`、`clipboard`、`clipboardPrivacy`、`translation`、`shortcuts`、`providers`、`agentCLI`、`hooks`、`dataAudit`、`permissions` 等 mode 语义。
- `SettingsViewMode` 到 pane 的映射必须明确：`hooks` 映射 `HooksSettingsPane`，`dataAudit` 映射 `DataAuditSettingsPane`；`all` 可以组合多个 pane，但不得成为唯一承载所有主体的实现。
- `clipboardPrivacy` 返回 Clipboard 设置，而不是关闭窗口或回到全部设置。
- 现有 setting key 不改名、不迁移、不丢失。
- Provider secret 输入、外发确认、连接测试、route check 的局部状态不泄漏到全局 store。
- Translation pane 继续基于 Step 3 accepted 的 `TranslationStore`。
- Permission pane 继续基于 Step 4B accepted 的 `PermissionStore`。
- Shortcut pane 继续使用单一录制状态。
- 布局密度、固定 trailing column、section / row / action row 语义不退化。

边界：

- 不做视觉重设计。
- 不新增敏感 API token 到 pane。
- 不把 Settings 拆分当作 Provider / Translation / Clipboard 行为重写。
- Agent/CLI pane 只描述现有能力，不承诺完整 payload 默认读取。
- Provider secret 输入、连接测试、route check、permission request / settings open、clipboard full payload 读取都必须继续由既有 store、adapter、gate 或用户显式动作路径承接；新增 pane 不得直接调用 `URLSession`、`SecItem`、`NSWorkspace` 系统动作、`NSPasteboard.general` 或 provider route。

### 3.4 Step 4C-4 Clipboard Hardening

目标：处理 Step 2 遗留的 repository 降级和 read model 问题，不开启 helper / App Group / CLI 完整 payload。

必须完成：

- `repositoryUnavailable` 的用户可见降级策略。
- Settings 或 Clipboard UI 中能解释 storage degraded / repository unavailable 的状态。
- 默认列表 read model 逐步转向 redacted / metadata-first。
- 完整 payload 只允许明确用例读取，例如 paste、copy、hover detail、translation preview。
- verification 明确默认列表 / 面板渲染不会为了普通展示读取完整 payload。

Clipboard hardening UX contract：

- `repositoryUnavailable`：Clipboard 面板和 Settings 中至少一个用户可见位置解释 storage degraded / repository unavailable，区分“无历史”“存储暂不可用”“历史不可写入”“复制/粘贴仍可用但历史降级”。
- `redacted list`：默认列表只展示 metadata / redacted preview / kind / source / timestamp / pin state 等低敏信息；占位文案必须让用户理解内容被保护，不是内容丢失。
- `explicit payload read`：paste、copy、hover detail、translation preview 触发完整 payload 读取前后必须有可解释状态；验收记录只能写读取类别和 record id 类低敏标识，不写正文。
- `empty / unavailable / filtered / redacted` 四类状态必须能在 UI 或测试证据中区分。
- 如果不新增 Settings UI，则必须说明用户在 Clipboard 面板哪里看到 storage degraded 反馈；若新增 Settings UI，不得泄露剪贴板正文。

完整 payload allowlist / denylist：

| 路径 | 完整 payload 读取 |
| --- | --- |
| 默认列表渲染 / 普通面板列表 / Settings summary / CLI 默认输出 | 禁止 |
| paste / copy / hover detail / translation preview | 允许，但必须是明确用户动作或明确业务用例 |
| helper 生产写库 / App Group / CLI 完整 payload 默认读取 | Step 4C 禁止开启 |

边界：

- 不启用 App Group。
- 不启用 helper 生产写库。
- 不让 CLI 默认读取完整 payload。
- 不把剪贴板正文写入开发记录、测试 JSON、audit 或日志。
- 不改变用户主动 copy / paste 的既有行为。

## 4. 跨切片依赖顺序

推荐顺序：

1. ScreenshotStore。
2. ShortcutStore。
3. Settings shell split。
4. Clipboard hardening。
5. Step 4C final integration / cleanup。

理由：

- Screenshot 和 Shortcut 先把 `AppState` 中剩余 feature facts 拆出，Settings pane 拆分时可依赖稳定 facade / store。
- Clipboard hardening 应在 Settings shell 基本稳定后进入独立 go/no-go 检查点，避免同一轮同时改 pane 结构和敏感 read model。
- 如果 Clipboard hardening 的 P11E、payload allowlist / denylist、UX contract、当前事实源门禁无法在开发前闭合，必须拆到 Step 4D，不阻断 Step 4C core 对 Screenshot / Shortcut / Settings shell 的收口。

子批次 hard stop/go：

- 每个子批次必须有独立开发记录、测试/质量验收记录和主 agent stop/go 记录。
- 触碰架构、UI 或安全边界的子批次必须按影响范围追加 App 架构师、UI/交互、安全合规复审或抽查。
- 前一子批次 P0/P1 未关闭前，不得启动后一子批次开发。
- 若同一开发线程连续承接多个子批次，必须在文件变更、命令、低敏证据和残余风险上清楚分段；否则测试/质量应拒绝合并验收。
- 4C-4 Clipboard hardening 启动前，主 agent 必须写 go/no-go 判断；若 no-go，写 Step 4D handoff record。

## 5. AppState 目标状态

Step 4C 完成后，`AppState` 应继续保留：

- app section / navigation / AppShell 状态。
- feature store 持有与 `objectWillChange` 桥接。
- 跨 feature coordinator facade。
- status banner / window-level coordination。

Step 4C 完成后，`AppState` 不应继续直接持有：

- screenshot facts：`lastCaptureSummary`、`recentCaptures`。
- shortcut facts：`shortcutRegistrationResults`。
- Settings pane 主体局部状态。
- Clipboard 完整 payload 默认展示策略。

如果某项事实源因为风险暂留 `AppState`，开发记录必须说明原因、影响、后续拆分入口和验收降级。

## 6. 安全与隐私边界

禁止在新增 store / pane 中直接出现以下 token，除非文件是明确 platform adapter 且专项 P11 门禁白名单解释：

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

截图图片、剪贴板正文、选中文本、窗口标题、OCR 原文、provider raw response、Authorization header、真实凭据不得进入：

- 开发记录。
- 验收记录。
- verification JSON。
- audit。
- debug logs。

ShortcutStore 不得扩大为任意自动化执行器。

Settings pane 不得绕过现有 provider / permission / clipboard 安全 gate。

Clipboard hardening 不得引入新的默认 payload 读取路径。

## 7. 门禁

### 7.1 新增 P11 门禁

必须新增或完成以下门禁：

```bash
python3 tools/verification/p11a_screenshot_store_boundary_checks.py
python3 tools/verification/p11c_shortcut_store_checks.py
python3 tools/verification/p11d_settings_shell_split_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
```

说明：

- `p11b_permission_store_checks.py` 已归属 Step 4B，不得复用为 Shortcut / Settings / Clipboard 的主门禁。
- 每个 P11 脚本必须 fail closed：脚本缺失、target membership 无法解析、预期路径缺失、旧事实源被当作阻断证据、检查静默跳过，都必须失败。
- 每个 P11 输出必须包含 checked files、target membership source、规则命中 / 未命中摘要和失败原因。
- 每个 P11 脚本必须显式列出 current evidence path；旧归档、旧 story、旧 acceptance、旧 AppState / SettingsView 字符串只能作为 `baseline_reference`，不得参与 `ok` 判定。

P11A ScreenshotStore 最低检查清单：

- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift` 存在并进入 Blocks app target。
- 允许的 screenshot feature helper / protocol 文件进入 target；未声明文件不得承载主要事实源。
- `AppState` 不再直接以 `@Published` 持有 `lastCaptureSummary`、`recentCaptures`；如保留 facade，必须是 computed / coordinator facade。
- `AppState` 持有 `ScreenshotStore` 并桥接 `objectWillChange`，但 `ScreenshotStore` 不持有完整 `AppState`。
- 截图前权限刷新和 Screen Recording snapshot 检查顺序保留；缺权状态不静默触发真实权限请求。
- Result presenter / route resolver 通过窄接口或 closure 注入；`ScreenshotStore` 不直接持有 `ProviderStore`。
- 新 screenshot feature 文件不含 `URLSession`、`SecItem`、`Authorization`、`Bearer`、OCR、image upload、image provider call、图片 base64 日志、窗口标题 / 屏幕文本输出 token。
- `ScreenshotResultView` 的 copy / save / retake / close、outcome banner、blocked detail、no-upload/provider-not-called 文案路径仍可引用。

P11C ShortcutStore 最低检查清单：

- `apps/Blocks/BlocksApp/Features/Shortcuts/ShortcutStore.swift` 存在并进入 Blocks app target。
- `AppState` 不再直接以 `@Published` 持有 `shortcutRegistrationResults`；如保留 facade，必须是 computed / coordinator facade。
- `AppState` 持有 `ShortcutStore` 并桥接 `objectWillChange`，但 `ShortcutStore` 不持有完整 `AppState`。
- `ShortcutStore` 只接收 AppShell 注入的声明动作闭包，动作集合必须与本文 allowlist 一致。
- 禁止动态 action 字符串派发、任意 shell、AppleScript、CGEvent / CGEventPost、外部 CLI、Accessibility 前台 UI 操作或未声明自动化入口。
- `ShortcutBindingStore` 持久化策略不改变；single recorder state 仍只能同时录一个命令。
- 注册 / 禁用 / 失败 / 自定义绑定 / restore default facade 均可追踪到 `ShortcutStore`，Settings 行不直接成为业务事实源。

P11D Settings shell split 最低检查清单：

- `SettingsShellView.swift`、`SettingsSectionList.swift`、`GeneralSettingsPane.swift`、`ClipboardSettingsPane.swift`、`ShortcutSettingsPane.swift`、`PermissionSettingsPane.swift`、`ProviderSettingsPane.swift`、`TranslationSettingsPane.swift`、`AgentCLISettingsPane.swift`、`HooksSettingsPane.swift`、`DataAuditSettingsPane.swift` 存在并进入 Blocks app target。
- `SettingsView.swift` 退化为 wrapper / compatibility entry，不继续承载所有 pane 主体。
- `SettingsViewMode` 全量保留：`all`、`general`、`clipboard`、`clipboardPrivacy`、`translation`、`shortcuts`、`providers`、`agentCLI`、`hooks`、`dataAudit`、`permissions`。
- mode mapping 明确，`hooks` 映射 `HooksSettingsPane`，`dataAudit` 映射 `DataAuditSettingsPane`，`clipboardPrivacy` 返回 Clipboard 设置。
- 现有 setting key 不改名、不迁移、不丢失。
- Provider secret 输入、外发确认、连接测试、Shortcut recorder、Permission assist、Translation route state 等 pane 局部状态不进入全局 store 且不跨 pane 串扰。
- 新 settings pane 不含未经白名单解释的 `URLSession`、`SecItem`、`Authorization`、`Bearer`、`NSWorkspace` 系统动作、`NSPasteboard.general`、provider route 直连、clipboard full payload 读取 token。

P11E Clipboard hardening 最低检查清单：

- `repositoryUnavailable` 有用户可见 degraded state，且 Clipboard / Settings UI 可区分 empty、unavailable、filtered、redacted。
- 默认列表、普通面板渲染、Settings summary、CLI 默认输出不读取完整 payload。
- 完整 payload 只允许在 paste、copy、hover detail、translation preview allowlist 中读取；新增读取路径必须先更新本文和 P11E。
- helper 生产写库、App Group、CLI 默认完整 payload 仍未开启。
- 验证输出、开发记录、验收记录、audit、logs 不包含剪贴板正文、payload text、图片 base64 或 OCR 文本。
- P11E 输出 read model allowlist / denylist 摘要，不能只输出 PASS/FAIL。

历史门禁当前事实源规则：

- Step 4C 阻断矩阵中凡使用旧 P3/P6/P7/P8/P9 脚本，开发前必须迁移到当前 Step 4C PRD、开发记录、验收记录或当前代码事实源。
- 仍读取 `docs/项目管理库/000_归档`、旧 `docs/项目管理库/实施记录/stories`、旧 acceptance / story 文档，或依赖旧 `AppState` / `SettingsView` 字符串形态的检查，只能作为 `baseline_reference`，不得参与 `ok` 判定。
- 已知需处理的候选包括但不限于：`p7q_screenshot_window_fullscreen_checks.py`、`p8_clipboard_product_polish_checks.py`、P3D/P3E/P3F、P6A/P6B/P6C、P8G、P9B。

### 7.2 子批次阻断门禁

Step 4C-1 ScreenshotStore：

```bash
python3 tools/verification/p11a_screenshot_store_boundary_checks.py
python3 tools/verification/p3c_screenshot_checks.py
python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py
python3 tools/verification/p3e_screenshot_result_polish_checks.py
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py
python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py
```

Step 4C-2 ShortcutStore：

```bash
python3 tools/verification/p11c_shortcut_store_checks.py
python3 tools/verification/p6a_shortcut_panel_interaction_checks.py
python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py
python3 tools/verification/p7c_shortcut_global_modifier_checks.py
python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py
```

Step 4C-3 Settings shell：

```bash
python3 tools/verification/p11d_settings_shell_split_checks.py
python3 tools/verification/p8g_settings_shell_redesign_checks.py
python3 tools/verification/p7b_settings_sidebar_stability_checks.py
python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py
python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py
python3 tools/verification/p7e_settings_visual_scroll_checks.py
python3 tools/verification/p7f_settings_menu_dedup_checks.py
```

Step 4C-4 Clipboard hardening：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
```

All Step 4C batches：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

如果触碰权限、TCC、签名、ScreenCaptureKit、shortcut hotkey、clipboard payload 或 provider route，按影响范围追加对应 P7 / P10 / P11 门禁。

## 8. 最小实物验收证据

每个子批次开发记录和测试/质量验收记录必须列出：

- 环境。
- 构建路径。
- 操作步骤。
- 已覆盖项。
- 未覆盖项。
- 低敏证据位置。
- 是否触发真实系统动作。
- 敏感数据处理声明。

Screenshot：

- Region / window / fullscreen 入口仍可达。
- Screen Recording 缺权提示和辅助路径不丢失。
- Screenshot Result copy/save/retake/close 不退化，copy success / copy failure、save success / save cancelled / save failure、retake 后状态更新、close 后主界面状态保持均需有低敏证据；无法真实触发的失败态必须写成未覆盖或用低敏测试替代。
- recent captures 更新正确，空态 / 列表态不误导用户。
- outcome banner 可见且不遮挡核心操作。
- AI route preview 仍是 preview，不上传图片，不调用 provider；ready / blocked、localized blocked detail、provider profile、confirmation level、dependency note 或等价信息不丢失。
- no-upload / provider-not-called 承诺必须是用户可见文案或等价可见状态，不只保留内部 token。
- 截图证据必须使用低敏桌面、低敏窗口标题和低敏图片；不得把真实屏幕内容写入记录。

Shortcut：

- 注册 / 禁用 / 失败 / 自定义绑定 / 恢复默认路径仍可验证。
- 快捷键动作只触发声明动作。
- Settings shortcut recorder 仍一次只录一个命令。
- invalid shortcut 有明确反馈，不能静默失败。
- Esc / cancel recording、录制中切换行、切换 pane、关闭 Settings 后 recorder 停止监听并恢复 idle。
- restore default 和 restore all defaults 后，binding source、注册结果和统计同步更新。
- Failed registration 展示 OSStatus 或等价失败摘要，不只写日志。

Settings：

- 各 mode 可打开。
- `clipboardPrivacy` 返回 Clipboard 设置。
- Provider / Translation / Permission / Shortcut / Clipboard pane 局部状态不串扰。
- Provider secret 输入、外发确认、连接测试状态不泄漏到其他 pane。
- Permission pane 继续使用 Step 4B accepted 的 `PermissionStore`；Translation pane 继续使用 Step 3 accepted 的 `TranslationStore`。
- 窄宽度、长文本、长路径、长 bundle ID、长 recommended action、中文 / 英文 / 日文长句和 VoiceOver label 做低敏抽查；不得出现控件丢失、文本不可理解截断或状态串扰。
- Toggle / Picker / icon button 等隐藏 label 控件必须能被可访问性检查读出具体设置名和动作名。

Clipboard hardening：

- repository unavailable 有用户可理解降级。
- 默认列表不读取完整 payload。
- 完整 payload 只在明确操作读取。
- 不把剪贴板正文写入验证输出。
- redacted list 不让用户误以为内容丢失。
- empty / unavailable / filtered / redacted 四类状态可区分。
- paste / copy / hover detail / translation preview 是完整 payload allowlist，验收输出只记录低敏读取类别和 record id 类标识。
- Clipboard hardening 若未进入 Step 4C，必须有 Step 4D handoff record，明确未接受范围和后续门禁。

## 9. 可接受标准

Step 4C 可接受必须同时满足：

- PRD 四方复审完成，P0/P1 为 0。
- PRD 阶段文档已提交，开发在干净基线上开始。
- Step 4C core 子批次 4C-1 ScreenshotStore、4C-2 ShortcutStore、4C-3 Settings shell 均有独立开发记录、必要复审、测试/质量验收和主 agent stop/go 记录。
- 4C-4 Clipboard hardening 若进入 Step 4C，必须有独立 go/no-go、开发记录、必要复审、测试/质量验收和主 agent stop/go 记录；若拆出 Step 4D，必须有 Step 4D handoff record，明确未接受范围、拆分原因、后续 P11E / UX / 安全 / 测试门禁。
- 已进入 Step 4C 的所有 P11 专项门禁通过；拆出 Step 4D 的 P11E 不得被写成 Step 4C 已通过。
- App / CLI build、`blocks --help`、`git diff --check` 通过。
- 无新增真实 secret 读写、截图图片外发、剪贴板正文日志、任意自动化执行能力。
- 主 agent 写 Step 4C 最终接受记录，明确接受范围和未覆盖残余。

## 10. 残余风险

预计残余风险：

- Settings shell 拆分可能产生大量文件移动，需避免无行为验收的机械重排。
- ScreenshotStore 若触碰 capture service 和 result presenter，回归面较大。
- ShortcutStore 若动作注入边界不清，可能扩大为通用自动化入口。
- Clipboard hardening 涉及敏感 payload 读取，安全和测试必须严格验证；如拆到 Step 4D，Step 4C 最终接受记录必须明确它未被接受。
- 如果四个子批次连续开发，开发记录必须清晰分段，否则验收难以定位问题。

## 11. 角色流程协议

### 11.1 方案复审

PRD 草案完成后并行派发：

- App 架构师：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-06-App架构师Step4C方案复审-v0.md`，重点看四个切片是否可放入同一 Step 4C、依赖顺序、store / pane / AppState 边界。
- UI/交互设计师：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-06-UI交互Step4C方案复审-v0.md`，重点看 Screenshot Result、Shortcut settings、Settings shell、Clipboard degraded 状态和体验证据。
- 测试/质量：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-06-测试质量Step4C方案复审-v0.md`，重点看 P11A/C/D/E 可执行性、旧门禁事实源、分批验收矩阵。
- 安全合规顾问：输出 `docs/项目管理库/003_架构升级/step_4/2026-07-06-安全合规Step4C方案复审-v0.md`，重点看截图图片、剪贴板 payload、快捷键动作、provider route、日志和系统 API token。

主 agent 汇总复审意见后回写本文。P0/P1 未关闭前不得派开发。

### 11.2 PRD 提交

PRD 复审完成并回写后，主 agent 必须先提交 PRD、复审文档和阶段状态更新，再派开发。

### 11.3 开发回调

开发线程按子批次回调，每次提供：

- 子批次编号。
- 开发记录路径。
- 实际改动文件。
- 运行命令和结果。
- 未运行命令和原因。
- 低敏实物证据。
- 安全隐私声明。
- 残余风险。

### 11.4 验收与最终接受

- 每个子批次至少由测试/质量独立验收。
- 触碰架构边界的子批次由 App 架构师复审。
- 触碰截图、剪贴板、快捷键、权限、provider route 或日志的子批次由安全合规复审。
- 触碰 Settings / Screenshot Result / Shortcut UX 的子批次由 UI/交互复审或抽查。
- Step 4C core 子批次均无 P0/P1，且 4C-4 若进入本阶段也无 P0/P1 后，主 agent 写 Step 4C 最终接受记录并提交实现。
- 若 4C-4 被拆到 Step 4D，主 agent 必须先写 Step 4D handoff record，再写 Step 4C 最终接受记录；最终接受记录不得暗示 Clipboard hardening 已完成。
