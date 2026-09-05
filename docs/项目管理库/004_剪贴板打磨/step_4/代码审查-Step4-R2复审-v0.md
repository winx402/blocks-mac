# 代码审查 - Step 4 R2 定向复审 v0

日期：2026-07-07

角色：代码审查

结论：`rework-required`

建议项目负责人：R2 尚不能接受。`ClipboardHistoryPanelPresenter` 内部关闭入口已统一到 `requestClosePanel`，但 `AppModel` 仍存在调用 `clipboardHistoryPanelPresenter.close()` 后立即继续执行后续动作的路径；这会绕过“dirty guard 确认通过后才继续原动作”的语义。P13D 新增场景当前未覆盖该类调用方 continuation，因此会假 PASS。

## P0 / P1 结论

P0：无。

P1：未清零。发现 1 个 R2 范围内 P1：

- P1-1：`AppModel` 程序化关闭调用仍把 `close()` 当同步关闭使用，dirty 时后续 paste / translation 动作会在用户选择 `Save and Continue` / `Discard Changes` / `Continue Editing` 前继续执行。

## P1 Findings

### P1-1：调用方在 guarded `close()` 后继续执行副作用，面板级 dirty guard 仍可被绕过

证据：

- `apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift:95`-`108`：`close()` 现在进入 `requestClosePanel()`，dirty 时会把真正关闭延后到 `ClipboardDetailStore.requestPanelClose` 的 handler。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:71`-`74`、`:343`-`:365`：dirty 时 `requestPanelClose` 只设置 pending action；只有 `Save and Continue` 或 `Discard Changes` 后才执行 handler。
- `apps/Blocks/BlocksApp/App/AppModel.swift:488`-`500`：`showTranslationFloatingPanel()` 调用 `clipboardHistoryPanelPresenter.close()` 后立即继续 `focusExistingIfVisible()`、设置 translation section/status，并继续打开翻译面板。dirty 时用户尚未确认关闭剪贴板面板，translation 动作已经继续。
- `apps/Blocks/BlocksApp/App/AppModel.swift:314`-`345`：`pasteClipboardRecord(recordID:)` 在第 334 行调用 `clipboardHistoryPanelPresenter.close()`，随后立即执行 paste，读取 `.paste` payload 并进入 auto-paste coordinator。若 detail editor dirty，这会在关闭确认前继续会离开编辑上下文的动作。
- `apps/Blocks/BlocksApp/App/AppModel.swift:1159`-`1167`：另一个 paste 路径先执行 paste，再调用 `clipboardHistoryPanelPresenter.close()`；dirty guard 此时已经太晚。

影响：

- R2 修复只保证 Presenter 内的直接 `panel.close()` 进入 guard；但外部调用方仍可在 guard 尚未完成时继续执行原动作。
- 对用户语义而言，`Continue Editing` 应取消关闭并保留当前编辑上下文；当前 translation / paste 调用路径已经继续执行后续动作，等于没有被 dirty-navigation 阻断。
- 对 `Save and Continue` 失败场景，`ClipboardDetailStore.saveAndContinue()` 会停留当前记录，但 `showTranslationFloatingPanel()` / `pasteClipboardRecord()` 已经继续执行，违反 R2 派发要求“保存失败停留并保留 draft，不继续原动作”。

可执行修复建议：

- 不要让外部调用方直接调用无 continuation 的 `close()` 后继续执行需要等待关闭完成的动作。
- 给 Presenter 暴露明确的 guarded close API，例如 `requestClose(afterClose:)` 或把 `close(afterClose:)` 公开；所有“关闭后继续”的调用方必须把后续动作放进 `afterClose`。
- 至少修复：
  - `showTranslationFloatingPanel`：translation panel 打开逻辑必须进入 `afterClose`，`Continue Editing` / 保存失败时不得打开 translation panel。
  - `pasteClipboardRecord` / direct paste 路径：如当前 detail editor dirty，paste 动作必须先进入同一 dirty guard；只有 `Save and Continue` / `Discard Changes` 后才能继续 paste，`Continue Editing` / 保存失败不得写 pasteboard 或发送 paste command。
- P13D 增加 AppModel 调用方 continuation 断言：扫描 `clipboardHistoryPanelPresenter.close()` 调用点，要求调用后同一函数无继续副作用，或调用的是带 `afterClose` 的 guarded continuation API。

## P13D 覆盖判断

P13D 当前新增 `detail_panel_close_dirty_guard_004` 会 PASS，但不足以关闭上述 P1。

证据：

- `tools/verification/p13d_clipboard_detail_edit_checks.py:996`-`1034` 的 `panel_close_checks` 只检查 Presenter / View / DetailStore 的 binding，例如 Presenter 内 direct `panel.close()` 是否只存在于 `closeImmediately()`。
- `tools/verification/p13d_clipboard_detail_edit_checks.py:1422`-`1427` 调用 `ui_binding_scenarios` 时传入的是 DetailStore、DetailView、FloatingPanelView、Presenter；没有把 `AppModel.swift` 的 close 调用点纳入 `detail_panel_close_dirty_guard_004`。
- 本轮运行 P13D：`ok True`、`failure_count 0`，`detail_panel_close_dirty_guard_004` 为 `pass`，9 个新增断言均为 true；但 `AppModel.swift:488`-`:500`、`:314`-`:345`、`:1159`-`:1167` 的 continuation 风险仍存在。

结论：P13D 对 R2 的假 PASS 风险未完全消除。它能防 Presenter 内直接 `panel.close()` 旁路，但不能防调用方把 guarded close 当同步 close 使用。

## 已关闭内容

以下 R2 子项在 Presenter / DetailStore 层看起来已正确收敛：

- Toolbar close：`ClipboardFloatingPanelView` 仍调用 `onClose()`，Presenter 注入的 `onClose` 为 `requestClosePanel()`。
- `.onExitCommand`：View 调用 `onClose()`，Presenter 注入 guard。
- Presenter Escape：`ClipboardHistoryPanelPresenter.swift:58`-`61` 调用 `requestClosePanel()`。
- dismiss monitor / outside dismiss：`ClipboardHistoryPanelPresenter.swift:125`-`134` 调用 `requestClosePanel()`。
- open settings：`ClipboardHistoryPanelPresenter.swift:43`-`45` 使用 `requestClosePanel(afterClose: openSettings)`，顺序正确。
- 直接 `panel.close()`：本轮静态搜索 Step 4 可达 Presenter 中只看到 `closeImmediately()` 内部调用。
- stale handler：`ClipboardDetailStore.continueEditing()`、`load()`、`beginEditing()`、`forceClose()`、`exitEditing()` 均清理 `pendingPanelCloseHandler`。

这些点不再单独作为 P1。

## P2 Residual

延续 R1 的 P2 residual：

1. R2 仍以静态结构断言和低敏 verifier 为主，未做真实 App 点击、焦点、VoiceOver、窄宽度验证。
2. Metadata full value 当前是 reveal / fake copy evidence，不是真实系统剪贴板 copy。
3. Rich text fidelity 覆盖代表 fixture，不覆盖所有真实 RTF 变体。
4. `Blocks` build 既有 `FloatingPanelSupport.swift` actor-isolation warnings 仍需后续统一收口。

## 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py | python3 -c '...extract panel close summary...'
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
git diff --check
rg -n "requestClosePanel|closeImmediately|requestPanelClose|pendingPanelCloseHandler|panel\\.close|close\\(\\)|onExitCommand|onClose|openSettings|Escape|dismiss|FloatingPanelDismissMonitor" apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift apps/Blocks/BlocksApp/App/AppModel.swift
rg -n "clipboardHistoryPanelPresenter\\.close\\(|requestClosePanel|showTranslationFloatingPanel|pasteClipboardRecord|pasteSelectedClipboardFloatingRecord" apps/Blocks/BlocksApp/App/AppModel.swift apps/Blocks/BlocksApp -g '*.swift'
```

结果摘要：

- P13D / P13C / P8 / P9B / P11E / `git diff --check` 均 PASS。
- 未重复运行 `xcodebuild` / CLI help；原因是静态 P1 已足够构成 R2 返工，且项目负责人已提供构建 PASS 证据。

## 未覆盖风险

- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。
- 未验证实际点击路径；本次结论基于代码路径与低敏静态/verifier。

## 最终建议

要求 R2 返工，不建议项目负责人接受当前 R2。修复重点不是 Presenter 内再包一层 guard，而是让所有调用 `close()` 后有后续动作的 AppModel / caller 路径进入 guarded continuation；P13D 也必须覆盖这些调用点，避免再次出现“guard 存在但调用方已继续执行”的假 PASS。
