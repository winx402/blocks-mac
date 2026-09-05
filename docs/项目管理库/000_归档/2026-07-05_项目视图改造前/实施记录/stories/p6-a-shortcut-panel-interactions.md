# P6-A Shortcut + Floating Panel Interactions

状态：implemented
日期：2026-07-02
来源：P5-O / P4 深化 / P3 补强 / 快捷浮层交互计划

## 目标

把正式 App 从主窗口入口推进到更接近真实工具体验的快捷浮层：

- `Option + A`：区域截图。
- `Option + V`：打开 Paste 风格剪贴板历史浮层。
- `Option + D`：打开 Bob 风格翻译浮层。

## 实现范围

- 新增 `ShortcutController`，使用系统 hot key 注册 `Option + A`、`Option + V`、`Option + D`，并把 OSStatus 注册结果展示到 Settings。
- 新增 `TranslationPanelPresenter` 和 `TranslationFloatingPanelView`，使用 `NSPanel + NSHostingView` 展示独立翻译浮层。
- 新增 `ClipboardTextPreviewService`，只在 Settings 开关允许时读取当前剪贴板纯文本，用于 `Option + D` 预填输入框。
- Settings 新增翻译浮层剪贴板预填开关；默认开启。
- 翻译浮层复用现有 Translation Engine router 和 P5-O translation runtime，不新增 provider、secret 或 CLI 执行边界。
- 新增三语文案：翻译浮层、快捷键状态、语言选项。

## 边界

- 不实现完整快捷键自定义录入 UI；本轮只固定默认快捷键并显示注册状态。
- 不读取剪贴板历史完整内容进入 provider；`Option + D` 只读取当前系统剪贴板纯文本并展示给用户。
- 不执行 CLI provider，不调用 OCR provider，不上传截图图片。
- OpenAI-compatible 翻译 runtime 仍受 P5-O gate 控制：只有用户配置并开启外发时才执行。

## 验证

- `python3 tools/verification/p6a_shortcut_panel_interaction_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180`
- `python3 tools/verification/p4i_clipboard_floating_panel_checks.py --timeout 180`
- `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py --timeout 180`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `git diff --check`
