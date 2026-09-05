# Step 1A 开发记录 v0

日期：2026-07-07
角色：开发
结论：DONE

## 1. 改动范围

本批次只实现 Step 1A：Search document 与 bounded preview 基础。

代码改动：

- `apps/Blocks/BlocksCore/ClipboardSearchDocument.swift`
  - 新增 `ClipboardSearchDocument`、`ClipboardContentPreviewSnapshot`、`ClipboardOCRState`、`ClipboardSearchResultState`、`ClipboardPayloadDerivationState`。
- `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift`
  - 新增唯一构建入口，负责 text、URL、file URL、rich text plain text 的 bounded preview、tokens、FTS projection 基础派生。
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
  - 新增 search document load/upsert/delete/redact/OCR update/rebuild/pending batch/search facade API。
- `apps/Blocks/BlocksCore/AppDatabase.swift`
  - SQLite `user_version` 从 v1 推进到 v2。
  - 新增 `clipboard_search_documents` 派生表和 OCR state 字段。
  - 保留 `clipboard_fts`，作为 search document projection 的查询投影。
- `apps/Blocks/BlocksCore/ClipboardRepository.swift`
  - insert 在同一 transaction 写 record、payload、search document、compat `search_text`、FTS。
  - duplicate/dedupe 不新建 search document。
  - delete / clear / prune / policy redaction 同步清理或失效 search document 与 FTS。
  - 移除独立 legacy `searchText(for:payload:)` 事实源。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
  - `preview(for:)` 改为优先读取 repository bounded preview snapshot。
  - fallback 只做有界 metadata/summary，不批量读 payload。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPayloadAccess.swift`
  - 保留 `ClipboardPayloadReadPurpose` 名称，但按 Step 1 重释义为高成本内容访问分类，补齐 `previewBuild`、`searchIndex`、`ocrInput`。
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
  - 新增 Core 三个 Swift 文件 target membership。
- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`
  - 从 Step 1A-0 baseline red 调整为 Step 1A 当前门禁；Step 1A 文件和后续 Step 1B/1C/1D 预期文件分层检查。
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
  - 升级为 v2 / search document / bounded preview / FTS projection / lifecycle 一致性 smoke。

## 2. 未改范围

- 未实现 Step 1B 搜索状态/UI 接入。
- 未实现 Step 1C Vision OCR queue、Apple Vision recognizer、OCR mock running-hold 或 retry UI。
- 未执行 Step 1D 设置页 hardening/redacted 文案清理和旧门禁迁移。
- 未触碰 Step 2/3/4/5、标签/收藏、详情编辑、hover 布局、权限、provider、Keychain 或真实系统动作。

## 3. 关键实现边界

- `ClipboardSearchDocument` 是 search/bounded preview/OCR state 的派生事实源；`clipboard_fts` 和 `clipboard_items.search_text` 都只来自同一 projection。
- `clipboard_items.search_text` 暂时保留为 compatibility projection，不再由 repository 内独立 builder 拼接。
- Store 高频 preview 路径读取 `ClipboardContentPreviewSnapshot`，不在列表加载时读完整 payload。
- file URL preview 只展示文件名；P9A fixture 检查 preview 不输出完整 `/Users/...` 路径。
- 当前 OCR 只保留状态和更新 API skeleton；不引入 Vision、不读取图片做 OCR、不触发真实 OCR。

## 4. P13A 变化

Step 1A-0 baseline：`ok=false`，19 个失败码。

Step 1A 实现后：`ok=false`，6 个失败码。`ok=false` 属预期，因为剩余项属于未派发的 Step 1B/1C/1D。

已消除或重分层的 Step 1A 相关失败码：

- `content_access_purpose_missing`
- `expected_step1_swift_files_missing`
- `fts_not_projected_from_search_document`
- `insert_writes_legacy_search_text`
- `legacy_search_text_builder_active`
- `repository_search_document_lifecycle_missing`
- `schema_v2_migration_missing`
- `search_document_builder_missing`
- `search_document_types_missing`
- `search_documents_schema_missing`
- `search_result_states_missing`
- `store_preview_uses_redacted_preview`
- `target_membership_missing`

剩余失败码归因：

- Step 1B：`visible_filter_search_path_active`、`panel_uses_store_filtered_records_for_query`
- Step 1C：`ocr_recognizer_protocol_missing`、`apple_vision_implementation_missing`、`ocr_mock_missing`
- Step 1D：`settings_hardening_negative_tokens_active`

## 5. 验证结果

| 命令 | 结果 | 备注 |
|---|---:|---|
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | EXPECTED FAIL | `ok=false`，剩余 6 个失败码均为 Step 1B/1C/1D。输出低敏，sanitizer ok。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `schema_version=2`，验证 text/url/file_url/rich_text search document fixtures 和 lifecycle cleanup。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 因触及 Xcode target membership 补跑。中途曾发现 pbxproj build file ID 冲突，已修复后通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI 目标通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅执行 help，不触发真实剪贴板或系统动作。 |
| `git diff --check` | PASS | 最终文档写入后复跑通过。 |

## 6. 低敏与安全声明

- 未读取真实系统剪贴板。
- 未触发真实 App、真实 OCR、TCC、provider、Keychain、系统设置、Show in Finder 或 restart。
- 验证只使用低敏 synthetic fixture。
- 验证输出不包含真实剪贴板正文、完整 URL query、完整 file path、图片 base64、完整 OCR 文本、secret 或 Authorization header。

## 7. 残余风险

- P0：无。
- P1：无。本批次 Step 1A 范围内 verification 和 build 已通过；P13A 保持红灯是后续子批次预期残余。
- P2：
  - 旧 v1 数据库打开后只创建 v2 派生表，不同步 backfill 全量历史；当前实现提供 `rebuildSearchDocuments(limit:)` skeleton，后续 Step 1B/1C 可接后台批处理。
  - `ClipboardPayloadReadPurpose` 保留旧名称并重释义，后续如要完全消除 Step 4D allowlist 命名歧义，可单独改名为 `ClipboardContentAccessPurpose`。
  - Store fallback 在无 repository snapshot 时只能展示有界 summary/metadata；真实明文列表质量依赖 repository 已生成 bounded preview snapshot。
