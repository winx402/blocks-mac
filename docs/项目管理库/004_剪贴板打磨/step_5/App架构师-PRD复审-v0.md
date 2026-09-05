# Step 5 App 架构师 PRD 复审 v0

日期：2026-07-07
角色：App 架构师
对象：`004_剪贴板打磨` Step 5 PRD v0
结论：`approve-with-changes`

## 1. 结论

Step 5 PRD v0 范围基本正确，可以继续推进到 PRD v1 收敛；但进入技术方案前需要补清几个架构边界，否则技术方案会替 PRD 做关键产品取舍。

本轮没有发现 P0，也没有发现 Step 5 明显把 Step 1-4 或 Step 6 拉回来的问题。主要 P1 集中在：

- `.app` 枚举范围的“下”到底是直系、有限递归还是包含 Utilities 等子目录。
- App row identity、policy subject 和 policy fact source 的关系还不够硬。
- UI 与 CLI 应共享单一策略事实源，而不是“同一或可映射”这种可漂移口径。
- CLI typed subject 的本地解析边界、`subject_ref` 稳定性和 mutating action 范围需要更明确。

建议：`approve-with-changes`，要求产品经理在 PRD v1 中吸收 P1 推荐口径；P2 可留给技术方案或测试验收细化。

## 2. 复审输入

按任务要求只读以下文档：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD派发-Step5-v0.md`
- `docs/项目管理库/004_剪贴板打磨/需求覆盖矩阵-v0.md`

未读取代码，未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置、Finder 或自动化动作。

## 3. 总体判断

PRD v0 已覆盖派发主线：

- UI 默认展示 `/Applications`、`~/Applications`、`/System/Applications` 下 `.app`。
- 真实 App 图标、fallback、搜索、过滤、排序、大量列表、局部失败均有产品口径。
- duplicate name、duplicate bundle id、missing bundle id、damaged app、hidden app、icon failed 均有用户可见状态。
- CLI 面向更广 typed subject，含 app bundle、bundle id、app path、login item、helper、launch label、command path。
- dry-run、confirm、dangerous action blocked、低敏输出和 provider / TCC / System Settings 禁止边界已覆盖。

PRD v0 没有明显越界：

- 没有重开 Step 1 明文展示 / 搜索 / OCR。
- 没有重开 Step 2 标签 / 收藏。
- 没有重开 Step 3 面板布局。
- 没有重开 Step 4 详情编辑。
- 没有把 Step 6 的真实环境回扫写成 Step 5 已完成事实。

## 4. P0 / P1 / P2

### P0

无。

### P1-1：`.app` 枚举范围仍有歧义，可能导致“默认展示所有 App”的验收口径漂移

问题：

PRD 写的是扫描 `/Applications`、`~/Applications`、`/System/Applications` 下可识别 `.app`，同时写了“不递归扫描任意用户目录”。这能排除全盘扫描，但没有明确三目录内部是只看直系 `.app`，还是允许有限递归。macOS 的系统应用和工具类 App 可能位于这些 root 的子目录中，例如 Utilities 类目录；如果 PRD 不定义，技术方案会自行决定“所有 App”的实际用户可见范围。

推荐 PRD v1 直接吸收：

```markdown
UI App 枚举范围定义为三条 root 的受控枚举：
- root 仅限 `/Applications`、`~/Applications`、`/System/Applications`。
- 允许在这些 root 内做 bounded recursion 以发现用户通常认为属于该 root 的 `.app`，但不得进入任意用户目录或全盘扫描。
- 遇到 `.app` bundle 后把它视为叶子节点，不扫描 bundle 内部嵌套内容。
- 技术方案需明确最大递归深度、跳过规则、symlink / alias / unreadable directory 处理，并用 fixture 验收。
- 单个目录或 App 读取失败只能产生 row-failed / partial 状态，不让整个隐私页空白。
```

如果产品只想直系扫描，也应在 PRD v1 明确写成“只扫描三目录直系 `.app`，不包含 Utilities 等子目录”。当前建议采用受控枚举，因为更符合“电脑里所有 App”的用户预期。

### P1-2：App identity、policy subject、policy fact source 需要分层，否则 duplicate bundle id / missing bundle id 会变成实现期取舍

问题：

PRD 已列出 display name、bundle id、path、source dir、异常状态，但还没有明确三类对象的关系：

- `AppInstance`：UI 列表中的一个实际 `.app` row。
- `PolicySubject`：策略真正绑定的对象，例如 bundle id 或 canonical app path。
- `PolicyRule`：Allowed / Restricted / Default 等策略事实。

没有这层分离时，重复 bundle id、无 bundle id、损坏 App 会出现两个风险：UI row 看似独立但实际共享策略，或 CLI 和 UI 对同一对象给出不同状态。

推荐 PRD v1 直接吸收：

```markdown
App identity 分三层：
- AppInstance：UI row 的事实源，至少包含 displayName、bundleID?、canonicalPath、sourceDirectory、iconState、identityStatus。
- PolicySubject：策略绑定对象，首版允许 `bundle_id` 与 `app_path` 两类；其他类型仅 CLI 使用。
- PolicyRule：绑定到 PolicySubject 的策略事实，UI / CLI 均读取同一事实源。

