---
id: P5-K
title: 用户 API Key Keychain 保存门禁
status: completed
sourcePlan: P5-K 用户 API Key Keychain 保存门禁计划
---

# P5-K 用户 API Key Keychain 保存门禁

## Summary

本轮把 P5-J 的 API key 输入预览推进到可显式写入 macOS Keychain 的 BYOK 门禁。实现目标是让 Settings 能表达用户 key 的保存、替换、存在性验证、删除和缺失验证路径，同时继续阻断真实 OpenAI-compatible provider 调用。

## Implementation

- `ProviderKeychainService` 保留 P5-G 的低敏 fixture 路径，并新增用户 secret 路径。
- 用户 secret account 使用 `openai-compatible:<alias>`，与 fixture 的 `mock-api:<alias>` 隔离。
- 用户 secret 操作包含 `save_or_replace`、`verify_stored`、`delete_stored`、`verify_missing`。
- Settings 的 API Key Input Gate 增加显式保存确认 toggle，保存后清空 `SecureField` 和确认状态。
- Settings 增加 Verify Stored、Delete Stored、Verify Missing，结果只展示 service、account、found、length 和 audit id。
- Provider connection readiness 改为 BYOK dry-run 语义：真实用户 secret 存在、base URL、model 和外发确认元数据齐备时显示 dry-run ready；真实网络测试仍不启用。

## Acceptance

- Given 用户没有勾选保存确认，Then Save/Replace Keychain Key 按钮不可用。
- Given 用户勾选保存确认且 alias/key 非空，When 点击保存，Then key 写入 Keychain，输入框和确认 toggle 被清空。
- Given 用户点击 Verify Stored，Then App 只确认 `openai-compatible:<alias>` item 是否存在，不读取 secret bytes。
- Given 用户点击 Delete Stored / Verify Missing，Then App 能删除并确认缺失。
- Given 任一用户 secret 操作，Then 审计只包含 account、动作、found、length 和 audit id，不包含 secret 原文或 hash。
- Given 当前 P5-K 状态，Then OpenAI Connection Preview / Provider Preview Test 仍不访问网络、不读取 Keychain secret、不构造 Authorization header。

## Privacy And Safety

- 用户 secret 只保存到 macOS Keychain，不写入 `AppStorage`、普通配置、日志、story、验证输出或仓库。
- 用户 secret 结果不返回 hash；短哈希只保留在 P5-G 低敏 fixture gate。
- 本轮不读取环境变量、不执行本地 CLI、不调用 OCR、不读取剪贴板、不处理真实截图。

## Not Covered

- 真实 OpenAI-compatible test connection。
- 真实 provider request / response / streaming / retry。
- 模型列表、费用提示、速率限制、provider 原始输出审计。
- Translation Engine 或 OCR Engine 的真实 provider 绑定。

## Verification

- `python3 tools/verification/p5k_user_secret_keychain_gate_checks.py --timeout 180`
- `python3 tools/verification/p5j_api_key_connection_gate_checks.py --timeout 180`
- `python3 tools/verification/p5g_keychain_ui_gate_checks.py --timeout 180`
- `./script/build_and_run.sh --verify`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
