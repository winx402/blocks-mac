# Step 4 R1 项目负责人复审收敛 v0

状态：rework-required
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 4 R1 / R1a 定向复审

## 1. 结论

结论：`rework-required`。

Step 4 R1 不能进入最终接受，必须做 R2 定向返工。

原因：五份 R1 定向复审已收齐，其中 App 架构师、测试/质量、安全合规顾问为 `approve`，代码审查为 `approve-with-changes` 且 P0/P1 清零；但 UI/交互设计师给出 `rework-required`，指出面板级关闭路径仍可绕过 dirty navigation guard。项目负责人抽查代码后确认该 P1 为事实。

## 2. 复审输入

- `step_4/App架构师-Step4-R1复审-v0.md`：`approve`
- `step_4/代码审查-Step4-R1复审-v0.md`：`approve-with-changes`，P0/P1 清零
- `step_4/测试-质量-Step4-R1复审-v0.md`：`approve`
- `step_4/安全合规顾问-Step4-R1复审-v0.md`：`approve`
- `step_4/UI-交互设计师-Step4-R1复审-v0.md`：`rework-required`
- `step_4/项目负责人-Step4-R1验收-v0.md`
- `step_4/开发记录-Step4-R1-v0.md`
- `step_4/开发记录-Step4-R1a-v0.md`

## 3. 已关闭内容

项目负责人接受四个角色和代码审查的共同判断：R1/R1a 已关闭上一轮主要实现 P1：

- P13D 已从 token / 文件存在假 PASS 升级为 dynamic deterministic fixture / fail-closed gate。
- OCR user-edited guard 已覆盖 late completion、retry、second completion 防覆盖。
- 详情编辑器内部 dirty 三动作确认、record switch guard、overlay close guard 已有实现与 P13D 证据。
- Metadata full value 已有显式读取 / 展开路径，不写真实系统剪贴板。
- Rich text 编辑合同已改为代表格式保真 + fail closed。

这些点不要求 R2 重做；R2 只处理面板级关闭 dirty guard。

## 4. R2 必须修复的 P1

### P1-1：面板级关闭路径仍绕过 dirty navigation guard

事实：

- `ClipboardFloatingPanelView.onExitCommand` 在无展开筛选组时直接调用 `onClose()`。
- 面板 toolbar close button 直接调用 `onClose()`。
- `ClipboardHistoryPanelPresenter.present` 传入的 `onClose` 是 `self?.panel?.close()`。
- `ClipboardHistoryPanelPresenter.close()` 直接 `panel?.close()`。
- `ClipboardHistoryPanelPresenter` 的 Escape handler 调用 `self?.close()`。
- `FloatingPanelDismissMonitor` 的回调调用 `self?.close()`。
- `windowWillClose` 只处理 frame 保存、monitor stop 和 `onClosed?()`，没有 dirty guard。

影响：

- 用户在详情编辑器中有未保存草稿时，按 Escape、点面板关闭、触发外部 dismiss，或其他面板级关闭入口，可能直接关闭面板。
- 这与 PRD v1 对“关闭面板或执行会离开当前编辑上下文的动作必须进入 Save and Continue / Discard Changes / Continue Editing 三动作确认”的要求冲突。
- 即使 draft 仍留在内存中，用户感知已经离开编辑上下文，没有得到阻断确认，因此不能降级为 P2。

R2 要求：

- 增加统一的面板级关闭 guard，所有会关闭剪贴板面板的入口都必须先进入该 guard。
- 至少覆盖：
  - toolbar close button；
  - SwiftUI `.onExitCommand`；
  - presenter `close()`；
  - presenter Escape；
  - dismiss monitor / outside dismiss；
  - open settings 前的 close；
  - 任何程序化 `panel.close()` 的 Step 4 可达路径。
- 如果 detail editor dirty：
  - 不得立即关闭 panel；
  - 复用现有三动作确认，pending action 表达为“保存/丢弃后关闭面板”；
  - `Continue Editing` 取消面板关闭并保留 draft；
  - `Save and Continue` 保存成功后关闭面板，保存失败停留当前记录；
  - `Discard Changes` 丢弃草稿后关闭面板。
- 如果没有 dirty detail editor，面板关闭行为保持当前体验。

## 5. R2 验证要求

R2 必须补充 P13D 或等价低敏 verifier 断言，至少包括：

- `panel_close_uses_dirty_guard`
- `toolbar_close_uses_dirty_guard`
- `exit_command_uses_dirty_guard`
- `escape_uses_dirty_guard`
- `dismiss_monitor_uses_dirty_guard`
- `settings_close_uses_dirty_guard`

这些断言不能只检查字符串存在；必须能证明面板关闭入口不会直接绕过 dirty guard 调 `panel.close()`。

R2 至少运行：

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

如果 R2 改动触及 repository、OCR、search document、tags 或 settings，应补跑对应 P13A / P13B / P8I / P9A。

## 6. P2 residual 继续保留

以下不作为 R2 阻塞，但最终验收要保留：

- 真实 UI、真实 VoiceOver、真实系统剪贴板未实测。
- Metadata full value 当前是显式 reveal / fake copy evidence，不是真实系统剪贴板 copy。
- Rich text fidelity 覆盖代表 fixture，不覆盖所有真实来源 RTF 变体。
- action bar 保存中 / 保存失败视觉质感、本地化和窄宽度实物证据仍可在 Step 6 回扫。

## 7. 下一步

派发开发执行 Step 4 R2 定向返工。R2 完成并通过项目负责人复核后，仅需对 UI/交互设计师、代码审查和测试/质量做定向复审；如 R2 触及安全边界，再补安全合规复审。
