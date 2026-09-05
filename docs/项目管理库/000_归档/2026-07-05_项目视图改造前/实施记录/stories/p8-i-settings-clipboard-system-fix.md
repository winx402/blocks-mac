# P8-I Settings 与 Clipboard 浮层系统化修复

状态：implemented / automated verification passed / visual screenshot follow-up needed
日期：2026-07-04

## 背景

P8-H 关闭了一部分可见问题，但用户反馈仍指出三个根因没有解决：

- Settings 内容区仍不像 Apple 设置行：左侧项目、右侧选项没有稳定对齐，行内图标过多。
- 不同设置页面混用 `SettingsSection`、厚卡片、随意 `VStack`、`Label`、`Grid`，导致全局风格不统一。
- Clipboard bottom panel 必须固定在屏幕底部、满宽、不可拖动位置，只允许调高度并记住高度。

本轮只修 Settings 体系和 Clipboard panel 行为，不扩展 provider/runtime、OCR、长期 recorder 或剪贴板数据层。

## 实现范围

### Settings 行模型

- 新增并统一使用 `SettingsTableSection + SettingsFormRow + SettingsActionRow`。
- 普通设置行不再渲染每行彩色 icon badge；行内结构固定为：
  - 左侧：标题 + 小字说明。
  - 右侧：单一 control / value / action group。
  - 中间：细分隔线。
- 内容最大宽度收敛为 Apple 风格设置表单，窗口变宽时增加留白，不拉散行内左右列。

### Settings 页面统一

- `General / Clipboard / Clipboard Privacy / Translation / Shortcuts / Providers / Permissions / Agent CLI / Hooks / Data Audit` 均接入统一 row/table 组件。
- 移除旧 `SettingsSection` 调用和容器类型。
- 复杂能力列表和诊断项保留为对象行，但嵌入同一 table section，不再做卡片套卡片。

### Clipboard bottom panel

- bottom frame 每次打开都按当前 `NSScreen.visibleFrame` 重新计算 `x/y/width`。
- bottom 宽度固定等于 `visibleFrame.width`，不读取、不保存宽度。
- bottom 只保存 `floatingPanel.clipboard.bottom.height`。
- panel `isMovable=false`、`isMovableByWindowBackground=false`。
- 增加 presenter anchor guard：打开、聚焦、移动结束后重新锚回当前屏幕底部。

## 非目标

- 不重做 Clipboard 条目内容模型、真实用户图片缩略图链路或 hover detail 边界避让。
- 不新增 OCR runtime、真实 provider、长期 Login Item、完整剪贴板内容恢复。
- 不调整 Shortcut / Provider 的业务能力，只统一设置页呈现。

## 验收标准

- Settings 普通偏好项不再出现一列 icon + 一列标题 + 一列控件的三列混乱感。
- 所有主要 Settings route 使用统一 table row 系统。
- Clipboard bottom panel 不可拖动位置，宽度满屏，高度可调并持久化。
- 自动检查脚本能阻止旧 `SettingsSection`、row-level icon 和 bottom panel 保存宽度回归。

## 证据

- 自动脚本：`python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180`
- 构建：`xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- 运行验证：`./script/build_and_run.sh --verify`
- 资源与接口回归：String Catalog JSON / `xcstringstool compile --dry-run`、`p2_action_smoke.py validate-schemas`、`p2_action_smoke.py smoke`
- 未覆盖：本轮未拿到 Clipboard Settings、Providers Settings、Clipboard bottom panel 三张指定视觉复核截图；见 acceptance record。
