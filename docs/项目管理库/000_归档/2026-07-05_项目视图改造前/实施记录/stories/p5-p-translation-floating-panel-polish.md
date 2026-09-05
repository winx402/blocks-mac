# P5-P Translation Floating Panel Polish

状态：implemented
日期：2026-07-03
来源：P5-O 翻译 runtime gate 后续交互补强

## 目标

把 Bob 风格翻译浮层补成可日常使用的最小面板：

- 支持清空输入。
- 支持运行中状态和短错误 banner。
- 支持复制当前译文。
- 保持 Local Mock 和 OpenAI-compatible runtime gate 的既有边界。

## 实现范围

- `TranslationFloatingPanelView` 新增 notice banner、清空、运行中状态和复制译文按钮。
- AppState 提供只复制当前 runtime output 的窄方法。
- 系统剪贴板写入集中在 `ClipboardTextPreviewService.writePlainText`。
- 新增 P5-P 验证脚本，回归 P5-O 并检查 UI/状态/隐私边界。

## 边界

- 不执行 CLI provider。
- 不读取环境变量。
- 不上传截图、OCR 图片或剪贴板历史完整内容。
- 不新增费用、额度或商业提示。

## 验证

- `python3 tools/verification/p5p_translation_panel_polish_checks.py --timeout 180`
- `python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180`
