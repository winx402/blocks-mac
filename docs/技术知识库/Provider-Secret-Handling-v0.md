# Provider Secret Handling v0

状态：proposed
最后审阅：2026-07-02
来源级别：security boundary

本文定义积木 AI 工具箱接入本地 CLI provider、API provider、翻译引擎和 OCR 引擎时的凭据边界。它不是最终实现方案；正式 App 建立后需要形成决策记录。

## 命名边界

- 产品暂定名：积木 AI 工具箱，简称积木工具。
- 技术前缀：`blocks`。
- action namespace 使用 `blocks.*`，例如 `blocks.translate.text`。

## Provider / Engine 类型

| 类型 | 凭据来源 | 当前策略 |
| --- | --- | --- |
| LLM API provider | API key、base URL、model | 正式 App 默认使用 Keychain；P5-K 已允许用户显式确认后写入 `openai-compatible:<alias>`，P5-L 已允许在外发确认后短生命周期读取 secret 做低敏 OpenAI-compatible test connection；P5-O 已允许用户开启 Translation Runtime Gate 后外发翻译正文。 |
| 本地 CLI provider | provider 自身登录态或本机配置 | 工具只调用 CLI，不读取、不复制、不保存 CLI token；当前仍不执行真实 CLI。 |
| 翻译 engine | LLM provider、专用翻译 API key、base URL、model 或语言服务配置 | 可以复用 LLM provider，也可以走 DeepL 类专用 API；P5-O 首条 runtime 只覆盖 OpenAI-compatible LLM-backed Translation。 |
| OCR engine | 本地 Apple Vision、multimodal LLM、专用云 OCR API key | Apple Vision 默认本地；外部 OCR / multimodal LLM 传输图片前必须确认；当前只做 placeholder。 |
| 本地模型/provider | 本机服务或模型目录 | 不属于 secret，但仍需记录路径、版本和数据流。 |

## 默认存储顺序

1. macOS Keychain：正式 App 的默认 secret 存储位置。
2. 环境变量：仅用于本地开发和 CI smoke，不能写入仓库。
3. 未提交本地配置文件：只允许保存 provider 名称、模型名、base URL、Keychain account alias，不保存 secret。

## 禁止项

- 不把 API key、token、完整订阅链接、验证码、私钥写入仓库。
- 不在日志、验证记录或 CLI 输出中保存完整 secret。
- 不把截图、完整剪贴板历史、OCR 图片、选中文本原文自动外发给 provider。
- 不让 agent 静默新增、读取或迁移 provider 凭据。

## P2-B 实调结论

- `blocks_provider_smoke.py` 已验证 Codex CLI 可以用低敏 prompt 返回结构化 JSON。
- Codex CLI 调用使用自身登录态；本仓库没有读取或保存 Codex 凭据。
- 在 `/tmp` 隔离目录运行时，Codex CLI 需要 `--skip-git-repo-check`。
- API provider 仍未实调；P2-B 不调用真实 API。

## P2-E Keychain 实调结论

- `BlocksMacOSProbe blocks-keychain --fixture-roundtrip --delete-after` 已验证 generic password 的 add、read、update、read、delete 和删除后 missing-read。
- 固定 service：`app.blocks.provider.p2e`；固定 account：`mock-api:p2e-dummy`。
- 本轮只写入低敏 dummy secret；输出只记录长度、字节数、SHA-256 前 12 位和 OSStatus，不输出 secret 原文。
- 测试结束后删除 Keychain 项，最终读取返回 `errSecItemNotFound`。
- 真实 API provider 仍未实调；没有 provider UI、未提交本地配置和数据出境确认前，不调用真实 API。

## P2-K Provider 设置确认结论

- `blocks_provider_settings_smoke.py smoke` 已验证 mock API provider profile 和 CLI provider profile 的 redacted 配置输出。
- mock API profile 只记录 provider、model、base URL 摘要、Keychain account alias、timeout 和 `external_transfer` preview。
- CLI profile 只记录命令形态、PATH 是否存在和 `external_transfer` preview；不读取 CLI token。
- 本轮不读取环境变量、不读取 Keychain secret、不访问网络、不调用真实 API。

## P2-L 正式 scaffold 边界

- 主 App 负责 provider 设置 UI、Keychain account alias、base URL、模型名、测试连接入口、外发 preview 和审计展示。
- Helper 默认不读取 provider secret，不执行外部 CLI provider，也不保存 provider 原始输出。
- `blocks` CLI 可以请求 provider 相关 action，但不能读取 Keychain secret；需要外发内容时必须返回或触发 `external_transfer` 确认。
- API provider 在正式 UI、Keychain account 命名、审计日志和数据出境确认落地前，仍不得执行真实调用。

## P5-B 到 P5-G 正式 App 状态

