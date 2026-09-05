# Step 5 App 架构师技术方案 v1

日期：2026-07-07
角色：App 架构师
对象：`004_剪贴板打磨` Step 5：隐私页真实 App 清单与 CLI 广义对象管理
状态：ready-for-project-owner-review

## 1. 方案结论

本 v1 继续采用 v0 的主线：`P13E-first + BlocksCore 单一策略事实源 + App 侧扫描/图标适配 + CLI typed subject`。

v1 相对 v0 的收敛点：

- 吸收测试/质量 P1-1：P13E 将 UI search / filter / sort / a11y / layout 场景提升为 required scenarios，而不是只在说明或 fail-closed 中出现。
- 吸收测试/质量 P1-2：P13E 将 capture bridge 作为 first-class validation object，直接验证 `PrivacyPolicySnapshot` 到 `ClipboardCapturePolicy` 的 allow / restricted / precedence 判定。
- 吸收 P2 建议：加入旧 `excludedBundleIDs` migration scenario、context-aware forbidden pattern、性能 evidence 字段、UI menu / duplicate / error / no-result / a11y 证据口径、首版不实现 CLI `--include-sensitive-paths`、固定 `blocked_capability` enum。

进入开发前仍需项目负责人接受本 v1。技术方案 v1 未接受前不得派发开发。

## 2. 范围与硬边界

Step 5 只解决：

- `/Applications`、`~/Applications`、`/System/Applications` 三 root 下真实 `.app` 清单。
- UI 可写 `Default` / `Allowed` / `Restricted` 剪贴板捕获策略。
- CLI 管理更广 typed subject 的本 App policy rule。
- 将策略事实接入 live capture 的 `ClipboardCapturePolicy`。

Step 5 不解决：

- Step 1-4 的搜索、标签、面板布局、详情编辑重做。
- Step 6 的整体回扫。
- 外部 provider、Keychain、TCC 修改、System Settings、Finder、App launch、命令执行、系统登记源扫描。
- CLI 首版不提供 `--include-sensitive-paths`。如未来要加入，需要安全合规重新复审。

## 3. 事实源与数据模型

### 3.1 Target 分层

建议新增 / 修改模块：

| Target | 文件 / 模块 | 职责 |
| --- | --- | --- |
| `BlocksCore` | `PrivacyPolicyModels.swift` | `PrivacyAppInstance`、`PrivacyPolicySubject`、`PrivacyPolicyRule`、`PrivacyPolicySnapshot`、DTO 和状态枚举。 |
| `BlocksCore` | `PrivacyPolicyRepository.swift` | 单一策略事实源，SQLite 读写、transaction、dry-run、mutation result、snapshot read。 |
| `BlocksCore` | `PrivacySubjectResolver.swift` | typed subject 解析、`subject_ref` 生成、ambiguous / unsupported / low-sensitive output。 |
| `BlocksCore` | `PrivacyAppScanner.swift` | Foundation-only 三 root 受控递归扫描、Info.plist / Bundle metadata 读取、identity edge case。 |
| `BlocksCore` | `PrivacyPathSanitizer.swift` | path summary、path hash、low-sensitive string helpers。 |
| `BlocksApp` | `Features/Privacy/PrivacyStore.swift` | `@MainActor ObservableObject`，scan state、visible rows、filters、search、sort、mutation state。 |
| `BlocksApp` | `Features/Privacy/AppIconProvider.swift` | `SystemAppIconProvider` / `FakeAppIconProvider`，真实图标读取和 in-memory icon cache。 |
| `BlocksApp` | `Features/Privacy/PrivacySettingsPane.swift` | 隐私 App 清单和策略控件，替换旧 `ClipboardPrivacyExclusionList`。 |
| `BlocksApp` | `Features/Privacy/PrivacyAppRowView.swift` | 固定 row 布局、policy menu、issue overflow、a11y。 |
| `BlocksCLI` | `main.swift` + `PrivacyCLIService.swift` | `blocks privacy ...` typed subject / policy JSON 输出。 |
| `tools/verification` | `p13e_clipboard_privacy_policy_checks.py` | Step 5 fail-closed hard gate。 |

