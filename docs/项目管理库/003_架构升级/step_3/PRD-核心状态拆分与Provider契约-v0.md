# Step 3 核心状态拆分与 Provider 契约 PRD / 实施方案 v0

状态：ready-for-development
日期：2026-07-05
来源级别：product and architecture plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or project long-lived agent threads to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 将 `AppState` 从跨域业务容器继续降级为 app shell / coordinator，并优先消除 Provider route 与 Translation runtime 的 `.llmBacked` 契约矛盾。

**Architecture:** 本阶段采用低风险 facade 迁移：新增 `ProviderStore` 与 `TranslationStore`，把 Provider / Translation 的状态、路由、审计和 runtime gate 从 `AppState` 抽出；`AppState` 保留现有 View API 作为兼容 facade。Provider 路由层负责给出一致的能力可用性结论，Translation runtime 不再绕过 route 语义。

**Tech Stack:** SwiftUI, AppKit, Combine, BlocksCore, macOS Keychain, OpenAI-compatible runtime gate, Python verification scripts, xcodebuild.

---

## 1. 背景

Step 2 已完成 Clipboard 架构第一阶段：`ClipboardStore` 已承接剪贴板状态和主要 use case，`AppState` 保留 facade 以保护既有 UI 行为。Step 2 验收同时留下进入 Step 3 的风险：

- Provider route/runtime 的 `.llmBacked` 契约不一致。
- `AppState` 仍需继续按 feature store / use case / platform adapter 收敛。
- `repositoryUnavailable` 的生产降级策略需要产品化。
- 剪贴板列表 read model 未来应从默认 payload 预载转向 redacted list + lazy payload。
- `SettingsView` / settings pane 边界仍需拆分。

本阶段不试图一次性关闭整个架构升级项目，而是完成 Step 3 的核心状态拆分第一批：Provider / Translation 相关状态拆出、`.llmBacked` route/runtime 统一、AppState 职责显著减少，并建立后续 feature store 拆分协议。

## 2. 当前事实

截至本方案创建时的代码事实：

- `apps/Blocks/BlocksApp/Stores/AppState.swift` 仍有约 2342 行，保留 screenshot、translation、provider、permission、shortcut、clipboard panel 和 status 编排。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift` 已存在，Clipboard 已有 feature store 先例。
- `apps/Blocks/BlocksApp/Models/ProviderRouting.swift` 中 `ProviderRouter.resolve()` 当前把 `.llmBacked` 判为 `unsupportedCapability`。
- `apps/Blocks/BlocksApp/Stores/AppState.swift` 中 `runTranslation()` 又把 `.llmBacked` 作为 OpenAI-compatible translation runtime gate 的可执行入口。
- `apps/Blocks/BlocksApp/Models/TranslationRequestPreview.swift` 仍保留旧 `TranslationProviderProfile`；`apps/Blocks/BlocksApp/Models/AICapabilityProfiles.swift` 已引入新的 `TranslationEngineProfile`。
- `SettingsView`、`TranslationHomeView` 和 `TranslationFloatingPanelView` 当前仍通过 `AppState` 访问 provider / translation 状态和动作。

## 3. 产品目标

### 3.1 用户目标

- 用户选择翻译引擎、检查路由、运行本地 mock 翻译或 OpenAI-compatible 翻译时，看到的 ready / blocked / confirmation 状态必须一致。
- 用户开启外发翻译 gate 并准备好 base URL、model 和 Keychain alias 后，LLM-backed 翻译不应在 route check 中显示 unsupported。
- 用户未开启外发确认或缺少 Keychain alias 时，route check 和 runtime 都应给出同类阻断原因。
- 当前翻译、Provider 设置、Keychain gate、test connection 和本地 mock 行为不得出现用户可见回归。

### 3.2 团队目标

- 后续开发不再把新的 Provider / Translation 状态直接写进 `AppState`。
- Provider / Translation 的状态和动作可以被单独静态检查和单独测试。
- `AppState` 保留协调职责，但不继续作为 Provider / Translation 的事实源。
- Step 4 迁移 Screenshot、Settings / Permission 时可复用本阶段的流程协议。

## 4. 非目标

本阶段不做以下事项：

- 不重写全部 Settings UI，不拆完整 `SettingsView`。
- 不删除所有 `AppState` facade，不一次性修改全部 View 调用点。
- 不新增真实 DeepL / dedicated translation API。
- 不新增真实 OCR、截图图片外发、streaming、模型列表或 provider 持久审计。
- 不启用 helper 生产写库、App Group 或 CLI 读取完整剪贴板 payload。
- 不改变 API key 存储策略；仍只允许用户显式确认后写入 Keychain，且不得写入仓库、日志或验证输出。
- 不改变商业模式、发布渠道或完整 V1 范围承诺。

## 4.1 安全边界

本阶段会把 LLM-backed translation 从 route 层的 unsupported 改为可进入 ready / blocked 判断，因此必须补齐以下边界：

- Keychain 读取必须后置。base URL、model、alias 和外发 gate 均通过本地校验后，才允许调用 `readUserSecretForProviderCall`。invalid base URL、missing model、missing alias、gate disabled、unsupported capability 都不得读取 Keychain。
- HTTP base URL 策略：外部 provider 必须使用 HTTPS。HTTP 只允许作为 localhost / loopback 本地网关例外，例如 `http://localhost`、`http://127.0.0.1`、`http://[::1]`；任何非 loopback HTTP URL 必须被阻断并返回 invalid base URL / insecure transport 类错误。
- Route check 只能做本地可用性判断，不得读取 Keychain、不得访问网络、不得执行 CLI。`.llmBacked` route ready 不等于 runtime 已执行授权。
- 新增 `ProviderStore` / `TranslationStore` 以及 View 层不得直接出现 `URLSession`、`SecItem`、`Authorization`、`Bearer`、`Process(`、`getenv(`、`NSPasteboard.general`。网络、Keychain、剪贴板写入只能通过明确 service / adapter。
- `translationRuntimeResult.outputText` 是敏感运行态数据。它可以用于当前 UI 展示和用户触发复制，但不得进入 provider audit、开发记录、验证 JSON、日志或持久化存储；审计只记录状态、字符数、耗时、request id 和 audit id。
- 低敏 fixture secret 与真实用户 secret 必须区分。真实用户 secret 不得输出原文、hash、Authorization header、完整 request body 或 provider raw response；低敏 fixture 的短 hash 只能留在 fixture gate，不能泛化到用户 secret。

