# P8-L Clipboard Bottom 面板高度锚定修复

状态：verified with automated gates / manual drag review pending
日期：2026-07-04

## 背景

P8-K 只验证了 Clipboard bottom panel 有顶部高度 handle 和只保存 height key，但用户实测指出拖动行为仍被感知为“把整个面板 position 拖到上面”。这说明验收口径不够硬：必须用窗口几何约束证明 bottom 面板底边始终贴着屏幕底部。

## 实现范围

- Clipboard bottom panel 的几何契约固定为 `x = visibleFrame.minX`、`y = visibleFrame.minY`、`width = visibleFrame.width`、`height = saved/clamped height`。
- `FloatingPanelFrameStore` 的 bottom frame / height helper 由打开、系统 resize、live resize 结束和 move guard 复用。
- `ClipboardHistoryPanelPresenter` 使用系统 `.resizable` 窗口边框调节高度，`windowDidResize` 每一帧都用 `visibleFrame.minY` 重建 frame，避免从旧 frame 继承 y。
- 面板继续 `isMovable=false`、`isMovableByWindowBackground=false`；不再渲染顶部自定义 resize handle。
- P8-K Clipboard 高度项标记为 `reopened_by_p8l`，本轮用 P8-L acceptance record 重新关闭。

## 非目标

- 不改 Clipboard 条目内容渲染、hover detail、筛选、权限、自动粘贴或数据层。
- 不改 left/right 面板策略；本轮只收敛 bottom 面板底部锚定。
- 不处理真实 provider、OCR、长期 Login Item 或新权限能力。

## 验收标准

- 打开 bottom panel 时底边贴着屏幕 `visibleFrame.minY`，宽度等于当前屏幕可见宽度。
- 拖动系统窗口顶部边框只改变 `frame.height`；resize 过程中 `frame.minY` 不变。
- 关闭重开后高度保持，但 x/y/width 仍按当前屏幕重新计算。
- P8-L / P8-K / P8-J / P8-I 自动门禁、构建和资源校验通过。

## 证据

- 自动脚本：`python3 tools/verification/p8l_clipboard_bottom_height_anchor_checks.py --timeout 180`
- 回归脚本：`python3 tools/verification/p8k_settings_fullscreen_section_clipboard_height_checks.py --timeout 180`
- 回归脚本：`python3 tools/verification/p8j_settings_alignment_picker_checks.py --timeout 180`
- 回归脚本：`python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180`