`ClipboardStore` 不持有 Step 5 policy fact。`AppModel` 只做 facade / coordinator / `objectWillChange` bridge，不持有 policy rules、AppInstance 列表或 CLI subject facts。

### 3.2 三层模型

`PrivacyAppInstance` 是 UI row 的扫描事实：

```swift
public struct PrivacyAppInstance: Identifiable, Codable, Equatable {
    public let id: String
    public let displayName: String
    public let bundleID: String?
    public let canonicalPath: String      // local-only, never default-output
    public let sourceDirectory: PrivacyAppSourceDirectory
    public let pathSummary: String
    public let pathHash: String
    public let iconState: PrivacyIconState
    public let identityStatus: PrivacyIdentityStatus
    public let policySubjectRef: String?
    public let policyStatus: PrivacyPolicyStatus
    public let issues: [PrivacyIdentityIssue]
}
```

`PrivacyPolicySubject` 是 UI 与 CLI 共享的策略 subject：

```swift
public enum PrivacyPolicySubjectType: String, Codable, CaseIterable {
    case bundleID = "bundle_id"
    case appPath = "app_path"
    case appBundle = "app_bundle"
    case loginItem = "login_item"
    case helper
    case launchLabel = "launch_label"
    case commandPath = "command_path"
}

public struct PrivacyPolicySubject: Codable, Equatable {
    public let subjectRef: String
    public let type: PrivacyPolicySubjectType
    public let displayName: String
    public let primaryIdentifier: String
    public let canonicalIdentifier: String? // local-only, not default-output
    public let resolvedIdentifiers: [String: String]
    public let identityStatus: PrivacyIdentityStatus
    public let uiVisible: Bool
    public let uiMatchCount: Int
    public let pathSummary: String?
    public let sourceDirectory: PrivacyAppSourceDirectory?
    public let pathHash: String?
    public let pathRedacted: Bool
}
```

`PrivacyPolicyRule` 是持久化策略事实：

```swift
public enum PrivacyPolicyStatus: String, Codable, CaseIterable {
    case `default`
    case allowed
    case restricted
    case unknown
    case unsupported
}

public struct PrivacyPolicyRule: Codable, Equatable {
    public let subjectRef: String
    public let subjectType: PrivacyPolicySubjectType
    public let status: PrivacyPolicyStatus
    public let updatedAt: Date
}
```

规则：

- `default` 表示无显式 rule；Repository 中不保留 default row。
- `allowed` / `restricted` 是 explicit rule。
- `unknown` / `unsupported` 只出现在 read model，不写入 rule table。
- `subject_ref = sub_v1_<type>_<sha256(canonicalIdentifier).prefix(20)>`，默认输出不暴露 `canonicalIdentifier`。

### 3.3 SQLite v5 与旧迁移

新增 `privacy_policy_rules` 表，延续 v0 设计：

```sql
CREATE TABLE IF NOT EXISTS privacy_policy_rules (
    subject_ref TEXT PRIMARY KEY NOT NULL,
    subject_type TEXT NOT NULL,
    primary_identifier TEXT NOT NULL,
    canonical_identifier TEXT,
    path_hash TEXT,
    path_summary TEXT,
    display_name TEXT NOT NULL,
    policy_status TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
```

约束：

- `canonical_identifier` 只允许为显式创建的 `app_path` / `command_path` / `app_bundle` policy rule 持久化。
- 不得由 App scan cache 批量写入真实机器完整路径。
- `Default` mutation 删除 explicit rule 时，必须删除 `canonical_identifier`、`path_hash`、`path_summary` 等 path-like 字段。
- 旧 `clipboard.policy.excludedBundleIDs` 只作为 one-shot migration input，迁移为 `restricted bundle_id` rules；迁移后不再是 active fact source。
- migration marker：`privacy.policy.migratedExcludedBundleIDs.v1`。

