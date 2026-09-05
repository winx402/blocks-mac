---
id: p5-m-provider-routing-error-localization
title: P5-M Provider Routing + Error Localization Foundation
status: implemented
date: 2026-07-02
sourcePlan: P5-M Provider Routing + Error Localization Foundation
---

# P5-M Provider Routing + Error Localization Foundation

## Summary

P5-M 在 P5-L 低敏 OpenAI-compatible test connection 之后新增 provider 路由和错误归一化基础。目标是让后续 LLM、翻译、OCR、总结、改写和未来 LLM 转换类工具共享同一套 route / error / localization 边界。

## Implemented

- 新增 `ProviderErrorCode`，覆盖 `missing_configuration`、`missing_secret`、`invalid_base_url`、`unauthorized`、`forbidden`、`rate_limited`、`timeout`、`network_error`、`invalid_response`、`provider_unavailable`、`unsupported_capability`、`confirmation_required`。
- 新增 `ProviderRouteRequest`、`ProviderRouteResolution`、`ProviderRouteSummary` 和 `ProviderRouter`。
- `OpenAIConnectionStatus` 增加统一 `ProviderErrorCode` 映射；`rate_limited` 只作为接口错误分类，不做费用、额度或商业策略提示。
- Translation 面板接入 route check；Local Mock 继续本地生成 mock result，API / CLI 路径只显示 route resolution，不执行真实 provider。
- Settings Provider / AI 区块新增 route check，展示 capability route、confirmation level 和结构化错误。
- Provider audit 新增 `provider_route_resolution`，仍为内存态脱敏摘要。
- `zh-Hans`、`en`、`ja` 三语补齐 provider error 文案。

## Privacy And Safety

- P5-M 不读取 Keychain secret、不调用 `URLSession`、不执行 CLI、不读取剪贴板、不读取截图正文。
- 路由结果只保存 capability、profile、execution mode、provider summary、confirmation level、error code 和 audit id。
- 不保存 prompt、翻译正文、OCR 图片、provider raw response、Authorization header 或 Bearer token。

## Verification

- `python3 tools/verification/p5m_provider_routing_error_localization_checks.py --timeout 180`
- `python3 tools/verification/p5l_openai_connection_test_gate_checks.py --timeout 180`
- `python3 tools/verification/p5k_user_secret_keychain_gate_checks.py --timeout 180`
- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `./script/build_and_run.sh --verify`

## Not Covered

- 真实翻译、OCR、总结、改写或截图/剪贴板内容外发。
- Streaming、模型列表、CLI execution、Apple Vision OCR runtime、DeepL 类专用翻译 API、LiteLLM gateway runtime。
- 持久 provider audit 和完整工具内容确认卡片。
