# AI Capability Provider Layer v0

状态：proposed
最后审阅：2026-07-02
来源级别：architecture boundary

本文定义「积木工具」后续接入 LLM、翻译和 OCR provider 的分层边界。它回应 P5-H 的范围收敛：provider 不是只给翻译工具使用；LLM provider 是全局 AI 能力，翻译 provider 和 OCR provider 则是各自能力域下的 engine，可以选择复用 LLM，也可以接专用服务。

## 结论

- App 内部保留一个轻量 **AI Capability Provider Layer**，按 `LLM / Translation / OCR` 三个能力域管理 profile、确认、Keychain account alias、外发预览和审计摘要。
- V1 先做薄 adapter，不把 LiteLLM、LangChain、LlamaIndex 等大型路由框架嵌进 App runtime；多厂商覆盖优先通过 OpenAI-compatible API、用户自建 gateway、LiteLLM gateway 或本地 CLI 实现。
- Translation Engine 和 OCR Engine 不能等同于 LLM Provider。翻译可以走 LLM，也可以走 DeepL 类专用翻译 API；OCR 可以走本地 Apple Vision，也可以走多模态 LLM 或专用云 OCR。
- P5-K 在 profile catalog 和 LLM adapter boundary 之上新增用户 API key Keychain 保存门禁与 OpenAI-compatible dry-run；P5-L 进一步新增低敏 OpenAI-compatible test connection，但仍不把真实工具内容交给 provider。
- P5-N 将 Translation 面板主选择源迁到 **Translation Engine**，Local Mock、LLM-backed Translation 和 Dedicated Translation API 都通过 `ProviderRouter` 做 route/error 解析；P5-O 在此基础上新增 OpenAI-compatible 翻译 runtime gate，只在用户开启 Settings gate 且 Keychain/base URL/model/alias 齐备时调用 provider。

## 能力域

| 能力域 | 当前 profile | 后续用途 | 外发边界 |
| --- | --- | --- | --- |
| LLM Provider | Local Mock、OpenAI-compatible API、LiteLLM / Gateway、本地 CLI / Agent | 总结、改写、解释、结构化提取、未来 LLM 转换类工具、LLM-backed 翻译、multimodal OCR | 非本地 mock 一律需要 `external_transfer` 确认、Keychain/CLI 边界和审计。 |
| Translation Engine | Local Mock Translation、LLM-backed Translation、Dedicated Translation API | 手动输入翻译、截图 OCR 后翻译、剪贴板条目翻译、agent 翻译 action | LLM-backed 继承 LLM provider 外发规则；专用 API 也必须确认和审计。 |
| OCR Engine | Local Mock OCR、Apple Vision OCR、Multimodal LLM OCR、Cloud OCR API | 截图 OCR、图片 OCR、OCR 后翻译/总结、未来图片文本工具 | Apple Vision 默认本地；多模态 LLM 和云 OCR 传输图片/截图前必须确认。 |

## Profile 模型

正式 App 当前新增 `AICapabilityProfile` 骨架，字段表达：

- `domain`：`llm`、`translation`、`ocr`。
- `executionMode`：本地 mock、OpenAI-compatible、LiteLLM gateway、本地 CLI、LLM-backed、专用 API、Apple Vision、多模态 LLM、云 OCR。
- `configured` / `implemented`：区分已可用、本地占位和未来入口。
- `localOnly` / `requiresExternalTransfer`：驱动 UI badge、确认级别和审计语义。
- `requiresKeychainSecret`：驱动 Keychain gate；不表示当前已经支持真实 secret 输入。

当前实现有三个 wrapper：`LLMProviderProfile`、`TranslationEngineProfile`、`OCREngineProfile`。它们是能力目录；P5-I 额外新增 `LLMProviderAdapter` 边界，但当前只有本地 mock adapter，不等于真实 runtime provider。

## Adapter 策略

### 推荐默认

1. OpenAI-compatible API：作为最小 API adapter 边界，降低多厂商维护成本。
2. 用户自建 gateway / LiteLLM gateway：作为“尽量全”的扩展路径，由 gateway 消化厂商差异，App 只维护兼容边界和安全策略。
3. 本地 CLI / Agent：适配 Codex、Claude Code、GitHub Copilot、Qoder、opencode 等 CLI，但默认不静默执行，需要显式确认、超时、结构化输出和审计。
4. 专用 engine adapter：只在确有质量或体验价值时接入，例如 Apple Vision OCR、DeepL 类翻译 API。

### P5-I adapter 边界

- `LLMProviderAdapter` 当前只定义 request、response、error 和 output format 边界。
- `OpenAICompatibleProfileBoundary` 只记录 base URL host 摘要、model、Keychain account alias、provider id/name 和 timeout；不保存 API key、完整 prompt、messages 或 provider 原始输出。
- `LLMProviderMockAdapter` 只生成本地 mock response 和 audit summary；不调用 `URLSession`、不执行 `Process`、不读取 Keychain、不读取剪贴板、不做 OCR。
- Settings 中的 OpenAI-compatible preview 只写入 `external_transfer` 预览事件；真实 provider 调用仍被阻断。
- P5-K 的用户 secret 路径只把确认后的 key 写入 `openai-compatible:<alias>` Keychain item；OpenAI connection dry-run 只记录 `POST /v1/chat/completions` 元数据，不读取 key、不发送网络请求。
- P5-L 新增 `OpenAICompatibleConnectionService`，只在用户显式确认外发后短生命周期读取 Keychain secret，发送固定低敏 ping test；返回脱敏状态、HTTP status、耗时和 request id，不保存 provider 原始响应。
- P5-M 新增 `ProviderRouter`、`ProviderRouteRequest`、`ProviderRouteResolution`、`ProviderRouteSummary` 和 `ProviderErrorCode`，统一 LLM / Translation / OCR 的路由检查和错误文案边界。
- P5-N 新增 Translation Engine router integration：Translation UI 使用 `selectedTranslationEngineID` / `translationEngineProfiles`，Settings 提供单独 Translation Engine route check；LLM-backed / Dedicated Translation 当前只返回 route/error，不执行 runtime。
- P5-O 新增 `OpenAITranslationRuntimeService`：复用 P5-L 的 OpenAI-compatible transport 和 Keychain 受控读取边界，执行翻译正文请求，结果只保留译文和脱敏 metadata，不保存 raw request、Authorization、Bearer 或 raw response。