## 5. 范围

### 5.1 必做范围

1. 新增 `ProviderStore`
   - 路径：`apps/Blocks/BlocksApp/Features/Provider/ProviderStore.swift`。
   - 管理 LLM / OCR provider profile、selected provider ID、provider route resolution、provider audit events、Keychain gate result、OpenAI-compatible connection result。
   - 持有 `ProviderRouter`、`ProviderKeychainService`、`OpenAICompatibleConnectionService` 和 `LLMProviderMockAdapter`。
   - 提供现有 AppState provider 相关方法的等价入口。

2. 新增 `TranslationStore`
   - 路径：`apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift`。
   - 管理旧 `TranslationProviderProfile`、新 `TranslationEngineProfile`、selected IDs、translation preview、mock result、OpenAI translation runtime result。
   - 持有或接收 `ProviderStore`、`OpenAITranslationRuntimeService`、`ProviderKeychainService`。
   - 提供现有 AppState translation 相关方法的等价入口。

3. 保留 AppState facade
   - `AppState` 新增 `let providerStore: ProviderStore` 和 `let translationStore: TranslationStore`。
   - `AppState` 继续暴露现有 View 使用的属性和方法，但内部转发到对应 store。
   - `AppState` 继续管理全局 `selectedSection`、`status`、窗口/面板 presenter、全局快捷键、截图协调和跨 feature 状态。
   - `AppState` 不再直接 `@Published` Provider / Translation 业务状态。

4. 统一 `.llmBacked` route/runtime 契约
   - `.localMock`：route 为 ready，confirmation level 为 `none_mock`。
   - `.openAICompatible`：route 按 Keychain alias 与 external transfer confirmation 判断。
   - `.llmBacked`：route 语义等同“翻译引擎使用 OpenAI-compatible LLM provider”，按 runtime configuration、Keychain alias 与 external transfer confirmation 判断；不再返回 `unsupportedCapability`。
   - `.dedicatedAPI`：仍返回 `unsupportedCapability`。
   - `.localCLI`、`.liteLLMGateway`、`.multimodalLLM`、`.cloudOCR`：仍返回 `unsupportedCapability`，除非后续独立项目明确启用。
   - `.appleVision`：如果未来本地 OCR 阶段启用，需要单独决策；本阶段不改变其 unsupported 行为。