## 4. 三 root 受控扫描与图标

### 4.1 扫描器

固定 root：

- `/Applications`
- `~/Applications`
- `/System/Applications`

最大目录深度：`2`。root 为 depth 0；直接子目录 depth 1；子目录的子目录 depth 2。

`.app` 是叶子：

- 后缀 `.app`。
- directory / package。
- canonicalized path 仍位于三 root。
- 一旦识别为 `.app`，不扫描 bundle 内部，只读取顶层 metadata / Info.plist。

symlink / alias / unreadable：

- 不递归 symlink directory。
- 不跟随逃出三 root 的 symlink / alias。
- unreadable directory 产出 `partial` scan issue。
- damaged App / unreadable Info.plist 产出 `row-failed` AppInstance，policy 为 `Unknown` / `Unsupported`。

首版不持久化 App index 到磁盘；只做进程内 scan cache。refresh 时继续展示上一代列表，新扫描完成后以 generationID 原子替换。

### 4.2 图标 provider

协议：

```swift
protocol AppIconProvider {
    func icon(for app: PrivacyAppInstance) async -> PrivacyIconResult
}
```

实现边界：

- `SystemAppIconProvider` 只在 BlocksApp target，使用 AppKit / NSWorkspace 读取 icon，不启动 App、不请求权限。
- `FakeAppIconProvider` 用于 P13E / fixture / preview，返回 deterministic loaded / fallback / failed。
- icon cache 只在进程内，key 为 `pathHash + bundleID? + resourceModificationDate? + iconFileName?`。
- icon 异步完成不得改变排序、row 高度或 policy 状态。
- icon binary 不进入日志、P13E JSON、开发记录、验收记录。

## 5. Policy 解析与 Capture Bridge

### 5.1 Precedence

首版支持 `app_path` override。

生效优先级：

1. `app_path` explicit rule。
2. `bundle_id` explicit rule。
3. `default allow`。

应用规则：

- path hash 匹配 restricted -> skip with `.excludedSource`。
- path hash 匹配 allowed -> allow。
- bundle id 匹配 restricted -> skip with `.excludedSource`。
- bundle id 匹配 allowed -> allow。
- 无匹配 -> default allow。
- 缺 path hash 时只按 bundle id 判断，不伪造 `app_path` match。

### 5.2 PrivacyPolicySnapshot

`ClipboardCapturePolicy` 必须消费 `PrivacyPolicySnapshot`，不得继续只消费旧 `excludedBundleIdentifiers`。

```swift
public struct PrivacyPolicySnapshot: Codable, Equatable {
    public let allowedBundleIDs: Set<String>
    public let restrictedBundleIDs: Set<String>
    public let allowedAppPathHashes: Set<String>
    public let restrictedAppPathHashes: Set<String>
    public let generatedAt: Date
    public let revision: Int64
}
```

`ClipboardRecorderSourceApp` 补充 optional low-sensitive path identity：

- `bundlePathHash`
- `bundlePathSummary`
- `sourceDirectory`

`ClipboardLiveCaptureService.frontmostSourceApp()` 可从 `NSRunningApplication.bundleURL` 计算 hash / summary；不得启动 App，不得读取窗口标题，不得读取剪贴板 payload。

### 5.3 Capture bridge evidence 合同

P13E 的每个 capture scenario 必须输出：

```json
{
  "id": "privacy_capture_bundle_restricted_004",
  "decision": "skip_excluded_source",
  "matched_rule_type": "bundle_id_restricted",
  "mutation_performed": false,
  "payload_read": false,
  "path_redacted": true
}
```

缺 `decision`、`matched_rule_type`、`mutation_performed=false` 或 `payload_read=false` 任一字段时，P13E fail。

