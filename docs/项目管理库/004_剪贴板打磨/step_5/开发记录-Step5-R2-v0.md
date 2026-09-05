# 004_剪贴板打磨 Step 5 R2 开发记录 v0

## 结论

DONE_WITH_EVIDENCE。

本轮只处理 Step 5 R2 代码审查确认的 4 个 P1：旧 exclusion migration、CLI typed subject 范围、P13E 实现级 fail-closed、真实 App icon provider。未进入 Step 6，未做无关重构，未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。

## 改动范围

- `apps/Blocks/BlocksCore/PrivacyPolicyModels.swift`
  - 扩展 `PrivacyPolicySubjectType`：`app_bundle`、`bundle_id`、`app_path`、`command_path`、`login_item`、`helper`、`launch_label`。
  - `PrivacyAppInstance` 增加 `canonicalPath`，用于本地 icon 读取，不进入 verifier/stdout 原文输出。
- `apps/Blocks/BlocksCore/PrivacySubjectResolver.swift`
  - `subject_ref` 改为稳定 opaque/hash 格式：`sub_v1_<type>_<hash20>`。
  - 增加 typed subject 解析、explicit subject 构造和 subject ref type 反解。
- `apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift`
  - 新增旧 `clipboard.policy.excludedBundleIDs` 到 `privacy_policy_rules` restricted `bundle_id` 的 repository migration 写入路径。
  - snapshot 支持 path-scoped subject 汇入 app path hash 集合。
- `apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift`
  - 新增 one-shot migration：旧 key -> restricted bundle rules，marker `privacy.policy.migratedExcludedBundleIDs.v1`。
  - marker 只在 repository 写入成功后写入；失败时清除 marker 并保留旧 key。
- `apps/Blocks/BlocksCore/PrivacyAppScanner.swift`
  - 输出 `canonicalPath`；缺 bundle id 时使用 opaque app path subject ref。
- `apps/Blocks/BlocksCore/PrivacyPathSanitizer.swift`
  - 默认 path summary 不输出完整 `/Applications` 路径，改为低敏 summary。
- `apps/Blocks/BlocksApp/Features/Privacy/PrivacyStore.swift`
  - 搜索字段包含 `pathSummary`，并拒绝 raw home path query 命中。
  - scanner 失败保留既有 app 列表，避免刷新失败白屏。
- `apps/Blocks/BlocksApp/Features/Privacy/AppIconProvider.swift`
  - 新增 `SystemAppIconProvider`：通过 `NSWorkspace.shared.icon(forFile:)` 读取本地 `.app` icon，带 cache / failed state。
  - 新增 `FakeAppIconProvider`，供 deterministic fixture/fallback evidence 使用。
  - 不启动 App，不持久化 icon binary，不输出 icon binary。
- `apps/Blocks/BlocksApp/Features/Privacy/PrivacyAppRowView.swift`
  - 接入 fixed-size app icon / fallback icon，保持布局尺寸稳定。
- `apps/Blocks/BlocksCLI/PrivacyCLIService.swift`
  - CLI typed subject 支持 explicit input / existing policy / opaque subject ref。
  - `--include-sensitive-paths` 继续 unsupported；dangerous action 仅返回 blocked evidence，不解锁系统动作。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py`
  - 增加 R2 accepted scenario id、legacy migration id、CLI typed subject id、icon scenario id。
  - 顶层输出包含 `ui_interaction`、`capture_bridge`、`performance`、`implementation_evidence`。
  - current evidence 指向本 R2 派发与本 R2 开发记录。
  - fail-closed 检查缺顶层 schema、缺 required id、缺实现证据、缺 R2 文档均失败。

## P1 修复说明

1. 旧 exclusion migration
   - 旧 `clipboard.policy.excludedBundleIDs` 迁移为 `privacy_policy_rules` restricted `bundle_id` 规则。
   - marker：`privacy.policy.migratedExcludedBundleIDs.v1`。
   - 成功后写 marker 并移除旧 key；失败不写完成 marker。
   - P13E required scenario：`privacy_policy_legacy_excluded_bundle_migration_004`。

2. CLI typed subject 范围
   - 支持 `app_bundle`、`bundle_id`、`app_path`、`command_path`、`login_item`、`helper`、`launch_label`。
   - `subject_ref` 使用 `sub_v1_<type>_<hash20>`，默认 stdout 低敏。
   - P13E accepted CLI ids 已覆盖：`privacy_cli_app_bundle_004`、`privacy_cli_login_item_004`、`privacy_cli_helper_004`、`privacy_cli_command_path_004`、`privacy_cli_dangerous_blocked_004`、`privacy_cli_low_sensitive_output_004`。

3. P13E 实现级 fail-closed
   - P13E 不再只输出 `_005` 旧场景或只依赖理想 Python fixture。
   - 新增 Swift/CLI 实现证据检查：`PrivacyStore` pathSummary/raw home guard、`ClipboardCapturePolicy.evaluate(...)`、`PrivacyCLIService` typed subject/dangerous block、legacy migration、icon provider。
   - 独立解析脚本验证顶层 schema 和 19 个 R2/accepted id 不缺失。

4. 真实 App icon provider
   - `SystemAppIconProvider` 使用 AppKit `NSWorkspace.shared.icon(forFile:)` 读取本地 `.app` icon。
   - 缺 path / 文件不存在 / icon 无效时返回 stable failed/unsupported fallback。
   - icon 固定尺寸，二进制不输出、不持久化。

## Baseline Red 证据

- R2 实现前运行 P13E + 独立解析：P13E 当时 `ok=true`，但独立解析失败，缺少：
  - `privacy_policy_legacy_excluded_bundle_migration_004`
  - `privacy_cli_app_bundle_004`
  - `privacy_cli_login_item_004`
  - `privacy_cli_helper_004`
  - `privacy_cli_command_path_004`
  - `privacy_cli_dangerous_blocked_004`
  - `privacy_cli_low_sensitive_output_004`
  - 顶层 `implementation_evidence.swift_privacy_store_search` / `swift_capture_policy` / `cli_service` / `legacy_migration` / `icon_provider`

## 验证结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` | PASS，`ok=true`，`failures=[]`，current evidence 指向 `开发记录-Step5-R2-v0.md` |
| 独立解析 P13E 顶层 schema / 12 个 UI+capture accepted id / legacy migration id / 6 个 CLI typed subject id | PASS，`missing_top_or_child=[]`，`missing_required_ids=[]` |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS，`ok=true` |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS，`ok=true` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS；仅有既有 `FloatingPanelSupport.swift` actor warning 和 AppIntents metadata warning |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS；输出 privacy actions list |
| `git diff --check` | PASS |

## 未覆盖项与残余风险

- P2：默认验证没有扫描真实 `/Applications`，也没有读取真实 App icon；真实 icon provider 通过代码路径、构建和 deterministic fixture/static evidence 验证。真实环境边界留给后续人工/项目负责人确认。
- P2：CLI policy set confirm 路径未对真实用户数据库执行；R2 默认验证只允许低敏 fixture / dry-run / static implementation evidence，避免真实 policy mutation。
- P2：hidden app、unreadable app 局部边界仍按 deterministic fixture 和 failed/fallback 状态覆盖，没有做真实系统枚举。

## 安全隐私声明

- 未读取或输出真实剪贴板正文、OCR 原文、真实 App 清单、完整本地路径、图片/base64、邮箱、secret、Authorization header 或凭据。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。
- P13E / 开发记录 / verifier stdout 仅包含低敏 synthetic fixture、opaque subject ref、hash/path summary 和 redacted marker。
