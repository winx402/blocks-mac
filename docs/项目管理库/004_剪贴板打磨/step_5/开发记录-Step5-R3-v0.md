# 004_剪贴板打磨 Step 5 R3 开发记录 v0

## 结论

DONE_WITH_EVIDENCE。

本轮只处理 Step 5 R3 单一 P1：legacy excluded bundle migration 在 `subject_ref` 冲突时不得覆盖已有 current policy rule。未进入 Step 6，未做无关重构，未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。

## 改动范围

- `apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift`
  - `migrateLegacyRestrictedBundleIDs` 的 conflict strategy 从 `ON CONFLICT(subject_ref) DO UPDATE ... policy = excluded.policy` 改为 `ON CONFLICT(subject_ref) DO NOTHING`。
  - 迁移只补齐缺失 rule；已存在 current rule 的 `policy`、用户/agent intent 和 `updated_at` 不被 legacy old key 覆盖。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py`
  - 新增 required scenario：`privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004`。
  - 新增 migration 函数体静态语义检查，只检查 `migrateLegacyRestrictedBundleIDs`，不误伤正常 `applyPolicy` 的 conflict update。
  - `implementation_evidence.legacy_migration.conflict_preserves_existing_policy` 必须为 true。
  - current fact sources 增加 R3 派发文档。

## P1 修复说明

修复前：

- legacy migration 遇到同一 `subject_ref` 时会执行 `policy = excluded.policy`，把已有 `allowed` 改成 `restricted`。
- P13E 没有覆盖“已有 allowed rule + legacy old key”的冲突路径，存在假 PASS。

修复后：

- legacy-only bundle 仍迁移为 `restricted`。
- 已有 current rule 保留原 policy。例如同一 bundle 预先为 `allowed` 时，legacy old key 包含该 bundle 后仍保持 `allowed`。
- marker 语义不变：`Step5OneShotMigration` 仍在 repository migration 成功后才写 `privacy.policy.migratedExcludedBundleIDs.v1`；失败不写完成 marker，旧 key 保留可重试。

## P13E Red / Green 证据

Red：

- 在只补 P13E conflict 场景、未改 Swift 生产代码时运行：
  - `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py`
  - 结果：FAIL，`ok=false`。
  - 失败码包含：`legacy_repository_conflict_policy_overwrite`、`legacy_repository_conflict_not_preserved`、`legacy_migration_conflict_overwrites_current_policy`、`implementation_legacy_conflict_failed`。

Green：

- 修改 repository conflict strategy 后运行：
  - `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py`
  - 结果：PASS，`ok=true`，`failures=[]`。
  - 新 scenario `privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004` 输出：
    - `existing_policy_before=allowed`
    - `existing_policy_after=allowed`
    - `legacy_only_policy_after=restricted`
    - `snapshot_allowed_bundle_ids=1`
    - `snapshot_restricted_bundle_ids=1`
    - `preserves_existing_current_rule=true`

## 验证结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` | PASS，`ok=true`，`failures=[]`，新增 conflict scenario 通过 |
| 独立解析 P13E 顶层 schema / 12 个 UI+capture accepted id / legacy migration id / 6 个 CLI typed subject id / 新 conflict id | PASS；`missing_top_or_child=[]`，`missing_required_ids=[]`，`conflict_preserves_current=true` |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS，`ok=true` |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS，`ok=true` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；保留既有 `FloatingPanelSupport.swift` actor warning 和 AppIntents metadata warning |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS；输出 privacy actions list |
| `git diff --check` | PASS |

## 未覆盖项与残余风险

- P0：无。
- P1：无已知残留。
- P2：本轮没有对真实用户数据库执行旧 key migration；验证使用 P13E 低敏 deterministic/static evidence，避免真实系统状态变更。
- P2：本轮只修复 repository migration conflict；R2 记录中关于真实 icon provider 视觉实物、真实 `/Applications` 扫描、CLI confirm 对真实库 mutation 的残余风险保持不扩大。

## 安全隐私声明

- 未读取或输出真实剪贴板正文、OCR 原文、真实 App 清单、完整本地路径、图片/base64、邮箱、secret、Authorization header 或凭据。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。
- P13E / 开发记录 / verifier stdout 仅包含低敏 synthetic fixture、opaque subject ref、hash/path summary 和 redacted marker。
