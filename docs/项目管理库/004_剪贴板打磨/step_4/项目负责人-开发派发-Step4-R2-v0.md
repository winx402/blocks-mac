# Step 4 R2 开发派发 v0

日期：2026-07-07
角色：项目负责人
派发对象：开发
范围：004_剪贴板打磨 Step 4 R2 定向返工

## 1. 任务结论

请执行 Step 4 R2 定向返工。

R2 只修复一个 P1：面板级关闭路径必须统一进入 dirty navigation guard。不要重做已关闭的 R1 内容，不进入 Step 5。

## 2. 背景

R1/R1a 已完成项目负责人验收和五角色定向复审。四个角色认为 P0/P1 清零，但 UI/交互设计师发现面板级关闭仍绕过 dirty guard。项目负责人抽查确认该问题存在，因此 Step 4 不能最终接受。

收敛文档：

- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R1复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/UI-交互设计师-Step4-R1复审-v0.md`

## 3. 必须修复

所有会关闭剪贴板面板的入口必须统一走面板级 dirty guard，至少覆盖：

- `ClipboardFloatingPanelView` toolbar close button；
- `ClipboardFloatingPanelView.onExitCommand`；
- `ClipboardHistoryPanelPresenter.close()`；
- `ClipboardHistoryPanelPresenter` Escape handler；
- `FloatingPanelDismissMonitor` outside dismiss；
- open settings 前的 close；
- Step 4 可达的任何程序化 `panel.close()`。

行为要求：

- 无 dirty detail editor：保持当前关闭行为。
- 有 dirty detail editor：
  - 不得立即关闭 panel；
  - 复用现有 `Save and Continue` / `Discard Changes` / `Continue Editing` 三动作确认；
  - `Continue Editing` 取消关闭并保留 draft；
  - `Save and Continue` 保存成功后关闭 panel，保存失败停留并保留 draft；
  - `Discard Changes` 丢弃草稿后关闭 panel。

实现边界：

- 不写真实系统剪贴板。
- 不触发真实 App、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 不扩大 Step 4 到真实 App 清单、CLI 广义对象管理或 Step 5。
- 不把已关闭的 P13D、OCR guard、metadata full value、rich text 代表 fixture 重做成大重构。

## 4. 验证要求

P13D 或等价低敏 verifier 必须新增面板级关闭 guard 断言，至少包括：

- `panel_close_uses_dirty_guard`
- `toolbar_close_uses_dirty_guard`
- `exit_command_uses_dirty_guard`
- `escape_uses_dirty_guard`
- `dismiss_monitor_uses_dirty_guard`
- `settings_close_uses_dirty_guard`

这些断言必须能防止“View/Presenter 仍直接调用 `panel.close()` 但 verifier 只扫到 guard 字符串”的假 PASS。

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

如果改动触及 repository、OCR、search document、tags 或 settings，请补跑对应 P13A / P13B / P8I / P9A。

## 5. 输出

请产出：

- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R2-v0.md`

开发记录至少包含：

- 修改范围；
- 面板级关闭入口覆盖表；
- dirty / non-dirty 两种行为说明；
- 新增 P13D 或等价 verifier 断言说明；
- 已运行命令和结果；
- 未触发真实 App / 剪贴板 / provider / TCC / Keychain / 系统设置 / 自动化的声明；
- 残余 P2 风险。
