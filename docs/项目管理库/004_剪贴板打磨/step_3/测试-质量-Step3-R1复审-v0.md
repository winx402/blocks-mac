# 004_剪贴板打磨 Step 3 R1 测试/质量定向复审 v0

日期：2026-07-07

复审角色：测试/质量

结论：`approve`

## 复审范围

本轮只复审 Step 3 R1 修复点与必要回归，不重新打开 Step 3 全量范围，不进入 Step 4。未触发真实 App、真实剪贴板、TCC、provider、Keychain、系统设置或自动化；未修改业务代码。

输入事实源：

- `AGENTS.md`
- `agents/测试-质量.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `step_3/测试-质量-Step3开发复审-v0.md`
- `step_3/开发记录-Step3-R1-v0.md`
- `step_3/项目负责人-Step3-R1验收-v0.md`
- 必要代码、P13C manifest 与 verification 脚本

## P0 / P1 / P2 Findings

### P0

无。

### P1

无。

上一轮收敛中的两个 P1 从测试/质量视角已关闭：

1. `detail_open` 不再只由 manifest 自述通过。P13C 新增代码级检查，且当前输出 `detailCodePathChecks=true`；代码中 hover detail open 通过 `handleRecordAction(... source: .hoverDetail, trigger: .hoverDetail, action: .detailOpen)` 进入统一 handler，再由 `.hoverDetail` purpose 做 lazy payload read。
2. paste activation 不再是 icon-only / 硬编码中文语义。P13C 当前输出 `pasteActivationLocalizationChecks=true`；代码使用 `L10n` 与 String Catalog，控件显示 `Text(mode.title)` + `mode.systemImage`，并提供 group / option / selected accessibility 语义。

### P2

1. 真实 App UI、真实剪贴板、真实 VoiceOver、TCC、provider、Keychain、系统设置仍未覆盖。本轮任务边界明确禁止触发这些动作；该限制仍可作为 P2 residual 接受。
2. SwiftUI 单击 / 双击真实事件顺序未通过现场 UI 自动化或录屏实测；当前由 activation handler 静态检查、低敏 manifest 和 event log 支撑。
3. Blocks App build 仍有既有 `FloatingPanelSupport.swift` main actor warning 和 AppIntents metadata skip；本轮未见 R1 新增构建 blocker。

## R1 修复点复核

### 1. P13C 新增 detail code path

判断：充分。

证据：

- `P13C` PASS，`detailCodePathChecks=true`。
- `static_checks.detail_open_handler_present=true`。
- `static_checks.detail_open_precedes_surface_load=true`。
- `static_checks.detail_payload_load_is_hover_detail=true`。
- 静态抽查命中 `.hoverDetail`、`.detailOpen`、`handleRecordAction(...)` 和 `readPayload(recordID: record.id, purpose: .hoverDetail)`，P13C 不再只信 manifest 中的 `detail_open` 事件。

### 2. Paste activation localization / accessibility

判断：充分。

证据：

- `P13C` PASS，`pasteActivationLocalizationChecks=true`。
- `static_checks.paste_activation_localized=true`。
- `static_checks.paste_activation_visible_current=true`。
- `static_checks.paste_activation_accessibility=true`。
- `ClipboardPanelSettings.swift` 使用 `L10n.string("clipboard.panel.pasteActivation...")`。
- `Localizable.xcstrings` 包含 zh-Hans / en / ja 的短标签、完整标签、accessibility、selected / not selected 文案。
- 顶部控件不再以通用 `checkmark.circle.fill` 代替模式语义。

### 3. Hover safe bridge hit-testing

判断：充分。

证据：

- `P13C` PASS，`hoverBridgeHitTestingChecks=true`。
- `static_checks.hover_safe_bridge_hit_transparent=true`。
- `ClipboardFilterBarView.swift` 中 `safeBridgePadding: 12`、`safeRegionInflation: 16` 与派发默认对齐，并显式 `.allowsHitTesting(false)`。
- `static_checks.hover_no_global_event_monitor=true`，未引入全局 event monitor。

### 4. Direct paste broadened scan

判断：充分。

证据：

- `P13C` PASS，`staticGestureChecks=true`。
- `static_checks.direct_paste_gesture_removed=true`。
- P13C 当前不只匹配旧字面量 `TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() }`，还在 row/card 主体范围内扫描 `onPaste()`、`pasteClipboardRecord(`、`action: .paste`、`performPaste` 等绕过 `onPrimaryActivation` 的直连风险。
- 静态抽查仍能看到父级闭包参数 `onPaste:`，但 row/card 主体 primary activation 入口使用 `onPrimaryActivation(.singleClick/.doubleClick)`；当前 P13C 范围未发现主体直连 paste。

## 回归矩阵判断

判断：足以支持 Step 3 进入最终验收准备。

已独立运行并通过：

| 命令 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS | `ok=true`；`detailCodePathChecks=true`；`pasteActivationLocalizationChecks=true`；`hoverBridgeHitTestingChecks=true`；`failures=[]` |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | `ok=true`；sanitizer PASS |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS | `ok=true`；`tag_search.e2e_gate=pass`；legacy exit clear |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | `step2_clear_all_includes_tag_filter=true` |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS | Settings clipboard system 边界通过 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `ok=true`；`storage_root=<TMP>`；search/OCR/tag fixtures 通过 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | `ok=true`；未用旧 AppState/archive 作为 ok evidence |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | `ok=true`；tag filter/menu/settings no payload reads |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `** BUILD SUCCEEDED **`；仅见既有 warning / metadata skip |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `** BUILD SUCCEEDED **` |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出低敏 action list 与 usage |
| `git diff --check` | PASS | 无输出 |

补充静态抽查：

- `rg` 抽查 P13C 新增 R1 checks：detail code path、paste activation localization/accessibility、hover bridge hit-testing、direct paste broadened scan 均存在。
- `rg` 抽查 `ClipboardFloatingPanelView.swift`、`ClipboardRecordViews.swift`、`ClipboardFilterBarView.swift`、`ClipboardPanelSettings.swift`，确认 `.hoverDetail` / `.detailOpen` / `handleRecordAction` / `.allowsHitTesting(false)` / 12/16 参数 / L10n 文案路径存在。
- `python3 -m json.tool .../manifest-v0.json` 抽查 manifest，仍为 synthetic-low-sensitivity evidence。

## 假 PASS 风险判断

未发现新的 P0/P1 或假 PASS 风险。

理由：

- P13C 输出明确使用当前 `开发记录-Step3-R1-v0.md` 作为 `current_evidence.dev_record`。
- `baseline_reference.old_archives_used_for_ok=false`、`old_step_docs_used_for_ok=false`、`real_app_or_clipboard_used_for_ok=false`。
- R1 新增的 P13C checks 已覆盖此前会导致假 PASS 的 detail code path 和 direct paste 扫描不足。
- P8 仍保留 `step2_clear_all_includes_tag_filter=true`，未因 Step 3 toolbar 改造掩盖 Step 2 tag filter clear-all 回归。

## 残余风险

- 真实 UI / 真实剪贴板 / 真实 VoiceOver 未覆盖仍是 P2 residual，可接受但不能写成已实测。
- P13C 是静态代码检查 + 低敏 fixture manifest + 合成事件证据，不等同于真实鼠标 hover、双击和辅助功能现场录屏。
- 建议后续 Step 6 或专门实物回扫补低敏真实 UI/VoiceOver 证据；当前 R1 不要求因此返工。

## 最终判断

Step 3 R1 从测试/质量角度可进入项目负责人最终验收准备。当前 P0/P1 为 0，R1 修复点和必要回归证据充分，真实 UI / 真实剪贴板 / 真实 VoiceOver 未覆盖继续作为 P2 residual 管理。