## 6. UI 数据流与交互合同

### 6.1 Store ownership

`PrivacyStore` 持有：

- scan state。
- visible rows。
- search / filter / sort state。
- row mutation state。
- icon state。

`PrivacyStore` 通过 `PrivacyPolicyRepository` 读取/写入策略，通过 `PrivacyAppScanner` 生成 read model，通过 `AppIconProvider` 异步加载 icon。

`AppModel` 只持有 `privacyStore` 并桥接 `objectWillChange`；不得持有 policy rules 或 AppInstance facts。

### 6.2 Settings integration

- `SettingsShellView(mode: .clipboardPrivacy)` 路由到完整 `PrivacySettingsPane()`。
- `SettingsShellView(mode: .all)` 只展示 privacy summary / entry，不触发完整扫描和真实 icon 加载。
- `ClipboardSettingsPane` 的旧隐私入口可保留为导航入口，但不再展示旧 bundle id 文本框。

### 6.3 UI search / filter / sort / a11y / layout

P13E 必须通过 fixture 验证以下 read model / row model 合同：

- search fields：display name、bundle id、source directory、path summary、policy status、identity issue code 均可命中；raw home path 不可命中。
- filter combination：同维度 OR，不同维度 AND；Clear filters / Clear search / Clear all 语义不同。
- sort stability：display name、bundle id、source directory priority、path summary、path hash tie-breaker；icon async 不改变排序；同 fixture refresh 顺序稳定。
- row a11y：row 暴露 App name、policy status、bundle id 可用性、source directory、主要异常；policy control 有 label / value / hint。
- narrow width：policy status/control 仍可见，长文本不挤压 trailing control。
- long text i18n：中文、英文、日文长 App 名、bundle id、path summary 使用低敏 fixture；截断状态与完整值入口可判定。

UI policy control 首版使用固定 trailing column 内的 menu button：

- visible label 显示当前 confirmed policy 或 pending target。
- VoiceOver label / value / hint 固定。
- unsupported 使用 disabled label 或 disabled menu + reason。
- saving / failed / pending 不改变 trailing column 宽度。
- failed 行显示短错误摘要 + Retry + Cancel，不只依赖 tooltip。
- duplicate confirmation 按钮文案固定为类似 `Apply to shared bundle id` / `Cancel`，避免泛化 `Apply`。
- issue popover 有标题、列表语义、Esc 关闭、焦点回到触发 row。
- no result 区分 search no result 与 filter no result，并提供对应 Clear action。

## 7. CLI 数据流与 typed subject

首版命令形态：

```bash
blocks privacy subjects list --type app_bundle|bundle_id|app_path|login_item|helper|launch_label|command_path --json
blocks privacy subjects resolve --type bundle_id --identifier <value> --json
blocks privacy policy get --subject-ref <ref> --json
blocks privacy policy set --subject-ref <ref> --policy default|allowed|restricted --dry-run --json
blocks privacy policy set --subject-ref <ref> --policy default|allowed|restricted --confirm --json
blocks privacy action blocked --capability tcc_reset --json
```

Allowed：

- `app_bundle` / `bundle_id` / `app_path`：UI 三 root App index、已有 policy rules、显式 typed input。
- `command_path`：显式 absolute path input、受控 fixture、技术方案定义的 synthetic allowlist。
- `login_item` / `helper` / `launch_label`：已有 policy rules、显式 typed input、synthetic fixture source。

Forbidden：

- PATH scan。
- command execution。
- shell parsing、glob、alias/function expansion。
- LaunchAgents / LaunchDaemons / Login Items 真实登记源枚举。
- `launchctl`。
- System Settings / Finder / TCC。
- ambiguous subject 执行 mutation。
- dry-run 改变 policy store。

## 8. 低敏与安全边界

### 8.1 默认输出

默认不得输出：

