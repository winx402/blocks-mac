---
id: P5-B
title: 翻译 Provider 确认适配与 Mock 结果面板
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - 继续完善翻译部分
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P5-B 翻译 Provider 确认适配与 Mock 结果面板

## Scope

本轮在 P5-A 的翻译入口 skeleton 上补 provider 选择、确认级别适配和本地 mock 结果面板。不调用真实 API、不执行本地 CLI、不接 OCR、不访问网络，也不读取完整剪贴板或截图内容。

已实现：

- `TranslationProviderProfile`：内置三类 profile，`Local Mock`、`BYOK API` placeholder、`Local CLI` placeholder。
- `TranslationRequestPreview.with(provider:)`：根据 provider 把确认级别适配为 `none_mock` 或 `external_transfer`。
- `AppState` 增加 provider 选择、preview 跟随更新和 `generateMockTranslationResult()`。
- `TranslationHomeView` 增加 provider picker、provider 说明和 mock 结果面板。
- `TranslationConfirmationCard` 增加 provider status 行；只有本地 mock provider 可以生成 mock result，API/CLI placeholder 仍保持 disabled。
- 新增三语 String Catalog 文案，覆盖 provider、mock result、状态反馈和确认卡片状态。
- 新增 `tools/verification/p5b_translation_mock_result_checks.py`，验证构建、P5-A 回归、本地化覆盖、provider/mock result 符号和无真实 runtime 调用。

## Acceptance Notes

- Given 用户进入 Translation section，Then 可以在 Local Mock、BYOK API placeholder、Local CLI placeholder 中选择 provider profile。
- Given 用户选择 Local Mock，When 点击生成 mock result，Then 显示本地 mock 结果面板、audit 摘要和无外部 provider 接收内容的提示。
- Given 用户选择 BYOK API 或 Local CLI placeholder，Then preview 显示 `external_transfer` 和 not ready 状态，不执行真实 provider。
- Given 来源来自截图结果或剪贴板摘要，Then 仍只使用 redacted preview；不会读取完整截图 OCR、剪贴板原文或 provider 原始输出。

## Privacy And Safety

- P5-B 不包含 `URLSession`、`Process`、`NSPasteboard.general` 或 `codex exec` 调用。
- `Local Mock` 只基于 redacted preview 生成固定摘要，不做真实翻译。
- BYOK/API 和本地 CLI 只作为 profile placeholder；真实调用必须等 Keychain、确认、审计和 provider UI 完成后再接入。
- 机器字段、action 名和错误 code 仍不本地化；只本地化 UI 文案。

## Not Covered Yet

- 真实 provider 连接测试、Keychain 凭据 UI、模型选择、网络调用和本地 CLI 调用。
- OCR 后翻译、划词翻译、自动语言识别、翻译历史和结果复用。
- provider 原始输出审计、失败重试、速率限制、计费提示和 hook 拦截。

## Verification

已执行并通过：

- `python3 tools/verification/p5b_translation_mock_result_checks.py --timeout 180`
- `python3 tools/verification/p5a_translation_skeleton_checks.py --timeout 180`
- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

