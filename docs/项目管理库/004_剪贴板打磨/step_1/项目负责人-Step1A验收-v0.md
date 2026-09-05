# Step 1A 项目负责人验收 v0

日期：2026-07-07
角色：项目负责人
对象：`开发记录-Step1A-v0.md`
结论：accepted

## 1. 验收结论

Step 1A 接受。

本批次完成了 search document 与 bounded preview 基础实现，符合 `项目负责人-开发派发-Step1A-v0.md` 的范围要求。剩余 `P13A` 红灯均属于未派发的 Step 1B / Step 1C / Step 1D，不作为 Step 1A 阻断。

Step 1B 可以在 Step 1 内继续串行派发；Step 2 / Step 3 仍暂停。

## 2. 独立核验结果

项目负责人复跑命令：

| 命令 | 结果 | 结论 |
| --- | ---: | --- |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | EXPECTED FAIL | `ok=false`，剩余 6 个失败码均归因 Step 1B / Step 1C / Step 1D。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `schema_version=2`，text / url / file_url / rich_text fixture 与 lifecycle cleanup 通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 构建通过；仅见既有 `FloatingPanelSupport.swift` main actor warning。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI target 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅执行 help，未触发剪贴板业务动作。 |
| `git diff --check` | PASS | 无 whitespace error。 |

`P13A` 剩余失败码：

- Step 1B：`visible_filter_search_path_active`
- Step 1B：`panel_uses_store_filtered_records_for_query`
- Step 1C：`ocr_recognizer_protocol_missing`
- Step 1C：`apple_vision_implementation_missing`
- Step 1C：`ocr_mock_missing`
- Step 1D：`settings_hardening_negative_tokens_active`

## 3. 范围核对

已接受事实：

- 新增 `ClipboardSearchDocument`、`ClipboardContentPreviewSnapshot`、`ClipboardOCRState`、`ClipboardPayloadDerivationState` 等模型。
- 新增 `ClipboardSearchDocumentBuilder`，作为 search document / bounded preview 的单一构建入口。
- SQLite schema 推进到 v2，新增 `clipboard_search_documents`。
- Repository insert / delete / prune / policy redaction 路径同步维护 search document、compat `search_text` 和 FTS。
- `ClipboardStore.preview(for:)` 高频路径优先读取 bounded preview snapshot，不再默认走 `redactedPreview`。
- `P9A` 已升级为 Step 1A repository smoke，并覆盖 text、URL、file URL、rich text fixture。
- Xcode target membership 已补齐。

未接受为本批次完成的内容：

- 非空搜索 UI / Store 主路径仍未切到 search document / FTS，这是 Step 1B 范围。
- Vision OCR recognizer、mock、queue、retry UI 尚未实现，这是 Step 1C 范围。
- 设置页 hardening / redacted 负向 token 清理和旧门禁迁移尚未完成，这是 Step 1D 范围。

## 4. 残余风险

P0：无。

P1：无。Step 1A 范围内 verification 和 build 已通过。

P2：

- 旧 v1 数据库打开后创建 v2 派生表，但不在启动、面板打开或搜索输入路径同步全量 backfill；后续 Step 1B / Step 1C 必须接住 `pendingIndex` / batch rebuild 策略。
- `ClipboardPayloadReadPurpose` 保留旧名称但已重释义；如果后续旧 Step 4D 文档或门禁继续产生语义干扰，再单独改名为 `ClipboardContentAccessPurpose`。
- Store 无 repository snapshot 时仍只能 fallback 到有界 summary / metadata；真实明文列表质量依赖 repository 已生成 bounded preview snapshot。

## 5. 下一步

派发 Step 1B：搜索状态与 Store / UI 接入。

Step 1B 目标是消除 `P13A` 中两个 Step 1B 残余失败码，并补齐正文、source、URL host/path、file name、rich plain text、类型同义词和最小时间 token 的搜索路径；不进入 Step 1C OCR runtime，也不进入 Step 1D 设置页清理。
