# Step 1A-0 开发记录：P13A baseline red v0

状态：baseline-red-established
日期：2026-07-07
角色：开发
范围：Step 1A-0，仅新增 P13A fail-closed verifier

## 1. 改动范围

新增文件：

- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`
- `docs/项目管理库/004_剪贴板打磨/step_1/开发记录-Step1A-0-P13A-baseline-red-v0.md`

未改动范围：

- 未实现 search document、bounded preview、search coordinator、Vision OCR queue 或 OCR mock。
- 未修改 Clipboard repository / Store / View / Settings / OCR 业务代码。
- 未迁移 P8 / P8I / P9A / P9B / P11E。
- 未推进 Step 2 / Step 3 / Step 4 / Step 5。
- 未提交 commit，未创建 branch。

## 2. P13A 设计摘要

`p13a_clipboard_plaintext_search_ocr_checks.py` 是 Step 1 当前事实源门禁，当前批次预期为 baseline red。

脚本输出低敏 JSON，包含：

- `ok`
- `failures`
- `current_evidence`
- `baseline_reference`
- `checked_files`
- `target_membership`
- `rules`
- `sanitizer`

旧 003 / Step 4D 文档只进入 `baseline_reference`，且 `used_for_ok=false`。

脚本复用 `verification_sanitizer.py`，并补充 P13A 本地规则，覆盖 URL query、Authorization 形态、完整 OCR 字段、data image / base64 和 secret-like token 的样例低敏自检。失败详情只输出相对路径、失败码、计数和低敏摘要，不输出真实剪贴板正文、完整 URL query、完整 file path、完整 OCR 文本、base64、secret 或 provider raw data。

## 3. P13A baseline red 结果

命令：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
```

结果：预期失败，exit 1，`ok=false`。

低敏输出摘要：

- `gate`: `P13A`
- `phase`: `Step1A-0 baseline red`
- `sanitizer.ok`: `true`
- `baseline_reference.used_for_ok`: `false`
- `current_evidence.step1_expected_files_present_count`: `0`
- `current_evidence.active_settings_hardening_token_count`: `5`
- `failure_summary.count`: `19`

失败码摘要：

- `search_document_types_missing`
- `expected_step1_swift_files_missing`
- `target_membership_missing`
- `search_document_builder_missing`
- `search_documents_schema_missing`
- `schema_v2_migration_missing`
- `legacy_search_text_builder_active`
- `insert_writes_legacy_search_text`
- `fts_not_projected_from_search_document`
- `store_preview_uses_redacted_preview`
- `visible_filter_search_path_active`
- `panel_uses_store_filtered_records_for_query`
- `content_access_purpose_missing`
- `ocr_recognizer_protocol_missing`
- `apple_vision_implementation_missing`
- `ocr_mock_missing`
- `settings_hardening_negative_tokens_active`
- `search_result_states_missing`
- `repository_search_document_lifecycle_missing`

这些失败均对应当前旧实现缺口，符合 Step 1A-0 baseline red 预期。

## 4. git diff 检查

命令：

```bash
git diff --check
```

结果：PASS。开发记录写入前预检通过；开发记录写入后最终运行仍通过。

## 5. 安全与隐私声明

本批次未触发：

- 真实 App 运行。
- 真实剪贴板读取。
- 真实 OCR / Vision 请求。
- TCC、ScreenCapture、Accessibility、Automation、Full Disk Access 或系统设置。
- provider、Keychain、网络外发、Show in Finder、restart。

P13A 只做静态文件读取和低敏 JSON 输出；未读取、保存或输出真实用户剪贴板正文、真实截图、完整本地路径、完整 URL query、完整 OCR 文本、base64 或凭据。

## 6. 残余风险

P0：无。

P1：无。本批次目标是建立 baseline red，当前 `ok=false` 为预期结果；P13A sanitizer 自检已通过。

P2：

- P13A 目前是静态门禁，不能替代后续 Step 1A-1D 的 repository smoke、runtime fixture、OCR mock running-hold、性能和可访问性验收。
- 由于当前工作区存在其他未提交项目文档/角色文档改动，本记录只声明本批次新增文件，不代表整个工作区已干净。
