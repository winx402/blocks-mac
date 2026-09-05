# Step 4C-2 ShortcutStore 开发记录 v0

日期：2026-07-06
角色：开发
结论：验证通过，存在 P2 残余风险，待主会和测试/质量验收

## 1. 改动范围

- 新增 `apps/Blocks/BlocksApp/Features/Shortcuts/ShortcutStore.swift`，作为快捷键注册状态、配置动作、诊断指标和绑定 facade 的 feature-level 事实源。
- 更新 `apps/Blocks/BlocksApp/Stores/AppState.swift`：持有 `ShortcutStore`，桥接 `shortcutStore.objectWillChange`，保留 `shortcutRegistrationResults`、注册计数、绑定配置、restore default、refresh 等 public facade。
- 更新 `apps/Blocks/Blocks.xcodeproj/project.pbxproj`：将 `ShortcutStore.swift` 加入 Blocks app target。
- 新增 `tools/verification/p11c_shortcut_store_checks.py`，覆盖 P11C ShortcutStore 边界门禁。
- 更新 P6A/P6B/P6C/P7C/P7D：阻断证据切换到当前 Step 4C PRD、当前 4C-2 开发记录和当前代码事实源；旧事实源仅保留为 `baseline_reference`，不参与 `ok`。

## 2. 未改范围

- 未启动 Step 4C-3 Settings shell split。
- 未启动 Step 4C-4 Clipboard hardening。
- 未重写 `SettingsView` 结构。
- 未修改 `ShortcutBindingStore` 持久化 key、迁移策略或 UserDefaults 存储策略。
- 未改 Permission、Screenshot、Clipboard、Provider runtime 业务逻辑。

## 3. 关键实现决策

- `ShortcutStore` 持有现有 `ShortcutController` adapter，继续通过 `ShortcutBindingStore` 读取和保存快捷键配置。
- `ShortcutStore` 不持有完整 `AppState`；AppState 初始化完成后通过 `ShortcutActionHandlers` 注入三个声明动作闭包。
- 声明动作 allowlist 仅包含 `screenshotRegion`、`clipboardHistory`、`translationPanel`。
- AppState 保留 shell/coordinator facade 和 status banner 责任，`shortcutRegistrationResults` 不再是 AppState 的 `@Published` 事实源。
- Settings 的 `ShortcutRecorderState` 仍保持单一 `@State`，P6A / P6B / P6C 覆盖快捷键配置、录制、诊断、restore default 和低敏证据；P7C / P7D 覆盖 global modifier 与浮窗焦点路径。

## 4. 旧事实源处理

- P6A/P6B/P6C 不再把 `docs/项目管理库/实施记录/stories` 或旧 acceptance/story 文档作为阻断输入。
- P7C/P7D 继续使用当前代码事实，并新增当前 Step 4C PRD 与本开发记录作为 `current_evidence`。
- P11C 会 fail closed 检查旧 story / 归档 / 旧 AppState 字符串形态不得参与阻断 `ok`。

## 5. 验证结果

| 命令 | 结果 | 说明 |
| --- | --- | --- |
| `python3 tools/verification/p11c_shortcut_store_checks.py` | PASS | P11C ShortcutStore 边界门禁通过；target membership、AppState facade、objectWillChange、allowlist、forbidden token、旧事实源检查均为 PASS。 |
| `python3 tools/verification/p6a_shortcut_panel_interaction_checks.py` | PASS | P6A shortcut panel interaction 当前事实源门禁通过。 |
| `python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py` | PASS | P6B 快捷键配置 / panel polish 当前事实源门禁通过。 |
| `python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py` | PASS | P6C acceptance gate 当前事实源门禁通过；曾因旧门禁要求 `settings.shortcutManualChecklist` 出现在代码事实中失败，已收敛为 localization key 检查。 |
| `python3 tools/verification/p7c_shortcut_global_modifier_checks.py` | PASS | P7C global modifier 门禁通过，global modifier facade 可追踪到 ShortcutStore。 |
| `python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py` | PASS | P7D panel exclusivity / shortcut focus 门禁通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | Blocks app build 通过；仍有既有 FloatingPanelSupport MainActor warning 与 AppIntents metadata skipped warning，未阻断。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | BlocksCLI build 通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出 `blocks list | blocks run blocks.screenshot.capture --dry-run [--mode region|window|fullscreen]`。 |
| `git diff --check` | PASS | whitespace / patch hygiene 通过。 |

## 6. 未覆盖项

- 未触发真实系统快捷键按键；本轮自动化验证不触发真实系统快捷键。
- 未自动化真实 Settings UI 操作、录制快捷键、Esc/cancel、切换行、切换 pane 或关闭 Settings 后监听清理。
- 未触发真实权限请求、系统设置、Show in Finder、restart、provider call、图片外发或剪贴板 payload 读取。
- 以上真实 UI / shortcut 实物场景需由主会或测试/质量在低敏环境中验收，不得把本记录写作已覆盖。

## 7. 安全隐私声明

- 本切片仅做 ShortcutStore 单切片状态拆分和 verification 事实源迁移。
- 未写入真实凭据，未读取真实 secrets，未调用真实外部 provider。
- 未输出真实剪贴板正文、选中文本、屏幕文本、窗口标题、图片/base64/OCR 原文。
- 未新增任意 shell、AppleScript、CGEvent/CGEventPost、外部 CLI、Accessibility 前台 UI 操作或动态 action 字符串派发。

## 8. 残余风险

- P2：真实系统快捷键注册冲突、OSStatus 展示、Esc/cancel 和 Settings pane 切换清理仍需低敏实物验收。
- P2：现有 `SettingsView` 仍较大，4C-3 才会处理 Settings shell split；本切片只保持现状并迁移快捷键事实源。