- P5-B 已在正式 App 中加入 Local Mock、BYOK API placeholder 和 Local CLI placeholder；只有 Local Mock 生成本地 mock result，不执行真实 provider。
- P5-C 已在 Settings 中加入 Provider / AI section；当前只保存默认 provider、Keychain account alias、API Base URL 和本地 CLI 名称，不读取 Keychain、不读取环境变量、不访问网络、不执行 CLI。
- P5-D 已在 Settings 中加入 Keychain secret lifecycle UI skeleton；Save / Rotate / Delete / Verify Missing 只改变本地生命周期状态和低敏 audit id，不提供 secret 输入框。
- P5-E 已在 Settings 中加入 Provider audit summary skeleton；Local Mock 结果、Provider confirmation preview 和 Keychain lifecycle UI intent 会写入最多 20 条内存态脱敏摘要，展示最近 5 条并支持清空。当前不持久化审计日志、不保存 provider 原始输出、不调用真实 provider。
- P5-F 已在 Settings 中加入 Provider connection gate skeleton；Local Mock 显示 ready，BYOK API 和 Local CLI 明确显示真实 Keychain / 网络 / CLI 执行门禁阻断。Validate / Preview Test 只更新本地状态和脱敏审计摘要，不读取 Keychain、不发起网络请求、不执行 CLI。
- P5-G 已在 Settings 中加入真实 Keychain 低敏测试门禁；固定 service 为 `app.blocks.provider.dev`，account 形态为 `mock-api:<alias>`。Save / Rotate / Delete / Verify Missing 调用 `SecItem` 写入、读取、更新、删除固定低敏 fixture，UI 和审计只展示 service、account、OSStatus、长度和 SHA-256 前 12 位。
- P5-G 的验证脚本执行 add、read、update、delete 和 missing-read，最终测试项必须被删除；验证输出不得包含 fixture secret 原文。
- P5-G 不等同于真实 BYOK：仍不提供真实 API key 输入框，不读取真实 API key，不读取环境变量，不发起网络请求，不执行本地 CLI，不保存 provider 原始输出。

## P5-H AI Capability Layer 状态

- P5-H 将 provider 口径从“翻译 provider”上移为 [AI Capability Provider Layer v0](AI-Capability-Provider-Layer-v0.md)。
- LLM provider 是全局能力，可支撑总结、改写、结构化提取、未来 LLM 转换类工具、LLM-backed 翻译和 multimodal OCR。
- Translation Engine 和 OCR Engine 是独立能力域：它们可以复用 LLM provider，也可以接专用翻译 / OCR 服务。
- 当前 Settings 只展示 LLM / Translation / OCR 三类 profile 和边界 badge；不读取真实 secret、不访问网络、不执行 CLI、不做真实 OCR。
- Secret handling 仍只对真实外部 provider 生效：API / cloud OCR / dedicated translation API 需要 Keychain；本地 CLI 继续使用自身登录态；Apple Vision OCR 不需要 provider secret。

## P5-I LLM Adapter Boundary 状态

- P5-I 新增 `LLMProviderAdapter` / `LLMProviderRequest` / `LLMProviderResponse` / `LLMProviderError` 边界和 `LLMProviderMockAdapter`。
- `OpenAICompatibleProfileBoundary` 只保存 base URL host 摘要、model、Keychain account alias、provider id/name 和 timeout；不保存 secret、不读取 Keychain、不读取环境变量。
- Settings 中的 LLM Adapter Boundary 可以生成 OpenAI-compatible `external_transfer` preview，也可以运行本地 mock adapter；两者都只写内存态脱敏 audit summary。
- P5-I 不调用 `URLSession`、不执行本地 CLI、不执行 OCR、不读取剪贴板、不保存完整 prompt / messages / provider 原始输出。
- 真实 BYOK 的本地 Keychain 保存门禁已在 P5-K 打通；低敏 test connection 已在 P5-L 打通；provider 路由、接口错误归一化和错误文案翻译已在 P5-M 打通。

## P5-J API Key Input / OpenAI Connection Gate 状态

- P5-J 新增 `ProviderSecretInputPreview` 和 `OpenAIConnectionPreviewDraft`，作为真实 BYOK 与 test connection 前的受控门禁。
- Settings 中的 API Key Input Gate 使用 `SecureField` 接收候选 key，但候选值只存在本地 view state，点击 preview 后清空。
- P5-J 审计仅保留结构化 action、outcome、confirmation level、低敏计数、错误码、warning count 和 audit id；provider、Keychain account alias、base URL、model、endpoint、prompt 等自由文本在进入内存审计前全部丢弃，也不记录 secret 原文、secret hash、认证 header 或完整请求体。
- OpenAI Connection Preview 只生成 `POST /v1/chat/completions` draft metadata，不调用 `URLSession`，不读取 Keychain，不访问网络。
- P5-K 在此基础上开放显式 Keychain 保存门禁；P5-L 继续开放低敏 test connection 的短生命周期读取路径。

