# 代码审查 - Step 3 R1 复审

日期：2026-07-07
角色：代码审查
范围：只读定向复审 `004_剪贴板打磨` Step 3 R1 修复点与必要回归；未重新打开 Step 3 全量范围，未进入 Step 4。

## 结论

`approve-with-changes`

R1 的上一轮 P1 已关闭：`.detailOpen` 现在经过统一 activation handler，`.hoverDetail` 详情打开路径先写 selected/focused/token/event，再进入详情 surface 与 payload 读取；P13C 也已从 manifest-only 扩展到相关代码路径检查。

本轮未发现新的 P0/P1。仅有 1 个 P2 verifier 覆盖缺口，影响未来回归捕获，不影响当前 R1 代码的实际可用路径。

## P0 Findings

无。

## P1 Findings

无。

上一轮 P1 关闭依据：

- `apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift:260` 的 `showDetail(for:)` 在 `detailCoordinator.show(...)` 前调用 `onHoveredRecordChanged?(recordID)`。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:800` 的 `setHoveredRecordID(_:)` 对非空 record 调用 `handleRecordAction(recordID, source: .hoverDetail, trigger: .hoverDetail, action: .detailOpen)`。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:728` 的 `handleRecordAction` 先生成 token、`selectAndFocusRecord`、记录 interaction event，再按 action 分发；`.detailOpen` 分支仅在之后设置 `hoverDetailState`。
- `apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift:617` 的详情 payload 读取使用 `clipboardStore.readPayload(recordID: record.id, purpose: .hoverDetail)`，与 hover detail 打开语义一致。
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py:361` 的 static checks 覆盖 `detail_open_handler_present`、`detail_open_precedes_surface_load`、`detail_payload_load_is_hover_detail`、view-local state、paste activation、hover safe bridge 和 direct paste gesture removal。

## P2 Findings

1. `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py:91` 的 `PASTE_ACTIVATION_KEYS` 未覆盖 `ClipboardPasteActivationMode.menuTitle` 使用的 `.label` localization keys。

   代码路径：`apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift:28` 使用 `clipboard.panel.pasteActivation.single.label`，`apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift:33` 使用 `clipboard.panel.pasteActivation.double.label`。当前 `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings:2381` 和 `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings:2513` 已存在对应 key，因此当前 UI/help 文案不会因此坏掉。

   风险：未来误删或改名 `.label` keys 时，P13C 仍可能通过，paste activation localization/accessibility 的 fail-closed 覆盖不完整。

   建议修复：把 `clipboard.panel.pasteActivation.single.label` 与 `clipboard.panel.pasteActivation.double.label` 加入 `PASTE_ACTIVATION_KEYS`，保持与 `ClipboardPanelSettings.menuTitle` 的实际契约一致。该修复不需要改业务行为。

## Residual Risk

- 本轮未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化；未做真实 hover/click/VoiceOver 运行时验收。
- Hover safe bridge 的 `.allowsHitTesting(false)`、12/16 参数和 detail ordering 已做静态验证，但 AppKit/SwiftUI 实际 hit-testing 与指针 re-enter 行为仍需后续真实 UI 验收覆盖。
- 本轮未重跑 `xcodebuild`；项目负责人 R1 验收记录已包含 app/CLI build 通过。本轮复审聚焦 R1 修复点与 verifier fail-closed。

## 已查看关键文件

- `AGENTS.md`
- `agents/代码审查.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-Step3开发复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/开发记录-Step3-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-Step3-R1验收-v0.md`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift`
- `apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift`
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`

## 已运行命令

- `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`：PASS
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`：PASS
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`：PASS
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`：PASS
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`：PASS
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`：PASS
- `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`：PASS
- `python3 tools/verification/p13b_clipboard_tags_model_checks.py`：PASS
- `git diff --check`：PASS
- 静态只读检索：`rg` / `nl -ba` 定位 detail/hover/paste activation/P13C 关键路径，未触发运行时 App 或系统能力。
