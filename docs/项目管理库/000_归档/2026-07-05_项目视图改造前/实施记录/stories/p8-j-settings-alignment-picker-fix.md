# P8-J Settings 右对齐与控件类型修复

状态：implemented / verification in progress
日期：2026-07-04

## 背景

P8-I 建立了 Settings 行模型，但体验验收继续暴露两个问题：

- 右侧控件仍不在同一条垂直线上，原因是页面内散落 `220 / 260 / 300 / 320 / 340 / 360 / 390` 等局部宽度。
- 4 个及以上选项仍使用 segmented control，导致控件拥挤且不像 macOS 设置。

本轮只修 Settings 对齐和控件类型，不改 Clipboard 浮层、权限、provider runtime 或剪贴板数据层。

## 实现范围

- 新增 `SettingsLayout`，固定 Settings 内容最大宽度和右侧控件列宽。
- 新增 `SettingsRowShell`，统一普通设置行、操作行、快捷键行、权限诊断行、Provider readiness / audit 行的左右布局。
- 删除 `SettingsFormRow` / `SettingsActionRow` 的行内 icon 参数，普通偏好项不再为每行保留彩色图标入口。
- 4 个及以上选项切换为 `.menu`：保留时间、最大条目、筛选清空延迟、全局快捷键修饰键、Agent 授权时长。
- 3 项选项继续使用 segmented：Clipboard 面板位置、Agent 默认读取范围。

## 非目标

- 不调整 Settings 侧边栏分类。
- 不重做 Clipboard 条目卡片、hover detail 或图片缩略图真实数据链路。
- 不新增 provider、OCR、权限或长期 recorder 能力。

## 验收标准

- 右侧控件统一使用 `SettingsLayout.trailingColumnWidth`。
- 主要 Settings 页面不再使用散落的控件宽度。
- 4+ 选项 picker 不再使用 `.segmented`。
- 3 项核心 picker 保持 `.segmented`。
- 构建和 P8-I / P8-J 静态门禁通过。

## 证据

- 自动脚本：`python3 tools/verification/p8j_settings_alignment_picker_checks.py --timeout 180`
- 回归脚本：`python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180`
- 构建：`xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
