# 004_剪贴板打磨 Step 5 R2 代码审查复审 v0

日期：2026-07-07

角色：代码审查

结论：`rework-required`

本轮只复审 Step 5 R2 返工与必要回归，未进入 Step 6，未触发真实 App、真实系统剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。

## P0 / P1 / P2 Findings

P0：无。

P1：未清零。

### P1-1：legacy excluded bundle migration 会覆盖已有 current policy rule，且 P13E 没有覆盖该冲突分支

文件 / 行号：

- `apps/Blocks/BlocksCore/AppDatabase.swift:331`-`348`
- `apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift:97`-`119`
- `apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift:43`-`47`
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:645`-`666`
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:864`-`977`

证据：

- `privacy_policy_rules.subject_ref` 是 primary key（`AppDatabase.swift:331`-`332`）。
- `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 对旧 `clipboard.policy.excludedBundleIDs` 构造 `restricted bundle_id` rule 后，使用 `ON CONFLICT(subject_ref) DO UPDATE SET ... policy = excluded.policy`（`PrivacyPolicyRepository.swift:97`-`119`）。这意味着只要同一 `subject_ref` 已存在，legacy migration 会把现有 policy 覆盖为 `restricted`，同时刷新 `updated_at`。
- `Step5OneShotMigration` 在 repository migration 不抛错后写 marker 并移除旧 key（`Step5OneShotMigration.swift:43`-`47`）。因此该覆盖不会被后续 marker 逻辑阻止。
- R2 派发明确要求旧 key 只作为 one-shot migration input，新 `privacy_policy_rules` / `PrivacyPolicySnapshot` 才是 active fact source；本次用户也特别要求复核 legacy migration 是否会覆盖用户已存在规则。当前实现会让 legacy 输入压过已经存在的 current rule。
- P13E 的 `privacy_policy_legacy_excluded_bundle_migration_004` 是 Python 合成 normalize / dedupe / subject_ref 场景（`p13e...py:645`-`666`），并没有建立“已存在 allowed rule + legacy old key”的 fixture，也没有断言 migration 必须 preserve existing rule。
- P13E 的 implementation evidence 只检查 `migrateLegacyRestrictedBundleIDs`、`PrivacyPolicyStatus.restricted`、marker 字符串等 token / presence（`p13e...py:864`-`977`）。本轮 P13E 仍 `ok=true`，说明 gate 没有 fail-closed 地覆盖这个实际代码缺陷。

影响：

- clean first-run 上，旧 exclusion 正常迁移为 restricted 的主路径已经实现；但在已有 current rule 的场景下，legacy migration 会覆盖用户或 agent 已经写入的新规则。
- 具体风险包括：用户已把同一 bundle 设置为 `allowed`，或 pre-release / retry / crash-recovery 状态下 DB 已有 rule 但 marker 未完成，下一次 migration 会重新把它改成 `restricted`。
- 这是隐私 policy fact source 的优先级错误：legacy key 应是迁移输入，不应覆盖已经存在的 current repository rule。

建议修复范围：

- 调整 `migrateLegacyRestrictedBundleIDs` 的 conflict 策略，避免覆盖已有 rule 的 `policy`。可选口径：
  - `ON CONFLICT(subject_ref) DO NOTHING`，legacy 只补齐缺失规则；
  - 或冲突时只补低敏 display metadata，但保留 existing `policy` / user intent。
- 保持现有事务边界和 marker 语义：repository 写入全部成功后再写 `privacy.policy.migratedExcludedBundleIDs.v1`，失败不写完成 marker，旧 key 保留可重试。
- P13E 增加 fail-closed 场景：预置同一 `subject_ref` 为 `allowed`，再输入旧 `clipboard.policy.excludedBundleIDs`，migration 后断言 existing rule 仍为 `allowed`，新增 legacy-only bundle 才变为 `restricted`；同时 snapshot 验证两者分别落入 allowed/restricted set。

## 上一轮 4 个 P1 关闭判断

1. 旧 `clipboard.policy.excludedBundleIDs` migration：主路径已实现，但冲突覆盖 current rule，未完全关闭，仍阻塞。
2. CLI typed subject：代码复核认为已关闭。`PrivacyPolicySubjectType` 覆盖 `app_bundle`、`bundle_id`、`app_path`、`command_path`、`login_item`、`helper`、`launch_label`；`PrivacyCLIService` 仅支持 explicit input / existing policy / opaque ref，不做真实系统枚举、PATH scan、命令执行或 App launch。
3. P13E fail-closed：有明显进步，顶层 schema、accepted id、`implementation_evidence` 已存在；但 legacy migration 仍可假 PASS，未完全关闭。
4. 真实 App icon provider：代码复核认为主要求已关闭。`SystemAppIconProvider` 使用 `NSWorkspace.shared.icon(forFile:)` 读取本地图标，缓存和失败 fallback 存在，没有持久化或输出 icon binary。

## P2 Residual

- `PrivacyAppRowView` 直接调用 `SystemAppIconProvider.icon(for:)`（`PrivacyAppRowView.swift:80`），没有完全通过 `PrivacyStore` 注入的 `AppIconProviding` 渲染 icon。当前真实 UI 路径可工作，但 fake provider 对 row image 分支的验证有限。
- `SystemAppIconProvider` 的 static cache / failed set 未显式标注 `@MainActor` 或 actor 隔离（`AppIconProvider.swift:8`-`40`）。目前调用路径来自 `@MainActor PrivacyStore` 和 SwiftUI body，暂未见实际并发问题；若后续改为后台扫描，需要收口。
- P13E 对 CLI / icon / capture 的 implementation evidence 仍以静态语义检查为主，未运行真实 Swift harness 或 built CLI fixture。因本轮代码审查未发现 CLI typed subject / icon 主路径 P1，暂列为 P2；但 legacy migration 场景必须补成可抓真实冲突的 hard gate。
- 本轮未触发真实 UI、真实 `/Applications` 全量扫描、真实 VoiceOver、真实 icon 视觉验收或真实用户 DB mutation。

## 关键证据

- `PrivacyPolicySnapshot.match` 先按 path hash，再按 bundle id 判定，且 `ClipboardCapturePolicy.evaluate` 消费 snapshot（`PrivacyPolicyModels.swift:171`-`188`，`ClipboardCapturePolicy.swift:38`-`55`）。
- `AppModel` 从 `privacyStore.policySnapshot` 构造 capture policy（`AppModel.swift:213`-`217`）；未看到旧 `excludedBundleIDs` 回到 AppModel / ClipboardStore / CapturePolicy active fact source。
- `ClipboardLiveCaptureService` 写入 `bundlePathHash` / `bundlePathSummary` / `sourceDirectory`（`ClipboardLiveCaptureService.swift:274`-`285`），path scoped policy 能在 capture snapshot 中生效。
- `PrivacySubjectResolver` 生成 `sub_v1_<type>_<hash20>` opaque subject ref，path 类型 identifier 使用 hash（`PrivacySubjectResolver.swift:3`-`23`、`63`-`87`）。
- `PrivacyCLIService` 阻断 `--include-sensitive-paths`，`policy set` 要求 `--dry-run` 或 `--confirm`，dangerous action 只返回 blocked evidence（`PrivacyCLIService.swift:4`-`14`、`103`-`131`、`140`-`156`）。
- target membership 抽查显示 Step 5 新增 Core/App/CLI 文件已在 Xcode project 中登记。

## 已运行命令

```bash
nl -ba AGENTS.md
nl -ba agents/代码审查.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/代码审查-Step5开发复审-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5开发复审收敛-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-开发派发-Step5-R2-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-R2-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5-R2验收-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md
nl -ba apps/Blocks/BlocksCore/PrivacyPolicyModels.swift
nl -ba apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift
nl -ba apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift
nl -ba apps/Blocks/BlocksCore/PrivacySubjectResolver.swift
nl -ba apps/Blocks/BlocksCore/PrivacyPathSanitizer.swift
nl -ba apps/Blocks/BlocksCLI/PrivacyCLIService.swift
nl -ba apps/Blocks/BlocksApp/Features/Privacy/PrivacyStore.swift
nl -ba apps/Blocks/BlocksApp/Features/Privacy/AppIconProvider.swift
nl -ba apps/Blocks/BlocksApp/Features/Privacy/PrivacyAppRowView.swift
nl -ba apps/Blocks/BlocksApp/Features/Privacy/PrivacySettingsPane.swift
nl -ba apps/Blocks/BlocksCore/PrivacyAppScanner.swift
nl -ba apps/Blocks/BlocksCore/ClipboardCapturePolicy.swift
nl -ba apps/Blocks/BlocksApp/App/AppModel.swift
nl -ba apps/Blocks/BlocksApp/Services/ClipboardLiveCaptureService.swift
nl -ba apps/Blocks/BlocksCore/ClipboardRepository.swift
rg -n "PrivacyPolicySnapshot|excludedBundleIDs|excludedBundleIdentifiers|capturePolicy|ClipboardCapturePolicy|privacySnapshot|canonicalPath|pathHash" apps/Blocks -g '*.swift'
rg -n "PrivacyPolicyModels.swift|PrivacyPolicyRepository.swift|PrivacySubjectResolver.swift|PrivacyAppScanner.swift|PrivacyPathSanitizer.swift|ClipboardCapturePolicy.swift|PrivacySettingsPane.swift|PrivacyStore.swift|AppIconProvider.swift|PrivacyAppRowView.swift|PrivacyCLIService.swift" apps/Blocks/Blocks.xcodeproj/project.pbxproj
python3 tools/verification/p13e_clipboard_privacy_policy_checks.py
git status --short
```

P13E 本轮代码审查复跑摘要：

- `ok=True`
- `status=pass`
- `scenario_count=36`
- `failure_count=0`
- 顶层存在 `ui_interaction` / `capture_bridge` / `implementation_evidence` / `performance` / `scenarios` / `failures`
- `implementation_evidence.cli_service.typed_subjects` 覆盖 7 类 subject
- `implementation_evidence.legacy_migration.repository_write=true`

未运行：

- 未运行 `xcodebuild`、built CLI help 或真实 CLI mutation。原因：静态代码复核和 P13E 复跑已定位 P1，继续运行 build/CLI 对该阻塞项没有增量证明；同时本任务要求避免不必要系统触达。

## 未覆盖风险

- 未做真实 App UI / 真实剪贴板 / 真实 `/Applications` 扫描 / provider / Keychain / TCC / System Settings / Finder / App launch / 真实系统枚举验证。
- 未替代测试/质量做完整行为验收；本结论只覆盖 R2 代码审查职责。

## 建议

建议项目负责人要求 R3 返工，至少修复 legacy migration conflict 策略并补 P13E 冲突场景。修复后再做定向复审；在 P1 清零前不建议最终接受 Step 5，也不建议进入 Step 6。
