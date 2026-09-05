# P7-D 浮层、设置页、快捷键与权限引导优化

状态：implemented
日期：2026-07-03
来源：用户指出剪贴板浮层仍接近全屏、尺寸不保存、默认详情过重；设置页剪贴板设置位置不自然；剪贴板/翻译/设置窗口会同时出现；输入框聚焦后第一次剪贴板快捷键偶发无反应；侧边栏不够高级；翻译目标语言自动识别不合理；权限授权需要独立拖拽辅助面板；玻璃透明感需要真实诊断。

## 变更摘要

- Clipboard / Translation 浮层改为 show/focus 语义，不再用快捷键 toggle 关闭；浮层展示前会隐藏普通主窗口/设置窗口，并关闭另一个工具浮层。
- 浮层接入外部点击关闭、`Esc` 关闭和右上角 Settings 按钮；Settings 按钮会关闭当前浮层并打开对应 Clipboard / Translation 设置 route。
- Clipboard 底部面板默认改为较窄 Paste-style tray，支持拖动调整宽高并按位置保存；默认不显示详情，改为 hover 条目时显示脱敏详情卡。
- Settings 左侧栏新增 Tools / Preferences 分组、彩色图标和更高行高；新增 Clipboard Settings / Translation Settings 独立 route。
- 权限授权按钮改为打开系统设置后展示独立 Permission Assist 浮层，浮层内有可拖拽 App 图标和动画箭头提示。
- Translation 浮层语言选择控件移动到左右 pane 顶部对齐；新增自动目标语言 resolver：自动模式下中文默认转英文，英文/日文默认转中文，用户手动选择后不再覆盖。
- 增加玻璃效果诊断卡，读取系统 Reduce Transparency 相关偏好；macOS 26 下 root glass 背景减轻，避免额外厚 material 压低透明感。

## 非目标

- 不新增 OCR runtime、长期 Login Item recorder、截图/OCR 图片上传、真实复杂剪贴板恢复、费用/额度提示或 provider 商业策略。
- Paste/Bob 只作为交互参考，不引入其代码或运行时依赖。

## 验证

已通过：

```bash
python3 tools/verification/p7d_clipboard_panel_resize_hover_checks.py
python3 tools/verification/p7d_panel_exclusivity_shortcut_focus_checks.py
python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py
python3 tools/verification/p7d_translation_auto_target_alignment_checks.py
python3 tools/verification/p7d_permission_assist_glass_diagnostics_checks.py
xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build
```

## 待人工低敏确认

- `Option + V` 首次按下稳定打开 Clipboard 浮层；调整尺寸后关闭再打开能恢复。
- Clipboard 底部卡片 tray 不再默认显示详情，hover 条目才出现详情。
- `Option + D` 中文输入默认目标为 English；手动改目标语言后不会被自动覆盖。
- 打开 Clipboard / Translation 浮层时，主设置窗口不再同时前置。
- 权限授权按钮打开系统设置后，Permission Assist 浮层显示可拖拽 App 图标和动画箭头。
