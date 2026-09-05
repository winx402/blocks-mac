---
id: P5-H
title: AI Capability Provider Layer
status: implemented
date: 2026-07-02
sourcePlan: 用户指令 - LLM / 翻译 / OCR provider 分层扩展
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
  - ../../../../技术知识库/AI-Capability-Provider-Layer-v0.md
  - ../../../../技术知识库/Provider-Secret-Handling-v0.md
---

# P5-H AI Capability Provider Layer

## Scope

本轮把 P5-B 到 P5-G 的“翻译 provider / Provider AI 设置”上移为可扩展的 AI Capability Provider Layer。目标是为未来 LLM 转换、总结、改写、OCR、翻译等能力保留统一 provider catalog，同时避免 App 自己维护过重的多厂商适配矩阵。

已实现：

- 新增 `AICapabilityProfiles.swift`，定义 `AICapabilityDomain`、`AICapabilityProfile`、`LLMProviderProfile`、`TranslationEngineProfile`、`OCREngineProfile` 和 `AICapabilityCatalog`。
- `AppState` 暴露 `llmProviderProfiles`、`translationEngineProfiles`、`ocrEngineProfiles` 和 selected id，为后续设置页、action core 和 adapter 预留入口。
- Settings Provider / AI section 新增 AI Capability Gate，将 LLM Provider、Translation Engine、OCR Engine 分层展示。
- 当前 catalog 预留 OpenAI-compatible API、LiteLLM / Gateway、本地 CLI / Agent、LLM-backed 翻译、专用翻译 API、Apple Vision OCR、多模态 LLM OCR 和云 OCR profile。
- 新增三语 String Catalog 文案和 `tools/verification/p5h_ai_capability_layer_checks.py`。
- 新增 [AI Capability Provider Layer v0](../../../../技术知识库/AI-Capability-Provider-Layer-v0.md)，同步 Provider Secret Handling、AI/Agent/CLI/Hook 边界和项目看板。

## Acceptance Notes

- Given 用户进入 Settings Provider / AI，Then 能看到 LLM、Translation、OCR 三组能力 profile，而不是只看到翻译 provider。
- Given 用户查看 LLM Provider，Then 能看到 OpenAI-compatible、LiteLLM / Gateway 和本地 CLI / Agent 作为未来接入方式，但当前均标记为 placeholder / not implemented。
- Given 用户查看 Translation Engine，Then 能区分 LLM-backed 翻译和专用翻译 API；两者都不是当前 Local Mock 结果面板的真实 provider。
- Given 用户查看 OCR Engine，Then 能区分本地 Apple Vision、multimodal LLM OCR 和云 OCR；当前不会读取图片或执行 OCR。
- Given 任何非本地 mock profile，Then UI 和文档都保留 external transfer / Keychain / audit 边界，不允许静默外发。

## Privacy And Safety

- P5-H 不读取真实 API key，不读取环境变量，不访问网络，不执行 CLI，不做真实 OCR。
- Settings 只展示 profile catalog 和边界 badge；不保存 provider 原始输出、CLI token、完整截图、完整剪贴板内容或 OCR 图片。
- 本地 CLI 仍使用自身登录态；App 不读取或复制 CLI token。
- 外部 provider、专用翻译 API、云 OCR 和 multimodal LLM OCR 必须在后续 story 中接入 `external_transfer` 确认和审计。

## Not Covered Yet

- 真实 API key 输入、保存、更新和删除 UI。
- OpenAI-compatible runtime adapter、streaming、错误归一化、模型列表和 test connection。
- LiteLLM / gateway 实调。
- 本地 CLI provider execution。
- Apple Vision OCR 或任何 OCR 结果 UI。
- Translation Engine 和 OCR Engine 连接到真实工具流程。
- 持久 provider audit、费用提示、重试、速率限制和模型健康状态。

## Verification

本轮目标验证：

- `python3 tools/verification/p5h_ai_capability_layer_checks.py --timeout 180`
- `python3 tools/verification/p5g_keychain_ui_gate_checks.py --timeout 180`
- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run`