默认策略解析：
- bundle id 存在且唯一：UI 默认映射到 `bundle_id` subject。
- duplicate bundle id：所有 row 都展示 duplicate 和 shared-policy 提示；任何 UI mutating action 必须说明会影响同 bundle id 的所有 App，或要求用户选择 path-scoped override。不得静默只改当前 row。
- missing bundle id：如 canonical path 可用且 PRD 接受 path-scoped 策略，则映射到 `app_path`；否则显示 Unsupported。
- damaged / unreadable app：可展示为 AppInstance，但默认 Unknown / Unsupported，不允许静默创建不可靠策略。
```

### P1-3：UI 与 CLI 的策略事实源关系需要从“共用或可映射”收紧为单一事实源

问题：

PRD 第 7 节写“UI 与 CLI 应指向同一隐私策略事实源或可映射的策略模型”。从架构边界看，“或可映射”会给后续留下双事实源风险：UI 用 app list 状态，CLI 用 typed subject 状态，两者可能对同一个 bundle id 或 path 输出不一致。

推荐 PRD v1 直接吸收：

```markdown
UI 与 CLI 必须共享同一隐私策略事实源。UI 是 `.app` AppInstance 的可视化子集；CLI 是 PolicySubject 的广义管理入口。

CLI 输出 app bundle / bundle id / app path 时，必须能映射回 UI AppInstance，输出 `ui_visible=true/false`、`ui_match_count`、`policy_subject_ref`。

如果同一 App 同时命中 bundle_id rule 与 app_path rule，PRD v1 需要明确 precedence：
- 推荐：path-scoped rule 优先于 bundle_id rule，并在 UI / CLI 中显示 override 来源。
- 如果暂不支持 path override，则 duplicate / missing bundle id 的 mutating action 必须 Unsupported 或 confirm-required。
```

### P1-4：CLI typed subject 的本地解析边界和 `subject_ref` 稳定性还需补硬

问题：

PRD 已要求 typed subject，不允许混成自由字符串，这是正确方向。但 `subject_ref` 如何稳定、哪些 subject 允许枚举、哪些只允许显式输入、mutating action 到底只改本 App 策略还是会触碰系统对象，还需要产品层明确。

推荐 PRD v1 直接吸收：

```markdown
CLI subject 是“本 App 隐私策略 subject”，不是系统对象生命周期控制器。

首版 mutating action 只允许修改本 App 自己的策略事实源，不允许启停、删除、kill、安装、卸载、授权、重置或打开系统设置。

`subject_ref` 是本 App 生成的稳定 opaque id，不等同于原始完整路径；结构化输出可包含低敏 path summary / hash，但默认不输出完整真实路径。

