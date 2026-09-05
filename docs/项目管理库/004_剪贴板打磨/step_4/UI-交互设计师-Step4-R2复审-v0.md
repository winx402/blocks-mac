# Step 4 R2 UI/交互设计师复审 v0

状态：`approve`
日期：2026-07-07
角色：UI/交互设计师
范围：004_剪贴板打磨 Step 4 R2 定向复审

## 1. 结论

结论：`approve`。

P0：0。
P1：0，已清零。
P2：保留真实 UI / VoiceOver / 窄宽度和后续新增关闭入口的 residual。

R2 只处理 R1 遗留的单一 P1：面板级关闭路径统一进入 dirty navigation guard。基于当前文档、源码静态复核和低敏 P13D 证据，本轮 R2 已满足 UI/交互侧接受条件：toolbar close、`.onExitCommand`、presenter `close()`、Escape、outside dismiss、open settings 前 close 和 Step 4 可达程序化 panel close 都已收敛到 `requestClosePanel` / `requestPanelClose` 链路；dirty 时不再直接 `panel.close()`。

## 2. 复审输入

- `docs/项目管理库/004_剪贴板打磨/step_4/UI-交互设计师-Step4-R1复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R1复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-R2-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R2-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R2验收-v0.md`

重点源码：

- `apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`

## 3. 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
git diff --check
```

结果：

- P13D：PASS，`ok=true`，`failure_summary.count=0`。
- `current_evidence.development_record` 指向 `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R2-v0.md`。
- 新增 `detail_panel_close_dirty_guard_004`：PASS。
- 新增断言均为 `true`：`panel_close_uses_dirty_guard`、`toolbar_close_uses_dirty_guard`、`exit_command_uses_dirty_guard`、`escape_uses_dirty_guard`、`dismiss_monitor_uses_dirty_guard`、`settings_close_uses_dirty_guard`、`programmatic_panel_close_guarded`、`detail_store_has_panel_close_action`、`panel_close_save_continue_handler`。
- `git diff --check`：PASS，无输出。

证据边界：未触发真实 App、真实系统剪贴板、provider、Keychain、TCC、System Settings、Finder、自动化动作或真实 VoiceOver。

## 4. R2 关闭路径复核

### Toolbar close

`ClipboardFloatingPanelView` 的 toolbar close button 仍调用 `onClose()`，但 presenter 注入的 `onClose` 已改为 `self?.requestClosePanel()`。因此 dirty 时会先进入 detail store 的 `requestPanelClose`，不再直接关 panel。

结论：通过。

### `.onExitCommand`

`.onExitCommand` 在没有展开筛选组时仍调用 `onClose()`。由于 `onClose` 注入点已统一到 `requestClosePanel()`，该路径与 toolbar close 行为一致。展开筛选组时先收起筛选组，不离开编辑上下文，不需要 dirty guard。

结论：通过。

### Presenter `close()` 与程序化 close

`ClipboardHistoryPanelPresenter.close()` 已改为调用 `requestClosePanel()`。源码搜索显示 R2 范围内唯一保留的 `panel?.close()` 位于 private `closeImmediately()`，由 `requestClosePanel` 确认通过后调用；P13D 也对 `programmatic_panel_close_guarded` 做了静态断言。

结论：通过。

### Escape

`ClipboardHistoryPanel` 的 `keyDown` 仍触发 `onEscape?()`；presenter 的 `onEscape` 现在调用 `requestClosePanel()`。这符合 dirty 时先三动作确认、非 dirty 时保持原关闭行为的目标。

结论：通过。

### Outside dismiss

`FloatingPanelDismissMonitor` 的回调已从直接 `close()` / `panel.close()` 收敛为 `requestClosePanel()`。这关闭了 R1 指出的外部点击 dismiss 旁路。

结论：通过。

### Open settings 前 close

`onOpenSettings` 现在调用 `requestClosePanel(afterClose: openSettings)`。dirty 时先三动作确认；`Continue Editing` 会取消 pending handler，`Save and Continue` / `Discard Changes` 通过后才关闭 panel 并打开 Settings。

结论：通过。

## 5. Dirty 三动作行为复核

`ClipboardDetailStore` 新增 `.closePanel` pending action 和 `pendingPanelCloseHandler`：

- 无 dirty：`requestNavigation(.closePanel)` 直接 `performNavigation(.closePanel)`，保持原关闭体验。
- dirty：设置 `pendingNavigationAction = .closePanel`，进入 `dirtyNavigation`，由既有 `confirmationDialog` 展示 `Save and Continue` / `Discard Changes` / `Continue Editing`。
- `Continue Editing`：清除 `pendingNavigationAction` 和 `pendingPanelCloseHandler`，保留 draft，取消关闭。
- `Discard Changes`：执行 `.closePanel`，清空 editor 并调用 panel close handler。
- `Save and Continue`：保存成功后执行 `.closePanel`；保存失败时不执行 handler，停留当前编辑上下文并保留 draft。

从 UI/交互合同看，R2 已闭合“关闭面板必须保护 dirty draft”的核心路径。

## 6. P2 residual

- 本轮未运行真实 App，无法实测 toolbar close、Escape、outside dismiss、open settings 后续动作的真实点击 / 键盘焦点 / sheet 聚焦表现。
- 未做真实 VoiceOver，不能证明三动作确认的读序、默认焦点和 hint 完全符合可访问性预期。
- R2 依赖静态结构断言和低敏 verifier；若后续新增其他 panel close 入口，需要继续接入 `requestClosePanel` 并扩展 P13D。
- R1 已记录的 Step 4 其他 P2 仍保留：真实 UI / 窄宽度 / 多语言长句、metadata full value 真实复制、本地化 polish、action bar saving / failed 视觉质感。

## 7. 建议

UI/交互侧建议项目负责人可将 R2 作为通过处理，并在 Step 4 最终接受记录中保留上述 P2 residual。若代码审查和测试/质量也确认 P0/P1 清零，Step 4 可以进入最终接受判断；不建议因 UI/交互侧再要求 R2 返工。
