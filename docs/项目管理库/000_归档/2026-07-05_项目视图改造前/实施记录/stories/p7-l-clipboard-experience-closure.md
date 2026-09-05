# P7-L Clipboard 体验闭环

状态：implemented / core path passed in P7-O

## Scope

P7-L 聚焦 `Control + Option + V` Clipboard 浮层的高频体验，不开放真实用户完整剪贴板内容恢复，不启用长期 Login Item。

## Changes

- Bottom Clipboard panel 保持满宽贴底、不可拖动、不可横向缩放，只保存高度。
- Bottom 默认高度和最大高度收紧，减少大面积空白玻璃区域。
- Bottom UI 以横向卡片 tray 为主体，footer 压缩成低调状态行。
- Hover detail 继续只在 hover 时显示；pin/delete 操作只在 hover 或选中时暴露。
- 双击可恢复 fixture 条目沿用自动粘贴路径：关闭浮层、写入系统剪贴板、恢复目标 App、发送 `Cmd+V`；失败时记录明确原因。

## Verification

- `python3 tools/verification/p7l_clipboard_experience_gate_checks.py`
- `python3 tools/verification/p7i_clipboard_bottom_tray_window_checks.py`
- `python3 tools/verification/p7h_clipboard_autopaste_activation_checks.py`

## Manual Acceptance

- P7-O 已在 TextEdit 中验证 `Control + Option + V` 能打开底部 Clipboard panel。
- 调整系统窗口顶部边框只改变高度；关闭再打开后高度恢复，宽度仍按当前屏幕满宽。
- P7-O 已验证 Return 和双击低敏可恢复 fixture 均能进入自动粘贴真实发送路径。
