# P7-F 设置导航、权限授权与自动粘贴回归修复

状态：superseded by P7-G for permission flow; P7-F findings remain historical

本轮回应 P7-E 后复现的回归问题：设置页重复菜单、授权后仍提示无权限、Permission Assist 面板显示/定位/拖拽异常。每一项按 `research / plan / dev / test / close` 记录；未低敏人工验收前不写成 fully closed。

后续 P7-G 已进一步重构设置侧边栏语义、Screen Recording request/recover、Accessibility 独立请求、Clipboard paste attempt 和 Permission Assist 状态机；当前验收应以 [P7-G story](p7-g-permission-settings-interaction-rework.md) 为准。

## References

- Apple Screen & System Audio Recording permission: <https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac>
- Apple Accessibility permission: <https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac>
- P7-E reopened issue ledger: [P7-E story](p7-e-settings-clipboard-translation-permission-deep-polish.md)

## Issue Ledger

| ID | User issue | Research | Plan | Dev | Test | Close |
| --- | --- | --- | --- | --- | --- | --- |
| P7-F-01 | 设置页菜单存在重复内容：旧 Clipboard / Translation 工具页和 Clipboard Settings / Translation Settings 重复。 | `AppSection` 同时保留 `.clipboard` / `.translation` 和 `.clipboardSettings` / `.translationSettings`，快捷键和浮层回调仍会切到旧 route。 | 主侧边栏只保留 Screenshot 工具入口和独立设置入口；Clipboard / Translation 主入口继续使用浮层。 | Removed old app sections and rerouted clipboard/translation main-window callbacks to settings routes. | Covered by `p7f_settings_menu_dedup_checks.py`; manual sidebar pass still pending. | `implemented`; close after low-sensitive UI pass. |
| P7-F-02 | 授权后截图仍提示无权限，自动粘贴也可能仍失败。 | Screen Recording / Accessibility 都由 macOS TCC 控制；当前 Debug App 是 ad-hoc signing，无 Team ID，授权变更可能需要 App 重新打开。 | 增加统一 permission snapshot，App 激活、截图前、自动粘贴前和授权流程结束时刷新；Screen Recording 未刷新时显示重启诊断；Accessibility 授权后保留 pending paste 并尝试重试。 | Added permission snapshot refresh, signing diagnostic, restart action, and pending paste retry. | Covered by `p7f_permission_state_refresh_checks.py` and `p7f_clipboard_autopaste_permission_retry_checks.py`; real TCC pass still manual. | `implemented`; close after low-sensitive permission pass. |
| P7-F-03 | 授权面板有时不出现，位置和箭头方向不一致，拖动图标时整个面板跟着移动。 | Presenter 立即显示并开始监控；System Settings 启动慢时可能被提前关闭；面板 `isMovableByWindowBackground=true` 会让图标拖拽区域也触发窗口移动；箭头固定向右。 | 打开 System Settings 后给启动 grace period；面板按 System Settings 窗口左右定位；箭头方向指向系统设置；关闭背景拖动，只让图标负责 file URL drag。 | Reworked `PermissionAssistPanelPresenter` launch wait, placement, arrow direction, and drag isolation. | Covered by `p7f_permission_assist_position_drag_checks.py`; exact System Settings positioning still needs manual pass. | `implemented`; close after manual permission-assist pass. |

## Verification

- `tools/verification/p7f_issue_ledger_reopen_checks.py`
- `tools/verification/p7f_settings_menu_dedup_checks.py`
- `tools/verification/p7f_permission_state_refresh_checks.py`
- `tools/verification/p7f_permission_assist_position_drag_checks.py`
- `tools/verification/p7f_clipboard_autopaste_permission_retry_checks.py`

## Manual Acceptance Still Required

- Sidebar no longer shows old Clipboard / Translation tool pages.
- After granting Screen Recording, screenshot succeeds after refresh or a clearly instructed app restart.
- After granting Accessibility, double-clicking a low-sensitive restorable fixture can paste into the previous text field.
- Permission Assist appears after System Settings opens, sits beside that window, points toward it, and dragging the App icon does not drag the panel.
