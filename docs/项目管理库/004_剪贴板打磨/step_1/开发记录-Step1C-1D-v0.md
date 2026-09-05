# 开发记录 Step 1C/1D - OCR 与 Step 1 收口 v0

状态：ready-for-review
日期：2026-07-07
角色：开发

## 范围

本轮按 `项目负责人-开发派发-Step1C-1D补充-v0.md` 合并完成 Step 1 剩余收口：

- Vision OCR recognizer protocol、Apple Vision 实现边界、deterministic mock。
- `ClipboardVisionOCRQueue` 队列、pending / running / failed / retry / succeeded 状态流。
- OCR text 通过 search document / FTS projection 进入搜索。
- 面板行 / 卡片显示低敏 OCR 状态，failed 状态提供 retry 入口。
- 设置页 active UI 清理旧 hardening / redacted / metadata-first 负向文案，改为 storage / search index / explicit local content access 口径。
- P8 / P8I / P9B / P11E 迁移到 004 Step 1 当前事实源；旧 Step 4D / Step 5 redacted-first 口径仅保留为 baseline reference，不参与 ok。

## 改动文件

App / Core：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionTextRecognizer.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Settings/DataAuditSettingsPane.swift`
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`

Verification：

- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`
- `tools/verification/p8_clipboard_product_polish_checks.py`
- `tools/verification/p8i_settings_clipboard_system_checks.py`
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
- `tools/verification/p11e_clipboard_hardening_checks.py`

文档：

- `docs/项目管理库/004_剪贴板打磨/step_1/开发记录-Step1C-1D-v0.md`

## 关键实现决策

- `BlocksCore` 只保存 OCR 状态、OCR 文本和 search document 投影，不 import Vision / AppKit / SwiftUI。
- Apple Vision OCR 和 deterministic mock 放在 BlocksApp feature 层，通过 `ClipboardVisionTextRecognizer` protocol 隔离。
- OCR queue 只读取已有 image payload，使用 `.ocrInput` purpose；不读取 file URL 本体、不扫描目录、不上传 provider。
- OCR 不在 View body / computed property / search input 同步路径运行；新图片入库后异步处理 pending OCR，失败后由用户显式 retry。
- `ClipboardStore.preview(for:)` 继续走 bounded preview snapshot；OCR 状态来自 preview snapshot，不把 OCR 文本传入 UI。
- 旧 hardening/redacted localization key 暂保留为历史字符串，但当前 Settings / DataAudit / empty state active UI 不再引用负向 token。

## Fixture 证据

- OCR 状态 fixture：`pending`、`running`、`failed`、`retry`、`succeeded`。
- OCR retry fixture：repository smoke 将 failed 图像记录重新置为 pending，再写入 succeeded。
- OCR text search fixture：repository smoke 验证 OCR text 写入 search document 后可通过 FTS 搜索命中；输出只记录 fixture 名，不输出 OCR 文本正文。
- 设置页负向 token：P13A `active_settings_hardening_token_count = 0`；P8I `clipboard_hardening_settings_removed = true`。

## 验证结果

已运行：

- `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`：PASS。
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`：PASS。
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`：PASS。
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`：PASS。
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`：PASS。
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`：PASS，定位为 Step 1 output-boundary / explicit-purpose guard；旧 Step 4D redacted-first 不参与 ok。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`：PASS。
- `git diff --check`：PASS。

备注：Blocks build 仍输出既有 `FloatingPanelSupport.swift` 的 `NSApp.isActive` main actor-isolation warning；本轮未触碰该文件，未作为 Step 1 阻断项处理。

## 未覆盖 / 未做

- 未触发真实 App、真实剪贴板、真实 OCR、provider、Keychain、系统设置、Show in Finder、restart。
- 未做 Step 2 标签 / 收藏、Step 3 面板专项布局、Step 4 详情编辑、Step 5 隐私页 App 清单。
- 未做真实 Vision OCR 端到端 UI 实物验收；本轮用 deterministic mock 边界、repository smoke 和 build 证明集成路径。

## 安全隐私声明

- 未读取、保存或输出真实剪贴板正文、真实截图、OCR 原文、Keychain secret、provider raw response。
- Verification / 开发记录只输出相对路径、fixture 名和低敏状态，不输出 base64、完整 file path、完整 URL query、Authorization header 或 secret。

## 残余风险

- P0：无。
- P1：无已知。
- P2：真实 Apple Vision OCR 质量、语言识别效果和 UI 交互细节仍需后续人工或专门可控样本验收；本轮不触发真实 OCR。

## P1 返工记录

项目负责人验收指出：Settings / DataAudit active UI 虽已移除直接 `settings.clipboardHardening.*` 引用，但仍通过 `ClipboardStore.repositoryStateSummary()` 的有记录分支返回 `.redacted(recordCount:)`，并展示 `repositoryStateSummary.state.rawValue`，可能在正常有记录状态显示 `redacted`。

修正：

- `ClipboardStore.repositoryStateSummary()` 正常有记录分支改为 `.normal(recordCount: records.count)`。
- P13A 增加 `repository_summary_active_redacted_state` / `repository_summary_normal_state_missing` 间接路径检查，并输出 `repository_summary_uses_normal_state`。
- P8I 增加 `repository_summary_normal_state` 检查，验证 Settings / DataAudit repository summary 不再通过 redacted 状态表示正常记录。
- P11E 增加 repository summary output-boundary 检查，拒绝 active summary 返回 `.redacted(recordCount:)` 或引用 `clipboard.hardening.state.redacted.*`。

返工验证：

- `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`：PASS，`repository_summary_uses_normal_state = true`。
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`：PASS，`repository_summary_normal_state = true`。
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`：PASS，`repository_summary_normal_state = true`。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
