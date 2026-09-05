# 004_剪贴板打磨 Step 4 R3 测试/质量定向复审 v0

日期：2026-07-07
角色：测试/质量
范围：仅复核 Step 4 R3：AppModel 调用方不能把 guarded `clipboardHistoryPanelPresenter.close()` 当同步关闭使用。不进入 Step 5，不重开 R1/R2 已关闭问题。

## 1. 结论

结论：`approve`。

P0：无。

P1：清零。R3 已用 guarded continuation 收敛 paste / translation 的后续副作用，P13D 新增 `detail_appmodel_close_continuation_004` 能覆盖本轮 P1 的主要假 PASS 风险。本轮独立复跑 R3 矩阵全部 PASS。

P2：真实 UI、真实系统剪贴板、真实 VoiceOver 未覆盖；在 R3 范围内可作为 residual 保留，不构成 P1。

## 2. 输入

- `项目负责人-Step4-R2复审收敛-v0.md`
- `项目负责人-开发派发-Step4-R3-v0.md`
- `开发记录-Step4-R3-v0.md`
- `项目负责人-Step4-R3验收-v0.md`

## 3. R3 P1 关闭判断

| 复核点 | 结论 | 证据 |
| --- | --- | --- |
| Translation 后续动作是否等待 guarded close | 通过 | `showTranslationFloatingPanel` 只调用 `clipboardHistoryPanelPresenter.close(afterClose:)`；`translationPanelPresenter.present`、`clipboardTextPreviewService.currentPlainText()`、`translationStore.prepareManualTranslation` 均在 `continueShowTranslationFloatingPanel` 内。P13D `appmodel_translation_uses_guarded_close_continuation=true`。 |
| Paste 后续动作是否等待 guarded close | 通过 | `pasteClipboardRecord(recordID:)` 只做权限刷新、record 存在性检查和 target app 捕获；`.paste` payload read、`NSPasteboard.general.changeCount`、`clipboardAutoPasteCoordinator.paste` 均在 `continuePasteClipboardRecord` 内。P13D `appmodel_paste_uses_guarded_close_continuation=true`。 |
| Direct paste / selected paste / permission retry 是否覆盖 | 通过 | `pasteSelectedClipboardFloatingRecord()` 仍走 `pasteClipboardRecord(recordID:)`；`retryPendingClipboardPasteIfPossible()` 也走 `close(afterClose:)` 后再调用 `continuePasteClipboardRecord(..., promptForAccessibility: false)`。P13D `appmodel_direct_paste_uses_guarded_close_continuation=true`。 |
| 是否仍存在 close 后同步副作用 | 通过 | 静态抽查未发现 `clipboardHistoryPanelPresenter.close()` 同步调用；P13D `appmodel_no_sync_close_then_side_effect=true`。 |

测试/质量判断：R3 的 pass/fail 语义足以表达用户选择：

- `Continue Editing`：guard 不执行 continuation，因此不 paste、不打开 translation panel、不读 clipboard preview、不修改 translation store。
- `Save and Continue`：保存成功后执行 continuation；保存失败时 continuation 不执行。
- `Discard Changes`：丢弃后执行 continuation。
- 无 dirty editor：continuation 立即执行，保持既有体验。

## 4. P13D 防假 PASS 复核

P13D 新增 `detail_appmodel_close_continuation_004`，不是只检查 API 名称存在。脚本会解析 `AppModel.swift` 的方法块，并检查：

- `showTranslationFloatingPanel` 中不得出现 translation panel present、clipboard preview read、translation store prepare；这些必须在 `continueShowTranslationFloatingPanel`。
- `pasteClipboardRecord` / `retryPendingClipboardPasteIfPossible` 中不得出现 `.paste` payload read、`clipboardAutoPasteCoordinator.paste`、`NSPasteboard.general.changeCount`；这些必须在 `continuePasteClipboardRecord`。
- 检查 `clipboardHistoryPanelPresenter.close()` 后同一方法块继续执行 paste / translation 副作用的模式。
- `pasteSelectedClipboardFloatingRecord()` 必须通过 `pasteClipboardRecord(recordID:)` 继承 guarded continuation。

本轮实跑 P13D 关键结果：

- `ok=true`
- `failure_summary.count=0`
- `detail_appmodel_close_continuation_004`：PASS
- 四个新增断言均为 true：
  - `appmodel_translation_uses_guarded_close_continuation`
  - `appmodel_paste_uses_guarded_close_continuation`
  - `appmodel_direct_paste_uses_guarded_close_continuation`
  - `appmodel_no_sync_close_then_side_effect`

非阻断建议：P13D `current_evidence.dispatch` 仍指向通用 Step 4 派发文档，而非 R3 派发文档；由于 `development_record` 已指向 R3 且新增场景可复跑通过，此问题不影响本轮 P1 关闭。建议后续把 R3 dispatch 纳入 current evidence，提升追溯清晰度。

## 5. 实际运行命令

| 命令 | 结果 | 备注 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS | R3 hard gate 通过，新增 AppModel continuation 场景 PASS。 |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS | 面板交互 / layout 回归通过；真实 App/剪贴板不参与 ok。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | clipboard product polish 未见回归。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | AppModel / repository integration 未见回归。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | 默认 payload deny 边界未见回归。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 仍有既有 `FloatingPanelSupport.swift` actor-isolation warning 和 AppIntents metadata skipped warning；未阻塞。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI target 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅输出 usage 和 `blocks.screenshot.capture` action。 |
| `git diff --check` | PASS | 写文档前通过。 |

未补跑 P13A / P13B / P8I / P9A。理由：R3 实际触碰 `AppModel.swift`、`ClipboardHistoryPanelPresenter.swift` 和 P13D；未触碰 repository、OCR、search document、tags 或 settings active UI。当前 R3 矩阵足以覆盖本轮 P1，不构成明显缺口。

## 6. 未覆盖与边界

本轮未启动真实 App，未读取或写入真实系统剪贴板，未触发 provider、TCC、Keychain、System Settings、Finder 或自动化动作。

未覆盖真实场景：

- 真实 UI 中 dirty editor 下点击 paste / translation 后选择三动作的焦点、时序、视觉反馈。
- 真实 VoiceOver 对三动作确认与后续动作取消 / 继续的读屏体验。
- 真实系统剪贴板写入与 paste command 的端到端行为。

这些未覆盖项与项目负责人 R3 边界一致，可作为 P2 residual 进入 Step 4 最终记录或 Step 6 回扫。

## 7. 建议

从测试/质量角度，R3 可以进入 Step 4 最终接受准备。建议最终记录明确：R3 已关闭 AppModel continuation P1，但未声称真实 UI / 真实 VoiceOver / 真实系统剪贴板端到端通过。
