# 004_剪贴板打磨 Step 5 R1 开发记录 v0

日期：2026-07-07
角色：开发
结论：DONE_WITH_EVIDENCE

## 范围

本轮只处理 Step 5 R1 的 P13E evidence schema / required scenario id 对齐问题。未进入 Step 6，未修改 Swift 业务实现、Xcode target membership、capture policy 行为或 CLI 行为。

## 修复文件

- `tools/verification/p13e_clipboard_privacy_policy_checks.py`
- `docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-R1-v0.md`

## R1 修复点

### P1-1：P13E 顶层 evidence schema

已将 P13E stdout 顶层补齐为 accepted contract：

- `ui_interaction`
  - `search_fields`
  - `filter_combination`
  - `sort_stability`
  - `a11y`
  - `layout`
- `capture_bridge`
  - `snapshot_shape`
  - `scenarios`
- `performance`
  - `elapsed_ms`
  - `threshold_ms`
  - `fixture_count`
  - `sample_count`

新增 `validate_evidence_schema(...)`，缺任一顶层字段或子字段会追加 failure，使 P13E `ok=false`。

### P1-2：accepted exact scenario id

P13E stdout 和 required scenario set 已改为使用以下 accepted exact id：

- `privacy_app_search_fields_004`
- `privacy_app_filter_combination_004`
- `privacy_app_sort_stability_004`
- `privacy_app_row_a11y_004`
- `privacy_app_narrow_width_004`
- `privacy_app_long_text_i18n_004`
- `privacy_capture_bundle_restricted_004`
- `privacy_capture_bundle_allowed_004`
- `privacy_capture_app_path_precedence_004`
- `privacy_capture_default_allow_004`
- `privacy_capture_missing_path_fallback_004`
- `privacy_capture_snapshot_low_sensitive_004`

新增 fail-closed 检查：缺任一 accepted exact id 时 P13E `ok=false`。

## Red / Green 证据

- Red：修改前运行独立解析脚本，P13E 自身 `exit=0` 且 `ok=true`，但解析结果缺顶层 `ui_interaction` / `capture_bridge` / `performance`，且 12 个 accepted exact id 全部缺失；解析脚本 `exit=1`。
- Green：修改后 P13E `exit=0`、`ok=true`、`failures=[]`。独立解析脚本确认 `top_level_schema_ok=true`、`accepted_ids_ok=true`、`missing_top_or_child=[]`、`missing_accepted_ids=[]`。

## 验证结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` | PASS，`ok=true`，顶层含 `ui_interaction` / `capture_bridge` / `performance` |
| 独立解析脚本：运行 P13E 后检查顶层 schema 与 12 个 accepted exact id | PASS，`top_level_schema_ok=true`，`accepted_ids_ok=true` |
| `git diff --check` | PASS |

## 未运行说明

本轮未改 Swift 实现、Xcode target membership、数据库迁移、Settings UI 行为、capture policy 行为或 CLI 行为，因此未复跑 xcodebuild 和 P13A-D/P8/P8I/P9/P11E 全量矩阵。Step 5 v0 已记录这些门禁通过；R1 只修 verifier evidence contract。

## 安全隐私声明

本轮未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。P13E 继续使用 deterministic synthetic fixture；输出经 shared sanitizer 处理，不输出完整本地路径、真实 App 名、邮箱、secret、Authorization header 或剪贴板 payload。

## 残余风险

- P0：0。
- P1：0。
- P2：真实 `/Applications` 与真实 VoiceOver/视觉验收仍属于后续人工或 Step 6 回扫范围；本轮未扩大验证范围。
