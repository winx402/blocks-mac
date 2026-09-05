# 代码审查 - Step 5 开发复审 v0

日期：2026-07-07

角色：代码审查

结论：`rework-required`

建议项目负责人：Step 5 当前不建议接受。R1 针对 P13E 顶层 `ui_interaction` / `capture_bridge` / `performance` schema 和 12 个 accepted `_004` scenario id 的返工已关闭；但 Step 5 仍存在实现范围缺口，并且 P13E 仍不能 fail-closed 地证明这些实现已完成。

## P0 / P1 / P2 结论

P0：无。

P1：未清零。发现 4 个阻塞项：

- P1-1：旧 `clipboard.policy.excludedBundleIDs` one-shot migration 未实现，旧 exclusion 配置会在旧 UI / active fact source 退出后丢失。
- P1-2：CLI typed subject 只实现 `bundle_id` / `app_path`，缺 `app_bundle` / `login_item` / `helper` / `launch_label` / `command_path` 的 Step 5 广义对象管理。
- P1-3：P13E 仍是 synthetic / token-heavy gate，未真正验证 Swift UI / scanner / capture policy / CLI 实现，当前 PASS 不能支撑 Step 5 接受。
- P1-4：隐私页真实 App 图标未实现；当前 UI 只显示 SF Symbols，并没有读取系统 App icon 或提供真实/fallback 图标流。

P2：有，见下文 residual。

## P1 Findings

### P1-1：旧 excluded bundle id 没有迁移到新 policy rule，用户既有限制会丢失

证据：

- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-开发派发-Step5-v0.md:31` 明确要求旧 `excludedBundleIDs` active fact source 退出时，旧值一次性迁移为 `restricted bundle_id` policy rule。
- `docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md:156`-`160` 明确旧 `clipboard.policy.excludedBundleIDs` 只作为 one-shot migration input，迁移后写 marker `privacy.policy.migratedExcludedBundleIDs.v1`。
- `apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift:15`-`23` 只运行旧 bottom height / shortcut migration，然后写 `step5.oneShotMigration.v0.completed`。
- `apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift:26`-`65` 只包含 bottom height 与 shortcut rewrite；没有读取 `clipboard.policy.excludedBundleIDs`，没有打开 `PrivacyPolicyRepository`，没有写 `restricted bundle_id` rule，也没有 `privacy.policy.migratedExcludedBundleIDs.v1` marker。
- `apps/Blocks/BlocksCore/AppDatabase.swift:327`-`350` 只创建 `privacy_policy_rules` 表；UserDefaults 旧 key 无法在 DB migration 中自然迁移。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:791`-`799` 只输出 `legacy_excluded_bundle_ids_inactive_005`，证明旧 active path 退出；没有 `privacy_policy_legacy_excluded_bundle_migration_004` 的值级 fixture 来证明旧值已迁移。

影响：

- 已配置旧 exclusion 的用户升级到 Step 5 后，旧 UI / active source 退出，但新 `PrivacyPolicySnapshot` 不包含这些 restricted bundle id。
- live capture 会按 default allow 继续捕获这些来源，违反隐私预期。
- P13E 当前能 PASS，说明 hard gate 未覆盖该数据迁移。

必须修改：

- 增加独立 privacy migration，使用 marker `privacy.policy.migratedExcludedBundleIDs.v1`，读取旧 `clipboard.policy.excludedBundleIDs`，规范化 bundle id 后通过 `PrivacyPolicyRepository` 写入 `restricted bundle_id` rules。
- migration 成功后再写 marker；失败不得标记完成。多条规则应避免部分提交或至少可重试且有低敏错误。
- P13E 增加并要求 `privacy_policy_legacy_excluded_bundle_migration_004`：旧 UserDefaults fixture -> migration -> repository rules -> snapshot restricted set，且 AppModel / capture policy 不读旧 key。

### P1-2：CLI typed subject 范围未实现，Step 5 CLI 广义对象管理缺失

