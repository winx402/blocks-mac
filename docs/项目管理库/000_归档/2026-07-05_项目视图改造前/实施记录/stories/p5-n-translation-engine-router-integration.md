# P5-N Translation Engine Router Integration

状态：done
最后审阅：2026-07-02
来源级别：implementation story

## Story

As a 奇点工具 user,
I want the Translation panel to choose a Translation Engine instead of the legacy translation provider picker,
so that Local Mock, LLM-backed Translation, Dedicated Translation API, and future Translation runtimes share the same provider routing and error boundary.

## Scope

- Translation 面板的主 picker 绑定 `selectedTranslationEngineID` / `translationEngineProfiles`。
- Local Mock Translation 继续生成本地 mock result。
- LLM-backed Translation 和 Dedicated Translation API 只展示 `ProviderRouter` route resolution、本地化错误和 confirmation level。
- `TranslationProviderProfile` / `selectedTranslationProviderID` / 旧 mock result API 保留为 P5-B 兼容层，本轮不删除。
- Settings Provider / AI 区块新增独立 Translation Engine route check，和 LLM provider route check 分开。
- 新增三语 UI 文案：`translation.enginePicker`、engine route、Settings translation engine route check 和 selected status。

## Non-goals

- 不做真实翻译 provider runtime。
- 不读取 secret、不读取 Keychain secret bytes。
- 不调用 provider、不联网、不执行 CLI。
- 不上传翻译正文、截图正文、剪贴板正文或 OCR 图片。
- 不处理费用、额度或商业策略提示；`rate_limited` 仅保留为接口错误码。

## Acceptance Criteria

- Given Translation 面板打开，When 用户切换 engine，Then AppState 使用 `selectTranslationEngine(id:)` 更新 preview provider summary，并刷新 route resolution。
- Given Local Mock Translation 被选中，When 用户生成 mock result，Then result 的 provider summary 来自 selected Translation Engine。
- Given LLM-backed Translation 或 Dedicated Translation API 被选中，When 用户检查 route，Then UI 展示 `unsupported_capability` 或对应 route/error，而不执行真实外发。
- Given Settings Provider / AI 区块，When 用户点击 Translation Engine route check，Then 只记录脱敏 `provider_route_resolution` audit metadata。
- Given 新增 UI 文案，Then `zh-Hans`、`en`、`ja` 都有 String Catalog 覆盖。

## Verification

- `python3 tools/verification/p5n_translation_engine_router_checks.py --timeout 180`
- `python3 tools/verification/p5m_provider_routing_error_localization_checks.py --timeout 180`
- `python3 tools/verification/p5b_translation_mock_result_checks.py --timeout 180`

## Notes

- P5-N 是 Translation Engine 路由接线，不是真实 provider runtime。
- P5-O 可继续做 OpenAI-compatible 翻译 runtime，但必须单独处理内容外发确认、脱敏审计和错误翻译。
