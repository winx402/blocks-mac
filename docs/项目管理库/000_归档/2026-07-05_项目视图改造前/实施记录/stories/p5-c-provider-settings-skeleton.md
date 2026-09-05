---
id: P5-C
title: Provider 设置占位与 Keychain UI Skeleton
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - 翻译部分继续完善
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P5-C Provider 设置占位与 Keychain UI Skeleton

## Scope

本轮在 Settings 中补 Provider / AI 设置骨架，让 P5-B 的 provider profile 有设置入口。仍不读取 Keychain、不读取环境变量、不访问网络、不执行 CLI、不调用真实 provider。

已实现：

- Settings 新增 Provider / AI section。
- 可选择默认 provider profile，并复用 P5-B 的 Local Mock、BYOK API placeholder 和 Local CLI placeholder。
- 增加 API Keychain account alias、API Base URL、本地 CLI 名称三个占位字段。
- 占位字段通过 `@AppStorage` 保存本机 UI 偏好；只保存 alias / base URL / CLI 名称，不保存 secret 原文。
- 增加 confirmation preview 按钮，用 `AppState.previewProviderSettingsConfirmation()` 更新状态栏，说明真实 provider 需要 external transfer、Keychain 和 audit metadata。
- 新增三语 String Catalog 文案和 `tools/verification/p5c_provider_settings_checks.py`。

## Acceptance Notes

- Given 用户打开 Settings，Then 可以看到 Provider / AI 设置区。
- Given 用户切换默认 provider，Then Translation section 的 provider selection 共享同一 `AppState` 选择。
- Given 用户填写 Keychain account alias，Then 仅保存 alias 文本，不读取或写入 Keychain secret。
- Given 用户点击 Preview Confirmation，Then 显示确认路径说明，不执行真实 provider 测试连接。

## Privacy And Safety

- P5-C 不包含 `SecItem`、`URLSession`、`Process`、`NSPasteboard.general` 或 `getenv` 调用。
- Keychain account 字段是 alias，不是 secret value。
- API Base URL 和 Local CLI 名称只是本机偏好占位，不触发网络或进程执行。
- 真实 provider 接入前仍必须完成 Keychain secret 生命周期 UI、external transfer confirmation、审计摘要和失败路径。

## Not Covered Yet

- 真实 API key 保存、读取、更新、删除 UI。
- provider 测试连接、模型列表、速率限制、失败重试和真实翻译调用。
- 本地 CLI 探测、CLI 权限确认、provider 原始输出脱敏和审计清理。

## Verification

已执行并通过：

- `python3 tools/verification/p5c_provider_settings_checks.py --timeout 180`
- `python3 tools/verification/p5b_translation_mock_result_checks.py --timeout 180`
- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

