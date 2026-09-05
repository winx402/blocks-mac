# P7-C 设置稳定性 / 浮层交互 / 玻璃视觉优化

状态：implemented  
日期：2026-07-03  
来源：用户指出 Settings 菜单漂移仍存在，并要求 Provider / 快捷键独立入口、权限拖拽辅助、全局快捷键修饰键、Paste 风格剪贴板面板、Bob 风格自动翻译面板和更明显的 macOS 26 Liquid Glass 透明感。

## 变更摘要

- 主窗口从 `NavigationSplitView + List` 改为固定宽度手动 sidebar + 顶部锚定 detail，避免设置 detail 高度继续影响左侧菜单位置。
- Provider、Shortcuts、Permissions 提升为独立主菜单项；Settings 只保留通用偏好。
- 权限页新增可拖拽 App 图标辅助区；它只帮助用户把 App 拖入系统隐私权限列表，不绕过 macOS TCC。
- 快捷键新增全局修饰键偏好；没有单项自定义时使用全局修饰键，单项自定义优先。
- 剪贴板底部浮层改成 Paste 风格横向卡片 tray；左/右位置继续使用纵向 redacted 列表。
- 翻译浮层改成左右分割，并在输入或目标语言变化后自动翻译；真实外发仍受 Settings runtime gate 控制。
- `GlassPanel` 统一 macOS 26+ Liquid Glass 和 macOS 14-25 material fallback，减少散落的重 material 卡片。

## 非目标

- 不新增 OCR runtime、长期 Login Item recorder、真实截图/OCR 上传、剪贴板历史完整内容外发、费用/额度提示或 provider 商业策略。
- Paste/Bob 只作为交互参考，不引入其代码或运行时依赖。

## 验证

已通过：

```bash
python3 tools/verification/p7c_settings_navigation_provider_shortcuts_checks.py --timeout 180
python3 tools/verification/p7c_shortcut_global_modifier_checks.py --timeout 180
python3 tools/verification/p7c_clipboard_paste_style_panel_checks.py --timeout 180
python3 tools/verification/p7c_translation_auto_split_panel_checks.py --timeout 180
python3 tools/verification/p7c_liquid_glass_visual_boundary_checks.py --timeout 180
python3 tools/verification/p7b_settings_sidebar_stability_checks.py --timeout 180
python3 tools/verification/p6c_shortcut_acceptance_gate_checks.py --timeout 180
python3 tools/verification/p4k_clipboard_recorder_policy_checks.py --timeout 180
python3 tools/verification/p5q_translation_language_error_ux_checks.py --timeout 180
python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py --timeout 180
python3 tools/verification/p7a_low_sensitive_acceptance_gate_checks.py --timeout 180
```