- 完整真实路径清单、home path、real command arguments。
- icon binary / image bytes。
- TCC raw rows、csreq、requirement data、auth_value、auth_reason、indirect object identifier。
- System Settings URL、Finder open token、launchctl / tccutil / shell snippets。
- provider route / upload token。
- Authorization、Bearer、password、OTP、private key、cookie、session、JWT、webhook。

默认允许：

- synthetic bundle id。
- source directory enum。
- path summary。
- path hash。
- counts。
- subject_ref。
- low-sensitive error code。

### 8.2 首版不实现 `--include-sensitive-paths`

v1 明确首版 CLI 不实现 `--include-sensitive-paths`。

如后续项目负责人要求加入，必须重新由安全合规复审，并满足：

- 默认 false。
- help 标注 `sensitive local output`。
- P13E、开发记录、验收记录、golden fixture 禁止使用。
- 每次使用输出 warning，warning 本身不含完整路径。

### 8.3 Dangerous action hard-block

`--confirm` / `--yes` 只能确认本 App policy mutation。

`blocked_capability` 固定枚举：

- `tcc_reset`
- `permission_request`
- `system_settings_open`
- `finder_open`
- `app_launch`
- `command_execution`
- `shell_execution`
- `launchctl_mutation`
- `login_item_lifecycle`
- `helper_lifecycle`
- `cli_tool_lifecycle`

hard-block JSON 不拼接用户输入、真实 command path、launch label 或系统配置字段；error message 不提供可复制危险命令。

## 9. P13E Hard Gate 设计

### 9.1 脚本

新增：

```bash
python3 tools/verification/p13e_clipboard_privacy_policy_checks.py
```

P13E 必须在 Step 5 开发和验收中排在首位。P13E fail 时不得用其他回归 PASS 声称 Step 5 完成。

### 9.2 Evidence schema

P13E stdout JSON 顶层结构：

```json
{
  "gate": "P13E",
  "status": "pass",
  "ok": true,
  "current_fact_sources": {
    "prd": "docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md",
    "technical_plan": "docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md",
    "development_record": "docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-v0.md"
  },
  "scan_scope": {},
  "identity_edge_matrix": {},
  "ui_policy_mutation": {},
  "ui_interaction": {
    "search_fields": {},
    "filter_combination": {},
    "sort_stability": {},
    "a11y": {},
    "layout": {}
  },
  "capture_bridge": {
    "snapshot_shape": {},
    "scenarios": []
  },
  "cli_subjects": {},
  "dangerous_actions": {},
  "low_sensitive_scan": {},
  "performance": {
    "elapsed_ms": {},
    "threshold_ms": {},
    "fixture_count": {},
    "sample_count": {}
  },
  "failures": []
}
```

所有 list-like evidence 只输出 counts / hashes / summaries；sample 不超过 20 rows；P13E stdout 不超过 180 KB。

### 9.3 Fixture data shape

P13E 使用 synthetic temp roots，不读取真实 `/Applications`：

```text
<TMP>/Applications
<TMP>/HomeApplications
<TMP>/SystemApplications
```

Fixture `.app` 至少包含：

```text
FixtureNormal.app/Contents/Info.plist
FixtureDuplicateA.app/Contents/Info.plist
FixtureDuplicateB.app/Contents/Info.plist
FixtureMissingBundle.app/Contents/Info.plist
FixtureDamaged.app/Contents/Info.plist (missing / malformed)
Utilities/FixtureNested.app/Contents/Info.plist
Fixture中文很长很长ApplicationName.app/Contents/Info.plist
FixtureJapanese非常に長い名前.app/Contents/Info.plist
```

P13E 将 synthetic roots 注入 `PrivacyAppScanner`，不得扫描真实 roots。

### 9.4 Required scenarios

UI scan：