5. 更新验证门禁
   - 更新 `tools/verification/p5m_provider_routing_error_localization_checks.py`，让 runner 断言 `translation_llm_backed` 在 runtime configured + alias + external confirmed 下为 ready。
   - 更新 `tools/verification/p5n_translation_engine_router_checks.py`，让 runner 断言 LLM-backed translation route 为 ready，dedicated route 仍 unsupported。
   - 更新 `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`，删除或改写 Step 2 风险提示，不再把 `.llmBacked` 合同矛盾作为已知残留。
   - 新增 `tools/verification/p10a_provider_translation_contract_checks.py`，专门验证 Provider / Translation route 契约；runtime gate 继续由 P5O / P5P 覆盖。
   - 新增 `tools/verification/p10b_core_state_split_checks.py`，专门验证 `ProviderStore`、`TranslationStore`、`AppState` facade 和 forbidden direct state。

6. 更新项目记录
   - 本 PRD 通过复审后，状态改为 `ready-for-development`。
   - 开发完成后新增 `docs/项目管理库/003_架构升级/step_3/开发记录-v0.md`。
   - 测试完成后新增 `docs/项目管理库/003_架构升级/step_3/验收记录-v0.md`。
   - App 架构师复审输出进入 `docs/项目管理库/003_架构升级/step_3/2026-07-05-App架构师复审-v0.md`。

### 5.2 可选但推荐

- 如果改动范围可控，将 `SettingsView` 中 Provider / Translation route check 的局部 helper 提取成小的 private view 或局部 section，但不做全量 settings pane 拆分。
- 如果门禁覆盖不足，补充低敏 UI harness 或截图/录屏记录；不阻塞第一批核心状态拆分，但必须记录未覆盖项。

## 6. 目标架构

```text
AppState
  - App shell / coordinator
  - selected section
  - global status projection
  - window / panel presenter orchestration
  - shortcut / screenshot top-level coordination
  - facade to ClipboardStore / ProviderStore / TranslationStore

Features
  Clipboard
    - ClipboardStore
  Provider
    - ProviderStore
  Translation
    - TranslationStore

Models
  - ProviderRouting
  - AICapabilityProfiles
  - TranslationRequestPreview
  - Provider / translation audit value types

Services
  - ProviderKeychainService
  - OpenAICompatibleConnectionService
  - OpenAITranslationRuntimeService
  - LLMProviderAdapter
```

依赖方向：

```text
Views -> AppState facade -> Feature Stores -> Router / Services / Adapters
AppState -> Feature Stores
Feature Stores -> Models + Services
Services -> platform APIs / network / Keychain
Models -> Foundation only
BlocksCore -> no SwiftUI / AppKit / Security imports
```

本阶段允许 View 继续调用 `AppState`，但新业务状态不得继续直接加入 `AppState`。

## 7. 功能需求

### FR-1 ProviderStore

`ProviderStore` 必须满足：

- 是 `@MainActor final class ProviderStore: ObservableObject`。
- 初始 catalog 使用 `AICapabilityCatalog.defaults()`。
- 持有：
  - `llmProviderProfiles`
  - `ocrEngineProfiles`
  - `selectedLLMProviderID`
  - `selectedOCREngineID`
  - `providerAuditEvents`
  - `providerKeychainLastResult`
  - `providerUserSecretLastResult`
  - `openAIConnectionLastResult`
  - `providerRouteResolution`
- 暴露：
  - `selectedLLMProvider`
  - `selectedOCREngine`
  - `resolveProviderSettingsRoute(apiKeychainAccountAlias:externalTransferConfirmed:)`
  - `routeSummaryForScreenshotAIAction(_:translationEngine:)`
  - `validateProviderConnectionGate(summary:ready:)`
  - `previewProviderConnectionTest(summary:ready:)`
  - `previewLLMAdapterBoundary(baseURL:modelName:keychainAccountAlias:)`
  - `runLLMMockAdapter()`
  - `previewProviderSecretInput(secretCharacterCount:keychainAccountAlias:)`
  - `previewOpenAIConnection(baseURL:modelName:keychainAccountAlias:)`
  - `runOpenAIConnectionTest(baseURL:modelName:keychainAccountAlias:externalTransferConfirmed:) async`
  - `clearProviderAuditEvents()`