证据：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md:314`-`318` 要求 `app_bundle` / `bundle_id` / `app_path` / `command_path` / `login_item` / `helper` / `launch_label` 的 typed subject 边界。
- `docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md:82`-`89` 明确 `PrivacyPolicySubjectType` 应包含 7 类。
- `apps/Blocks/BlocksCore/PrivacyPolicyModels.swift:3`-`8` 实际只包含 `bundleID` 与 `appPath`。
- `apps/Blocks/BlocksCLI/PrivacyCLIService.swift:61`-`70` 的 `subjects resolve` 只接受 enum 中已有类型，并且除 `bundleID` 外直接返回 `app_path_resolve_requires_ui`。
- `apps/Blocks/BlocksCLI/PrivacyCLIService.swift:165`-`185` 的 `policy set` 只从 `bundle_id:` / `app_path:` 两种 `subject_ref` 还原 subject。
- `apps/Blocks/BlocksCore/PrivacySubjectResolver.swift:4`-`15` 生成 `bundle_id:<identifier>` / path hash 形式的 ref；没有技术方案要求的 `sub_v1_<type>_<hash>` opaque ref，`bundle_id` ref 直接暴露 primary identifier。

影响：

- `privacy_cli_app_bundle_004`、`privacy_cli_login_item_004`、`privacy_cli_helper_004`、`privacy_cli_command_path_004` 等技术方案 required scenario 对应能力不存在。
- CLI 首版退化为 bundle/path policy editor，未完成 Step 5 “CLI 广义对象管理”目标。
- `subject_ref` 不是 accepted opaque/hash contract，后续 agent 依赖会固化错误引用格式。

必须修改：

- 扩展 `PrivacyPolicySubjectType` 到技术方案 v1 的 7 类，并在 resolver / repository / CLI JSON 中保持统一 subject model。
- `subjects resolve` 至少支持显式 typed input / existing policy / synthetic fixture 允许的 login item、helper、launch label、command path，不做真实系统枚举、不执行命令、不扫描 PATH。
- `policy get/set` 能处理这些 subject_ref；ambiguous / unsupported 不 mutation。
- subject_ref 改为稳定 opaque / hash 格式；默认输出不得用完整 path 或真实 command arguments。
- P13E 用 accepted CLI `_004` 场景覆盖这些类型，不能只用当前 `_005` bundle id happy path。

### P1-3：P13E 仍不能证明实际实现，存在 hard gate 假 PASS

R1 关闭情况：

- 本轮运行 P13E，结果 `exit=0`、`ok=true`。
- 顶层包含 `ui_interaction`、`capture_bridge`、`performance`。
- 12 个 accepted UI / capture `_004` scenario id 均存在。

但 P13E 仍不是足够的 Step 5 hard gate。

证据：

- `tools/verification/p13e_clipboard_privacy_policy_checks.py:212`-`338` 的 UI interaction evidence 来自 Python 内置 `make_synthetic_apps()` 与本地 `matches(...)`，没有调用 `PrivacyStore.visibleApps`、`PrivacySettingsPane` 或 Swift row model。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:214` 的 synthetic `search_fields` 不包含 `path_summary`；而 `docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md:497` 明确 `privacy_app_search_fields_004` 必须覆盖 path summary。
- 实际实现同样缺 path summary search：`apps/Blocks/BlocksApp/Features/Privacy/PrivacyStore.swift:43`-`50` 只搜索 display name、bundle id、source directory、policy status、identity issue，没有 `app.pathSummary`。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:341`-`455` 的 capture bridge evidence 是 Python `capture_decision(...)`，没有调用 `ClipboardCapturePolicy.evaluate(...)`。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:458`-`522` 的 CLI evidence 是 hardcoded dict，没有运行 `BlocksCLI` 或 `PrivacyCLIService`。
- `tools/verification/p13e_clipboard_privacy_policy_checks.py:724`-`746` 的 code checks 多为 token presence，例如包含 `PrivacyPolicySnapshot`、`maxDepth`、`--confirm`、`tcc_reset` 即通过；无法识别 P1-1/P1-2 这类实现缺口。

影响：

- 当前 P13E 可以 `ok=true`，但实际实现仍缺旧 exclusion migration、CLI typed subject、path summary search、真实 icon 读取等 required behavior。
- 这正是 Step 5 hard gate 要防的假 PASS 类型；不能把当前 P13E PASS 当作 Step 5 完成证据。

必须修改：

- P13E 应通过低敏 Swift fixture / test harness 或更严格的静态语义检查验证实际 Swift 实现，而不是仅运行 Python 重写的理想逻辑。
- 至少补上以下 fail-closed 断言：
  - `privacy_app_search_fields_004` 必须证明 Swift `PrivacyStore` 搜索包含 `pathSummary`，同时 raw home path 不命中。
  - capture scenarios 必须证明 `ClipboardCapturePolicy.evaluate(...)` 对 `PrivacyPolicySnapshot` 的真实输出。
  - CLI scenarios 必须证明 CLI service 对各 typed subject 的真实 parse / dry-run / confirm / dangerous blocked 输出。
  - legacy migration scenario 必须证明旧 key 写入新 repository rule。
  - icon scenarios 必须证明 App icon provider 有真实 provider 与 deterministic fake/fallback 分支。

### P1-4：隐私页没有读取真实系统 App icon

证据：

- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-开发派发-Step5-v0.md:29` 要求 App 侧 icon provider 与 in-memory cache，图标失败有 fallback。
- `docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md:202`-`203` 要求 `SystemAppIconProvider` 使用 AppKit / NSWorkspace 读取 icon，`FakeAppIconProvider` 用于 fixture / preview。
- `apps/Blocks/BlocksApp/Features/Privacy/AppIconProvider.swift:8`-`11` 的 `SystemAppIconProvider` 只根据 `pathSummary.isEmpty` 返回 `.loaded` / `.unsupported`，没有调用 `NSWorkspace`、没有读取 `NSImage`、没有 cache，也没有失败/fallback 分支。
- `apps/Blocks/BlocksApp/Features/Privacy/PrivacyAppRowView.swift:15`-`18` 使用 SF Symbol `Image(systemName: iconName)`，不是实际 App 图标。

影响：

- Step 5 的 R9 目标“默认展示真实 `.app`，使用真实系统 App 图标”未实现。
- icon failed / fallback / async 不改变布局排序的验收无法被真实代码支撑。

必须修改：

- 增加真实 icon 读取与缓存路径，例如使用 `NSWorkspace.shared.icon(forFile:)` 或等价 AppKit API，仅读取本地 icon、不启动 App、不请求权限。
- row model 需要能携带可渲染 icon 或 stable fallback；失败时显示 fallback 并保留固定尺寸。
- P13E 使用 fake provider 覆盖 loaded / failed / fallback，不把 icon binary 输出到 evidence。

## P2 Residual / 建议修复项

1. Hidden app edge case 当前不成立：`PrivacyAppScanner.swift:63`-`67` 使用 `.skipsHiddenFiles`，且 `PrivacyIdentityIssue` 没有 hidden 状态；技术方案 `privacy_app_hidden_004` 要求 hidden app 可展示 / 标记。建议在 P1 返工时一并修。
2. `PrivacyStore.retryLastMutation()` 只把状态设为 `.retry`（`PrivacyStore.swift:130`-`132`），没有保存并重放失败的 mutation plan；失败态 Retry 当前不可恢复。
3. `PrivacyStore.loadApps()` 失败时清空 `apps`（`PrivacyStore.swift:81`-`85`），违反 refresh 有旧结果时不白屏的性能/稳定性口径。
4. `PrivacyPathSanitizer.pathSummary(for:)` 对 `/Applications` / `/System/Applications` 返回绝对路径（`PrivacyPathSanitizer.swift:19`-`29`），与默认不输出完整路径清单的口径偏紧；建议改成 source directory + file-name summary。
5. scanner 对 unreadable directory 使用 `try? ... ?? []` 静默吞掉（`PrivacyAppScanner.swift:63`-`67`），没有 partial issue，后续 UI 会像最终结果一样展示。

## 已运行命令

```bash
python3 - <<'PY'
import json, subprocess, sys
proc = subprocess.run([sys.executable, 'tools/verification/p13e_clipboard_privacy_policy_checks.py'], cwd='.', text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
data = json.loads(proc.stdout)
print('exit=', proc.returncode)
print('ok=', data.get('ok'))
print('top_keys=', ','.join(sorted(data.keys())))
print('ui_keys=', sorted(data.get('ui_interaction', {}).keys()))
print('capture_keys=', sorted(data.get('capture_bridge', {}).keys()))
print('perf_keys=', sorted(data.get('performance', {}).keys()))
print('missing_accepted=', ...)
print('scenario_count=', len({s.get('scenario_id') for s in data.get('scenarios', [])}))
print('stdout_bytes=', len(proc.stdout.encode('utf-8')))
PY
rg -n "appBundle|loginItem|launchLabel|commandPath|case helper|case appPath|case bundleID" apps/Blocks/BlocksCore/PrivacyPolicyModels.swift apps/Blocks/BlocksCore/PrivacySubjectResolver.swift apps/Blocks/BlocksCLI/PrivacyCLIService.swift
rg -n "clipboard\\.policy\\.excludedBundleIDs|privacy\\.policy\\.migratedExcludedBundleIDs|PrivacyPolicyRepository|applyPolicy|restricted|bundle" apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift tools/verification/p13e_clipboard_privacy_policy_checks.py
rg -n "SystemAppIconProvider|NSWorkspace\\.shared\\.icon|icon\\(forFile|NSImage|FakeAppIconProvider|iconState" apps/Blocks/BlocksApp/Features/Privacy tools/verification/p13e_clipboard_privacy_policy_checks.py docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md
rg -n "hidden|skipsHiddenFiles|duplicate_name|partial|unreadable|pathSummary|sourceDirectory" apps/Blocks/BlocksCore/PrivacyAppScanner.swift apps/Blocks/BlocksApp/Features/Privacy/PrivacyStore.swift tools/verification/p13e_clipboard_privacy_policy_checks.py
```

P13E 摘要：

- `exit=0`
- `ok=True`
- 顶层 schema 存在：`ui_interaction` / `capture_bridge` / `performance`
- 12 个 accepted UI / capture `_004` id 缺失数：0
- `scenario_count=26`
- `stdout_bytes=22983`

未运行：

- 未运行 `xcodebuild`。原因：当前静态代码审查已发现 P1，且本轮要求避免不必要系统动作；Xcode build 可能产生 LaunchServices 注册类副作用，不需要用构建结果证明这些 P1。
- 未运行 `DerivedData/.../blocks --help` 或真实 CLI mutation。CLI 代码静态缺口已足够构成 P1。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。

## 最终建议

要求开发返工，不建议项目负责人接受当前 Step 5。R1 schema/id 小范围修复可视为关闭，但 Step 5 仍需要至少补齐旧 exclusion migration、CLI typed subject、P13E fail-closed 实现级验证和真实 App icon provider 后再进入下一轮复审。