- `privacy_apps_three_dirs_004`
- `privacy_apps_bounded_recursion_004`
- `privacy_app_leaf_boundary_004`
- `privacy_app_symlink_outside_root_denied_004`
- `privacy_app_unreadable_partial_004`
- `privacy_app_duplicate_name_004`
- `privacy_app_duplicate_bundle_id_004`
- `privacy_app_missing_bundle_id_004`
- `privacy_app_damaged_004`
- `privacy_app_hidden_004`
- `privacy_app_icon_success_004`
- `privacy_app_icon_failed_004`
- `privacy_apps_large_list_004`

UI interaction / layout：

- `privacy_app_search_fields_004`：display name、bundle id、source directory、path summary、policy status、identity issue code 都能命中；path search 不匹配 raw home path。
- `privacy_app_filter_combination_004`：同维度 OR，不同维度 AND，Clear filters / Clear search / Clear all 语义可区分。
- `privacy_app_sort_stability_004`：display name、bundle id、source directory priority、path summary、path hash tie-breaker；icon async 不改变排序；refresh 同 fixture 顺序稳定。
- `privacy_app_row_a11y_004`：row 暴露 App name、policy status、bundle id 可用性、source directory、主要异常；policy control 有 label / value / hint。
- `privacy_app_narrow_width_004`：窄宽度下 policy status/control 仍可见，长文本不挤压 trailing control。
- `privacy_app_long_text_i18n_004`：中文、英文、日文长 App 名、bundle id、path summary 使用低敏 fixture，截断与完整值入口可判定。

Policy mutation：

- `privacy_app_policy_mutation_success_004`
- `privacy_app_policy_mutation_failed_004`
- `privacy_app_policy_dry_run_no_mutation_004`
- `privacy_app_duplicate_bundle_confirm_004`
- `privacy_app_path_override_precedence_004`
- `privacy_app_missing_bundle_unsupported_or_path_scoped_004`
- `privacy_policy_legacy_excluded_bundle_migration_004`

Capture bridge：

- `privacy_capture_bundle_restricted_004`：source bundle id 命中 restricted bundle_id rule -> skip with `.excludedSource`。
- `privacy_capture_bundle_allowed_004`：source bundle id 命中 allowed bundle_id rule -> allow。
- `privacy_capture_app_path_precedence_004`：app_path restricted 优先于 bundle_id allowed；app_path allowed 优先于 bundle_id restricted。
- `privacy_capture_default_allow_004`：无 explicit rule -> default allow。
- `privacy_capture_missing_path_fallback_004`：无 path hash 时只按 bundle id 规则判断，不伪造 app_path match。
- `privacy_capture_snapshot_low_sensitive_004`：evidence 只输出 bundle id fixture、path hash、summary、decision code，不输出真实路径、窗口标题、剪贴板 payload。

CLI：

- `privacy_cli_app_bundle_004`
- `privacy_cli_bundle_id_duplicate_004`
- `privacy_cli_missing_bundle_id_004`
- `privacy_cli_damaged_app_004`
- `privacy_cli_hidden_app_004`
- `privacy_cli_unsupported_subject_004`
- `privacy_cli_path_conflict_004`
- `privacy_cli_policy_failed_004`
- `privacy_cli_login_item_004`
- `privacy_cli_helper_004`
- `privacy_cli_command_path_004`
- `privacy_cli_fixture_source_only_004`
- `privacy_cli_dry_run_004`
- `privacy_cli_confirm_required_004`
- `privacy_cli_dangerous_blocked_004`
- `privacy_cli_json_output_004`
- `privacy_cli_low_sensitive_output_004`

### 9.5 Fail-closed 条件

P13E 必须在以下情况 fail：

