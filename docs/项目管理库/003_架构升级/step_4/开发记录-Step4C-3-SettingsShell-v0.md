# Step 4C-3 Settings shell split 开发记录 v0

## 结论

当前记录用于 Step 4C-3 Settings shell split 单切片开发。实现目标是把 `SettingsView` 拆为兼容 wrapper + `SettingsShellView` + feature pane 文件，并保持现有 setting key、路由、局部状态和 Settings UX 不退化。

## 实际改动范围

- 新增 `apps/Blocks/BlocksApp/Features/Settings/SettingsShellView.swift`，承接 Settings 页面滚动容器、header、mode route mapping 和 `all` 组合。
- 新增 `apps/Blocks/BlocksApp/Features/Settings/SettingsSectionList.swift`，承接 `SettingsViewMode`、Settings header、pane group、section/row 等共享布局组件。
- 新增 General、Clipboard、Shortcut、Permission、Provider、Translation、AgentCLI、Hooks、DataAudit pane 文件。
- `apps/Blocks/BlocksApp/Views/SettingsView.swift` 退化为兼容 wrapper，仅保留 `mode` 和 `SettingsShellView(mode: mode)`。
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj` 接入上述 Settings shell / pane 文件到 Blocks app target。
- 新增 `tools/verification/p11d_settings_shell_split_checks.py`。
- 更新 P8G/P7B/P7C/P7D/P7E/P7F Settings 相关 verifier，使阻断检查使用当前 Step 4C 事实源；旧事实源只作为 `baseline_reference` 说明，不参与 `ok` 判定。

## 未改范围

- 未启动 Step 4C-4 Clipboard hardening。
- 未重写 Provider / Translation / Permission / Shortcut / Clipboard 行为。
- 未更改 setting key、持久化策略、provider secret 输入流程、外发确认、route check 或连接测试语义。
- 未触发真实权限请求、系统设置、Show in Finder、restart、真实快捷键按键、provider call、Keychain secret 读取或剪贴板完整 payload 读取。

## 关键实现决策

- `SettingsView` 只保留 facade，主体迁入 `SettingsShellView`。
- 每个 pane 自己持有原本属于该 pane 的 `@AppStorage` / `@State`，Provider secret 输入、外发确认、连接测试确认、Shortcut recorder state 仍是 pane 局部状态，没有迁入全局 store。
- `clipboardPrivacy` 明确映射到 `ClipboardSettingsPane(showPrivacySection: true)`，普通 `clipboard` 映射到 `ClipboardSettingsPane(showPrivacySection: false)`。
- `hooks` 明确映射到 `HooksSettingsPane()`；`dataAudit` 明确映射到 `DataAuditSettingsPane()`。
- Permission pane 保持通过 `appState.permissionSnapshot` facade 读取 Step 4B accepted 的 `PermissionStore` 状态。
- 新 pane 不直接出现 `URLSession`、`SecItem`、`Authorization`、`Bearer`、`Process(`、`getenv(`、`NSWorkspace`、`NSPasteboard.general`、provider route 直连或 clipboard full payload 读取。Permission 拖拽卡片保留用户显式拖拽行为，图标读取改用 `NSApplication.shared.applicationIconImage`，避免在 pane 中直接出现系统设置/工作区动作 token。

## P11D 检查摘要

- P11D 覆盖 target membership、`SettingsView` wrapper、全量 `SettingsViewMode`、mode mapping、`clipboardPrivacy` 返回 Clipboard pane、setting key 保留、pane 局部状态不进全局 store、敏感 forbidden token、旧事实源处理。
- P11D 初始红灯已按预期失败，失败集中在新 Settings 文件、target membership、wrapper 和开发记录缺失。
- 当前 P11D 最终结果 PASS。

## 旧事实源处理

- P8G/P7B/P7C/P7D/P7E/P7F 的阻断判断已迁移到当前 PRD、当前开发记录和当前代码事实源。
- 旧 story、旧 acceptance、旧归档、旧 AppState 单体字符串不参与 `ok` 判定。
- verifier 输出保留 `baseline_reference` 字段，仅说明旧资料未作为阻断输入。

## 运行命令和结果

| 命令 | 结果 | 备注 |
| --- | --- | --- |
| `python3 tools/verification/p11d_settings_shell_split_checks.py` | PASS | Settings shell split 边界、target membership、mode mapping、forbidden token、旧事实源处理均通过。 |
| `python3 tools/verification/p8g_settings_shell_redesign_checks.py` | PASS | 已使用当前 `Features/Settings` shell/pane 事实源。 |
| `python3 tools/verification/p7b_settings_sidebar_stability_checks.py` | PASS | 已使用当前 Settings shell 和 sidebar 事实源。 |
| `python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py` | PASS | 已使用当前 Settings mode / pane mapping / Permission pane 事实源。 |
| `python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py` | PASS | Clipboard / Translation route 与 sidebar visual 静态检查通过。 |
| `python3 tools/verification/p7e_settings_visual_scroll_checks.py` | PASS | Sidebar scroll、Settings shell padding、header icon、Clipboard pane advanced control 检查通过。 |
| `python3 tools/verification/p7f_settings_menu_dedup_checks.py` | PASS | Settings 菜单路由去重检查通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 构建通过；日志仍有既有 `FloatingPanelSupport.swift` main actor warning 和 AppIntents metadata warning，非本次新增错误。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出仅包含 `blocks.screenshot.capture` 动作列表和 usage。 |
| `git diff --check` | PASS | 无 whitespace error。 |

## 未覆盖项

- 未做真实 UI 自动化点击、真实系统权限动作、真实快捷键按键或真实外部 provider 调用。
- Settings 视觉与滚动的实物交互仍建议主会或 UI/交互在验收阶段手动确认。
- 未做多语言实际渲染截图验收；仅通过 localization key 和静态 UI 结构检查。

## 低敏证据

- 本记录只记录文件路径、命令名和 PASS/FAIL，不记录真实用户主目录之外的敏感内容、窗口标题、剪贴板正文、屏幕文本、图片/base64、secret 或 provider raw response。

## 安全隐私声明

- 本次未保存或读取真实敏感凭据。
- 本次未读取 Keychain secret，未调用真实外部 provider，未上传图片，未读取剪贴板完整 payload。
- 本次未触发真实权限请求、系统设置、Show in Finder、restart 或 TCC reset。
