# 004_剪贴板打磨 Step 5 R2 复审收敛 v0

日期：2026-07-07

## 结论

结论：`rework-required`。

项目负责人接受代码审查 Step 5 R2 复审结论。R2 已关闭 CLI typed subject、真实 App icon provider 等主要实现缺口，但 legacy excluded bundle migration 仍存在 P1：迁移冲突时会覆盖已有 current policy rule，且 P13E 未覆盖该冲突分支。该问题属于 privacy policy fact source 的优先级错误，不能降级为 P2 residual。

在 R3 返工完成、项目负责人验收和代码审查定向复审前，Step 5 不最终接受，Step 6 不启动。

## 输入材料

- [Step 5 R2 开发记录 v0](开发记录-Step5-R2-v0.md)
- [Step 5 R2 项目负责人验收 v0](项目负责人-Step5-R2验收-v0.md)
- [Step 5 R2 代码审查复审 v0](代码审查-Step5-R2复审-v0.md)

## 复审结论收敛

代码审查发现的 P1：

- `PrivacyPolicyRepository.migrateLegacyRestrictedBundleIDs` 使用 `ON CONFLICT(subject_ref) DO UPDATE SET ... policy = excluded.policy`。
- 当同一 `subject_ref` 已存在 current rule，例如用户或 agent 已设置为 `allowed`，legacy migration 会将其覆盖为 `restricted`。
- `Step5OneShotMigration` 在 repository 不抛错后写 marker 并移除旧 key，因此该覆盖会被视为迁移成功。
- P13E 当前 legacy migration 场景没有覆盖“已有 allowed rule + legacy old key”的冲突分支，仍可能假 PASS。

项目负责人判断：

- 该问题影响 Step 5 的核心事实源优先级。legacy key 只能作为迁移输入，不应压过已经存在的 `privacy_policy_rules`。
- 该问题可能发生在 pre-release、retry、crash-recovery、或用户/agent 已写入 current rule 但 old key 尚未清理的状态。
- 该问题不需要回用户澄清；按保守且一致的迁移语义处理即可。

## R3 返工口径

R3 只修复一个 P1：

1. legacy migration 冲突策略必须保留已有 current rule 的 policy。
2. legacy-only bundle 仍应迁移为 restricted。
3. marker 语义保持不变：repository 写入成功后才写 `privacy.policy.migratedExcludedBundleIDs.v1`，失败不写完成 marker，旧 key 保留可重试。
4. P13E 必须新增 fail-closed 场景：预置同一 `subject_ref` 为 `allowed`，再输入旧 `clipboard.policy.excludedBundleIDs`，migration 后该 rule 仍为 `allowed`；另一个只存在于 legacy old key 的 bundle 才进入 `restricted`。
5. P13E implementation evidence 需要能抓住 `policy = excluded.policy` 这类冲突覆盖实现，不能只做 token presence。

可选实现口径：

- 推荐 `ON CONFLICT(subject_ref) DO NOTHING`，legacy migration 只补齐缺失规则。
- 如选择 conflict update，只能补低敏 display metadata，不能改变 existing `policy`、`identifier`、`subject_type` 或破坏 existing user intent。

## 下一步

派发开发执行 Step 5 R3 定向返工。R3 完成后，项目负责人先做独立验收，再派代码审查做定向复审。R3 未关闭 P1 前，不派 UI/测试/安全复审，不进入 Step 6。
