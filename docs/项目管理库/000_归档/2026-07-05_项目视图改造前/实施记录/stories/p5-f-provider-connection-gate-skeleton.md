---
id: P5-F
title: Provider Connection Gate Skeleton
status: implemented
date: 2026-07-02
sourcePlan: 用户指令 - 继续推进 P5-F
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
  - ../../../../技术知识库/Provider-Secret-Handling-v0.md
---

# P5-F Provider Connection Gate Skeleton

## Scope

本轮在 P5-E audit summary skeleton 基础上，补 Provider test connection 的门禁骨架。它不做真实连接测试，而是把未来执行真实 API / CLI test connection 前需要满足的条件明确展示出来，并把用户点击“预览测试”的动作写入内存态脱敏审计摘要。

已实现：

- Settings Provider / AI section 新增 Provider Test Gate。
- Local Mock provider 显示 ready，因为它只使用本地脱敏 preview，不外发内容。
- BYOK API provider 显示阻断项：Keychain account alias、API Base URL 元数据、真实 Keychain 读取、真实网络测试执行。
- Local CLI provider 显示阻断项：CLI 名称、显式 CLI 执行路径。
- 新增 Validate Configuration 按钮，只更新本地状态栏，不调用 provider。
- 新增 Preview Test 按钮，写入 `provider_connection_preview` 审计摘要；API/CLI 当前会记录 blocked preview。
- 新增三语 String Catalog 文案和 `tools/verification/p5f_provider_connection_gate_checks.py`。

## Acceptance Notes

- Given 用户选择 Local Mock provider，Then Provider Test Gate 显示本地 mock ready。
- Given 用户选择 BYOK API provider，Then UI 能看到真实 Keychain 读取和网络测试执行仍被阻断。
- Given 用户选择 Local CLI provider，Then UI 能看到真实 CLI 执行路径仍被阻断。
- Given 用户点击 Validate Configuration，Then 只更新状态栏，不调用 API、不执行 CLI、不读取 Keychain。
- Given 用户点击 Preview Test，Then Settings Audit Summary 增加一条 provider test preview 摘要，且记录 warning：真实 API/CLI test connection 未实现。

## Privacy And Safety

- P5-F 不调用 `SecItem`、`URLSession`、`Process`、`NSPasteboard.general`，不读取环境变量。
- 不保存 secret 原文、provider 原始输出、API 响应、CLI 输出或真实连接日志。
- API Base URL 和 CLI name 仍只是本地设置元数据；它们不代表 provider 可用。
- 真实 test connection 必须在后续 story 中引入明确 external transfer 确认、超时、错误分类、输出脱敏和审计策略。

## Not Covered Yet

- 真实 Keychain add/read/update/delete UI 已由后续 P5-G 以固定低敏 fixture gate 补齐；真实 API key 输入仍未实现。
- 真实 API provider test connection。
- 真实 local CLI provider execution。
- provider 失败重试、模型列表、速率限制、费用提示。
- 持久审计日志、导出和清理策略。

## Verification

已执行并通过：

- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`
- `python3 tools/verification/p5e_provider_audit_checks.py --timeout 180`
- `python3 tools/verification/p5d_keychain_lifecycle_ui_checks.py --timeout 180`
- `python3 tools/verification/p5c_provider_settings_checks.py --timeout 180`
- `python3 tools/verification/p5b_translation_mock_result_checks.py --timeout 180`
- `python3 tools/verification/p4c_clipboard_interactions_checks.py --timeout 180`
- `python3 tools/verification/p3c_screenshot_checks.py --timeout 180`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `xcstringstool compile --dry-run`
