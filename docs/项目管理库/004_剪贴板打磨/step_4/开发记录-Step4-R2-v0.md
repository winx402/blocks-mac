# 004_剪贴板打磨 Step 4 R2 开发记录

日期：2026-07-07

结论：DONE_WITH_EVIDENCE

## 范围

本轮只处理 Step 4 R2 定向返工的单一 P1：面板级关闭路径统一进入 dirty navigation guard。未进入 Step 5 / Step 6，未重做 R1 已关闭内容。

本轮 R2 实际改动文件：
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R2-v0.md`

未改范围：
- 未触碰 repository、OCR、search document、tags、settings active UI。
- 未进入 Step 5 隐私页 App 清单 / CLI 广义对象。
- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。

## 修复说明

`ClipboardHistoryPanelPresenter` 现在保留弱引用 `AppModel`，所有面板关闭入口统一调用 `requestClosePanel(afterClose:)`。该方法把关闭动作交给 `ClipboardDetailStore.requestPanelClose`，由现有 dirty navigation confirmation 复用 `Save and Continue` / `Discard Changes` / `Continue Editing` 三动作；只有确认通过后才执行唯一的 `closeImmediately()`。

`ClipboardDetailStore` 新增 `ClipboardDetailPendingNavigationAction.closePanel` 与 `pendingPanelCloseHandler`：
- 无 dirty detail editor：直接执行关闭 handler，保持原关闭行为。
- 有 dirty detail editor：进入 dirty navigation 状态，不立即关闭 panel。
- `Continue Editing`：清除 pending panel close，保留 draft，取消关闭。
- `Save and Continue`：保存成功后执行 panel close；保存失败时停留在编辑上下文并保留 draft。
- `Discard Changes`：丢弃草稿后执行 panel close。

## 面板级关闭入口覆盖

| 入口 | R2 处理 |
| --- | --- |
| Toolbar close button | `ClipboardFloatingPanelView.onClose` 注入到 `requestClosePanel()` |
| `.onExitCommand` | View 仍调用 `onClose()`，最终进入 presenter dirty guard |
| `ClipboardHistoryPanelPresenter.close()` | 改为调用 `requestClosePanel()` |
| Presenter Escape handler | 改为调用 `requestClosePanel()` |
| dismiss monitor / outside dismiss | 改为调用 `requestClosePanel()` |
| open settings 前 close | 改为 `requestClosePanel(afterClose: openSettings)`，dirty 确认通过后再打开 Settings |
| Step 4 可达程序化 `panel.close()` | 只保留在 `closeImmediately()` 内，外部入口先过 dirty guard |

## P13D 门禁补强

`p13d_clipboard_detail_edit_checks.py` 新增 `detail_panel_close_dirty_guard_004` static scenario，并把 current evidence 的开发记录指针更新为本文件。

新增/补强断言：
- `panel_close_uses_dirty_guard`
- `toolbar_close_uses_dirty_guard`
- `exit_command_uses_dirty_guard`
- `escape_uses_dirty_guard`
- `dismiss_monitor_uses_dirty_guard`
- `settings_close_uses_dirty_guard`
- `programmatic_panel_close_guarded`
- `detail_store_has_panel_close_action`
- `panel_close_save_continue_handler`

防假 PASS 方式：
- P13D 解析 presenter method block，排除唯一允许的 `closeImmediately()` 后统计直接 `panel.close()`。
- Toolbar / exit command / Escape / dismiss monitor / settings close 分别追踪到 `requestClosePanel` 或等价 guard 链路。
- Detail store 需要存在 panel close action 与 pending handler，不能只靠字符串场景名通过。

R2 实现前低敏 RED 证据：P13D 失败仅落在 `detail_panel_close_dirty_guard_004`，9 项新增断言均为 false。

R2 实现后低敏 GREEN 证据：P13D `ok=true`，`failure_summary.count=0`，上述 9 项新增断言均为 true。

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

Blocks / BlocksCLI build 仅出现既有 `FloatingPanelSupport.swift` 中 `NSApp.isActive` main actor 相关 warning；R2 未触碰该文件。

未补跑 P13A / P13B / P8I / P9A：本轮未修改 repository、OCR、search document、tags 或 settings。

## 低敏输出与安全声明

- 未读取或写入真实系统剪贴板正文。
- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 未输出真实剪贴板正文、OCR 原文、完整路径、真实 App 名、邮箱、凭据、Authorization header、图片字节或 base64。
- P13D 使用低敏 static evidence 和 deterministic fixture，不依赖真实用户数据。

## 残余风险

P0：无。

P1：无已知残留。

P2：
- R2 仍以 Swift 编译、低敏 static evidence 和 store/presenter 代码路径约束为证据；未启动真实 App 做实物点击验证。
- 若未来新增面板关闭入口，需要继续要求入口接入 `requestClosePanel`，并由 P13D 扩展对应断言。