- 缺 PRD / 技术方案 / 开发记录当前事实源。
- 缺任一 required scenario。
- scenario 缺 fixture id、result、assertions。
- `ui_interaction` 缺 `search_fields`、`filter_combination`、`sort_stability`、`a11y`、`layout`。
- `capture_bridge` 缺 `snapshot_shape` 或 required capture scenarios。
- `PrivacyPolicySnapshot` 未包含 `bundle_id allowed/restricted` 与 `app_path allowed/restricted` set。
- `ClipboardCapturePolicy` 未消费 `PrivacyPolicySnapshot`，或仍只消费旧 `excludedBundleIdentifiers`。
- capture bridge scenario 缺 `decision`、`matched_rule_type`、`mutation_performed=false`、`payload_read=false`。
- scan scope 超出三 root。
- `.app` bundle 被扫描内部内容。
- helper / login item / command path 出现在 UI App list。
- ambiguous subject 执行 mutation。
- dry-run 改变 policy store。
- `--confirm` 解锁 dangerous action。
- CLI JSON 缺 `subject_ref`、`mutation_performed`、`policy_before` / `policy_after`。
- 旧 `excludedBundleIDs` 仍作为 active fact source 被 AppModel / capture policy 读取。
- 输出命中 hard forbidden token / pattern。
- context forbidden 出现在可复制命令、URL、raw output 或用户拼接字段。
- 性能 evidence 缺 `elapsed_ms`、`threshold_ms`、`fixture_count`、`sample_count`。
- large-list fixture dump 全量列表。

### 9.6 Context-aware forbidden pattern

P13E sanitizer 分两类。

Hard forbidden：命中即 fail，输出只给 label，不输出原文。

- raw home path。
- real `/Applications` path。
- Authorization / Bearer / password / OTP / private key / cookie / session / JWT / webhook。
- TCC raw dump、csreq、requirement_data、auth_requirement、auth_value、auth_reason、indirect_object_identifier。
- icon binary、`data:image`、large base64 blob。
- provider route、upload token。

Context forbidden：只允许出现在 `blocked_capability`、`denied_runtime_actions` 或技术说明 label；不得出现在可复制命令、URL、raw output 或用户输入拼接中。

- `launchctl`
- `tccutil`
- `osascript`
- `open `
- `x-apple.systempreferences`
- `System Settings`
- `Finder`
- `URLSession`
- `provider`
- `upload`

## 10. 性能阈值

开发前不得缺数值：

| 指标 | 阈值 | Evidence 字段 |
| --- | --- | --- |
| large-list fixture count | 3000 synthetic apps，覆盖三 root、duplicates、missing bundle id、damaged、hidden、icon failed。 | `fixture_count=3000` |
| first page readiness | 首屏 50 row read model <= 300 ms；首次无缓存时至少发布 loading / partial 状态。 | `elapsed_ms` / `threshold_ms=300` / `sample_count=50` |
| full synthetic index build | 3000 apps scan + identity classification + stable sort <= 2000 ms。 | `elapsed_ms` / `threshold_ms=2000` |
| search/filter response | index loaded 后 3000 apps 内搜索 / filter / sort recompute <= 120 ms。 | `elapsed_ms` / `threshold_ms=120` |
| refresh no-blank | 有旧结果时 refresh 全程 `visibleRows.count > 0`。 | `sample_count` / `refresh_kept_visible_rows=true` |
| icon layout stability | icon loaded / fallback / failed 前后 row height delta = 0，sort order unchanged。 | `row_height_delta=0` / `sort_order_changed=false` |
| verifier output bound | P13E stdout <= 180 KB；每个列表类 scenario sample <= 20 rows。 | `stdout_bytes` / `sample_count<=20` |
| CLI resolve response | synthetic 3000 subject index 下 resolve <= 150 ms。 | `elapsed_ms` / `threshold_ms=150` |

若本地机器波动导致性能失败，允许 P13E 串行重跑一次；重跑仍失败才 fail。超时输出只给 scenario id、summary 和低敏 count，不 dump app list。

## 11. 开发批次建议

### Batch A：P13E baseline + Core model / schema

目标：

