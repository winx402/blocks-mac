# 004_剪贴板打磨 Step 5 R3 开发派发 v0

日期：2026-07-07

## 任务

执行 Step 5 R3 定向返工，只关闭 R2 代码审查发现的 1 个 P1：legacy excluded bundle migration 冲突时会覆盖已有 current policy rule，且 P13E 没有覆盖该冲突分支。

R3 完成前不进入 Step 6，不做无关重构。

## 必读材料

- [Step 5 R2 代码审查复审 v0](代码审查-Step5-R2复审-v0.md)
- [Step 5 R2 复审收敛 v0](项目负责人-Step5-R2复审收敛-v0.md)
- [Step 5 R2 开发记录 v0](开发记录-Step5-R2-v0.md)
- [Step 5 R2 项目负责人验收 v0](项目负责人-Step5-R2验收-v0.md)
- [Step 5 技术方案 v1](App架构师-技术方案-v1.md)

## 必须修复

### P1：legacy migration 不得覆盖已有 current policy

当前风险：

- `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 对同一 `subject_ref` 的冲突使用 `policy = excluded.policy`。
- 这会让旧 `clipboard.policy.excludedBundleIDs` 覆盖已经存在的 `privacy_policy_rules`，例如把 existing `allowed` 改成 `restricted`。

修复要求：

1. legacy migration 只能补齐缺失 rule，不得改变已有 current rule 的 `policy`。
2. legacy-only bundle 必须继续迁移为 restricted。
3. 已有 current rule 的 user / agent intent 必须保留。
4. marker 语义保持：repository migration 全部成功后才写 `privacy.policy.migratedExcludedBundleIDs.v1`，失败不写完成 marker，旧 key 保留可重试。
5. 修复范围优先限制在 `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 和 P13E；除非编译或验证要求，不要改 UI、CLI、icon provider、scanner 或 Step 6 范围。

推荐实现：

- 将 legacy migration conflict 策略改为 `ON CONFLICT(subject_ref) DO NOTHING`。
- 如果需要更新 metadata，必须明确保留 existing `policy`，并用 P13E 覆盖。

## P13E 必须补强

新增 fail-closed 场景：

- 预置一个 current rule：同一 bundle subject_ref 的 policy 为 `allowed`。
- legacy old key 同时包含该 bundle 和一个 legacy-only bundle。
- migration 后断言：
  - existing bundle 仍为 `allowed`，不得被改成 `restricted`；
  - legacy-only bundle 被迁移为 `restricted`；
  - snapshot allowed / restricted 集合分别正确；
  - marker 语义不变。

implementation evidence 要能抓住冲突覆盖实现，例如 `policy = excluded.policy` 不应在 legacy migration conflict 分支中继续出现。

## 验证要求

至少运行：

```bash
python3 tools/verification/p13e_clipboard_privacy_policy_checks.py
```

并用独立解析脚本确认：

- P13E `ok=true`；
- 顶层 `ui_interaction`、`capture_bridge`、`performance`、`implementation_evidence` 不缺；
- 12 个 UI/capture accepted id 不缺；
- `privacy_policy_legacy_excluded_bundle_migration_004` 不缺；
- 6 个 CLI typed subject id 不缺；
- 新增 legacy conflict scenario id 不缺；
- `failures=[]`。

同时复跑：

```bash
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

如果 R3 确认只修改 repository SQL/P13E/开发记录，仍建议保留上述完整矩阵，因为本轮已出现 verifier 假 PASS 风险。

## 输出

开发完成后写入：

`docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-R3-v0.md`

开发记录必须包含：

- 改动范围；
- P1 修复说明；
- P13E 新增 conflict scenario id；
- 验证命令结果；
- 未覆盖项和残余风险；
- 明确说明未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。
