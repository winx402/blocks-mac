---
id: P5-I
title: LLM Adapter Boundary
status: implemented
date: 2026-07-02
sourcePlan: 用户指令 - LLM provider 接入层预留与 OpenAI-compatible 边界
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
  - ../../../../技术知识库/AI-Capability-Provider-Layer-v0.md
  - ../../../../技术知识库/Provider-Secret-Handling-v0.md
---

# P5-I LLM Adapter Boundary

## Scope

本轮在 P5-H 的 AI Capability Provider Layer 之上补最小 LLM adapter 边界。目标是为未来总结、改写、结构化提取、LLM-backed 翻译、multimodal OCR 和后续 LLM 转换类工具预留统一入口，同时继续避免 App 自己维护过重的厂商矩阵。

已实现：

- 新增 `LLMProviderAdapter.swift`，定义 `LLMProviderTask`、`LLMProviderOutputFormat`、`LLMProviderError`、`LLMProviderRequest`、`LLMProviderResponse`、`OpenAICompatibleProfileBoundary`、`LLMProviderAdapter` 和 `LLMProviderMockAdapter`。
- `OpenAICompatibleProfileBoundary` 只保存 provider id/name、base URL host 摘要、model 名称、Keychain account alias 和 timeout，不保存 API key 或完整请求内容。
- Settings Provider / AI section 新增 LLM Adapter Boundary 区块，可生成 OpenAI-compatible 外发预览，也可运行本地 mock adapter。
- Provider audit 新增 `llmAdapterPreview` 和 `llmMockRun` 两类内存态脱敏事件，继续只记录 provider、model、来源摘要、字符数、确认级别和 audit id。
- 新增三语 String Catalog 文案和 `tools/verification/p5i_llm_adapter_boundary_checks.py`。

## Acceptance Notes

- Given 用户进入 Settings Provider / AI，Then 能看到 LLM Adapter Boundary 区块，并能明确当前不会调用 API、CLI、OCR 或网络。
- Given 用户点击 OpenAI-compatible preview，Then App 只生成 `external_transfer` 边界预览和脱敏 audit summary，不读取 Keychain secret。
- Given 用户点击 Local Mock，Then App 只生成本地 mock response 和 `llmMockRun` audit event，不访问外部 provider。
- Given 用户配置 base URL、model 或 Keychain account alias，Then audit 只保存 base URL host 摘要和 alias，不保存 secret 或完整 prompt。
- Given 后续工具需要 LLM 能力，Then 可以复用 `LLMProviderAdapter` request / response / error 边界，而不是把翻译 provider 当作唯一入口。

## Privacy And Safety

- P5-I 不读取真实 API key，不读取环境变量，不访问网络，不执行 CLI，不做 OCR，不读取剪贴板，也不保存完整 prompt / messages / provider 原始输出。
- 非本地 mock 的 LLM provider 仍必须经过 `external_transfer` 确认；真实调用前还需要真实 key 输入确认、连接测试、错误归一化和持久审计策略。
- 本地 CLI / agent provider 仍使用 CLI 自身登录态；App 不复制、不读取、不迁移 CLI token。
- OCR provider 和 Translation Engine 继续作为独立能力域；它们可以复用 LLM provider，但不能被简化成同一个翻译 provider。

## Not Covered Yet

- 真实 API key 输入框、Keychain secret 读取和 BYOK provider 调用。
- OpenAI-compatible request body、streaming、工具调用、模型列表、费用提示、速率限制和真实 test connection。
- LiteLLM / gateway 实调和 provider 兼容矩阵。
- 本地 CLI provider execution。
- Apple Vision OCR、多模态 LLM OCR 或云 OCR runtime adapter。
- Translation Engine / OCR Engine 与真实工具流程的 adapter 接线。
- 持久 provider audit、重试策略和 provider 健康状态。

## Verification

本轮目标验证：

- `python3 tools/verification/p5i_llm_adapter_boundary_checks.py --timeout 180`
- `python3 tools/verification/p5h_ai_capability_layer_checks.py --timeout 180`
- `python3 tools/verification/p5g_keychain_ui_gate_checks.py --timeout 180`
- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run`
