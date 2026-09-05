# P7-E 设置页、Clipboard、Translation 与权限辅助深度打磨

状态：partially superseded by P7-F; automated checks exist; pending low-sensitive manual acceptance

本轮把用户在 P7-D 后继续指出的问题独立成质量门禁。每一项必须按 `research / plan / dev / test / close` 记录；没有真实人工验收的项目不能写成完全关闭。

## Scope

- 设置页整体风格、滚动和 route 稳定性。
- Clipboard 浮层位置策略、hover detail、双击自动粘贴。
- Translation 浮层语言识别、交换语言、结果展示。
- Screen Recording / Accessibility 权限辅助流程。

## References

- Apple Screen & System Audio Recording permission: <https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac>
- Apple Accessibility permission: <https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac>
- Apple Privacy & Security settings: <https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac>
- Paste Mac interaction reference: <https://pasteapp.io/help/paste-on-mac>
- Bob quick translation reference: <https://bobtranslate.com/guide/quickstart/translate.html>

## Issue Ledger

| ID | User issue | Research | Plan | Dev | Test | Close |
| --- | --- | --- | --- | --- | --- | --- |
| P7-E-01 | Settings 整体风格不统一，内容区顶到上方，侧栏不可滚动导致底部菜单选不到。 | Existing `ContentView` sidebar used a plain `VStack` without a scroll container; `SettingsView` content started with small vertical padding. | Make the sidebar independently scrollable, increase row height, reuse colored icon badge, and give Settings pages stable top/bottom padding plus section icon treatment. | Implemented in `ContentView.swift` and `SettingsView.swift`. | Covered by `p7e_settings_visual_scroll_checks.py`; manual visual pass still pending. | `implemented`; close after low-sensitive UI pass. |
| P7-E-02 | Clipboard bottom 浮层必须满宽、宽度不可调，高度可调并保存；left/right 固定屏幕高度。 | Existing `FloatingPanelFrameStore` saved width and height for all positions, so later opens restored a stale non-full-width frame. | Store only bottom height; derive bottom width from `visibleFrame`; clamp left/right to fixed visible height. | Implemented in `FloatingPanelSupport.swift` and `ClipboardHistoryPanelPresenter.swift`. | Covered by `p7e_clipboard_position_autopaste_checks.py`; manual resize pass still pending. | `implemented`; close after manual resize verification. |
| P7-E-03 | Clipboard 条目双击后自动粘贴到原输入框；缺 Accessibility 时显示授权引导。 | macOS paste automation needs Accessibility for synthetic Command+V; real user clipboard records remain redacted and not restorable. | Add fixture-only auto-paste coordinator: write low-sensitive restorable payload, restore target app, send Command+V; on missing Accessibility show assist panel. | Initial P7-E implementation left permission refresh and retry gaps. Reopened and addressed in [P7-F](p7-f-settings-permission-regression-fix.md). | P7-E script covers static shape; P7-F adds permission retry checks. | `reopened_by_p7f`; close only after manual paste pass. |
| P7-E-04 | Translation 语言 picker 未对齐；Auto 目标语言错误；中间应是双向箭头；结果必须展示。 | Existing resolver returned only a target language, so UI had no effective detected source state; swap was disabled in auto mode. | Return detected/effective source language; align pane headers; allow swap using effective source; prioritize result text display. | Implemented in `TranslationLanguageResolver.swift` and `TranslationFloatingPanelView.swift`. | Covered by `p7e_translation_language_result_checks.py`; manual Chinese/English/Japanese pass still pending. | `implemented`; close after manual translation pass. |
| P7-E-05 | 打开屏幕录制权限时 JDTool 设置页应隐藏，辅助面板应贴近系统设置，不应遮挡；箭头动画只作用于箭头。 | Apple permission flows remain user-mediated in System Settings; app can open Privacy panes and guide, not bypass TCC. | Make permission assist a flow coordinator: hide JDTool windows, open target Privacy pane, locate System Settings window when possible, show draggable app icon and animated arrow, close on grant or System Settings close. | Initial P7-E implementation could close before System Settings appeared and had fixed arrow direction / panel-drag leakage. Reopened and addressed in [P7-F](p7-f-settings-permission-regression-fix.md). | P7-E script covers baseline; P7-F adds launch grace, placement, arrow direction, and drag isolation checks. | `reopened_by_p7f`; close only after manual permission-flow pass. |
| P7-E-06 | Clipboard / Translation panels must behave like tool floaters, not normal windows. | P7-D already added mutual exclusion and click-outside close; P7-E preserves that and narrows Clipboard sizing behavior. | Keep show/focus semantics; avoid bringing Settings forward through panel flows; Settings button from panel routes to relevant settings. | Old main-window Clipboard / Translation routes remained visible and were removed in [P7-F](p7-f-settings-permission-regression-fix.md). | Covered by P7-D/P7-E scripts; P7-F adds menu dedup check. | `reopened_by_p7f`; close after sidebar/manual shortcut pass. |

## Verification

Automated scripts added:

- `tools/verification/p7e_issue_ledger_checks.py`
- `tools/verification/p7e_settings_visual_scroll_checks.py`
- `tools/verification/p7e_clipboard_position_autopaste_checks.py`
- `tools/verification/p7e_translation_language_result_checks.py`
- `tools/verification/p7e_permission_assist_flow_checks.py`

## Manual Acceptance Still Required

- Settings sidebar can scroll to every route and content scrollbars remain visible.
- Clipboard bottom mode opens full width, only height changes persist; left/right stay fixed height.
- Double-clicking a low-sensitive fixture pastes into a current text field when Accessibility is granted; missing permission shows assist.
- Translation Chinese input resolves to English target and shows output; swap uses detected source.
- Permission assist panel does not cover JDTool settings, appears relative to System Settings when discoverable, and closes when the permission flow ends.
