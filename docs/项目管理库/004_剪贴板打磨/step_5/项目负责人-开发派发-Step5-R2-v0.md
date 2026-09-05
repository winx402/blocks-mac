# Step 5 R2 开发派发

日期：2026-07-07
角色：项目负责人
对象：`004_剪贴板打磨` Step 5 R2 返工
状态：dispatched-to-development

## 1. 任务目标

关闭代码审查 Step 5 开发复审 v0 提出的 4 个 P1。R2 只处理 Step 5，不进入 Step 6，不重做 Step 1-4。

## 2. 必读输入

- [代码审查 Step5 开发复审 v0](代码审查-Step5开发复审-v0.md)
- [项目负责人 Step5 开发复审收敛 v0](项目负责人-Step5开发复审收敛-v0.md)
- [App 架构师技术方案 v1](App架构师-技术方案-v1.md)
- [产品经理 PRD v1](产品经理-PRD-v1.md)
- [项目负责人开发派发 Step5 v0](项目负责人-开发派发-Step5-v0.md)
- [开发记录 Step5 v0](开发记录-Step5-v0.md)
- [开发记录 Step5 R1 v0](开发记录-Step5-R1-v0.md)

## 3. 必须关闭的 P1

### P1-1：旧 exclusion migration

实现旧 `clipboard.policy.excludedBundleIDs` 到新 policy rule 的 one-shot migration：

- 读取旧 key。
- 规范化 bundle id。
- 写入 `PrivacyPolicyRepository`，policy 为 `.restricted`。
- 使用 marker `privacy.policy.migratedExcludedBundleIDs.v1`。
- 成功后再写 marker，失败不得标记完成。
- 不把旧 key 重新作为 AppModel / ClipboardStore / CapturePolicy active fact source。

P13E 必须增加并 require：

- `privacy_policy_legacy_excluded_bundle_migration_004`

### P1-2：CLI typed subject 范围

扩展 subject model 和 CLI：

- `app_bundle`
- `bundle_id`
- `app_path`
- `command_path`
- `login_item`
- `helper`
- `launch_label`

约束：

- 只支持 explicit input / existing policy / synthetic fixture。
- 不做真实系统登记源枚举。
- 不执行命令、不扫描 PATH、不启动 App。
- `policy get/set` 对这些 subject_ref 可用。
- ambiguous / unsupported 不 mutation。
- `subject_ref` 必须是稳定 opaque / hash 格式，默认输出低敏。

P13E 必须覆盖 accepted CLI `_004` 场景，至少包括：

- `privacy_cli_app_bundle_004`
- `privacy_cli_login_item_004`
- `privacy_cli_helper_004`
- `privacy_cli_command_path_004`
- `privacy_cli_dangerous_blocked_004`
- `privacy_cli_low_sensitive_output_004`

### P1-3：P13E 实现级 fail-closed

P13E 必须从“Python 重写理想逻辑”升级为能证明实际实现：

- 用 Swift fixture / CLI fixture / 更严格静态语义检查验证真实实现。
- `privacy_app_search_fields_004` 验证 Swift `PrivacyStore` 搜索包含 `pathSummary`，且 raw home path 不命中。
- capture bridge 场景验证 `ClipboardCapturePolicy.evaluate(...)` 的真实输出。
- CLI 场景验证真实 `PrivacyCLIService` 或 built CLI 的 parse / dry-run / confirm / dangerous blocked 输出。
- legacy migration 场景验证旧 key -> repository rule -> snapshot restricted set。
- icon 场景验证真实 provider 与 fake/fallback 分支。

### P1-4：真实 App icon provider

实现真实 App icon provider：

- 使用 AppKit / NSWorkspace 或等价 API 读取本地 `.app` icon。
- 不启动 App、不请求权限。
- 不持久化 icon binary。
- 不把 icon binary 写入日志、P13E、开发记录或验收记录。
- 失败时有 stable fallback / failed state，布局尺寸稳定。

## 4. 验证要求

R2 最低验证：

- `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py`
- 独立解析 P13E：顶层 schema、12 个 accepted UI/capture id、legacy migration id、CLI typed subject ids 均存在。
- P13A / P13B / P13C / P13D。
- P11E。
- P9A / P9B。
- P8 / P8I。
- Blocks App build。
- BlocksCLI build。
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`。
- `git diff --check`。

如需运行 CLI 行为验证，只允许 synthetic fixture / temp repository / low-sensitive output；不得执行系统命令或真实 mutation。

## 5. 输出

开发完成后写入：

- `/Users/bot/Documents/Mac 工具集/docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-R2-v0.md`

开发记录必须包含：

- 4 个 P1 的修复说明。
- P13E 新 evidence / fail-closed 说明。
- 新增或调整的 required scenario id。
- 验证命令结果。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更的声明。
