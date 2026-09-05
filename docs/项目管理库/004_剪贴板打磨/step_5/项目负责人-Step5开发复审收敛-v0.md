# Step 5 开发复审收敛 v0

日期：2026-07-07
角色：项目负责人
对象：`004_剪贴板打磨` Step 5 开发代码审查
状态：rework-required

## 1. 输入

- [开发记录 Step5 v0](开发记录-Step5-v0.md)
- [开发记录 Step5 R1 v0](开发记录-Step5-R1-v0.md)
- [项目负责人 Step5 R1 验收 v0](项目负责人-Step5-R1验收-v0.md)
- [代码审查 Step5 开发复审 v0](代码审查-Step5开发复审-v0.md)

## 2. 收敛结论

接受代码审查结论：Step 5 当前仍为 `rework-required`，不进入测试/质量、UI/交互、安全合规定向复审，也不进入 Step 6。

R1 已关闭 P13E 顶层 schema 和 12 个 accepted `_004` scenario id 对齐问题；但代码审查指出的 4 个 P1 属于实现范围缺口和 hard gate 假 PASS 风险，不能降级为 P2 或 residual。

## 3. 必须返工的 P1

### P1-1：旧 excluded bundle id 未迁移

必须补齐：

- 读取旧 `clipboard.policy.excludedBundleIDs`。
- 迁移为新 `privacy_policy_rules` 中的 `restricted bundle_id` policy rule。
- 使用 `privacy.policy.migratedExcludedBundleIDs.v1` marker。
- 成功后再写 marker；失败不得标记完成。
- P13E 增加 `privacy_policy_legacy_excluded_bundle_migration_004` 并验证 old key -> repository rule -> snapshot restricted set。

### P1-2：CLI typed subject 范围不足

必须补齐：

- `PrivacyPolicySubjectType` 覆盖 `app_bundle`、`bundle_id`、`app_path`、`command_path`、`login_item`、`helper`、`launch_label`。
- CLI `subjects resolve` / `policy get` / `policy set` 支持这些 typed subject 的 explicit input / existing policy / synthetic fixture，不做真实系统枚举、不执行命令、不扫描 PATH。
- `subject_ref` 使用稳定 opaque / hash 格式，默认输出不得暴露完整路径或真实 command arguments。
- P13E 覆盖 accepted CLI `_004` 场景，至少包括 app bundle、login item、helper、command path 和 dangerous blocked。

### P1-3：P13E 仍不能证明实际 Swift/CLI 实现

必须补齐：

- P13E 不能只用 Python hardcoded ideal fixture 证明行为。
- `privacy_app_search_fields_004` 必须证明 Swift `PrivacyStore` 搜索覆盖 `pathSummary`，并且 raw home path 不命中。
- capture scenarios 必须证明 `ClipboardCapturePolicy.evaluate(...)` 对真实 `PrivacyPolicySnapshot` 的输出。
- CLI scenarios 必须证明 `PrivacyCLIService` / built CLI 对 typed subject parse、dry-run、confirm、dangerous blocked 的真实输出。
- legacy migration scenario 必须证明旧 key 写入新 repository rule。
- icon scenarios 必须证明真实 provider 与 fake/fallback 分支都存在且不会输出 icon binary。

### P1-4：真实 App icon provider 未实现

必须补齐：

- `SystemAppIconProvider` 使用 AppKit / NSWorkspace 或等价 API 读取本地 `.app` 图标。
- 不启动 App、不请求权限、不把 icon binary 写入日志、P13E、开发记录或验收记录。
- 提供 stable fallback / failed state，并保持固定尺寸。
- P13E 使用 fake provider 覆盖 loaded / failed / fallback。

## 4. 建议一并处理的 P2

以下不单独阻塞 R2，但若和 P1 同区域改动重合，建议一并修：

- hidden app edge case：scanner 不应因 `.skipsHiddenFiles` 直接漏掉需要展示/标记的 hidden app。
- `PrivacyStore.retryLastMutation()` 应能重放失败 mutation plan，而不是只把状态改成 `.retry`。
- `PrivacyStore.loadApps()` 失败时不应直接清空已有 `apps`，避免 refresh 白屏。
- `PrivacyPathSanitizer.pathSummary(for:)` 不应默认输出 `/Applications` / `/System/Applications` 完整路径样式。
- scanner 对 unreadable directory 不应完全静默吞掉 partial issue。

## 5. 下一步

派发开发执行 Step 5 R2 返工。R2 完成后，项目负责人先独立验收；验收通过后重新派代码审查。代码审查 P0/P1 清零前，不派测试/质量、UI/交互、安全合规定向复审。
