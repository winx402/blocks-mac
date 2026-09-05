# Step 4 R3 开发派发 v0

日期：2026-07-07
角色：项目负责人
派发对象：开发
范围：004_剪贴板打磨 Step 4 R3 定向返工

## 1. 任务结论

请执行 Step 4 R3 定向返工。

R3 只修复一个 P1：`AppModel` 调用方不能把 guarded `clipboardHistoryPanelPresenter.close()` 当同步关闭使用。不要进入 Step 5，不要重做 R1/R2 已关闭内容，不做无关重构。

## 2. 背景

R2 已修复 Presenter / View / DetailStore 内部的面板级关闭 guard。R2 定向复审中，代码审查发现 AppModel 调用方仍在 `close()` 后继续执行 paste / translation 副作用。项目负责人抽查确认该问题成立。

收敛文档：

- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R2复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/代码审查-Step4-R2复审-v0.md`

## 3. 必须修复

所有“关闭剪贴板面板后继续动作”的 AppModel 调用方必须使用 guarded continuation。

至少覆盖：

- `showTranslationFloatingPanel`
- `pasteClipboardRecord(recordID:)`
- `pasteSelectedClipboardFloatingRecord` 或等价直接 paste 路径

行为要求：

- 无 dirty detail editor：保持现有体验，立即继续原动作。
- 有 dirty detail editor：
  - `Continue Editing`：取消关闭，不继续原动作。
  - `Save and Continue`：保存成功后继续原动作；保存失败不继续。
  - `Discard Changes`：丢弃后继续原动作。
- Paste 类动作不得在 dirty 确认前读取 `.paste` payload、写系统 pasteboard 或发送 paste command。
- Translation 类动作不得在 dirty 确认前打开 translation panel、读取 clipboard preview 或修改 translation store。

实现建议：

- 给 `ClipboardHistoryPanelPresenter` 暴露明确的 guarded continuation API，例如 `close(afterClose:)` / `requestClose(afterClose:)`，而不是让调用方继续使用无 completion 的 `close()` 后接副作用。
- 将 paste / translation 的后续动作提取为内部 helper，并只在 guarded close completion 中调用。
- 若某些路径必须先 capture `targetApplicationForPaste()`，只允许 capture 低风险上下文；真正 payload read / pasteboard write / command post 必须在 continuation 后执行。

## 4. 验证要求

P13D 或等价低敏 verifier 必须新增 AppModel 调用方 continuation 断言，至少包括：

- `appmodel_translation_uses_guarded_close_continuation`
- `appmodel_paste_uses_guarded_close_continuation`
- `appmodel_direct_paste_uses_guarded_close_continuation`
- `appmodel_no_sync_close_then_side_effect`

这些断言必须能防止以下假 PASS：

- `clipboardHistoryPanelPresenter.close()` 后同一函数继续执行 paste / translation 副作用；
- paste payload read / pasteboard write 发生在 guarded close completion 之前；
- translation panel / clipboard preview / translation store 修改发生在 guarded close completion 之前。

至少运行：

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

如触及 repository、OCR、search document、tags 或 settings，请补跑对应 P13A / P13B / P8I / P9A。

## 5. 输出

请产出：

- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R3-v0.md`

开发记录至少包含：

- 修改范围；
- AppModel 调用方覆盖表；
- dirty / non-dirty 行为说明；
- 新增 P13D 或等价 verifier 断言说明；
- 已运行命令和结果；
- 未触发真实 App / 剪贴板 / provider / TCC / Keychain / 系统设置 / 自动化的声明；
- 残余 P2 风险。
