# P6-B Shortcut Customization + Floating Panel Polish

状态：implemented
日期：2026-07-03
来源：P6-A 后续交互补强

## 目标

把 P6-A 的固定 `Option + A/V/D` 快捷入口推进为可配置入口，并补齐 Paste / Bob 风格浮层的基础键盘交互：

- Settings 支持截图、剪贴板、翻译三条快捷键的启用/禁用、录入、恢复默认和全部恢复默认。
- `Option + V` 再次触发时关闭剪贴板历史浮层；搜索框默认聚焦，`Esc` 关闭。
- `Option + D` 如果翻译浮层已打开，只聚焦现有浮层，不覆盖正在编辑的输入；输入框默认聚焦，预填时尝试全选，`Esc` 关闭。
- 翻译浮层增加 source / target 交换按钮；source 为 auto 时禁用。

## 实现范围

- `ShortcutController` 新增 `ShortcutBinding` / `ShortcutBindingStore`，从 UserDefaults 读取每条命令的绑定并注册全局快捷键。
- 保留 `registerDefaultShortcuts()` 兼容入口，内部转到 `registerConfiguredShortcuts()`。
- Settings 新增 `ShortcutRecorderRow`，使用一次性 `NSEvent.addLocalMonitorForEvents` 捕获下一个组合键；只接受“至少一个修饰键 + 一个普通按键”。
- 浮层 presenter 继续使用 `NSPanel + NSHostingView`；剪贴板面板提供 toggle，翻译面板提供 focus existing。
- 新增三语 String Catalog 文案，覆盖录入、禁用、恢复默认、无效组合、翻译结果和交换语言。

## 边界

- 本轮不实现复杂 key sequence、系统保留快捷键识别、跨键盘布局完整映射或冲突自动修复。
- 禁用只影响 `ShortcutController` 的全局 hot key 注册；不会改变菜单按钮本身的可点击行为。
- 不新增 provider 调用、Keychain 读取、CLI 执行、剪贴板历史完整内容读取、截图外发或 OCR。
- 快捷键配置只保存在本机 UserDefaults，不进入 action JSON 字段名或 CLI 机器接口。

## 验证

- `python3 tools/verification/p6b_shortcut_customization_panel_polish_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/verification/p6a_shortcut_panel_interaction_checks.py --timeout 180`
- `python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180`
- `python3 tools/verification/p4i_clipboard_floating_panel_checks.py --timeout 180`
- `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py --timeout 180`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `git diff --check`