- 所有 audit event 裁剪仍保留 20 条容量。
- 所有 secret 相关输出仍只包含 alias、长度、OSStatus、audit id 或脱敏摘要，不包含 secret 原文、hash、Authorization header 或完整 request body。

### FR-2 TranslationStore

`TranslationStore` 必须满足：

- 是 `@MainActor final class TranslationStore: ObservableObject`。
- 持有：
  - `translationProviderProfiles`
  - `selectedTranslationProviderID`
  - `translationEngineProfiles`
  - `selectedTranslationEngineID`
  - `translationPreview`
  - `translationResult`
  - `translationRuntimeResult`
- 暴露：
  - `selectedTranslationProvider`
  - `selectedTranslationEngine`
  - `selectTranslationProvider(id:)`
  - `selectTranslationEngine(id:)`
  - `prepareManualTranslation(characterCount:targetLanguage:)`
  - `prepareScreenshotTranslation(_:)`
  - `prepareClipboardTranslation(_:)`
  - `generateMockTranslationResult()`
  - `resolveTranslationProviderRoute(apiKeychainAccountAlias:externalTransferConfirmed:)`
  - `resolveTranslationEngineRoute(baseURL:modelName:keychainAccountAlias:externalTransferConfirmed:)`
  - `runTranslation(text:sourceLanguageMode:targetLanguage:baseURL:modelName:keychainAccountAlias:externalTransferEnabled:) async`
  - `copyTranslationRuntimeOutputToClipboard()` 可以暂留在 `AppState`，因为它使用 pasteboard；如果迁移，必须通过明确 adapter 注入，不直接让 store 访问 `NSPasteboard`。
- `TranslationStore` 不直接拥有全局 `AppStatus`，而是返回或暴露操作结果，由 `AppState` facade 投射成 status。
- `TranslationStore` 不强持有 `ProviderStore`。它可以接收 `ProviderRouter` 和 `auditRecorder: (ProviderAuditEvent) -> Void` 闭包，也可以接收一个窄协议；不得形成 ProviderStore <-> TranslationStore 双向引用。
- Provider audit 只有一个事实源：`ProviderStore.providerAuditEvents`。Translation runtime、mock result 和 route check 只能通过 `auditRecorder` 写入，不得复制第二套 audit list。
- `TranslationStore` 不保存 secret material，不把 `ProviderUserSecretMaterial` 放入 `@Published`、stored property 或 audit event；secret material 只允许在单次 runtime call 的局部作用域内存在。

### FR-3 AppState facade

`AppState` 必须满足：

- 初始化 `ProviderStore`、`TranslationStore`、`ClipboardStore`，并绑定它们的 `objectWillChange`。
- 保留现有 View 调用入口，减少 UI 改动面。
- 不再声明以下 Provider / Translation `@Published` 事实源：
  - `translationProviderProfiles`
  - `selectedTranslationProviderID`
  - `llmProviderProfiles`
  - `translationEngineProfiles`
  - `ocrEngineProfiles`
  - `selectedLLMProviderID`
  - `selectedTranslationEngineID`
  - `selectedOCREngineID`
  - `translationPreview`
  - `translationResult`
  - `translationRuntimeResult`
  - `providerAuditEvents`
  - `providerKeychainLastResult`
  - `providerUserSecretLastResult`
  - `openAIConnectionLastResult`
  - `providerRouteResolution`
- 可以继续以 computed property 或 facade method 形式暴露这些名称，内部必须转发到 store。
- `AppState.status` 仍可保留在 AppState，由 facade 方法统一更新。
- `TranslationHomeView`、`TranslationFloatingPanelView`、`SettingsView` 中现有 `@AppStorage("provider.api.baseURL")`、`@AppStorage("provider.api.modelName")`、`@AppStorage("provider.api.keychainAccountAlias")` 和 translation runtime external gate 仍可暂留在 View 层；调用 route / runtime 时必须通过 AppState facade 传入 `TranslationStore`。不得只修改 `ProviderRouter` 而让调用点继续使用无 runtime context 的 `translationEngineRouteRequest()`。

### FR-4 `.llmBacked` route/runtime contract

Provider route 必须覆盖以下矩阵：

