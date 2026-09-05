# Step 5 App 架构师技术方案 v0

日期：2026-07-07
角色：App 架构师
对象：`004_剪贴板打磨` Step 5：隐私页真实 App 清单与 CLI 广义对象管理
状态：ready-for-role-review

## 1. 方案结论

本方案建议 Step 5 采用“P13E-first + Core 单一策略事实源 + App 侧扫描/图标适配 + CLI typed subject”的架构。

核心取舍：

- UI 默认展示 `/Applications`、`~/Applications`、`/System/Applications` 三个 root 下受控递归发现的 `.app`。
- `.app` bundle 是枚举叶子，不扫描 bundle 内部。
- 首版支持 `bundle_id` 与 `app_path` 两类 App 策略 subject；`app_path` override 进入首版，但只有在 canonical path / path hash 可获得时才允许写入和应用。
- `app_path` rule 优先于 `bundle_id` rule；若 path 不可获得，missing bundle id / damaged app 降级为 `Unsupported` 或 `confirm-required`，不得伪造策略。
- UI 与 CLI 共用 `PrivacyPolicyRepository` 作为单一策略事实源；`AppModel` 只做 facade / coordinator，不持有策略事实。
- CLI subject 是本 App policy subject，不是系统对象生命周期控制器；login item / helper / launch label / command path 首版只允许显式 typed input、已有 policy 记录或白名单 fixture，不扫描 PATH、不执行命令、不读取系统登记源。
- 真实图标读取仅在 App target 通过 `AppIconProvider` adapter 完成；P13E 使用 fake icon provider / synthetic fixture，不依赖真实机器图标。
- 首版不持久化 icon binary；只做进程内 icon cache，避免图标二进制进入仓库、日志或验收证据。
- 技术方案通过前不派发开发；开发必须先实现 P13E baseline red / schema，再实现业务代码。

## 2. 事实源与数据模型

### 2.1 Target 分层

建议新增 / 修改的模块边界：

| Target | 文件 / 模块 | 职责 |
| --- | --- | --- |
| `BlocksCore` | `PrivacyPolicyModels.swift` | `AppInstance`、`PolicySubject`、`PolicyRule`、状态枚举、CLI output DTO。 |
| `BlocksCore` | `PrivacyPolicyRepository.swift` | 单一策略事实源，SQLite 读写、transaction、dry-run plan、mutation result。 |
| `BlocksCore` | `PrivacySubjectResolver.swift` | typed subject 解析、`subject_ref` 生成、ambiguity、unsupported、low-sensitive output。 |
| `BlocksCore` | `PrivacyAppScanner.swift` | Foundation-only 三 root 受控递归扫描、Info.plist / Bundle metadata 读取、identity edge case。 |
| `BlocksCore` | `PrivacyPathSanitizer.swift` | path summary、path hash、low-sensitive string helpers。 |
| `BlocksApp` | `Features/Privacy/PrivacyStore.swift` | `@MainActor ObservableObject`，加载 App index、连接 policy repository、UI mutation 状态、搜索过滤排序。 |
| `BlocksApp` | `Features/Privacy/AppIconProvider.swift` | `SystemAppIconProvider` / `FakeAppIconProvider` protocol，真实图标读取和 in-memory icon cache。 |
| `BlocksApp` | `Features/Privacy/PrivacySettingsPane.swift` | 替换当前 `ClipboardPrivacyExclusionList`，展示真实 App 清单和策略控件。 |
| `BlocksApp` | `Features/Privacy/PrivacyAppRowView.swift` | 固定 row 布局、policy control、issue overflow、a11y。 |
| `BlocksCLI` | `main.swift` + `PrivacyCLIService.swift` | `blocks privacy ...` typed subject / policy JSON 输出。 |
| `tools/verification` | `p13e_clipboard_privacy_policy_checks.py` | Step 5 fail-closed hard gate。 |

不建议把 Step 5 放进 `ClipboardStore` 或 `ClipboardSettingsPane` 内部继续扩写。`ClipboardStore` 的职责是剪贴板记录/搜索/标签/详情；Step 5 的核心事实源是隐私策略，不应变成 clipboard feature 的内部状态。

### 2.2 三层事实模型

`AppInstance`：UI row 的扫描事实，代表一个可识别 `.app`。

建议字段：

