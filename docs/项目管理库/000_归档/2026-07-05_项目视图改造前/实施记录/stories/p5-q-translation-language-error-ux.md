# P5-Q Translation Language Preferences + Error UX

状态：implemented
日期：2026-07-03
来源：P5-P 翻译浮层补强后的语言与错误体验收敛

## 目标

把翻译入口的语言行为和接口错误展示收敛到可日常使用的最小形态：

- 支持 default target language。
- 支持 remember last target language。
- 主窗口和 `Option + D` 浮层共用同一套目标语言偏好。
- 翻译 runtime 错误使用 ProviderErrorCode 的本地化错误短文案。
- 不增加费用、额度或商业解释类提示。

## 实现范围

- `AppState` 增加目标语言偏好解析与记忆方法。
- `TranslationHomeView` 和 `TranslationFloatingPanelView` 改用偏好驱动的目标语言选择。
- `OpenAITranslationRuntimeResult` 提供 `localizedErrorTitle` / `localizedErrorDetail`。
- Settings 增加 Language Preferences。

## 边界

- 不新增 provider 调用形态。
- 不执行 CLI provider。
- 不读取环境变量。
- 不上传截图、OCR 图片或剪贴板历史完整内容。

## 验证

- `python3 tools/verification/p5q_translation_language_error_ux_checks.py --timeout 180`
- 回归 `P5-P` / `P5-O` 翻译 runtime gate。
