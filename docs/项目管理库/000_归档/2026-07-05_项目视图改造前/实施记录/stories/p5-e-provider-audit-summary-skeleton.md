---
id: P5-E
title: Provider Audit Summary Skeleton
status: implemented
date: 2026-07-02
sourcePlan: 用户指令 - P5-E provider audit summary
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
  - ../../../../技术知识库/Provider-Secret-Handling-v0.md
---

# P5-E Provider Audit Summary Skeleton

## Scope

本轮在 P5-B/P5-C/P5-D 的翻译 provider、设置和 Keychain 生命周期 UI skeleton 基础上，补一个内存态、脱敏的 Provider Audit Summary。它用于把“生成本地 mock 结果”“预览 provider 设置确认”“预览 Keychain 生命周期意图”这些动作串到同一个审计摘要列表里。

已实现：

- 新增 `ProviderAuditEvent` / `ProviderAuditEventKind`，字段包含 `id`、`createdAt`、`kind`、`providerSummary`、`confirmationLevel`、`sourceSummary`、`resultSummary`、`auditID`、`warnings`。
- `AppState` 新增 `providerAuditEvents`，最多保留 20 条，当前只存在内存里。
- Local Mock 翻译结果生成后自动记录一条脱敏审计摘要。
- Settings provider confirmation preview 自动记录一条脱敏审计摘要。
- Keychain lifecycle Save / Rotate / Delete / Verify Missing UI skeleton 自动记录一条脱敏审计摘要。
- Settings Provider / AI section 增加 Audit Summary：空状态、最近 5 条摘要、清空按钮、audit id、provider、confirmation level、source/result 摘要和 warning。
- 新增三语 String Catalog 文案和 `tools/verification/p5e_provider_audit_checks.py`。

## Acceptance Notes

- Given 用户生成 Local Mock 翻译结果，Then Translation 面板仍显示 audit id，Settings Audit Summary 能看到对应 mock result 审计摘要。
- Given 用户点击 Provider confirmation preview，Then Settings Audit Summary 增加 provider settings preview 摘要，但不调用网络、API 或 CLI。
- Given 用户点击 Keychain lifecycle skeleton 按钮，Then Settings Audit Summary 增加 keychain lifecycle preview 摘要，但不读写真实 Keychain。
- Given 用户点击 Clear，Then 仅清空本次运行的内存态脱敏摘要。
- Given audit summary 列表超过 20 条，Then 只保留最新 20 条。

## Privacy And Safety

- P5-E 不新增持久审计日志，不保存 provider 原始输出，不保存 secret、API key、CLI token、真实截图或真实剪贴板内容。
- 审计摘要只保存来源摘要、结果摘要、provider 摘要、confirmation level、audit id 和 warning。
- 本轮不调用 `URLSession`、`Process`、`SecItem`、`NSPasteboard.general`，也不读取环境变量。
- 真实 provider 调用、真实 Keychain secret 生命周期和持久审计日志必须在后续 story 中单独实现并复核确认边界。

## Not Covered Yet

- 持久审计日志、筛选、导出、自动清理策略。
- 真实 API provider 调用、模型测试连接、速率限制、失败重试。
- 真实 Keychain add/read/update/delete UI。
- CLI/agent 查询审计摘要。
- hook enabled / destructive path 的完整审计流。

## Verification

已执行并通过：

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
