---
id: P5-J
title: API Key Input / OpenAI Connection Gate
status: implemented
date: 2026-07-02
sourcePlan: 继续推进真实 API key 输入确认路径与 OpenAI-compatible test connection 前置设计
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
  - ../../../../技术知识库/Provider-Secret-Handling-v0.md
  - ../../../../技术知识库/AI-Capability-Provider-Layer-v0.md
---

# P5-J API Key Input / OpenAI Connection Gate

## Scope

本轮在 P5-I LLM adapter boundary 之后，补真实 API key 输入确认路径和 OpenAI-compatible test connection 的前置门禁。实现目标是让 Settings 可以表达“用户将来如何输入、确认、审计和测试 provider”，但仍不保存真实 key、不读取 Keychain secret、不访问网络。

已实现：

- `ProviderSecretInputPreview`：只记录 provider、Keychain account alias、候选字符数、确认级别和 audit id。
- `OpenAIConnectionPreviewDraft`：只记录 base URL host 摘要、model、Keychain account alias、endpoint 摘要、timeout、确认级别和 audit id。
- Settings Provider / AI section 新增 API Key Input Gate：`SecureField` 候选值只存在本地 view state，点击 preview 后清空。
- Settings 新增 OpenAI Connection Preview：生成 `POST /v1/chat/completions` request draft 元数据，不发送网络请求。
- Provider audit 新增 `secretInputPreview` 和 `openAIConnectionPreview` 两类脱敏事件。
- 新增三语文案和 `tools/verification/p5j_api_key_connection_gate_checks.py`。

## Acceptance Notes

- Given 用户输入候选 key，When 点击 Preview Save，Then App 只记录 account alias 和字符数，并清空候选输入。
- Given 用户查看审计摘要，Then 不会看到 secret 原文、secret hash、Authorization header、Bearer token 或完整请求体。
- Given 用户点击 OpenAI Connection Preview，Then App 只生成 endpoint、base URL host、model、account alias、timeout 和 `external_transfer` 元数据。
- Given 当前 P5-J 状态，Then App 不写真实 Keychain、不发网络请求、不执行 CLI、不调用 OCR、不读取剪贴板。
- Given 后续要做真实 test connection，Then 必须基于本轮门禁继续补 Keychain 读取确认、外发确认、错误归一化和持久审计。

## Privacy And Safety

- P5-J 不保存真实 API key，不读取环境变量，不读取 Keychain secret，不访问网络，不执行 CLI，不输出或提交 secret。
- 候选 key 只在 Settings 的本地 `@State` 中短暂停留；preview 后主动清空。
- 审计只记录 account alias、字符数、provider、model、base URL host 摘要、endpoint 摘要和 audit id。
- 本轮调整了旧验证脚本：`SecureField` 不再被历史 provider skeleton 检查绝对禁止；P5-J 专项检查负责约束其受控使用。

## Not Covered Yet

- 真实 API key 写入 Keychain。
- 从 Keychain 读取真实 secret。
- OpenAI-compatible 真实 test connection、streaming、重试、错误归一化和模型列表。
- LiteLLM / gateway 实调。
- 本地 CLI provider execution。
- 持久 provider audit、费用提示和速率限制。

## Verification

本轮目标验证：

- `python3 tools/verification/p5j_api_key_connection_gate_checks.py --timeout 180`
- `python3 tools/verification/p5i_llm_adapter_boundary_checks.py --timeout 180`
- `python3 tools/verification/p5h_ai_capability_layer_checks.py --timeout 180`
- `python3 tools/verification/p5g_keychain_ui_gate_checks.py --timeout 180`
- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run`