- 新增 P13E skeleton，缺实现时 red。
- 固化 evidence schema，含 `ui_interaction` 与 `capture_bridge`。
- 新增 `PrivacyPolicyModels.swift`、`PrivacyPathSanitizer.swift`、`PrivacyPolicyRepository.swift` skeleton。
- AppDatabase v5 migration skeleton。
- 不接 UI，不改 capture policy。

验收：

- P13E 能 fail closed，指出缺 scanner / UI interaction / capture bridge / CLI scenarios。
- Blocks App / CLI build 仍可过。

### Batch B：Scanner / icon / PrivacyStore read model

目标：

- 实现 `PrivacyAppScanner` synthetic roots。
- 实现 `SystemAppIconProvider` 与 `FakeAppIconProvider`。
- 新增 `PrivacyStore`，含 scan state、cache、search/filter/sort、icon state。
- `PrivacyStore` 暴露 fixture-testable row model，用于 P13E UI search/filter/sort/a11y/layout 验证。
- AppModel 注入 `privacyStore`，只做 facade。

验收：

- P13E scan / identity / icon / UI interaction / performance scenarios pass。
- P13E 不扫描真实 roots。

### Batch C：Policy mutation + UI privacy pane + capture bridge

目标：

- 实现 `PrivacyPolicyRepository` apply / dry-run / transaction。
- 实现 `PrivacySettingsPane`、row、policy menu、duplicate confirmation、failed retry/cancel。
- 替换旧 `ClipboardPrivacyExclusionList`。
- `Step5OneShotMigration` 迁移旧 excluded bundle ids。
- `ClipboardCapturePolicy` 接入 `PrivacyPolicySnapshot`。

验收：

- P13E policy mutation / UI state / duplicate / migration scenarios pass。
- P13E capture bridge scenarios pass。
- UI 不触发系统权限、Finder、App launch。

### Batch D：CLI + low-sensitive hardening + full regression

目标：

- `blocks privacy ...` CLI。
- subject resolver、JSON schema、dry-run、confirm apply、dangerous blocked。
- context-aware sanitizer / forbidden pattern。
- target membership / project file update。

验收：

- P13E 全 PASS。
- 回归：P13A / P13B / P13C / P13D / P11E / P9A / P9B / P8 / P8I，Blocks App build，BlocksCLI build，`blocks --help`，`git diff --check`。

## 12. 风险与待复审问题

### P1 风险

v1 已将测试/质量提出的两个 P1 纳入 P13E hard gate。若后续开发派发或实现中弱化以下任一项，应视为 P1 回归：

- UI interaction / layout required scenarios 被降级为 optional。
- capture bridge 没有一等 evidence。
- `ClipboardCapturePolicy` 没有消费 `PrivacyPolicySnapshot`。
- 旧 `excludedBundleIdentifiers` 仍是 active fact source。

### P2 残余

- 真实机器 App 图标和真实 `/Applications` 列表不在技术方案阶段验证；后续开发验收或 Step 6 回扫处理。
- 真实 VoiceOver 仍需 UI/测试验收；P13E 验证的是 row model / a11y metadata 合同。
- icon cache 首版仅内存，不跨启动。
- login item / helper / launch label 首版不做系统登记源枚举；只支持 explicit input / existing policy / synthetic fixture。

### 需要项目负责人取舍

无新的产品取舍问题。v1 只回写验收覆盖和安全/低敏边界。

## 13. 进入开发前检查清单

进入开发前必须满足：

- 项目负责人接受本 v1。
- P13E evidence schema 被项目负责人和测试/质量定向接受。
- `ui_interaction` 与 `capture_bridge` 在 P13E required scenarios 中不可降级。
- 性能阈值与 evidence 字段没有缺项。
- `app_path` override 首版支持与 capture bridge 范围被接受。
- 首版 CLI 不实现 `--include-sensitive-paths`。
- 开发派发明确禁止真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。

## 14. 本轮验证

本轮只产出技术方案文档。完成后运行：

```bash
git diff --check -- docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v1.md
```

结果：PASS。
