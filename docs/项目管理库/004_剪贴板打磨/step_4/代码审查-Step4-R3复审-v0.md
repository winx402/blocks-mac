# 代码审查 - Step 4 R3 定向复审 v0

日期：2026-07-07

角色：代码审查

结论：`approve`

建议项目负责人：R3 可接受。上一轮 R2 遗留的单一 P1 已关闭：`AppModel` 不再把 guarded `ClipboardHistoryPanelPresenter.close()` 当同步关闭使用，paste / translation 的副作用已进入 `close(afterClose:)` continuation。未发现新的 P0/P1；保留少量 P2 residual。

## P0 / P1 / P2 结论

P0：无。

P1：无。R2 的 AppModel 同步 close 后继续副作用问题已关闭。

P2：有非阻塞 residual，见下文。

## Findings

本次 R3 定向复审未发现 P0 / P1 / 必须返工的 P2 findings。

## R3 关闭证据

### 1. Presenter continuation 复用 R2 dirty guard

`apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift:95`-`112`：

- `close()` 仍只进入 `requestClosePanel()`。
- 新增 `close(afterClose:)` 进入同一个 `requestClosePanel(afterClose:)`。
- 可见 panel 且有 `appModel` 时，后续动作只在 `appModel.clipboardStore.detailStore.requestPanelClose { ... }` 的 handler 内执行。
- 不存在新的直接 `panel.close()` 旁路；`panel?.close()` 仍只在 `closeImmediately()` 内。

这个设计符合 R3 目标：对“关闭后继续动作”的调用方提供显式 continuation，而不是让调用方在 guarded close 后立即继续执行。

### 2. Paste 路径副作用已进入 continuation

`apps/Blocks/BlocksApp/App/AppModel.swift:314`-`332`：

- `pasteClipboardRecord(recordID:)` 只做权限状态刷新、record 存在性检查、`targetApplication` 捕获。
- 调用 `clipboardHistoryPanelPresenter.close(afterClose:)` 后，把后续 paste 放入 `continuePasteClipboardRecord(...)`。

`apps/Blocks/BlocksApp/App/AppModel.swift:335`-`364`：

- `continuePasteClipboardRecord(...)` 在 continuation 中重新从 `clipboardStore.records` 取当前 record。
- `NSPasteboard.general.changeCount`、`.paste` purpose payload 读取、`clipboardAutoPasteCoordinator.paste(...)` 均在 continuation 内。

因此若用户在 dirty guard 中选择 `Save and Continue`，paste 使用保存后的当前 record / payload；若保存失败或选择 `Continue Editing`，不会进入 paste continuation，不会写真实 pasteboard 或发送 paste command。

`apps/Blocks/BlocksApp/App/AppModel.swift:481`-`490`：

- `pasteSelectedClipboardFloatingRecord()` 仍委托 `pasteClipboardRecord(recordID:)`，没有独立直接 paste 副作用。

`apps/Blocks/BlocksApp/App/AppModel.swift:1163`-`1184`：

- `retryPendingClipboardPasteIfPossible()` 同样只做权限 / pending id / record 存在性检查与 `targetApplication` 捕获，随后进入 `close(afterClose:)`。
- retry 的实际 paste 也复用 `continuePasteClipboardRecord(...)`，未在 dirty guard 完成前读取 payload 或写 pasteboard。

### 3. Translation 路径副作用已进入 continuation

`apps/Blocks/BlocksApp/App/AppModel.swift:511`-`544`：

- `showTranslationFloatingPanel(...)` 外层只调用 `clipboardHistoryPanelPresenter.close(afterClose:)`。
- `focusExistingIfVisible()`、translation section/status 更新、`clipboardTextPreviewService.currentPlainText()`、`translationStore.prepareManualTranslation(...)`、`translationPanelPresenter.present(...)` 都在 `continueShowTranslationFloatingPanel(...)` 内。

因此 translation panel 打开、剪贴板 preview 读取、translation store 修改不会早于 dirty guard 的 continuation。

### 4. DetailStore handler 生命周期没有发现 stale continuation 漏洞

`apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:71`-`74`：

- `requestPanelClose(after:)` 设置 `pendingPanelCloseHandler` 后请求 `.closePanel` navigation。

`apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:188`-`193`：

- `continueEditing()` 清理 `pendingNavigationAction` 与 `pendingPanelCloseHandler`，不会继续执行 paste / translation。

`apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:203`-`213`：