| 场景 | 输入 | 期望 |
| --- | --- | --- |
| Local mock LLM | `.localMock` | `ok=true`, `confirmationLevel=none_mock` |
| OpenAI-compatible missing secret | `.openAICompatible`, empty alias, confirmed | `ok=false`, `errorCode=missingSecret` |
| OpenAI-compatible missing config | `.openAICompatible`, missing base URL or model at caller gate | `ok=false`, `errorCode=missingConfiguration` |
| OpenAI-compatible confirmation missing | `.openAICompatible`, alias, not confirmed | `ok=false`, `errorCode=confirmationRequired` |
| OpenAI-compatible ready | `.openAICompatible`, alias, confirmed | `ok=true`, `confirmationLevel=external_transfer` |
| LLM-backed translation missing secret | `.llmBacked`, empty alias, confirmed | `ok=false`, `errorCode=missingSecret` |
| LLM-backed translation missing config | `.llmBacked`, missing base URL or model at caller gate | `ok=false`, `errorCode=missingConfiguration` |
| LLM-backed translation confirmation missing | `.llmBacked`, alias, not confirmed | `ok=false`, `errorCode=confirmationRequired` |
| LLM-backed translation ready | `.llmBacked`, alias, confirmed | `ok=true`, `confirmationLevel=external_transfer` |
| Dedicated translation API | `.dedicatedAPI` | `ok=false`, `errorCode=unsupportedCapability` |
| Local CLI | `.localCLI` | `ok=false`, `errorCode=unsupportedCapability` |

Runtime 必须遵守：

- `.llmBacked` 的 runtime readiness 不以 `TranslationEngineProfile.base.configured` / `implemented` 的静态 catalog 值作为唯一事实源。开发必须选择一种明确实现：要么在创建 `ProviderRouteRequest` 时传入 runtime-derived `configured` / `implemented`，要么扩展 request 加入 runtime readiness 字段。验收以 P10A route matrix 为准。
- base URL 与 model 的非空校验仍属于 runtime / settings caller gate；route runner 可用显式 `configured: true` 构造 ready case，用 `configured: false` 构造 missing configuration case。
- `runTranslation()` 在本地 mock 时仍返回 mock result，不触发 Keychain 或网络。
- `runTranslation()` 在 `.llmBacked` 且 external gate 未启用时返回与 route `confirmationRequired` 语义一致的结果，不读取 Keychain。
- `runTranslation()` 在 `.llmBacked` 且 base URL 或 model 缺失时返回 missing configuration / unsupported input 结果，不读取 Keychain、不访问网络。
- `runTranslation()` 在 `.llmBacked` 且 base URL 为非 loopback HTTP 时返回 invalid base URL / insecure transport 结果，不读取 Keychain、不访问网络。
- `runTranslation()` 在 `.llmBacked` 且 alias/baseURL/model/gate 齐备时，短生命周期读取 Keychain 并调用 `OpenAITranslationRuntimeService`。
- `runTranslation()` 在 `.dedicatedAPI` 或其他 unsupported mode 时不执行 provider call，并返回 unsupported result。

### FR-5 验证与项目记录

- 新增 P10 门禁，避免 Step 3 完成后仍依赖 P9B 的风险提示。
- P5M/P5N 更新后仍覆盖旧场景，并新增 `.llmBacked` ready / blocked 场景。
- P10A 必须断言 route check 不触发 Keychain、网络或 CLI；P5O / P5P 必须继续使用 mock transport 或低敏 fixture，不得要求真实 API key 或真实外部网络。
- P10B 必须静态检查新 store / View 层禁止出现 `Authorization`、`Bearer`、`URLSession`、`SecItem`、`Process(`、`getenv(`、`NSPasteboard.general`。
- Runtime gate 验证必须覆盖：gate false、missing alias、missing base URL、missing model、invalid URL、非 loopback HTTP URL 均不读取 Keychain、不访问网络。
- `p7l_clipboard_experience_gate_checks.py` 的过时 `appstate_owns_live_payloads` 不得作为 Step 3 阻断项；需要在开发记录说明其退役或替代门禁。
- 开发记录必须列出 AppState 行数变化和 Provider / Translation `@Published` 迁移结果。

## 8. 文件结构

### 新增文件

