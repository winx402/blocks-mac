---
id: P5-D
title: Keychain Secret Lifecycle UI Skeleton
status: implemented
date: 2026-07-02
sourcePlan: 用户指令 - p5-D
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P5-D Keychain Secret Lifecycle UI Skeleton

## Scope

本轮在 P5-C Provider / AI 设置骨架上补 Keychain secret 生命周期 UI skeleton。它只表达保存、更新、删除、验证缺失的用户交互和审计预览，不读写真实 Keychain，不提供 secret 原文输入框，不调用真实 provider。

已实现：

- Settings Provider / AI section 增加 Keychain secret lifecycle 状态。
- 生命周期状态仅通过 `@AppStorage("provider.api.secretLifecycleState")` 保存状态枚举。
- 最近审计 ID 仅通过 `@AppStorage("provider.api.secretLifecycleAuditID")` 保存低敏 UI intent id。
- 增加 Save Placeholder、Rotate Placeholder、Delete Placeholder、Verify Missing 四个按钮。
- `AppState.previewProviderSecretLifecycle(...)` 更新状态栏，说明本轮只记录 UI intent，没有读写 Keychain item。
- 新增三语 String Catalog 文案和 `tools/verification/p5d_keychain_lifecycle_ui_checks.py`。

## Acceptance Notes

- Given 用户打开 Settings，Then Provider / AI section 能显示 Keychain secret lifecycle 状态。
- Given 用户点击 Save Placeholder，Then 状态变为 placeholder saved，并生成本地 audit id。
- Given 用户点击 Rotate Placeholder，Then 状态变为 placeholder rotated，不读取或写入真实 secret。
- Given 用户点击 Delete Placeholder 或 Verify Missing，Then UI 能表达删除/缺失验证路径，但不调用 Keychain API。
- Given 用户查看提示文案，Then 能明确当前 skeleton 不保存或显示 secret value。

## Privacy And Safety

- P5-D 不包含 `SecItem`、`kSecClass`、`SecureField`、`URLSession`、`Process`、`NSPasteboard.general` 或 `getenv` 调用。
- 没有 secret 原文输入框，也没有 `secretValue` 存储字段。
- 当前只保存生命周期状态和低敏 audit id，不保存 API key、CLI token、provider 原始输出或真实请求结果。
- 真实 Keychain secret 生命周期 UI 必须在后续 story 中单独实现，并配套确认、审计和错误路径。

## Not Covered Yet

- 真实 Keychain add/read/update/delete/missing-read。
- API key 输入、保存、读取、更新、删除确认。
- provider 测试连接、真实翻译调用、模型列表、速率限制和失败重试。
- provider 审计日志持久化、清理和导出。

## Verification

已执行并通过：

- `python3 tools/verification/p5d_keychain_lifecycle_ui_checks.py --timeout 180`
- `python3 tools/verification/p5c_provider_settings_checks.py --timeout 180`
- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