- `saveAndContinue()` 只有保存成功或 `savedIndexPending` 时才执行 pending action；保存失败时保留 dirty navigation，不触发 handler。

`apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:357`-`365`：

- `.closePanel` 是执行 `pendingPanelCloseHandler` 的收敛点，执行前先清空 handler 并 `forceClose()`。

`load(...)`、`beginEditing(...)`、`forceClose()`、`exitEditing()` 等路径也清理 `pendingPanelCloseHandler`，未发现 record switch 或 stale handler 导致旧 continuation 被误执行的 P0/P1 风险。

### 5. P13D 新场景不是 manifest-only 假 PASS

`tools/verification/p13d_clipboard_detail_edit_checks.py:837`-`862`：

- `method_block(...)` 会解析函数签名括号深度，再提取函数体，能覆盖带默认 closure 参数的 Swift 方法签名。

`tools/verification/p13d_clipboard_detail_edit_checks.py:1047`-`1106`：

- P13D 分别提取 `showTranslationFloatingPanel`、`continueShowTranslationFloatingPanel`、`pasteClipboardRecord`、`pasteSelectedClipboardFloatingRecord`、`retryPendingClipboardPasteIfPossible`、`continuePasteClipboardRecord` 的方法体。
- 断言 outer 方法使用 `close(afterClose:)` 并调用 continuation helper。
- 断言 payload read、auto paste、translation present、manual translation prepare、clipboard preview read 等副作用只出现在 continuation helper，不出现在 outer 方法。
- 断言 `pasteSelectedClipboardFloatingRecord()` 走 `pasteClipboardRecord(recordID:)`，retry 路径也走 `close(afterClose:)` 与 `continuePasteClipboardRecord(...)`。
- 断言没有 `clipboardHistoryPanelPresenter.close()` 后同函数继续执行副作用的同步 close 模式。

`tools/verification/p13d_clipboard_detail_edit_checks.py:1168`-`1178`：

- `detail_appmodel_close_continuation_004` 以 `appmodel_close_continuation_static` 方式输出，并且本轮运行结果中四个 AppModel continuation 断言均为 true。

结论：P13D 已覆盖 R3 关注的“同步 close 后继续副作用”假 PASS 风险；不是只检查 scenario id 或文件存在。

## P2 Residual

1. 本轮仍未触发真实 App、真实系统剪贴板、provider、TCC、Keychain、System Settings、Finder 或自动化动作；真实 UI / VoiceOver / pasteboard 行为仍需后续阶段覆盖。
2. `xcodebuild` 主 app target 仍有既有 `FloatingPanelSupport.swift` actor-isolation warnings；不属于 R3 引入，非阻塞。
3. 未来如果新增“关闭剪贴板面板后继续动作”的 AppModel / caller 路径，必须继续使用 `close(afterClose:)`，并同步扩展 P13D 的 AppModel continuation 断言。

## 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
git diff --check
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
rg -n "clipboardHistoryPanelPresenter\\.close\\(|continuePasteClipboardRecord|continueShowTranslationFloatingPanel|detail_appmodel_close_continuation_004|appmodel_.*guarded_close" apps/Blocks/BlocksApp/App/AppModel.swift tools/verification/p13d_clipboard_detail_edit_checks.py
rg -n "clipboardHistoryPanelPresenter\\.close\\(\\)|\\.close\\(afterClose:|requestPanelClose|pendingPanelCloseHandler|NSPasteboard\\.general|clipboardAutoPasteCoordinator\\.paste|translationPanelPresenter\\.present|clipboardTextPreviewService\\.currentPlainText|prepareManualTranslation" apps/Blocks/BlocksApp/App/AppModel.swift apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift
```

结果摘要：

- P13D / P13C / P8 / P9B / P11E / `git diff --check` 均 PASS。
- `Blocks` / `BlocksCLI` Debug build 均 PASS。
- `blocks --help` PASS，输出仅包含现有 CLI usage 与 `blocks.screenshot.capture` action。

## 未覆盖风险

- 未做真实 App 运行、真实系统剪贴板读写、provider、TCC、Keychain、System Settings、Finder 或自动化动作。
- 未重新打开 Step 4 R1 / R2 已关闭问题，也未进入 Step 5。
- 本次结论基于 R3 文档、R3 改动代码路径、静态 verifier 与 build；真实交互语义仍留给后续测试/质量与阶段验收。

## 最终建议

建议项目负责人接受 R3 返工结果。P0/P1 已清零；R3 不需要继续返工。