- `apps/Blocks/BlocksApp/Features/Provider/ProviderStore.swift`
  - Provider route、Keychain gate、connection test、LLM mock adapter、audit events。
- `apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift`
  - Translation provider / engine selection、preview、mock result、runtime result、translation route。
- `tools/verification/p10a_provider_translation_contract_checks.py`
  - 编译 Swift runner，验证 Provider / Translation route contract。
- `tools/verification/p10b_core_state_split_checks.py`
  - 静态检查 feature stores、AppState facade、forbidden direct `@Published` 状态。
- `docs/项目管理库/003_架构升级/step_3/开发记录-v0.md`
  - 开发完成后创建。
- `docs/项目管理库/003_架构升级/step_3/验收记录-v0.md`
  - 测试完成后创建。

### 修改文件

- `apps/Blocks/BlocksApp/Stores/AppState.swift`
  - 迁移 Provider / Translation 状态到 store，保留 facade。
- `apps/Blocks/BlocksApp/Models/ProviderRouting.swift`
  - 统一 `.llmBacked` route 语义。
- `apps/Blocks/BlocksApp/Models/AICapabilityProfiles.swift`
  - 处理 LLM-backed translation 的 profile metadata 与 ready route 的关系。可选实现是将 `translation-llm-backed-placeholder` 标记为 route-capable；如果保留静态 `implemented: false`，必须通过动态 readiness 文案或 route UI 避免“route ready 但 UI 仍显示 not implemented”的冲突。
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
  - 添加 `ProviderStore.swift`、`TranslationStore.swift` 到 Blocks app target。
- `tools/verification/p5m_provider_routing_error_localization_checks.py`
  - 更新 expected route matrix。
- `tools/verification/p5n_translation_engine_router_checks.py`
  - 更新 translation engine route expected result。
- `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
  - 删除已解决风险提示，或改为失败条件。
- `docs/项目管理库/003_架构升级/index.md`
  - 反映 Step 3 进展。
- `docs/项目管理库/003_架构升级/step.md`
  - 反映 Step 3 状态和出口。

## 9. 实施任务

### Task 1: Provider route contract

**Files:**

- Modify: `apps/Blocks/BlocksApp/Models/ProviderRouting.swift`
- Modify: `apps/Blocks/BlocksApp/Models/AICapabilityProfiles.swift`
- Modify: `tools/verification/p5m_provider_routing_error_localization_checks.py`
- Modify: `tools/verification/p5n_translation_engine_router_checks.py`
- Create: `tools/verification/p10a_provider_translation_contract_checks.py`

**Steps:**

- [ ] 修改 `ProviderRouter.resolve()`，让 `.llmBacked` 走与 `.openAICompatible` 相同的 missing secret / confirmation / ready 语义。
- [ ] 明确 `.llmBacked` 的 runtime readiness 来源：`ProviderRouteRequest.configured` 必须由 caller 根据 base URL / model / alias/gate 构造，或新增等价 runtime readiness 字段；不得让静态 catalog 的 `configured: false` 永久压制 ready route。
- [ ] 保持 `.dedicatedAPI`、`.localCLI`、`.liteLLMGateway`、`.multimodalLLM`、`.cloudOCR` unsupported。
- [ ] 更新 P5M runner expected values：`translation_llm_backed` 在 runtime configured + alias + confirmed 下必须 `ok=true`。
- [ ] 更新 P5N runner expected values：`llm_route.ok == true`，`dedicated_route.errorCode == .unsupportedCapability`。
- [ ] 新增 P10A runner，覆盖 FR-4 route matrix。P10A 不读取真实 Keychain、不访问网络、不运行真实 provider；runtime gate 继续由 P5O / P5P 使用 mock transport 覆盖。
- [ ] 如 `.llmBacked` route ready，同步处理 `AICapabilityProfiles.swift` metadata 或动态 readiness 文案，避免 UI 显示 not implemented 与 route ready 冲突。
- [ ] 增加 HTTP transport policy 验证：非 loopback `http://` base URL 必须阻断，loopback HTTP 如保留必须单独 case 覆盖。
- [ ] 运行：

```bash
python3 tools/verification/p5m_provider_routing_error_localization_checks.py
python3 tools/verification/p5n_translation_engine_router_checks.py
python3 tools/verification/p10a_provider_translation_contract_checks.py
```

