# P8-K Settings 全屏适配、Section 标题与 Clipboard 高度调节

状态：verified with automated gates / Clipboard height reopened_by_p8l
日期：2026-07-04

## 背景

P8-J 修复了 Settings 右侧控件列对齐和 picker 类型，但全屏体验继续暴露三个问题：

- Settings 内容区在全屏时贴左显示，右侧留下大面积空白。
- 普通 section 标题仍带彩色图标，与“设置项: 控件”的 Apple 风格不一致。
- Clipboard bottom panel 的高度调节需要明确为真实窗口高度 `frame.height`，不是位置或 position 设置。

更新：用户在 P8-K 后实测指出 Clipboard 高度调节仍被感知为 position 拖动。Clipboard bottom panel 的完整几何闭环由 [P8-L Clipboard Bottom Height Anchor](p8-l-clipboard-bottom-height-anchor.md) 重开处理；本 P8-K 只保留 Settings 全屏和 section 标题修复证据。

## 实现范围

- Settings 内容继续限制最大宽度，但在全屏容器中居中收敛。
- `SettingsTableSection` 移除 `systemImage/color` 入参，普通 section 标题不再渲染图标，使用更清晰的 semibold 文本。
- Clipboard bottom panel 继续固定底部满宽；高度调节入口已由 P8-L 后续收敛为系统窗口边框 resize。
- 新增 P8-K 自动验证脚本，覆盖全屏居中、section 无图标和 clipboard 高度只保存 `frame.height`。

## 非目标

- 不做 Settings 全屏铺满或双栏自适应。
- 不改变侧边栏、App 列表、权限对象行等对象型图标。
- 不处理 Clipboard 条目内容渲染、hover detail 边界避让、权限、provider、OCR 或数据层。

## 验收标准

- Settings 全屏时内容居中收敛，不再 `topLeading`。
- 普通 Settings section 标题不再显示彩色图标。
- Clipboard bottom panel 仍固定底部满宽，只能通过系统窗口 resize 调整真实高度，并只保存高度 key。
- P8-K / P8-J / P8-I 自动门禁、构建和 String Catalog 校验通过。

## 证据

- 自动脚本：`python3 tools/verification/p8k_settings_fullscreen_section_clipboard_height_checks.py --timeout 180`
- 回归脚本：`python3 tools/verification/p8j_settings_alignment_picker_checks.py --timeout 180`
- 回归脚本：`python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180`
