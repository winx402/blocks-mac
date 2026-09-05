# 004_剪贴板打磨 Step 4 R3 开发记录

日期：2026-07-07

结论：DONE_WITH_EVIDENCE

## 范围

本轮只处理 Step 4 R3 定向返工的单一 P1：`AppModel` 调用方不能把 guarded `clipboardHistoryPanelPresenter.close()` 当同步关闭使用，并在 dirty guard 完成前继续执行 paste / translation 副作用。

实际改动文件：
- `apps/Blocks/BlocksApp/App/AppModel.swift`
- `apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R3-v0.md`

未改范围：
- 未进入 Step 5 / Step 6。
- 未重做 R1/R2 已关闭的 OCR guard、metadata full value、rich text fidelity、Presenter/View/DetailStore 面板级关闭 guard。
- 未触碰 repository、OCR、search document、tags 或 settings，因此未补跑 P13A / P13B / P8I / P9A。
- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。

## 修复说明

`ClipboardHistoryPanelPresenter` 新增 `close(afterClose:)`，复用 R2 的 `requestClosePanel(afterClose:)`。调用方如果需要“关闭剪贴板面板后继续动作”，必须把后续动作放进 guarded continuation。

`AppModel` 调整：
- `showTranslationFloatingPanel` 只发起 `clipboardHistoryPanelPresenter.close(afterClose:)`，不再同步打开 translation panel、读取 clipboard preview 或修改 `translationStore`。
- 新增 `continueShowTranslationFloatingPanel(openMainWindow:)`，translation panel focus/present、clipboard preview 读取和 `translationStore.prepareManualTranslation` 只在 dirty guard continuation 后执行。
- `pasteClipboardRecord(recordID:)` 只做权限快照刷新、低风险 record 存在性检查和 target application 捕获；`.paste` payload read、系统 pasteboard 写入和 paste command 都进入 `continuePasteClipboardRecord(...)`。
- `pasteSelectedClipboardFloatingRecord()` 继续走 `pasteClipboardRecord(recordID:)`，因此继承 guarded continuation。
- `retryPendingClipboardPasteIfPossible()` 也改为先走 `clipboardHistoryPanelPresenter.close(afterClose:)`，再调用 `continuePasteClipboardRecord(..., promptForAccessibility: false)`，避免权限恢复后的自动 retry paste 绕过 dirty guard。

## AppModel 调用方覆盖表

| 调用方 | R3 处理 |
| --- | --- |
| `showTranslationFloatingPanel` | 后续 translation panel / clipboard preview / translation store 操作全部进入 `close(afterClose:)` continuation |
| `pasteClipboardRecord(recordID:)` | `.paste` payload read、pasteboard write、paste command 全部进入 `close(afterClose:)` continuation |
| `pasteSelectedClipboardFloatingRecord()` | 仍调用 `pasteClipboardRecord(recordID:)`，无独立 paste 副作用 |
| `retryPendingClipboardPasteIfPossible()` | 自动 retry paste 也进入 `close(afterClose:)` continuation |

## 行为说明

- 无 dirty detail editor：Presenter 的 guarded close completion 立即执行，保持原动作继续体验。
- 有 dirty detail editor 且选择 `Continue Editing`：关闭被取消，continuation 不执行，paste / translation 副作用不发生。
- 有 dirty detail editor 且选择 `Save and Continue`：保存成功后执行 continuation；保存失败时 continuation 不执行，仍停留编辑上下文。
- 有 dirty detail editor 且选择 `Discard Changes`：丢弃草稿后执行 continuation。
- Paste 类动作在 continuation 前不读取 `.paste` payload、不写系统 pasteboard、不发送 paste command。
- Translation 类动作在 continuation 前不打开 translation panel、不读取 clipboard preview、不修改 `translationStore`。

## P13D 门禁补强

新增 `detail_appmodel_close_continuation_004` static scenario。

新增断言：
- `appmodel_translation_uses_guarded_close_continuation`
- `appmodel_paste_uses_guarded_close_continuation`
- `appmodel_direct_paste_uses_guarded_close_continuation`
- `appmodel_no_sync_close_then_side_effect`

防假 PASS 方式：
- P13D 解析 `AppModel.swift` 方法块，而不是只检查 API 名称存在。
- `showTranslationFloatingPanel` 方法块中不得包含 translation panel present、clipboard preview read、translation store prepare；这些必须出现在 `continueShowTranslationFloatingPanel`。
- `pasteClipboardRecord` / `retryPendingClipboardPasteIfPossible` 方法块中不得包含 `.paste` payload read、`clipboardAutoPasteCoordinator.paste` 或 `NSPasteboard.general.changeCount`；这些必须出现在 `continuePasteClipboardRecord`。
- 检查同步 `clipboardHistoryPanelPresenter.close()` 后同一方法块继续执行 paste / translation 副作用的模式。
- 修正 P13D `method_block`，使其能正确解析带默认闭包参数的方法签名，例如 `openMainWindow: @escaping () -> Void = {}`。

R3 实现前 RED 证据：
- `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` 失败，仅新增 `detail_appmodel_close_continuation_004` 未通过。
- 四项新增断言均为 false。

R3 实现后 GREEN 证据：
- `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` PASS。
- `detail_appmodel_close_continuation_004` 四项新增断言均为 true。

## 验证结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS |
| `git diff --check` | PASS |

Blocks build 仍有既有 `FloatingPanelSupport.swift` 中 `NSApp.isActive` main actor warning；R3 未触碰该文件。

`blocks --help` 低敏输出摘要：
- usage: `blocks list | blocks run blocks.screenshot.capture --dry-run [--mode region|window|fullscreen]`
- actions: `blocks.screenshot.capture`

## 低敏输出与安全声明

- 未读取或写入真实系统剪贴板正文。
- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 未输出真实剪贴板正文、OCR 原文、完整路径、真实 App 名、邮箱、凭据、Authorization header、图片字节或 base64。
- P13D 使用低敏 static evidence 和 deterministic fixture，不依赖真实用户数据。

## 残余风险

P0：无。

P1：无已知残留。

P2：
- R3 仍以 Swift 编译、低敏 static evidence 和代码路径约束为证据；未启动真实 App 做点击、焦点、VoiceOver 或真实系统剪贴板验证。
- `FloatingPanelSupport.swift` actor-isolation warning 是既有问题，本轮未扩大范围处理。
- 若未来新增“关闭剪贴板面板后继续动作”的 AppModel 调用方，需要继续使用 `close(afterClose:)` 并扩展 P13D 断言。
