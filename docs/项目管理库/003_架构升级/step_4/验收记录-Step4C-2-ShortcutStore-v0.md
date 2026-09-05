# Step 4C-2 ShortcutStore 测试/质量验收记录 v0

日期：2026-07-06
角色：测试/质量
结论：accepted-with-residual-risk

## 验收范围

- 本次仅验收 Step 4C-2 ShortcutStore 单切片。
- 事实源：`PRD-Step4C-剩余Feature收口-v0.md`、`开发记录-Step4C-2-ShortcutStore-v0.md`、当前代码和当前 verification 脚本。
- 未启动、未验收 4C-3 Settings shell、4C-4 Clipboard hardening。
- 未创建分支、未提交 commit、未修改业务代码。

## 已验证项

- `apps/Blocks/BlocksApp/Features/Shortcuts/ShortcutStore.swift` 存在并进入 Blocks app target。
- `AppState.shortcutRegistrationResults` 不再是 `@Published` 事实源；当前为 computed facade，转发 `shortcutStore.shortcutRegistrationResults`。
- `AppState` 持有 `ShortcutStore`，并通过 `bindShortcutStore()` 桥接 `shortcutStore.objectWillChange`。
- `ShortcutStore` 不持有完整 `AppState`，只接收 AppShell 注入的 `ShortcutActionHandlers` 窄动作闭包。
- 快捷键动作 allowlist 与 PRD 一致：`screenshotRegion`、`clipboardHistory`、`translationPanel`；未发现动态 action 字符串派发。
- `ShortcutStore` forbidden token 检查通过：未发现 provider、translation、screenshot store、URLSession、SecItem、Authorization、Bearer、Process/getenv、AppleScript、CGEvent/CGEventPost、AXUIElement、Register/UnregisterEventHotKey、NSPasteboard、clipboard payload read 或 secret 读取等禁止 token。
- `ShortcutBindingStore` 持久化路径保留，未改 shortcut binding / enabled / global modifier 的既有 UserDefaults key 与 restore default 入口。
- Settings 中 `shortcutRecorderState` 仍为单一 recorder state，P11C 覆盖 `recording(command)`、local monitor、stopRecording 和 onDisappear 清理符号。
- P6A/P6B/P6C/P7C/P7D 输出均指向当前 Step 4C PRD 和当前 4C-2 开发记录；旧 story/archive/project docs 未参与 `ok`。
- 构建和 CLI 通过；未触发真实系统快捷键按键、真实 UI 操作、权限请求、provider call 或剪贴板 payload read。

## 命令结果

| 命令 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p11c_shortcut_store_checks.py` | PASS | `ok=true`；target membership、AppState direct fact source、allowlist、forbidden tokens、ShortcutBindingStore、single recorder state、historical gate current sources 均无 failure。 |
| `python3 tools/verification/p6a_shortcut_panel_interaction_checks.py` | PASS | `ok=true`；app build 通过；localization checked=12；privacy forbidden hits 为空；`legacy_story_used_for_ok=false`。 |
| `python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py` | PASS | `ok=true`；app build 通过；localization checked=11；privacy forbidden hits 为空；`legacy_story_used_for_ok=false`、`legacy_project_docs_used_for_ok=false`。 |
| `python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py` | PASS | `ok=true`；app build 和 P6B regression 通过；localization checked=9；`legacy_story_used_for_ok=false`。 |
| `python3 tools/verification/p7c_shortcut_global_modifier_checks.py` | PASS | `ok=true`；app build 通过；current evidence 指向 Step 4C PRD 和 4C-2 开发记录；`legacy_story_used_for_ok=false`。 |
| `python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py` | PASS | `ok=true`；checked files 包含 AppState、ShortcutStore、Clipboard/Translation panel presenter 和 FloatingPanelSupport；`legacy_story_used_for_ok=false`。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`；仅见既有 Xcode 多 destination warning、`FloatingPanelSupport.swift` MainActor/NSApp warning、AppIntents metadata skipped warning。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`；仅见 Xcode 多 destination warning。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出仅包含 `blocks.screenshot.capture`，usage 为 dry-run 截图命令。 |
| `git diff --check` | PASS | 写入验收记录前无输出；写入验收记录后复跑也无输出。 |

## 未验证项 / 环境限制

- 未触发真实系统快捷键按键或真实全局快捷键注册冲突。
- 未实物操作 Settings UI：未录制快捷键、未按 Esc/cancel、未切换录制行、未切换 pane、未关闭 Settings 后观察 recorder 监听清理。
- 未触发真实权限请求、系统设置、Show in Finder、restart、TCC reset 或 TCC 状态变化。
- 未触发 provider call、图片外发、真实 OCR、Keychain secret 读取或网络请求。
- 未读取剪贴板完整 payload；本轮只验证快捷键动作边界不会扩大为 clipboard payload read。

## P0 / P1 / P2

- P0：未发现。
- P1：未发现。
- P2：真实系统快捷键按键、OSStatus 展示、注册冲突、Esc/cancel、录制中切换行、切换 pane、关闭 Settings 后 recorder 清理仍需低敏实物验收。
- P2：SettingsView 仍较大，Settings shell split 属于 4C-3，本轮只确认 ShortcutStore 单切片迁移未扩大范围。
- P2：既有 `FloatingPanelSupport.swift` MainActor/NSApp warning 和 AppIntents metadata skipped warning 仍存在；本轮未见其阻断 4C-2。

## 质量判断

自动化门禁、代码抽查和串行构建证据足以支撑 Step 4C-2 ShortcutStore 单切片进入主 agent stop/go。残余风险集中在真实系统快捷键和 Settings UI 实物场景，测试/质量不替主 agent 接受该残余风险。

建议：允许主 agent 基于本记录做 4C-2 stop/go；进入 4C-3 前仍应遵守 Step 4C 子批次硬门禁，即前一子批次 P0/P1 未关闭不得启动后一子批次。
