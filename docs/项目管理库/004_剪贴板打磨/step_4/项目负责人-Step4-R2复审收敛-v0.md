# Step 4 R2 项目负责人复审收敛 v0

状态：rework-required
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 4 R2 定向复审

## 1. 结论

结论：`rework-required`。

Step 4 R2 不能进入最终接受，必须做 R3 定向返工。

原因：R2 三方定向复审已收齐，UI/交互设计师和测试/质量均为 `approve`，但代码审查给出 `rework-required`。项目负责人抽查 `AppModel` 后确认：虽然 Presenter 内部面板关闭已经进入 dirty guard，但外部调用方仍把 `clipboardHistoryPanelPresenter.close()` 当同步关闭使用，并在 dirty guard 完成前继续执行 paste / translation 等副作用。

## 2. 复审输入

- `step_4/UI-交互设计师-Step4-R2复审-v0.md`：`approve`
- `step_4/测试-质量-Step4-R2复审-v0.md`：`approve`
- `step_4/代码审查-Step4-R2复审-v0.md`：`rework-required`
- `step_4/项目负责人-Step4-R2验收-v0.md`
- `step_4/开发记录-Step4-R2-v0.md`

## 3. 已关闭内容

R2 已关闭 Presenter / View 内部面板级关闭旁路：

- toolbar close 经 presenter 注入的 `requestClosePanel()`。
- `.onExitCommand` 经 `onClose()` 进入 presenter guard。
- presenter `close()`、Escape、dismiss monitor、open settings 前 close 已进入 `requestClosePanel()`。
- `panel.close()` 只保留在 `closeImmediately()`。
- DetailStore 有 `.closePanel` pending action 和 `pendingPanelCloseHandler`。

这些内容不要求 R3 重做。

## 4. R3 必须修复的 P1

### P1-1：AppModel 调用方把 guarded close 当同步 close 使用

事实：

- `AppModel.pasteClipboardRecord(recordID:)` 调用 `clipboardHistoryPanelPresenter.close()` 后立即读取 `.paste` payload 并执行 paste。
- `AppModel.showTranslationFloatingPanel()` 调用 `clipboardHistoryPanelPresenter.close()` 后立即继续打开 translation panel / 读取 clipboard preview / 准备 translation store。
- `AppModel` 另一路 paste path 先执行 paste，再调用 `clipboardHistoryPanelPresenter.close()`；dirty guard 已经太晚。

影响：

- Dirty editor 存在时，`close()` 现在只是发起 pending close，并不代表关闭已经完成。
- 调用方继续执行 paste / translation，会让 `Continue Editing` 失去“取消离开当前编辑上下文”的语义。
- `Save and Continue` 保存失败时，DetailStore 会停留当前记录，但调用方副作用已经发生，违反 R2 派发要求。
- P13D 当前只验证 Presenter / View / DetailStore 的关闭入口，没有覆盖 AppModel 调用方 continuation，因此存在假 PASS。

R3 要求：

- 对所有“关闭剪贴板面板后继续动作”的调用方使用 guarded continuation API。
- 至少覆盖：
  - `showTranslationFloatingPanel`；
  - `pasteClipboardRecord(recordID:)`；
  - `pasteSelectedClipboardFloatingRecord` 或等价直接 paste 路径。
- 后续动作必须只在 dirty guard 确认通过后执行：
  - 无 dirty：立即继续原动作；
  - `Save and Continue`：保存成功后继续原动作，保存失败不得继续；
  - `Discard Changes`：丢弃后继续原动作；
  - `Continue Editing`：不得继续原动作。
- `paste` 类动作不得在 dirty 确认前读取 payload、写系统 pasteboard 或发送 paste command。
- `translation` 类动作不得在 dirty 确认前打开 translation panel、读取 clipboard preview 或修改 translation store。

## 5. R3 验证要求

P13D 或等价低敏 verifier 必须新增 AppModel 调用方 continuation 断言，至少包括：

- `appmodel_translation_uses_guarded_close_continuation`
- `appmodel_paste_uses_guarded_close_continuation`
- `appmodel_direct_paste_uses_guarded_close_continuation`
- `appmodel_no_sync_close_then_side_effect`

这些断言不能只检查新 API 名称存在；必须能防止 `clipboardHistoryPanelPresenter.close()` 后同一函数继续执行 paste / translation / provider / clipboard preview 等副作用。

R3 至少运行：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

如 R3 触及 repository、OCR、search document、tags 或 settings，应补跑对应 P13A / P13B / P8I / P9A。

## 6. P2 residual 继续保留

以下不作为 R3 阻塞：

- 真实 UI、真实 VoiceOver、真实系统剪贴板未实测。
- Metadata full value 当前是显式 reveal / fake copy evidence，不是真实系统剪贴板 copy。
- Rich text fidelity 覆盖代表 fixture，不覆盖所有真实来源 RTF 变体。
- 既有 `FloatingPanelSupport.swift` actor-isolation warning。

## 7. 下一步

派发开发执行 Step 4 R3 定向返工。R3 完成并通过项目负责人复核后，至少需要代码审查和测试/质量定向复审；若 UI 入口或交互语义再改动明显，也补 UI/交互复审。
