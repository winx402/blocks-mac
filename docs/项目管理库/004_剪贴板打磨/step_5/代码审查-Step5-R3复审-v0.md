# 004_剪贴板打磨 Step 5 R3 代码审查复审 v0

日期：2026-07-07

角色：代码审查

结论：`approve`

本轮只复审 Step 5 R3 单一 P1：legacy excluded bundle migration 在 `subject_ref` 冲突时不得覆盖已有 current policy rule，且 P13E 必须 fail-closed 覆盖该冲突分支。未进入 Step 6，未重新打开 Step 1-4，未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。

## P0 / P1 / P2 Findings

P0：无。

P1：无。R2 遗留的 legacy migration conflict P1 已关闭。

P2 residual：

- P13E 对 legacy conflict 的覆盖仍是静态语义 + 合成场景，不是临时 SQLite repository 的运行时迁移 harness。它已能抓住本次要求的旧 `policy = excluded.policy` 回归，但对语义等价、不同写法的未来 SQL 回归仍建议后续用低敏 temp DB fixture 加强。
- 本轮未对真实用户数据库执行旧 key migration；验证保持 deterministic/static evidence，符合本次禁止真实系统状态变更的边界。

## R3 关闭判断

- `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 已改为 `ON CONFLICT(subject_ref) DO NOTHING`（`apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift:97`-`116`）。legacy migration 只补齐缺失 rule；同一 `subject_ref` 已存在时不会更新 `policy`、`identifier`、`display_name` 或 `updated_at`。
- legacy-only bundle 仍按原路径插入 `restricted bundle_id` rule（`PrivacyPolicyRepository.swift:117`-`128`）。
- 正常 `applyPolicy` 未被误伤，仍在用户/agent 显式 policy set 路径保留 `ON CONFLICT(subject_ref) DO UPDATE SET ... policy = excluded.policy`（`PrivacyPolicyRepository.swift:141`-`188`）。这符合 R3 只修 legacy migration、不破坏正常 mutation 的边界。
- `Step5OneShotMigration` marker 语义未变：repository migration 成功后才写 `privacy.policy.migratedExcludedBundleIDs.v1` 并移除旧 key；失败只清 marker（`apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift:43`-`50`）。
- 未看到旧 `excludedBundleIDs` 回到 AppModel / ClipboardStore / CapturePolicy active fact source；残留仅在 legacy migration input、fixture/baseline、无关 screenshot service 自有排除列表中出现。

## P13E 复核

- 新增 required scenario `privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004` 已列入 accepted policy mutation scenarios（`tools/verification/p13e_clipboard_privacy_policy_checks.py:95`-`98`）。
- 新 conflict scenario 截取 `migrateLegacyRestrictedBundleIDs` 函数体，并断言该函数体不含 `policy = excluded.policy`，且包含 `ON CONFLICT(subject_ref) DO NOTHING` 或 `WHERE NOT EXISTS`（`p13e_clipboard_privacy_policy_checks.py:681`-`731`）。
- P13E 的 code check 只检查 legacy migration 函数体，不误伤正常 `applyPolicy` 的合法 conflict update（`p13e_clipboard_privacy_policy_checks.py:946`-`973`）。
- `implementation_evidence.legacy_migration.conflict_preserves_existing_policy` 被 schema validation 强制要求为 true（`p13e_clipboard_privacy_policy_checks.py:919`-`927`、`1028`-`1056`）。
- current evidence 已指向 R3 派发和 R3 开发记录（`p13e_clipboard_privacy_policy_checks.py:1120`-`1138`）。

本轮复跑 P13E 摘要：

- `ok=True`
- `status=pass`
- `scenario_count=37`
- `failure_count=0`
- `privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004` 存在
- `preserves_existing_current_rule=True`
- `existing_policy_before=allowed`
- `existing_policy_after=allowed`
- `legacy_only_policy_after=restricted`
- `snapshot_allowed_bundle_ids=1`
- `snapshot_restricted_bundle_ids=1`
- `implementation_evidence.legacy_migration.conflict_preserves_existing_policy=True`

## 已运行命令

```bash
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/代码审查-Step5-R2复审-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5-R2复审收敛-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-开发派发-Step5-R3-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-R3-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5-R3验收-v0.md
nl -ba docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md
nl -ba apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift
nl -ba apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift
nl -ba apps/Blocks/BlocksCore/AppDatabase.swift
nl -ba tools/verification/p13e_clipboard_privacy_policy_checks.py
rg -n "policy = excluded\\.policy|ON CONFLICT\\(subject_ref\\)|migrateLegacyRestrictedBundleIDs|DO NOTHING|DO UPDATE SET|privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004|conflict_preserves|legacy_repository_conflict" apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift tools/verification/p13e_clipboard_privacy_policy_checks.py
python3 tools/verification/p13e_clipboard_privacy_policy_checks.py
git diff --check
```

补充静态自查：

```bash
python3 - <<'PY'
from pathlib import Path
text=Path('apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift').read_text()
start=text.index('public func migrateLegacyRestrictedBundleIDs')
end=text.index('public func rule', start)
body=text[start:end]
print('migration_body_contains_policy_update=', 'policy = excluded.policy' in body)
print('migration_body_contains_do_nothing=', 'ON CONFLICT(subject_ref) DO NOTHING' in body)
print('apply_policy_contains_policy_update=', 'policy = excluded.policy' in text[text.index('public func applyPolicy'):])
PY
```

输出确认：

- `migration_body_contains_policy_update=False`
- `migration_body_contains_do_nothing=True`
- `apply_policy_contains_policy_update=True`

## 未运行

- 未运行 `xcodebuild`、built CLI help、真实 CLI mutation 或真实 DB migration。原因：R3 只改 repository SQL / P13E，P13E 与静态复核已覆盖本轮阻塞点；同时本任务要求避免真实系统动作。

## 建议

代码审查建议项目负责人可收敛 R3 并继续 Step 5 最终接受判断。该结论不代表代码审查单独接受 Step 5，也不代表可以绕过项目负责人进入 Step 6。