Expected：全部通过，且 P10A 输出 `.llmBacked` ready / missing secret / confirmation required 三类结果。

### Task 2: ProviderStore boundary

**Files:**

- Create: `apps/Blocks/BlocksApp/Features/Provider/ProviderStore.swift`
- Modify: `apps/Blocks/BlocksApp/Stores/AppState.swift`
- Modify: `apps/Blocks/Blocks.xcodeproj/project.pbxproj`

**Steps:**

- [ ] 创建 `ProviderStore`，把 FR-1 列出的 provider 状态迁入 store。
- [ ] 将 provider route、LLM mock adapter、secret preview、Keychain gate、OpenAI connection test、provider audit 相关方法迁入 store。
- [ ] `AppState` 初始化并绑定 `ProviderStore.objectWillChange`。
- [ ] `AppState` 以 computed properties 和 facade methods 转发现有 View 调用。
- [ ] 确认 `SettingsView`、`TranslationHomeView`、`TranslationFloatingPanelView` 不需要大规模改动。
- [ ] 运行 App build 和 P5M：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
python3 tools/verification/p5m_provider_routing_error_localization_checks.py
```

Expected：build 通过，P5M 通过。

### Task 3: TranslationStore boundary

**Files:**

- Create: `apps/Blocks/BlocksApp/Features/Translation/TranslationStore.swift`
- Modify: `apps/Blocks/BlocksApp/Stores/AppState.swift`
- Modify: `apps/Blocks/Blocks.xcodeproj/project.pbxproj`

**Steps:**

- [ ] 创建 `TranslationStore`，把 FR-2 列出的 translation 状态迁入 store。
- [ ] 将 engine / provider selection、translation preview、mock result、engine route、provider route、runtime result 迁入 store。
- [ ] `TranslationStore` 通过 `auditRecorder` 闭包或窄协议写入 provider audit event，不复制第二套 audit list，不强持有 `ProviderStore`。
- [ ] `TranslationStore` 的 route request 必须接收 base URL、model、Keychain alias 和 external transfer gate，用这些 runtime 输入生成 route readiness。
- [ ] `TranslationStore.runTranslation` 或其调用链必须先完成 base URL / model / alias / external gate 本地校验，再读取 Keychain；invalid base URL、missing model、missing alias、gate disabled、unsupported capability 均不得读取 Keychain。
- [ ] `AppState.resolveTranslationEngineRoute()` 需要保留现有无参 facade 以兼容旧调用，但新增或内部使用带 runtime context 的 facade；所有已有 View 调用点必须传入当前 `@AppStorage` baseURL、model、alias 和 gate，或由 AppState 明确读取同一组 UserDefaults key 生成等价 context。
- [ ] `AppState` 初始化并绑定 `TranslationStore.objectWillChange`。
- [ ] `AppState` 保留现有 translation facade。
- [ ] 保持 local mock、manual/screenshot/clipboard preview、floating panel translation path 和 OpenAI-compatible runtime gate 行为一致。
- [ ] 运行：

```bash
python3 tools/verification/p5n_translation_engine_router_checks.py
python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180
python3 tools/verification/p5p_translation_panel_polish_checks.py --timeout 180
```

Expected：全部通过。

### Task 4: AppState split gate

**Files:**

- Create: `tools/verification/p10b_core_state_split_checks.py`
- Modify: `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`

**Steps:**

- [ ] 新增 P10B，检查 `ProviderStore.swift`、`TranslationStore.swift` 存在并进入 Xcode target。
- [ ] P10B 检查 `AppState` 持有 `let providerStore: ProviderStore`、`let translationStore: TranslationStore`。
- [ ] P10B 检查 `TranslationStore` 不声明 `let providerStore: ProviderStore` 或 `var providerStore`，只允许 audit recorder closure / narrow protocol。
- [ ] P10B 检查 `ProviderStore`、`TranslationStore` 和 View 层不直接出现 `Authorization`、`Bearer`、`URLSession`、`SecItem`、`Process(`、`getenv(`、`NSPasteboard.general`。
- [ ] P10B 检查 `AppState` 不再直接声明 FR-3 中列出的 Provider / Translation `@Published` 事实源。
- [ ] P10B 检查 `AppState` 仍有 facade methods：`selectTranslationEngine`、`resolveTranslationEngineRoute`、`runTranslation`、`runOpenAIConnectionTest`、`clearProviderAuditEvents`。
- [ ] 更新 P9B：如果 `.llmBacked` 仍 unsupported 且 AppState 仍有 runtime，则 fail；不要再只输出 risk。
- [ ] 运行：

```bash
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
```

Expected：全部通过，P9B 不再输出 Step 3 risk。

### Task 5: Regression suite and docs

**Files:**

- Create: `docs/项目管理库/003_架构升级/step_3/开发记录-v0.md`
- Modify: `docs/项目管理库/003_架构升级/index.md`
- Modify: `docs/项目管理库/003_架构升级/step.md`

**Steps:**

- [ ] 运行回归：

```bash
python3 tools/verification/p10a_provider_translation_contract_checks.py
python3 tools/verification/p10b_core_state_split_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
python3 tools/verification/p5m_provider_routing_error_localization_checks.py
python3 tools/verification/p5n_translation_engine_router_checks.py
python3 tools/verification/p5o_openai_translation_runtime_gate_checks.py --timeout 180
python3 tools/verification/p5p_translation_panel_polish_checks.py --timeout 180
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

- [ ] 创建开发记录，包含改动范围、未做事项、验证结果、残余风险。
- [ ] 更新 index / step 状态为 `step-3-developed` 或等待测试后更新为 `step-3-accepted`。

## 10. 验收标准

Step 3 可接受必须满足：

- `.llmBacked` route/runtime contract 不再矛盾。
- `ProviderStore` 和 `TranslationStore` 存在并进入 Blocks app target。
- `AppState` 不再直接 `@Published` Provider / Translation 事实源。
- 现有 View 通过 AppState facade 继续工作。
- P10A / P10B 通过。
- P5M / P5N / P5O / P5P 通过。
- P10A 不读取真实 Keychain、不访问网络、不要求真实 API key；P5O / P5P 只能使用既有 mock transport 或低敏 fixture，不得调用真实外部 provider。
- invalid base URL、missing model、missing alias、gate disabled、unsupported capability 和非 loopback HTTP URL 均不读取 Keychain、不发网络。
- provider audit、开发记录、测试输出和验证 JSON 不包含 secret 原文、secret hash、Authorization header、完整 request body、provider raw response 或真实翻译正文。
- P9A / P9B / P9C 通过，P9B 不再输出 Step 3 风险提示。
- App / CLI build 通过。
- `blocks --help` 通过。
- `git diff --check` 通过。
- 开发记录、架构师复审、测试记录齐全。

## 11. 残余风险

以下风险允许留到后续阶段，但必须记录：

- `SettingsView` 仍是大型设置聚合；Step 4 迁移 Settings / Permission 时继续拆。
- Screenshot 仍未迁移到 feature store。
- Clipboard `repositoryUnavailable` 生产降级策略仍未产品化。
- Clipboard list read model 仍未完成 redacted list + lazy payload。
- helper / App Group / CLI 读取完整 payload 仍是未来能力。

## 12. 后续角色流程协议

1. 主 agent 负责 PRD、范围、验收标准、冲突处理和最终接受。
2. 方案阶段可以并行邀请 App 架构师、安全合规顾问、测试/质量或 UI/交互设计师审阅；每个角色必须输出独立文档，写明结论、阻断项、必改项和建议项。
3. 主 agent 汇总多角色意见，只把与本阶段目标、风险边界和验收标准相关的内容回写 PRD；不同角色意见冲突时，由主 agent 明确取舍理由。
4. 开发只在 PRD 状态为 `ready-for-development` 后实施；不得静默扩大范围，不得处理非本阶段目标。
5. 开发实施可以异步推进，主 agent 不需要同步等待；开发完成后必须回调主 agent，并同时提供 `开发记录-v0.md`、验证命令、验证结果、未完成项和阻塞项。
6. 测试/质量在开发回调后独立读取 PRD、开发记录和代码结果，运行或复核门禁，输出 `验收记录-v0.md`。
7. App 架构师对最终实现做架构复审，重点看 AppState 是否继续瘦身、route/runtime 是否一致、store 边界是否清楚。
8. 主 agent 根据开发记录、测试记录和架构复审决定接受、返工、降级接受或暂停。
9. 任何角色发现涉及真实凭据、外发数据、权限、分发或政策限制时，必须显式标注风险；不得把待验证结论写成事实。
