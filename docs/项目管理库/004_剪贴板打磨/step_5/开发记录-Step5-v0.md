# 004_剪贴板打磨 Step 5 开发记录 v0

日期：2026-07-07
角色：开发
结论：DONE_WITH_EVIDENCE

## 范围

本轮只处理 Step 5：隐私页真实 App 清单、UI policy mutation、CLI typed subject 管理、capture policy 接入和 P13E fail-closed 门禁。未进入 Step 6，未重做 Step 1-4 已验收范围。

工作区在本轮前已有 Step 1-4 未提交文件；本记录只描述 Step 5 相关改动，未回滚或整理其他历史改动。

## 主要改动文件

- `tools/verification/p13e_clipboard_privacy_policy_checks.py`
- `apps/Blocks/BlocksCore/PrivacyPathSanitizer.swift`
- `apps/Blocks/BlocksCore/PrivacyPolicyModels.swift`
- `apps/Blocks/BlocksCore/PrivacySubjectResolver.swift`
- `apps/Blocks/BlocksCore/PrivacyAppScanner.swift`
- `apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift`
- `apps/Blocks/BlocksApp/Features/Privacy/AppIconProvider.swift`
- `apps/Blocks/BlocksApp/Features/Privacy/PrivacyStore.swift`
- `apps/Blocks/BlocksApp/Features/Privacy/PrivacyAppRowView.swift`
- `apps/Blocks/BlocksApp/Features/Privacy/PrivacySettingsPane.swift`
- `apps/Blocks/BlocksCLI/PrivacyCLIService.swift`
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
- `apps/Blocks/BlocksCore/AppDatabase.swift`
- `apps/Blocks/BlocksCore/ClipboardCapturePolicy.swift`
- `apps/Blocks/BlocksCore/ClipboardRecorderFoundation.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository.swift`
- `apps/Blocks/BlocksApp/App/AppModel.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Settings/SettingsShellView.swift`
- `apps/Blocks/BlocksApp/Services/ClipboardLiveCaptureService.swift`
- `apps/Blocks/BlocksCLI/main.swift`
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `tools/verification/p8i_settings_clipboard_system_checks.py`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`

## 关键实现决策

- 新增 `PrivacyPolicySnapshot` / `PrivacyPolicyRule` / `PrivacySubjectRef`，并通过 `PrivacyPolicyRepository` 持久化到 `privacy_policy_rules`。数据库 schema 升到 v5；Step 4 的 v4 migration 仍保留，P13D 已调整为接受 `userVersion >= 4`。
- `ClipboardCapturePolicy` 改为消费 `PrivacyPolicySnapshot`。匹配优先级为 app path restricted、app path allowed、bundle restricted、bundle allowed、default allow；capture 判定不读取 payload、不写 policy、不访问网络。
- 旧 `excludedBundleIDs` / `excludedBundleIdentifiers` 不再作为 `AppModel`、`ClipboardStore` 或 capture policy 的 active fact source。旧 key 可留在历史文档或 localization，不作为 Step 5 当前事实源。
- `PrivacyAppScanner` 只扫描受限根目录的 `.app` bundle，跳过 symlink，输出 display name、bundle id、source directory、policy status、identity issue、path hash/path summary；UI 和验证输出不展示完整本地路径。
- `PrivacyStore` 成为隐私页 UI mutation 状态和 snapshot 的 feature-level 入口，支持搜索、筛选、duplicate bundle confirmation、saving/saved/failed/retry/cancel/unsupported 状态。
- `PrivacySettingsPane` 接入 Settings 的 `clipboardPrivacy` 路由；旧 exclusion list UI 退出 active route。
- `PrivacyCLIService` 提供 `privacy.subjects.list`、`privacy.subjects.resolve`、`privacy.policy.get`、`privacy.policy.set`、`privacy.action.blocked`。首版不支持 `--include-sensitive-paths`；`--confirm` 只确认本 App policy mutation，不解锁 TCC reset、系统设置或命令执行。
- `ClipboardLiveCaptureService` 只记录前台 App 的低敏 source metadata：bundle id、path hash、path summary、source directory；不保存完整 bundle path。

## P13E baseline red / green

- Baseline red：先新增 `p13e_clipboard_privacy_policy_checks.py` 后运行，当前基线缺 Privacy model/repository/scanner/store/CLI target membership，capture policy 未接 `PrivacyPolicySnapshot`，AppModel/Store/CapturePolicy 仍有旧 excluded active path，Settings 仍走旧 privacy route，CLI privacy 入口缺失；脚本以 `ok=false` 失败，符合 P13E-first。
- Implementation green：实现后 `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` 返回 `ok=true`。stdout 包含 required categories：`ui_interaction`、`cli_typed_subject`、`capture_bridge`、`performance`；`failures=[]`；`sensitive_output_summary` 中 root/home/users/email/auth/secret 均为 false。
- P13E value-level 证据包括 synthetic app list/search/filter/duplicate confirmation/mutation states、typed CLI subject resolve/get/set/dry-run/confirm、dangerous action blocked、snapshot-backed capture allow/deny/default/path precedence、large list first-page performance。

## 验证结果

以下命令均在项目根目录串行运行，未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch 或真实系统状态变更。

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py` | PASS，`ok=true`，含 `ui_interaction` / `capture_bridge` / `performance` |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS，`ok=true`，schema v5，输出低敏 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS，`ok=true` |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS，`ok=true` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS，`** BUILD SUCCEEDED **` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS，`** BUILD SUCCEEDED **` |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS，输出包含 `privacy.subjects.list`、`privacy.subjects.resolve`、`privacy.policy.get`、`privacy.policy.set`、`privacy.action.blocked` |
| `git diff --check` | PASS，本记录写入后复跑 |

## 未覆盖项和残余风险

- P0：0。
- P1：0。
- P2：未做真实 `/Applications` 环境下的手工 UI 视觉验收；P13E 使用 synthetic temp roots 和 deterministic fixtures 覆盖 required scenarios。
- P2：未触发真实前台 App capture；capture bridge 通过低敏 synthetic `SourceApp` 和 `PrivacyPolicySnapshot` 断言。
- P2：构建输出仍有项目既有 Xcode destination 选择提示；未观察到 Step 5 编译错误。

## 安全隐私声明

本轮未保存或读取真实敏感凭据，未访问 Keychain，未调用 provider，未读取真实剪贴板正文，未上传图片/OCR/base64，未触发 TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。P13E 使用 synthetic fixtures/temp roots；验证与开发记录不输出完整本地路径、真实 App 名、邮箱、secret、Authorization header 或剪贴板 payload。
