# P3-F Screenshot AI Route Ready

状态：implemented
日期：2026-07-03
来源：P3-E 截图结果浮层补强后的 OCR / AI 路由门禁

## 目标

把截图结果浮层里的 OCR / Translate / Summarize 从静态 preview 入口推进到 route-ready 状态展示：

- OCR 入口展示当前 OCR engine route。
- Translate 入口展示当前 Translation engine route，并提示需要先有 OCR 文本。
- Summarize 入口展示当前 LLM provider route，并提示需要 OCR 文本或本地图片摘要。
- 卡片展示 provider profile、confirmation level、error code / ready 状态和 audit-safe route detail。

## 实现范围

- `ScreenshotResultPresenter` 向结果浮层注入 `AppState`。
- `AppState.routeSummaryForScreenshotAIAction` 统一复用 `ProviderRouter`。
- `ScreenshotAIActionRoutePreview` 只承载 route metadata 和依赖提示。
- 结果浮层继续显示 `provider_call_not_executed / image_not_uploaded`。

## 边界

- 不执行 OCR。
- 不上传图片。
- 不调用 provider。
- 不把截图图片、OCR 内容或 provider 原始输出写入审计。

## 验证

- `python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py --timeout 180`
- 回归 `P3-E` 和 `P5-M`。