### 当前不做

- 不在 App 内维护完整厂商矩阵。
- 不把第三方 Python/Node provider router 作为主 App 必需 runtime。
- 不读取环境变量里的真实 key。
- 不保存 provider 原始输出、CLI token、完整截图、完整剪贴板原文到日志或仓库。

## 安全与确认

- 完整截图、完整剪贴板内容、OCR 图片、翻译原文、AI 改写原文进入外部 provider 前必须展示摘要、来源、数量、provider 和确认级别。
- API secret 只走 Keychain；Settings 当前允许用户显式确认后写入 `openai-compatible:<alias>`，并在 P5-L 允许显式确认后的低敏 test connection。P5-O 允许用户开启 Translation Runtime Gate 后外发翻译正文；截图图片、OCR 图片、剪贴板历史完整内容和其他工具内容外发仍必须单独实现边界。
- 本地 CLI 使用 CLI 自身登录态；App 不复制、不读取、不迁移 CLI token。
- Agent 默认只能拿摘要。完整内容读取和外发处理必须走 `preview` 或 `external_transfer` 确认。
- Hook enabled、阻断、修改、删除、自动外发仍属于 `destructive_or_hook` 高风险路径。

## P5-H / P5-I / P5-J / P5-K / P5-L / P5-M / P5-N / P5-O 当前实现状态

- 新增 `AICapabilityProfiles.swift`，定义 `AICapabilityDomain`、`AICapabilityProfile`、`LLMProviderProfile`、`TranslationEngineProfile`、`OCREngineProfile` 和 `AICapabilityCatalog`。
- `ProviderStore` / `TranslationStore` 暴露 `llmProviderProfiles`、`translationEngineProfiles`、`ocrEngineProfiles` 和对应 selected id；`AppModel` 只负责 route/status/coordinator 装配，不再作为 Provider / Translation facts facade。
- Settings Provider / AI section 新增 AI Capability Gate，展示 LLM / Translation / OCR 三组 profile、local/external/not implemented badge。
- 现有 P5-B 翻译 provider profile 保持兼容；P5-H 不改变当前 Local Mock 翻译结果面板，不执行真实 provider。
- P5-I 新增 `LLMProviderAdapter.swift`、`LLMProviderMockAdapter`、`OpenAICompatibleProfileBoundary` 和 Settings LLM Adapter Boundary 区块。
- P5-I 新增 provider audit kind：`llmAdapterPreview` 和 `llmMockRun`；事件仍为内存态脱敏摘要。
- P5-J 新增 `ProviderSecretInputPreview`、`OpenAIConnectionPreviewDraft`、Settings API Key Input Gate 和 OpenAI Connection Preview。
- P5-J 新增 provider audit kind：`secretInputPreview` 和 `openAIConnectionPreview`；事件仍为内存态脱敏摘要。
- P5-K 新增用户 API key Keychain 保存门禁和 `userSecretKeychainGate` audit kind；用户 secret 审计不含原文或 hash。
- P5-L 新增 OpenAI-compatible low-sensitive test connection 和 `openAIConnectionTest` audit kind；自动化验证使用 mock transport，不调用真实外部 provider。
- P5-M 新增 provider routing foundation 和 `providerRouteResolution` audit kind；Translation 面板和 Settings 可做本地 route check，不读取 secret、不调用 provider、不执行 CLI。
- P5-N 将 Translation 面板 picker 迁到 Translation Engine；Local Mock 继续生成本地 mock result，LLM-backed Translation 和 Dedicated Translation API 只展示 route resolution、本地化错误和 confirmation level。
- P5-O 新增 OpenAI-compatible 翻译 runtime gate 和 `translationRuntime` audit kind；自动化验证使用 mock transport，不调用真实外部 provider。

## 后续落地顺序

1. 保持 P5-H profile catalog 与现有 Provider connection gate 一致。
2. 在 P5-O Translation runtime gate 基础上，继续规划 Bob 风格独立翻译浮层、截图 AI preview entries 和 OCR / 总结的独立 runtime 边界。
3. 将 OCR Engine 的具体 runtime 接入继续拆成单独 story。
4. 再决定是否接 LiteLLM gateway、本地 CLI execution 或 Apple Vision OCR。
5. 后续真实工具内容外发仍必须保持显式确认和脱敏审计。

## 关联文档

- [Provider Secret Handling v0](Provider-Secret-Handling-v0.md)
- [AI / Agent / CLI / Hook 能力边界](AI-agent-CLI-Hook能力边界.md)
- [正式 App Scaffold 架构 v0](正式AppScaffold架构-v0.md)
- [项目进度索引](../项目管理库/index.md)
