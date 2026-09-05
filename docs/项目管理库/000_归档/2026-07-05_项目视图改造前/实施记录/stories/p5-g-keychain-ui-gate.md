---
id: P5-G
title: Keychain UI Gate
status: implemented
date: 2026-07-02
sourcePlan: 用户指令 - 继续推进 P5-G
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
  - ../../../../技术知识库/Provider-Secret-Handling-v0.md
---

# P5-G Keychain UI Gate

## Scope

本轮把 P5-D 的 Keychain 生命周期 UI skeleton 升级为真实 Keychain 低敏测试门禁。Settings Provider / AI section 现在可以通过固定低敏测试项验证 macOS Keychain add、read、update、delete 和 missing-read 路径，并把结果写入内存态脱敏审计摘要。

已实现：

- 新增 `ProviderKeychainService`，固定 service 为 `com.jdtool.provider.dev`，account 形态为 `mock-api:<alias>`。
- Save / Rotate / Delete / Verify Missing 按钮调用真实 `SecItem` 路径，但只写入固定低敏测试 secret。
- UI 只展示 service、account 和 SHA-256 前 12 位；不显示 secret 原文。
- BYOK API 的 Keychain requirement 在低敏测试项验证后可通过；网络测试和真实 API key 输入仍被阻断。
- Provider audit summary 新增 Keychain gate 结果和低敏 fixture warning。
- 新增三语 String Catalog 文案和 `tools/verification/p5g_keychain_ui_gate_checks.py`。

## Acceptance Notes

- Given 用户填写 Keychain account alias，When 点击 Save Test Item，Then App 写入固定低敏测试项并记录脱敏审计摘要。
- Given 已保存测试项，When 点击 Rotate Test Item，Then App 更新固定低敏测试项并只显示长度和短哈希。
- Given 用户点击 Delete Test Item 或 Verify Missing，Then App 删除并验证测试项缺失，失败时返回结构化状态。
- Given 用户查看 Provider Test Gate，Then 低敏 Keychain 测试通过只解除 Keychain fixture gate，不解除真实 API 网络执行 gate。
- Given 任意 Keychain UI 操作，Then UI、日志和验证输出都不包含测试 secret 原文或真实 API key。

## Privacy And Safety

- P5-G 不提供真实 API key 输入框，不读取环境变量，不调用真实 API，不执行本地 CLI。
- Keychain 写入只使用固定低敏 fixture：`jdtool-p5g-low-sensitive-test-secret-v1` / `v2`。
- 验证脚本会执行 add、read、update、delete 和 missing-read；最终测试项必须被删除。
- 审计摘要只记录 service、account、OSStatus、长度和短哈希。

## Not Covered Yet

- 真实 API key 输入、保存、更新和删除 UI。
- 真实 API provider test connection。
- 真实 local CLI provider execution。
- Keychain access group、同步 Keychain、迁移和导入导出策略。
- 持久审计日志、清理策略和失败重试 UX。

## Verification

已执行并通过：

- `python3 tools/verification/p5g_keychain_ui_gate_checks.py --timeout 180`
- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`
- `python3 tools/verification/p5e_provider_audit_checks.py --timeout 180`
- `python3 tools/verification/p4h_app_group_readiness_checks.py --timeout 180`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run`