```swift
public struct PrivacyAppInstance: Identifiable, Codable, Equatable {
    public let id: String                 // app_<pathHash>
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

`PolicySubject`：UI 与 CLI 共享的策略 subject。

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

`PolicyRule`：绑定到 subject 的策略事实。

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
    public let status: PrivacyPolicyStatus // only allowed/restricted are persisted as explicit rules
    public let updatedAt: Date
}
```

规则：

- `default` 表示无显式 rule；Repository 中不必持久化 default row。
- `allowed` 是显式允许 rule，保留给 UI/CLI 表达用户选择；它不扩大剪贴板支持类型，只是不限制该 subject。
- `restricted` 会使匹配 subject 的剪贴板捕获被跳过。
- `unknown` / `unsupported` 只能作为 read model 状态，不写入 rule table。

### 2.3 subject_ref 生成

`subject_ref` 必须 stable / opaque / low-sensitive：

```text
sub_v1_<type>_<sha256(canonicalIdentifier).prefix(20)>
```

示例：

- `bundle_id` canonicalIdentifier = normalized bundle id。
- `app_path` canonicalIdentifier = standardized canonical path，本地只用于 hash 和匹配。
- `command_path` canonicalIdentifier = lexical standardized absolute input path；默认不检查 PATH、不执行、不读输出。
- `login_item` / `helper` / `launch_label` canonicalIdentifier = explicit typed identifier 或已有 policy record identifier。

默认 CLI / audit / verification 不输出 canonicalIdentifier；只输出 `subject_ref`、`path_summary`、`source_directory`、`path_hash`、`path_redacted=true`。

### 2.4 SQLite policy store

建议将 `AppDatabase` schema 升级到 v5，新增表：

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

CREATE INDEX IF NOT EXISTS idx_privacy_policy_rules_type
ON privacy_policy_rules(subject_type, policy_status);