## P5-K 用户 API Key Keychain 保存门禁状态

- P5-K 新增用户 secret 路径：account 使用 `openai-compatible:<alias>`，与 P5-G fixture 的 `mock-api:<alias>` 隔离。
- Settings 只有在 alias/key 非空且用户勾选确认后才写入 Keychain；保存后立即清空 `SecureField` 和确认状态。
- Verify Stored 默认只检查 item 存在，不读取 secret bytes；Delete / Verify Missing 可删除并确认缺失。
- 用户 secret 结果只返回 service、account、OSStatus、found、长度和 audit id；不返回原文、不返回 hash、不构造认证 header。
- OpenAI connection preview 仍是 dry-run 元数据，不访问网络、不读取 Keychain secret。

## P5-L OpenAI-compatible Test Connection Gate 状态

- P5-L 新增 `OpenAICompatibleConnectionService`，使用 `POST /v1/chat/completions` 做 OpenAI-compatible 低敏 ping test connection。
- `ProviderKeychainService` 新增 `ProviderUserSecretMaterial` 和 `readUserSecretForProviderCall(alias:)`，只在 provider test call 的短生命周期内读取 `openai-compatible:<alias>` secret。
- Settings 新增 Run Test Connection gate：必须满足 account alias、base URL、model、已保存用户 secret 和显式外发确认。
- 审计仅记录结构化 connection-test action、outcome、confirmation level、低敏计数、错误码和 audit id；provider、base URL、model、account alias、request id 等自由文本不进入内存审计，也不保存 secret 原文、secret hash、认证 header、完整 request body 或 provider 原始响应。
- 自动化验证通过 mock transport 覆盖 success、401、timeout、invalid response 和 invalid base URL；不调用真实外部 provider。
- P5-L 不代表真实翻译、OCR、总结、截图/剪贴板内容外发、streaming、模型列表或持久 provider audit 已开放；P5-O 单独开放用户开启 gate 后的 OpenAI-compatible 翻译正文 runtime。

## P5-M Provider Routing / Error Localization 状态

- P5-M 新增 `ProviderErrorCode`，作为 LLM / Translation / OCR 共用错误码；`rate_limited` 只作为接口错误分类，不做费用、额度或商业策略提示。
- P5-M 新增 `ProviderRouter`，用于本地解析 profile route、confirmation level、Keychain alias readiness 和 unsupported capability。
- Provider route check 不读取 Keychain secret、不访问网络、不执行 CLI、不处理真实截图、剪贴板或翻译正文。

## P5-O OpenAI-compatible Translation Runtime Gate 状态

- P5-O 新增 `OpenAITranslationRuntimeService`，复用 P5-L 的 `OpenAIConnectionTransport` 和 `ProviderKeychainService.readUserSecretForProviderCall(alias:)`。
- Settings 默认关闭 Translation Runtime Gate；只有用户开启 gate，且 base URL、model、Keychain alias 和用户 secret 齐备时，LLM-backed Translation 才会调用 OpenAI-compatible `/v1/chat/completions`。
- Runtime result 可在当前受控调用生命周期内携带必要的结构化运行结果；写入内存审计时仅保留 translation-runtime action、outcome、confirmation level、低敏计数、错误码和 audit id。provider、base URL、model、target language、request id 等自由文本不进入审计，也不保存 secret 原文、secret hash、Authorization、Bearer、完整 request body 或 provider raw response。
- 自动化验证使用 mock transport 覆盖 success、401、timeout、invalid response、missing secret 和 gate disabled；不调用真实外部 provider。
- P5-O 不代表 OCR、总结、截图/OCR 图片外发、剪贴板历史完整内容外发、本地 CLI provider、streaming、模型列表或持久 provider audit 已开放。

## 待决策

- 正式 App 是只支持 Keychain，还是允许环境变量作为高级开发者入口。
- provider 配置 UI 是否暴露模型名、timeout、组织/项目 ID 等高级字段。
- LLM provider adapter 是只支持 OpenAI-compatible，还是内置少量一方厂商 adapter；当前 P5-I 仅采用 OpenAI-compatible / gateway 边界和本地 mock adapter。
- P5-L/P5-O 已暂定 Keychain secret 读取只允许在 test connection / approved translation provider call 的短生命周期内发生；P5-M 已补 provider routing、接口错误映射和本地化错误文案。
- Translation Engine 和 OCR Engine 是否需要独立 credential profile，还是复用同一 Keychain account 命名规则。
- provider 审计日志保存多久，以及是否允许用户一键清空。
