# P5-O OpenAI-compatible Translation Runtime Gate

状态：done
最后审阅：2026-07-02
来源级别：implementation story

## Story

As a 奇点工具 user,
I want LLM-backed Translation to run through my configured OpenAI-compatible provider only after I explicitly enable the runtime gate,
so that translation can become real without exposing screenshots, clipboard history, secrets, or provider raw responses.

## Scope

- 新增 `OpenAITranslationRuntimeService`，复用 P5-L 的 `OpenAIConnectionTransport` 和 Keychain 受控读取边界。
- Translation 面板新增 `Run Translation` 路径：Local Mock 本地生成；LLM-backed engine 在 Settings runtime gate、base URL、model、Keychain alias 和用户 secret 齐备时执行。
- Runtime result 只记录 status、provider summary、base URL host、model、target language、输出文本、duration、request id、secret length 和 audit id。
- Settings Provider / AI 区块新增 Translation Runtime Gate；默认关闭。
- Provider audit 新增 `translation_runtime` kind，只保存脱敏 metadata。
- 新增三语文案覆盖 runtime gate、runtime result、status 和 audit 字段。

## Non-goals

- 不自动读取剪贴板、截图、OCR 图片或剪贴板历史完整内容进入 provider。
- 不保存 raw request body、raw response body、Authorization、Bearer、API key、环境变量或 CLI token。
- 不执行本地 CLI、不读取环境变量、不做 OCR、不做 streaming、不做模型列表。
- 不做费用、额度或商业策略提示；provider 错误只作为接口错误显示。
- Dedicated Translation API、Local CLI Translation 和 OCR provider 仍只保留 route/error 模型。

## Acceptance Criteria

- Given Local Mock Translation 被选中，When 用户点击 Run Translation，Then App 生成本地 runtime result，不联网、不读 Keychain。
- Given LLM-backed Translation 被选中且 runtime gate 关闭，When 用户点击 Run Translation，Then 返回 `confirmation_required`，不读 Keychain、不联网。
- Given LLM-backed Translation 被选中且 runtime gate 开启，When Keychain/base URL/model/alias 齐备，Then App 从 Keychain 受控读取 secret 并调用 OpenAI-compatible `/v1/chat/completions`。
- Given provider 返回 401/403/429/5xx/timeout/invalid response，Then result 和 audit 使用统一短错误状态，不保存 raw response。
- Given 新增 UI 文案，Then `zh-Hans`、`en`、`ja` 都有 String Catalog 覆盖。

## Verification

- `python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180`
- `python3 tools/verification/p5n_translation_engine_router_checks.py --timeout 180`
- `python3 tools/verification/p5m_provider_routing_error_localization_checks.py --timeout 180`
- `python3 tools/verification/p5l_openai_connection_test_gate_checks.py --timeout 180`

## Notes

- P5-O 是首条真实翻译 runtime gate；自动化验证仍使用 mock transport，不调用外部 provider。
- 后续 `Option + D` 独立翻译浮层可以复用本轮 `runTranslation()` 路径，但剪贴板读取必须走 Settings 一次性开关。