subject 解析边界：
- app_bundle / bundle_id / app_path：可来自 UI 三目录 App index、已有策略事实源或显式 typed 输入。
- command_path：默认只接受调用方显式提供的路径或受控 fixture / allowlisted enumeration；不全盘扫描。
- login_item / helper / launch_label：首版如无法无权限、低敏、稳定枚举，应只支持已有策略记录或显式 typed 输入；广泛系统枚举留给技术方案确认并经安全复审。
- ambiguous 时只返回候选，不执行 mutation；mutation 必须使用精确 subject_ref 或完整 typed subject。
```

### P2-1：真实图标读取与缓存口径可再具体，但不阻塞 PRD v1

PRD 已要求真实图标、fallback、缓存由技术方案确认。建议 PRD v1 补一句：

```markdown
图标缓存 keyed by app identity 和 icon source metadata，必须支持 stale / missing / failed 状态；图标异步完成不得改变列表排序或行高。
```

### P2-2：路径低敏输出需要统一字段口径

PRD 已要求不输出真实完整路径清单。建议补充：

```markdown
验收 JSON / CLI 默认输出使用 `path_summary`、`source_dir`、`path_hash` 或 `path_redacted=true`，完整路径只允许用户显式本地操作时查看或复制，不写入项目文档和默认日志。
```

### P2-3：P13E 建议门禁可以增加架构负向断言

PRD 第 14 节的 P13E 方向合理。建议后续技术方案至少补这些断言：

- UI App index 只来自三 root 受控枚举，不来自全盘扫描。
- `.app` bundle 是枚举叶子，不扫描 bundle 内部。
- UI row identity、policy subject、policy rule 三层字段齐全。
- Duplicate bundle id / missing bundle id 的 mutating action 不静默落错 subject。
- CLI mutating action 只写本 App policy store，不触发 login item/helper/system lifecycle 操作。
- Provider / TCC / System Settings / Finder / command execution forbidden token scan fail closed。
- 图标读取使用 fake icon provider / fixture，不启动真实 App。

### P2-4：性能阈值和刷新策略可留给技术方案，但 PRD 可给验收下限

建议 PRD v1 给出产品级下限，不要求具体技术实现：

```markdown
大量 App fixture 下，隐私页应先显示 loading / partial，而不是阻塞或空白；刷新时保留旧列表直到新结果可用，单个 App 失败不影响其他 row。
```

## 5. 对五个复审重点的回答

### 5.1 `.app` 枚举、真实图标、缓存、fallback

PRD 方向可落地，但需要补清“受控枚举”规则。真实图标读取、缓存、fallback 不应在 PRD 指定 API，但 PRD 应要求稳定尺寸、失败状态、异步加载不改排序、不启动 App、不请求权限。

建议 P13E 用 fixture icon provider 覆盖 success / failed / stale / fallback，不用真实 App 图标作为唯一证据。

### 5.2 App identity model

PRD 当前字段齐全，但事实源口径还不够硬。推荐把 identity 拆成 AppInstance、PolicySubject、PolicyRule 三层，并明确 duplicate bundle id、missing bundle id、damaged app 的 policy resolution 规则。

### 5.3 UI 与 CLI 策略事实源

PRD 的“UI 只展示真实 `.app`，CLI 管理更广 typed subject”是正确分层。需要把“同一或可映射”改成“单一策略事实源 + 不同入口视图”，避免后续双事实源。

### 5.4 CLI typed subject model

PRD 对 type、subject_ref、display_name、primary_identifier、resolved_identifiers、policy_status、identity_status、ui_visible 的字段要求是可用起点。进入技术方案前还需明确 subject_ref opaque/stable、显式输入 vs 受控枚举、login item/helper/launch label 的本地边界。

### 5.5 Step 5 范围遗漏或越界

未发现明显遗漏。PRD 覆盖 R9、C8、C13、C16、C17 的当前阶段责任，也没有把 Step 1-4 已验收内容重新打开。Step 6 回扫仍应保留真实环境、可访问性和端到端一致性验证。

## 6. 建议给项目负责人的取舍

建议项目负责人要求产品经理产出 PRD v1，吸收以上 P1 后再进入技术方案派发。

不建议直接 reject：PRD v0 的范围控制、非目标、危险动作边界和 fixture 方向是正确的。当前问题主要是产品级架构口径不够硬，不是方向错误。

不建议进入技术方案前由 App 架构师自行决定 duplicate bundle id、path-scoped policy、CLI subject_ref 和受控枚举深度。这些决定会影响用户可见行为和验收口径，应先在 PRD v1 固化。

## 7. 本轮验证

本轮只做文档复审。按任务要求，完成文档后运行：

```bash
git diff --check -- docs/项目管理库/004_剪贴板打磨/step_5/App架构师-PRD复审-v0.md
```

结果：PASS。
