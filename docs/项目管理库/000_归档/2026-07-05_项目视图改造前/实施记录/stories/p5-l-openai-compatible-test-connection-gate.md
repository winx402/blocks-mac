---
id: P5-L
title: OpenAI-compatible Test Connection Gate
status: completed
sourcePlan: P5-L OpenAI-compatible Test Connection Gate 计划
---

# P5-L OpenAI-compatible Test Connection Gate

## Summary

本轮在 P5-K 用户 API key Keychain 保存门禁之后，补正式 App 内的 OpenAI-compatible 低敏测试连接路径。App 可以在用户显式确认外发后，短生命周期读取 `openai-compatible:<alias>` Keychain secret，并发送一次固定 ping test request；自动化验证仍使用 mock transport，不调用真实外部 provider。

## Implementation

- 新增 `OpenAICompatibleConnectionService`，封装 base URL 规范化、`POST /v1/chat/completions` 请求构造、transport 注入、响应解析和错误归一化。
- `ProviderKeychainService` 新增 `ProviderUserSecretMaterial` 和 `readUserSecretForProviderCall(alias:)`，只给 provider test call 短生命周期使用；UI 和审计只接收脱敏元数据。
- Main App entitlement 增加 `com.apple.security.network.client`；helper entitlement 不变。
- Settings 在 OpenAI Connection Preview 下新增 Test Connection gate：必须具备 account alias、base URL、model、已保存用户 Keychain secret 和外发确认，按钮才可用。
- Provider audit 新增 `openAIConnectionTest` kind，记录 provider、base URL host、model、account alias、状态、HTTP status、耗时、audit id 和 warning；不保存 provider 原始响应。
- 新增 `tools/verification/p5l_openai_connection_test_gate_checks.py`，用 mock transport 覆盖 success、401、timeout、invalid response 和 invalid base URL。

## Acceptance

- Given 用户未保存 Keychain secret，Then Run Test Connection 不可用。
- Given 用户未勾选外发确认，Then Run Test Connection 不可用。
- Given 用户已满足 alias/base URL/model/secret/确认，When 点击 Run Test Connection，Then App 只发送固定低敏 ping test。
- Given provider 返回成功，Then UI 和 audit 只展示状态、HTTP status、耗时、request id、输出字符数和 audit id。
- Given provider 返回 401、timeout、invalid response 或 invalid base URL，Then App 显示结构化失败状态，不崩溃。
- Given 任一测试结果，Then 不记录 secret 原文、secret hash、认证 header、完整 request body 或 provider raw response。

## Privacy And Safety

- 自动化验证不调用真实 OpenAI 或任何外部 provider。
- 用户 secret 不写入 `AppStorage`、日志、story、验证输出或普通配置。
- P5-L 只开放低敏 test connection；真实翻译、OCR、总结、截图/剪贴板内容外发、streaming、重试、模型列表和持久审计仍不进入本轮。

## Verification

- `python3 tools/verification/p5l_openai_connection_test_gate_checks.py --timeout 180`
- `python3 tools/verification/p5k_user_secret_keychain_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