CREATE INDEX IF NOT EXISTS idx_privacy_policy_rules_path_hash
ON privacy_policy_rules(path_hash)
WHERE path_hash IS NOT NULL;
```

说明：

- `canonical_identifier` 可以包含本地完整路径，仅用于本地匹配，不进入默认输出、fixture golden、开发记录或验收记录。
- mutating transaction 只写 `privacy_policy_rules`。
- dry-run 不写 DB，不写 audit 表，不更新 UserDefaults。
- `Default` mutation 删除对应 explicit rule；返回 mutation count 1 或 0，但必须说明 before / after。

### 2.5 旧 `excludedBundleIDs` 迁移

当前 `ClipboardSettingsPane` 使用 `@AppStorage("clipboard.policy.excludedBundleIDs")` 作为旧隐私排除事实源。Step 5 不应继续让它作为事实源。

建议：

- `Step5OneShotMigration` 新增 `migratePrivacyExcludedBundleIDsIfNeeded`。
- App 启动时读取旧 UserDefaults 中的 bundle id 列表，将每个 bundle id 迁移为 `bundle_id` subject + `restricted` rule。
- 迁移 marker：`privacy.policy.migratedExcludedBundleIDs.v1`。
- 迁移后 `AppModel.clipboardCapturePolicyFromSettings()` 不再读取旧 excluded string，而从 `PrivacyPolicyRepository` / `PrivacyStore` 读取 policy snapshot。
- 保留旧 UserDefaults 字段只作为 migration input，不再作为 UI 事实源。

## 3. 三 root 受控递归扫描器

### 3.1 Root 与最大深度

固定 root：

- `/Applications`
- `~/Applications`
- `/System/Applications`

最大目录深度：`2`。

定义：

- root 本身 depth = 0。
- root 的直接子目录 depth = 1。
- 子目录的子目录 depth = 2。
- 扫描 depth <= 2 的目录项。
- 在任意 depth 发现 `.app` 时，记录为 `AppInstance`，并停止进入该 bundle 内部。

理由：

- 覆盖常见 `/Applications/Utilities/*.app`、`/System/Applications/Utilities/*.app` 和 vendor 子目录。
- 避免全盘扫描或深入 `.app` 内部目录。
- 若后续需要更深层级，必须由项目负责人接受范围变化。

### 3.2 `.app` 叶子规则

候选路径满足：

- 后缀 `.app`。
- resource value 表示 directory / package。
- path canonicalized 后仍位于三 root 中某一个 root 下。

一旦识别为 `.app`：

- 不扫描 bundle 内部。
- 只读取 bundle 顶层元数据：display name、bundle id、Info.plist 可读性、hidden 标记、resource modification date。
- 不启动 App。
- 不读取 App 内任意用户内容。

### 3.3 symlink / alias / unreadable 处理

规则：

- 不递归 symlink directory。
- 不跟随会逃出三 root 的 symlink / alias。
- `.app` symlink / alias 仅在可安全解析且 target canonical path 仍位于三 root 内时纳入；否则记录 scan issue，不作为正常 App row。
- unreadable directory 产生 `partial` scan issue，不让整个页面失败。
- damaged App / unreadable Info.plist 产生 `row-failed` AppInstance，`identityStatus = .damaged`，policy `Unknown` / `Unsupported`。

扫描输出：

```swift
public struct PrivacyAppScanResult {
    public let generationID: String
    public let startedAt: Date
    public let completedAt: Date?
    public let state: PrivacyAppScanState // loading, partial, loaded, failed
    public let apps: [PrivacyAppInstance]
    public let issues: [PrivacyAppScanIssue]
    public let rootCounts: [PrivacyAppSourceDirectory: Int]
}
```

### 3.4 缓存与刷新

首版使用进程内扫描缓存：

- `PrivacyAppIndexCache` 保存上一代 scan result。
- refresh 时继续展示上一代列表，状态切换为 `refreshing` / `partial`。
- 新扫描完成后以 generationID 原子替换。
- 单个 row 失败不清空列表。
- 首次加载无缓存时显示 loading skeleton / partial count。

不在首版持久化 App index 到磁盘，原因：

- 三目录扫描成本可控。
- 避免持久化完整本机路径清单。
- policy fact source 已经持久化；App index 是可重建 read model。

## 4. 真实图标读取与缓存

### 4.1 Provider 边界

定义协议：

```swift
protocol AppIconProvider {
    func icon(for app: PrivacyAppInstance) async -> PrivacyIconResult
}
```

实现：

- `SystemAppIconProvider`：BlocksApp target，使用 AppKit / NSWorkspace 读取 icon，不启动 App、不请求权限。
- `FakeAppIconProvider`：测试 / P13E / preview fixture，返回 deterministic loaded / failed / fallback。

禁止：

- App launch。
- Finder / System Settings。
- provider upload。
- 读取 icon binary 并写入 fixture / docs / verifier output。

### 4.2 Icon 状态

```swift
public enum PrivacyIconState: String, Codable {
    case loading
    case loaded
    case fallback
    case failed
    case stale
}
```

状态规则：

- 初次 row 出现为 `loading` 或 `fallback`，固定尺寸占位。
- 成功读取后为 `loaded`。
- 读取失败为 `failed`，UI 显示同尺寸 fallback。
- cache fingerprint 变更时为 `stale`，保留旧 icon / fallback，后台重读。

### 4.3 Icon cache

首版只做 in-memory cache：

```text
iconCacheKey = pathHash + bundleID? + resourceModificationDate? + iconFileName?
```

要求：

- 图标异步完成不改变 row 高度。
- 图标异步完成不改变排序。
- cache miss / failed 不影响 policy 状态。
- cache 内容不写入日志、P13E JSON、开发记录、验收记录。

如后续需要磁盘 icon cache，必须先由安全合规复审，因为会产生本机 App 图标二进制持久化。

## 5. Policy 解析与 capture 集成

### 5.1 precedence

首版支持 `app_path` override。

生效优先级：

1. `app_path` explicit rule。
2. `bundle_id` explicit rule。
3. `default`。

解释：

- `app_path` 只在 canonical path hash 可用时参与解析。
- duplicate bundle id 默认共享 `bundle_id` policy；若用户选择 path override，则 UI / CLI 明确显示 override 来源。
- missing bundle id 如 canonical path 可用，可使用 `app_path` rule；否则 Unsupported。
- damaged / unreadable App 不静默创建 rule；只有 path 可安全 canonicalize 时才允许 `app_path` subject。

### 5.2 Capture policy bridge

当前 live capture source 只有 bundle id / localized name。Step 5 需要补：

- `ClipboardRecorderSourceApp` 增加 optional low-sensitive path identity 字段，例如 `bundlePathHash`、`bundlePathSummary`、`sourceDirectory`。
- `ClipboardLiveCaptureService.frontmostSourceApp()` 从 `NSRunningApplication.bundleURL` 计算 path hash / summary；不启动 App。
- `ClipboardCapturePolicy` 不再只接收 `excludedBundleIdentifiers`，而接收 `PrivacyPolicySnapshot`。
- `PrivacyPolicySnapshot` 至少包含：
  - restricted bundle id set。
  - allowed bundle id set。
  - restricted app path hash set。
  - allowed app path hash set。

应用规则：

- path hash 匹配 restricted -> skip with `.excludedSource`。
- path hash 匹配 allowed -> allow。
- bundle id 匹配 restricted -> skip。
- bundle id 匹配 allowed -> allow。
- 无匹配 -> default allow。

旧记录没有 path hash，不影响历史展示；新 capture 后按可用 path hash 生效。

### 5.3 UI mutation transaction

`PrivacyPolicyRepository.applyPolicyMutation(_:)` 是唯一写入口。

输入：

```swift
public struct PrivacyPolicyMutationCommand: Codable {
    public let subject: PrivacyPolicySubject
    public let requestedStatus: PrivacyPolicyStatus // default / allowed / restricted
    public let expectedRuleRevision: Int64?
    public let confirmation: PrivacyPolicyConfirmation?
    public let source: PrivacyPolicyMutationSource // ui / cli
    public let now: Date
}
```

输出：

```swift
public struct PrivacyPolicyMutationResult: Codable {
    public let ok: Bool
    public let mutationCount: Int
    public let subjectRef: String
    public let policyBefore: PrivacyPolicyStatus
    public let policyAfter: PrivacyPolicyStatus
    public let warnings: [PrivacyPolicyWarning]
    public let errorCode: String?
}
```

失败要求：

- DB transaction rollback。
- 原 policy 不变。
- UI row 回到 failed，显示 Retry / Cancel。
- CLI 输出 `ok=false`、stable error code、`mutation_performed=false`。

## 6. UI 数据流

### 6.1 Store ownership

新增 `PrivacyStore: ObservableObject`：

- 持有 scan state、visible rows、filters、search、sort、row mutation state。
- 通过 `PrivacyPolicyRepository` 读取/写入策略。
- 通过 `PrivacyAppScanner` 生成 AppInstance read model。
- 通过 `AppIconProvider` 异步加载 icon。
- 对外暴露 bounded / low-sensitive view model。

`AppModel`：

- 持有 `privacyStore`。
- bridge `objectWillChange`。
- 提供 Settings environment object。
- 不持有 policy rules、AppInstance 列表或 CLI subject facts。

### 6.2 Settings integration

建议：

- 新增 `PrivacySettingsPane`，替换 `ClipboardSettingsPane(showPrivacySection: true)` 中的 `ClipboardPrivacyExclusionList`。
- `SettingsShellView(mode: .clipboardPrivacy)` 路由到 `PrivacySettingsPane()`。
- `SettingsShellView(mode: .all)` 中也使用 `PrivacySettingsPane()`，但可只展示摘要和入口，避免 all settings 页面加载 3000 行列表。
- `ClipboardSettingsPane` 的旧隐私入口保留为导航入口，不再展示旧 bundle id 文本框。

### 6.3 Row 与 policy control

行结构：

- fixed icon slot：32x32 或 36x36，图标加载前后尺寸不变。
- primary：display name。
- secondary：bundle id / source directory / path summary。
- trailing：固定宽度 policy control。
- issue overflow：最多显示 2 个 chip，更多进入 popover。

Policy control 首版建议使用 menu button，而不是 segmented control：

- 常规 row：Menu 显示 Default / Allowed / Restricted。
- unsupported row：disabled label + reason。
- duplicate bundle id：选择后进入 pending confirmation popover / dialog。
- saving：trailing control disabled，显示 spinner / saving label。
- failed：显示 error + Retry / Cancel。

原因：

- 三个状态 + pending/failed + duplicate confirmation 放在固定 trailing column 内更稳定。
- menu button 比 segmented control 更能承载 confirm-required 和 unsupported 文案。

### 6.4 UI 状态机

```text
confirmed(default/allowed/restricted)
  -> pending(changePlan)
  -> saving
  -> saved(confirmed)
  -> failed(originalConfirmed, samePlan)
failed -> retry -> saving
failed -> cancel -> confirmed(original)
pending -> cancel -> confirmed(original)
unsupported -> no mutation
```

duplicate bundle id：

- plan 生成阶段计算 affected AppInstance count。
- UI 显示 bundle id、affected count、sourceDirectory/pathSummary 列表摘要，最多显示 5 条，剩余只显示 count。
- confirm 后写同一个 `bundle_id` PolicySubject。

## 7. CLI 数据流与 schema

### 7.1 命令形态

建议在现有 `blocks` CLI 下增加：

```bash
blocks privacy subjects list --type app_bundle|bundle_id|app_path|login_item|helper|launch_label|command_path --json
blocks privacy subjects resolve --type bundle_id --identifier <value> --json
blocks privacy policy get --subject-ref <ref> --json
blocks privacy policy set --subject-ref <ref> --policy default|allowed|restricted --dry-run --json
blocks privacy policy set --subject-ref <ref> --policy default|allowed|restricted --confirm --json
blocks privacy action blocked --capability tcc_reset --json
```

`privacy action blocked` 只用于稳定输出 hard-block evidence；不执行任何系统动作。

### 7.2 JSON 输出

统一 envelope：

```json
{
  "ok": true,
  "action": "privacy.policy.set",
  "dry_run": true,
  "requires_confirmation": false,
  "mutation_performed": false,
  "subject": {
    "type": "bundle_id",
    "subject_ref": "sub_v1_bundle_id_abc123",
    "display_name": "Fixture App",
    "primary_identifier": "app.fixture.example",
    "identity_status": "normal",
    "policy_status": "default",
    "ui_visible": true,
    "ui_match_count": 1,
    "path_summary": "Fixture.app",
    "path_hash": "path_abc123",
    "path_redacted": true
  },
  "policy_before": "default",
  "policy_after": "restricted",
  "warnings": [],
  "error": null
}
```

Error envelope:

```json
{
  "ok": false,
  "action": "privacy.subject.resolve",
  "error": {
    "code": "ambiguous_subject",
    "message": "Subject matched multiple local policy subjects.",
    "low_sensitive_reason": "multiple_candidates"
  },
  "candidates_count": 2,
  "mutation_performed": false
}
```

### 7.3 Subject 解析边界

Allowed:

- `app_bundle` / `bundle_id` / `app_path`：UI 三 root App index、已有 policy rules、显式 typed input。
- `command_path`：显式 absolute path input、受控 fixture、allowlisted enumeration defined in technical plan only。
- `login_item` / `helper` / `launch_label`：已有 policy rules、显式 typed input、技术方案列白名单的 fixture source。

Forbidden:

- PATH scan。
- command execution。
- shell parsing、glob、alias/function expansion。
- LaunchAgents / LaunchDaemons 全盘枚举。
- `launchctl`。
- System Settings / Finder / TCC。

Validation:

- 相对路径 rejected。
- command string with whitespace arguments rejected。
- shell metacharacters `|`, `;`, `&&`, `$(`, backtick rejected。
- ambiguous subject returns candidates and `mutation_performed=false`。

## 8. 低敏与安全边界

### 8.1 默认输出

默认不得输出：

- 完整真实路径清单。
- home path。
- real command arguments。
- icon binary / image bytes。
- TCC raw rows、csreq、requirement data、auth_value、auth_reason、indirect object identifier。
- System Settings URL。
- Finder open token。
- launchctl / tccutil / shell snippets。
- provider route / upload token。
- secret、Authorization、Bearer、password、OTP、private key、cookie、session、JWT、webhook。

默认允许：

- synthetic bundle id。
- source directory enum。
- path summary。
- path hash。
- counts。
- subject_ref。
- low-sensitive error code。

### 8.2 full-path / sensitive-output 参数

如果 CLI 提供 full-path reveal：

- 参数名建议 `--include-sensitive-paths`，默认 false。
- CLI help 必须标记 `sensitive local output`。
- 每次使用输出 warning。
- P13E、开发记录、验收记录、golden fixture 禁止使用该参数。
- P13E 发现该参数出现在 verifier command / docs evidence 中必须 fail。

### 8.3 Dangerous action hard-block

`--confirm` / `--yes` 只能确认本 App policy mutation。

Hard-block 输出：

```json
{
  "ok": false,
  "action": "privacy.action.blocked",
  "error": {
    "code": "dangerous_action_blocked",
    "low_sensitive_reason": "system_lifecycle_action_not_supported",
    "blocked_capability": "launchctl_mutation",
    "required_future_review": true
  },
  "mutation_performed": false
}
```

禁止在 error message 中提供可复制危险命令，例如 `launchctl ...`、`tccutil ...`、`open x-apple.systempreferences:`、shell snippet。

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
    "technical_plan": "docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v0.md",
    "development_record": "docs/项目管理库/004_剪贴板打磨/step_5/开发记录-Step5-v0.md"
  },
  "scan_scope": {},
  "identity_edge_matrix": {},
  "ui_policy_mutation": {},
  "cli_subjects": {},
  "dangerous_actions": {},
  "low_sensitive_scan": {},
  "performance": {},
  "failures": []
}
```

### 9.3 Fixture data shape

P13E 使用 synthetic temp roots，不读取真实 `/Applications`。

Synthetic roots：

```text
<TMP>/Applications
<TMP>/HomeApplications
<TMP>/SystemApplications
```

Fixture `.app`：

```text
FixtureNormal.app/Contents/Info.plist
FixtureDuplicateA.app/Contents/Info.plist
FixtureDuplicateB.app/Contents/Info.plist
FixtureMissingBundle.app/Contents/Info.plist
FixtureDamaged.app/Contents/Info.plist (missing / malformed)
Utilities/FixtureNested.app/Contents/Info.plist
```

P13E injects these roots into `PrivacyAppScanner` rather than scanning real roots.

### 9.4 Required scenarios

UI scan:

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

Policy mutation:

- `privacy_app_policy_mutation_success_004`
- `privacy_app_policy_mutation_failed_004`
- `privacy_app_policy_dry_run_no_mutation_004`
- `privacy_app_duplicate_bundle_confirm_004`
- `privacy_app_path_override_precedence_004`
- `privacy_app_missing_bundle_unsupported_or_path_scoped_004`

CLI:

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
- scan scope 超出三 root。
- `.app` bundle 被扫描内部内容。
- helper / login item / command path 出现在 UI App list。
- ambiguous subject 执行 mutation。
- dry-run 改变 policy store。
- `--confirm` 解锁 dangerous action。
- CLI JSON 缺 `subject_ref`、`mutation_performed`、`policy_before` / `policy_after`。
- 输出命中 forbidden token / pattern。
- 性能阈值缺失。
- large-list fixture dump 全量列表。

### 9.6 Forbidden pattern

P13E sanitizer 在既有 `verification_sanitizer.py` 基础上扩展：

- `csreq`
- `requirement_data`
- `auth_requirement`
- `auth_value`
- `auth_reason`
- `indirect_object_identifier`
- `x-apple.systempreferences`
- `System Settings`
- `Finder`
- `launchctl`
- `tccutil`
- `osascript`
- `open `
- `URLSession`
- `provider`
- `upload`
- `Authorization`
- `Bearer`
- `password`
- `OTP`
- `private key`
- `cookie`
- `session`
- `JWT`
- `webhook`
- `data:image`
- `base64`
- `/Users/`
- `/Applications/<non-synthetic>`
- real home path

Pattern 命中必须给出 label，不输出原文。

## 10. 性能阈值

技术方案固定以下数值，开发前不得缺失：

| 指标 | 阈值 |
| --- | --- |
| large-list fixture count | 3000 synthetic apps，覆盖三 root、duplicates、missing bundle id、damaged、hidden、icon failed。 |
| first page readiness | synthetic scan 下，首屏 50 row read model 在 300 ms 内可发布；首次无缓存时至少发布 loading / partial 状态。 |
| full synthetic index build | 3000 apps scan + identity classification + stable sort 在 2000 ms 内完成。 |
| search/filter response | index loaded 后 3000 apps 内搜索 / filter / sort recompute <= 120 ms。 |
| refresh no-blank | 有旧结果时 refresh 全程 `visibleRows.count > 0`；除首次加载外不得空白。 |
| icon layout stability | icon loaded / fallback / failed 前后 row height delta = 0，sort order unchanged。 |
| verifier output bound | P13E stdout <= 180 KB；每个列表类 scenario 输出 sample <= 20 rows，只输出 counts / hashes / summaries。 |
| CLI resolve response | synthetic 3000 subject index 下 resolve <= 150 ms。 |

这些阈值在 P13E 中至少做 fixture 级断言；真实机器性能可以留到 Step 6 回扫，但不能替代 P13E synthetic threshold。

## 11. 开发批次建议

### Batch A：P13E baseline + Core model / schema

目标：

- 新增 P13E skeleton，缺实现时 red。
- 新增 `PrivacyPolicyModels.swift`、`PrivacyPathSanitizer.swift`、`PrivacyPolicyRepository.swift` skeleton。
- AppDatabase v5 migration skeleton。
- 固化 CLI JSON / P13E evidence schema。
- 不接 UI，不改 capture policy。

验收：

- P13E 能 fail closed，指出缺 scanner / CLI / UI scenarios。
- Blocks App / CLI build 仍可过。

### Batch B：Scanner / icon / PrivacyStore

目标：

- 实现 `PrivacyAppScanner` synthetic roots。
- 实现 AppKit `SystemAppIconProvider` 与 fake provider。
- 新增 `PrivacyStore`，含 scan state、cache、search/filter/sort、icon state。
- AppModel 注入 `privacyStore`，只做 facade。

验收：

- P13E scan / identity / icon / performance scenarios pass。
- 不扫描真实 roots 的 P13E fixture pass。

### Batch C：Policy mutation + UI privacy pane + capture bridge

目标：

- 实现 `PrivacyPolicyRepository` apply / dry-run / transaction。
- 实现 `PrivacySettingsPane`、row、policy control、duplicate confirmation、failed retry/cancel。
- 替换旧 `ClipboardPrivacyExclusionList`。
- `Step5OneShotMigration` 迁移旧 excluded bundle ids。
- `ClipboardCapturePolicy` 接入 `PrivacyPolicySnapshot`。

验收：

- P13E UI policy mutation / duplicate / missing bundle / path override scenarios pass。
- 旧 excluded bundle id 可迁移为 restricted bundle id policy。
- UI 仍不触发系统权限 / Finder / App launch。

### Batch D：CLI + low-sensitive hardening + full regression

目标：

- `blocks privacy ...` CLI。
- subject resolver、JSON schema、dry-run、confirm apply、dangerous blocked。
- sanitizer / forbidden pattern 完整。
- target membership / project file update。

验收：

- P13E 全 PASS。
- 回归：P13A / P13B / P13C / P13D / P11E / P9A / P9B / P8 / P8I，Blocks App build，BlocksCLI build，`blocks --help`，`git diff --check`。

## 12. 风险与待复审问题

### P1 风险

当前无技术方案级 P1 阻断；但以下点必须在技术方案复审中重点看：

- AppDatabase v5 migration 是否低风险，旧库 v4 -> v5 是否有 fixture。
- `app_path` override 是否实际接入 capture policy；若只接 UI/CLI 不接 capture，会形成假策略。
- `canonical_identifier` 存储完整路径是否严格不出现在默认输出和 evidence。
- P13E 是否真 fixture / fail-closed，而不是 token presence。

### P2 残余

- 真实机器 App 图标和真实 `/Applications` 列表不在技术方案阶段验证；后续开发验收或 Step 6 回扫处理。
- 真实 VoiceOver 仍需 UI/测试验收。
- icon cache 首版仅内存，不跨启动；如产品后续要求跨启动 cache，需要安全复审。
- login item / helper / launch label 首版不做系统登记源枚举；只支持 explicit input / existing policy / fixture 白名单。

### 需要角色复审的问题

给 UI/交互：

- Policy control 使用 menu button 是否接受。
- Duplicate confirmation 和 issue overflow 的低敏 evidence 是否足够。
- `all settings` 页面是否只展示 privacy summary / entry，而不是直接加载 3000 rows。

给测试/质量：

- P13E evidence schema 和性能阈值是否可执行。
- required scenarios 是否足以覆盖 PRD v1。
- 回归矩阵是否需要增加 P13E 与 P8/P8I 的顺序要求。

给安全合规：

- `canonical_identifier` 存储完整路径的本地 DB 边界是否可接受。
- `--include-sensitive-paths` 参数是否应进入首版；若进入，help / P13E 禁用证据规则是否足够。
- login item / helper / launch label 白名单是否需要更窄。

## 13. 进入开发前检查清单

进入开发前必须满足：

- 项目负责人接受本技术方案或 v1。
- P13E evidence schema 已被角色复审接受。
- 性能阈值没有缺项。
- `app_path` override 首版支持与 capture bridge 范围被接受。
- full-path / sensitive-output 参数是否首版支持被接受；默认建议不实现，先只做 UI 显式 reveal。
- 开发派发明确禁止真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。

## 14. 本轮验证

本轮只产出技术方案文档。完成后运行：

```bash
git diff --check -- docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v0.md
```

结果：PASS。
