# Step 5 产品经理 PRD v1：隐私页真实 App 清单与 CLI 广义对象管理

状态：prd-revision-v1
修订日期：2026-07-07
起草角色：产品经理
所属项目：004_剪贴板打磨
所属阶段：Step 5
来源级别：基于 `产品经理-PRD-v0.md`、`项目负责人-PRD复审收敛-v0.md`、`UI-交互设计师-PRD复审-v0.md`、`App架构师-PRD复审-v0.md`、`测试-质量-PRD复审-v0.md`、`安全合规顾问-PRD复审-v0.md` 修订。

## 1. v0 -> v1 吸收摘要

PRD v1 吸收项目负责人收敛文档第 3 节全部 P1：

1. 明确 Step 5 UI 首版支持 App 级策略变更，不只是只读；补齐 pending / saving / saved / failed / retry / cancel / duplicate bundle id 影响范围。
2. 补齐 App row 信息结构、长文本、异常标记、键盘 / VoiceOver / 窄宽度硬验收。
3. 明确三目录 `.app` 枚举采用受控递归：root 限三目录，遇到 `.app` 视为叶子，技术方案必须给最大深度与失败 / partial 规则。
4. 写明 `AppInstance` / `PolicySubject` / `PolicyRule` 三层产品事实模型；UI 与 CLI 必须共享单一策略事实源。
5. 补硬 CLI typed subject、`subject_ref` opaque / stable、本地解析边界、ambiguous 不 mutation。
6. 补 CLI / audit / verification JSON 低敏输出合同，默认不输出完整真实路径清单。
7. 补 dangerous action hard-block；`--confirm` / `--yes` 只确认本 App policy mutation。
8. 将 P13E 或等价 fail-closed gate 升为 Step 5 hard gate。
9. 补最低性能和稳定性验收口径，并要求技术方案给出数值阈值；缺数值不得进入开发。

本阶段仍只覆盖 Step 5，不进入技术方案、开发或真实运行验证，不触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。

## 2. 阶段目标

Step 5 聚焦隐私页真实 App 清单与 CLI 广义对象管理。

目标：

- 隐私页默认展示 `/Applications`、`~/Applications`、`/System/Applications` 三个 root 下受控枚举到的真实 `.app`。
- 使用真实系统 App 图标，图标读取失败时使用稳定 fallback。
- 隐私页支持搜索、过滤、稳定排序、大量 App 列表和 App 级策略状态查看 / 变更。
- CLI 面向本地 agent 管理 UI 外的广义隐私策略对象，例如登录项、helper、命令行工具等，但只管理本 App 自己的隐私策略事实源。
- 全程本地枚举、本地展示、本地策略管理；不上传 provider，不静默请求权限，不做系统生命周期管理。

## 3. 需求覆盖矩阵对齐

| 矩阵 ID | 本阶段覆盖口径 |
| --- | --- |
| R9 | 隐私页默认展示三目录真实 `.app`，使用真实系统 App 图标，fallback 稳定可验。 |
| C8 | UI 管理三目录 `.app`；CLI 管理 UI 外广义 PolicySubject，如登录项、helper、命令行工具。 |
| C1 / C12 | 延续“真实内容可访问，交互输出可控”：允许本地枚举身份和策略，但 UI / CLI / audit / verification 输出低敏、可控。 |
| C13 | 不新增复杂权限开关，不静默请求 ScreenCapture / Accessibility / Automation / Full Disk Access，不 TCC reset，不打开 System Settings / Finder。 |
| C16 | App identity、PolicySubject、PolicyRule 分层，为 UI 和 CLI 共享策略事实源打基础。 |
| C17 | 覆盖大量 App、长文本、重复身份、异常状态、键盘 / VoiceOver、低敏证据和性能稳定性。 |

不属于本阶段：

- Step 1 明文展示、搜索底座、OCR。
- Step 2 标签 / 收藏。
- Step 3 面板 hover、toolbar、点击模式、条目密度。
- Step 4 详情编辑、保存事务、dirty guard。
- Step 6 最终集成回扫。

## 4. 明确非目标

本阶段不覆盖：

- 不扫描 UI 范围外的所有对象到隐私页；登录项、helper、命令行工具默认只进入 CLI。
- 不做任意系统状态变更执行器。
- 不请求、授予或引导授予 ScreenCapture、Accessibility、Automation、Full Disk Access。
- 不执行 TCC reset。
- 不打开 System Settings。
- 不打开 Finder。
- 不启动 App 来读取身份或图标。
- 不执行 command_path，不运行 shell，不读取命令输出。
- 不删除、启停、kill、安装、卸载登录项、helper、命令行工具。
- 不修改系统登录项、launch agent 或 launch daemon 状态。
- 不上传 App 清单、图标、路径、策略、CLI 输出、audit 或 verification JSON 到 provider。

## 5. UI 策略状态：首版可写

Step 5 UI 首版支持 App 级策略变更，不是只读状态页。

UI 支持对可管理 App 切换：

- `Default`
- `Allowed`
- `Restricted`

策略变更只写本 App 自己的隐私策略事实源，不触发系统权限申请或系统状态变化。

### 5.1 UI 策略状态机

| 状态 | 用户可见行为 | 操作 |
| --- | --- | --- |
| default / allowed / restricted | 显示当前策略状态。 | 可切换到其他状态，若 subject 可管理。 |
| pending | 用户选择新策略但尚未提交或确认影响范围。 | 可取消。 |
| saving | 正在写入本 App policy store。 | 禁止重复提交；保留原状态显示或展示 pending state。 |
| saved | 写入成功，row 状态更新。 | 可继续操作。 |
| failed | 写入失败，原策略状态保持，错误行内可见。 | Retry / Cancel。 |
| retry | 用户重试失败的策略写入。 | 进入 saving。 |
| cancel | 用户取消 pending 或 failed 草稿。 | 回到原策略状态。 |
| unsupported | identity 不足或 subject 不支持 mutation。 | 不显示可写控件，只显示原因。 |

失败语义：

- 失败不产生用户可见部分提交。
- 失败反馈必须行内可见，并可被 VoiceOver 理解。
- Retry 重试同一 mutation plan。
- Cancel 回到最近一次已确认策略状态。

### 5.2 Duplicate Bundle ID 影响范围

如果 AppInstance 使用 `bundle_id` PolicySubject，且多个 AppInstance 共享同一 bundle id：

- 所有相关 row 必须显示 duplicate / shared-policy 提示。
- UI mutation 前必须显示影响范围说明，至少包含受影响 App 数量、bundle id、低敏路径摘要 / source directory。
- 用户确认后，mutation 影响同一 `bundle_id` PolicySubject 下的所有 AppInstance。
- 不得让用户误以为只修改当前一行。

如果技术方案支持 path-scoped override：

- UI 必须明确当前操作是修改 `bundle_id` rule 还是 `app_path` override。
- path override 优先级必须在 PRD / 技术方案中清楚显示。

如果暂不支持 path-scoped override：

- duplicate bundle id 场景下只能修改共享 `bundle_id` rule，或对有风险操作显示 confirm-required。

## 6. 三目录 `.app` 受控枚举

UI App 枚举范围采用三条 root 的受控递归：

- `/Applications`
- `~/Applications`
- `/System/Applications`

规则：

- root 仅限以上三目录。
- 可在 root 内做 bounded recursion，以覆盖用户通常认为属于该 root 的 `.app`，例如工具类子目录。
- 不进入任意用户目录或全盘扫描。
- 遇到 `.app` bundle 后视为叶子节点，不扫描 bundle 内部嵌套内容。
- 不跟随会逃出三条 root 的 symlink / alias。
- unreadable directory、alias 失败、单个 App 损坏只产生 partial / row-failed，不让整页空白。
- 技术方案必须定义最大递归深度、目录跳过规则、symlink / alias 处理、unreadable directory 处理和 partial 状态。
- 缺少最大深度、跳过规则和 partial 口径时，不得进入开发。

如果后续技术方案发现受控递归成本不可接受，必须回到项目负责人做范围取舍，不能自行降级为直系扫描。

## 7. 产品事实模型

Step 5 使用三层产品事实模型，避免 UI / CLI 双事实源。

### 7.1 AppInstance

`AppInstance` 是 UI row 的事实源，代表一个实际可识别 `.app`。

字段口径：

- `displayName`
- `bundleID?`
- `canonicalPath`，默认只用于本地解析，不进入默认低敏输出。
- `sourceDirectory`
- `pathSummary`
- `pathHash`
- `iconState`：loaded、fallback、failed、loading。
- `identityStatus`：normal、duplicate_name、duplicate_bundle_id、missing_bundle_id、damaged、hidden、unsupported、policy_failed。
- `policySubjectRef?`
- `policyStatus`

### 7.2 PolicySubject

`PolicySubject` 是策略绑定对象，是 UI 和 CLI 共享的策略 subject。

首版支持：

- `bundle_id`
- `app_path`
- `app_bundle`
- `login_item`
- `helper`
- `launch_label`
- `command_path`

其中 UI 默认只展示 `.app` AppInstance；CLI 可管理更广 PolicySubject。

### 7.3 PolicyRule

`PolicyRule` 是绑定到 PolicySubject 的策略事实：

- `Default`
- `Allowed`
- `Restricted`

UI 与 CLI 必须共享同一隐私策略事实源。UI 是 `.app` AppInstance 的可视化子集；CLI 是 PolicySubject 的广义管理入口。不得写成“同一或可映射”的双事实源弹性口径。

### 7.4 策略解析规则

- bundle id 存在且唯一：UI 默认映射到 `bundle_id` PolicySubject。
- duplicate bundle id：所有 AppInstance 展示 shared-policy 提示；mutation 必须说明共享影响范围。
- missing bundle id：如 canonical path 可用且 path-scoped 策略被技术方案接受，则映射到 `app_path`；否则显示 Unsupported，只读。
- damaged / unreadable App：可展示 AppInstance，但默认 Unknown / Unsupported，不允许静默创建不可靠策略。
- hidden App：如位于受控枚举范围且可识别 `.app`，正常展示并标记 hidden；hidden 是文件系统隐藏状态，不代表权限隐藏。
- 同一 App 同时命中 `app_path` 与 `bundle_id` rule 时，推荐 `app_path` 优先并显示 override 来源；若技术方案暂不支持 override，相关 mutation 必须 Unsupported 或 confirm-required。

## 8. App Row 信息结构与可访问性

每个 App row 使用固定高度或稳定自适应高度，不因图标异步加载、状态变化或异常标记出现而跳动。

默认层级：

- Leading：固定尺寸真实 App 图标；读取失败时使用同尺寸 fallback。
- Primary：App display name，单行优先，过长时中间或尾部截断。
- Secondary：bundle id、source directory、path summary，最多两行；默认不展示完整真实路径。
- Trailing：policy status / control；状态文案、图标、颜色不能互为唯一信息来源。
- Issues：duplicate、missing bundle id、damaged、hidden、icon failed、unsupported 等异常最多行内展示 1-2 个紧凑标记，更多进入详情、tooltip 或 popover。

长文本规则：

- 长 App 名、长 bundle id、长 path summary 不得挤压 policy control。
- 完整值必须有显式复制、详情或 reveal-in-app 入口；不得通过打开 Finder 实现。
- 窄宽度下降级为单列或两行布局，policy status 仍可见。
- 中文、英文、日文长文本进入低敏 fixture。

键盘验收：

- Tab / Shift-Tab 可进入和退出列表。
- 方向键或等价机制可移动 row focus。
- Enter / Space 可触发主要动作或打开详情。
- Esc 可关闭 popover、detail、filter menu。
- focused、selected、hover、active filter 状态视觉层级可区分，不只依赖颜色。

VoiceOver 验收：

- 每行至少读出 App 名、policy status、bundle id 可用性、source directory、主要异常标记。
- policy control 需要 label、value、hint。
- duplicate / damaged / missing bundle id / unsupported 不只靠颜色或图标表达。

## 9. 搜索、过滤、排序

### 9.1 搜索

搜索字段：

- display name
- bundle id
- source directory
- path summary
- policy status
- identity issue code

默认规则：

- display name 和 bundle id case-insensitive。
- bundle id 支持 segment / token match，具体 tokenization 由技术方案确认。
- path search 只匹配 sanitized source directory / file name summary，不匹配完整 raw home path。
- 无结果显示空态和 clear search。
- 搜索不上传 provider，不读取剪贴板 payload。

### 9.2 过滤

过滤维度：

- source directory。
- policy status。
- identity status。
- icon state。
- hidden / non-hidden。

组合规则：

- 同一维度多选使用 OR。
- 不同维度组合使用 AND。
- `Clear filters` 只清过滤。
- `Clear search` 只清搜索。
- `Clear all` 同时清搜索和过滤。
- loading / partial 状态下的结果数量必须标记 partial，不能伪装最终数量。

### 9.3 排序

默认排序：

1. display name，本地化 / 大小写不敏感。
2. bundle id。
3. source directory priority：`/Applications`、`~/Applications`、`/System/Applications`。
4. sanitized path summary。
5. stable path hash。

排序不得依赖图标加载完成。相同 fixture refresh 后 row order 保持稳定。

## 10. CLI Typed Subject

CLI subject 是“本 App 隐私策略 subject”，不是系统对象生命周期控制器。

### 10.1 Subject Model

CLI 必须使用 typed subject model。

字段：

- `type`
- `subject_ref`
- `display_name`
- `primary_identifier`
- `resolved_identifiers`
- `policy_status`
- `identity_status`
- `ui_visible`
- `ui_match_count`
- `policy_subject_ref`
- `path_summary`
- `source_directory`
- `path_hash`
- `path_redacted`

`subject_ref` 必须是稳定 opaque id 或低敏 hash，不等同于完整真实路径。

### 10.2 本地解析边界

- `app_bundle` / `bundle_id` / `app_path` 可来自 UI 三目录 App index、已有策略事实源或显式 typed 输入。
- `command_path` 默认只接受显式输入，或受控 fixture / allowlisted enumeration。
- `command_path` 不全盘扫描，不扫描 PATH，不执行命令，不读取命令输出，不解析 shell alias / function，不展开 glob / alias / shell。
- 相对路径、shell 片段、带参数 command string 默认 rejected。
- `login_item` / `helper` / `launch_label` 如无法无权限、低敏、稳定枚举，首版仅支持已有策略记录或显式 typed 输入。
- CLI list / resolve 只能读取技术方案明确列出的本地登记源或调用方显式 subject。
- ambiguous 时只返回候选，不执行 mutation。
- mutation 必须使用精确 `subject_ref` 或完整 typed subject。

### 10.3 CLI Action Matrix

CLI 最低 action：

- list subjects。
- resolve subject。
- get policy。
- dry-run policy change。
- apply policy change with confirm。
- blocked dangerous action。

每个 action 必须支持 JSON 输出与稳定低敏错误。

## 11. CLI / Audit / Verification 低敏输出合同

默认输出低敏：

- UI 主列表、CLI 默认 JSON、audit、日志、verification JSON、开发记录和验收记录默认不得输出真实完整路径清单。
- path-like subject 默认输出 `subject_ref`、`path_summary`、`source_directory`、`path_hash` 或 `path_redacted=true`。
- 完整 canonical path 只能通过用户显式 reveal / copy 或显式敏感输出参数查看。
- 完整 canonical path 不得进入开发记录、验收记录、fixture golden file、日志或 provider payload。
- 错误信息不得包含完整路径、真实命令参数、权限数据库细节或系统配置 dump。
- bundle id / team id 是本地 identity 字段，不视为 secret；但验收文档默认使用 synthetic 值或 hash。
- 真实第三方 / 企业 / 个人 bundle id 不进入 fixture golden file、日志样例或 provider payload。
- 真实 App 图标缓存仅用于本地 UI，不上传 provider，不写入验收文档；验收截图优先使用 synthetic app fixture 或公开系统 App。

## 12. Confirm 与 Dangerous Action Hard-Block

`--confirm` / `--yes` 只允许确认本 App 自己隐私策略事实源中的 policy mutation：

- allow。
- restrict。
- default。

以下动作 Step 5 必须 hard-block，即使提供 `--confirm` / `--yes` 也不得执行：

- TCC reset。
- 请求或授予 ScreenCapture / Accessibility / Automation / Full Disk Access。
- 打开 System Settings。
- 打开 Finder。
- 启动 App。
- 执行 command_path。
- 运行 shell。
- `launchctl load` / `unload` / `kickstart`。
- 启停、kill、删除、安装、卸载登录项、helper、命令行工具。
- 修改系统登录项或 launch agent 状态。

hard-blocked action 返回稳定错误码，例如 `dangerous_action_blocked`，并包含：

- `low_sensitive_reason`
- `blocked_capability`
- `required_future_review=true`

错误不得输出完整路径、真实命令行参数、权限数据库细节或系统配置 dump。

## 13. 性能与稳定性验收

PRD 不写死最终数值，但技术方案必须给出数值阈值；缺数值不得进入开发。

技术方案至少量化：

- large-list fixture count，至少在 500 / 1000 / 3000 synthetic apps 中选择明确目标。
- initial visible list readiness 或 first page readiness。
- search / filter response after index loaded。
- refresh 行为：有旧结果时不得清空为白屏，除非首次加载无数据。
- icon loading 不改变行高或排序。
- memory / output bound：verifier 输出只汇总 counts，不 dump full app list。

产品验收最低口径：

- large-list 下先显示 loading / partial，而不是阻塞或空白。
- 单个 App / icon / policy 失败不影响其他 row。
- refresh 保留旧列表直到新结果可用或明确显示 partial。
- search / filter 在 partial 状态下显示 partial result count。

## 14. 统一 Identity Edge Case Matrix

| Case | UI expected | CLI expected | Policy expected |
| --- | --- | --- | --- |
| duplicate name | 全部展示，用 bundle id / source directory / path summary 区分。 | 候选列表。 | 不静默合并。 |
| duplicate bundle id | 标记 duplicate / shared policy。 | `ambiguous_subject`，除非精确 subject_ref。 | 明示共享影响范围。 |
| missing bundle id | path-scoped 或 Unsupported。 | typed subject 带 missing id status。 | 不按空 bundle id 写策略。 |
| damaged app | row-failed / Unknown / Unsupported。 | stable error code。 | 不阻塞其他对象，不创建不可靠 rule。 |
| hidden app | 可展示 / 可过滤，标记 hidden。 | `identity_status=hidden`。 | 正常或 Unsupported 明示。 |
| unsupported subject | UI 显示 Unsupported 或不展示。 | `unsupported_subject`。 | mutation blocked。 |
| path conflict | UI 显示冲突提示。 | ambiguous。 | 不静默选择。 |
| policy failed | row 内 Unknown / failed。 | low-sensitive error code。 | 不产生部分提交。 |

## 15. Fixture 与最低验收矩阵

### 15.1 UI fixture

- `privacy_apps_three_dirs_004`
- `privacy_apps_bounded_recursion_004`
- `privacy_app_icon_success_004`
- `privacy_app_icon_failed_004`
- `privacy_app_duplicate_name_004`
- `privacy_app_duplicate_bundle_id_004`
- `privacy_app_missing_bundle_id_004`
- `privacy_app_damaged_004`
- `privacy_app_hidden_004`
- `privacy_apps_large_list_004`
- `privacy_app_policy_failed_004`
- `privacy_app_policy_mutation_success_004`
- `privacy_app_policy_mutation_failed_004`
- `privacy_app_row_a11y_004`
- `privacy_app_narrow_width_004`
- `privacy_app_long_text_i18n_004`

### 15.2 CLI fixture

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

### 15.3 最低验收矩阵

- UI scan scope：三 root 受控递归，`.app` 为叶子。
- UI row：固定 icon、primary name、secondary identity、trailing policy、issues overflow。
- UI mutation：Default / Allowed / Restricted、pending、saving、saved、failed、retry、cancel、duplicate bundle id 影响范围。
- UI accessibility：keyboard、VoiceOver、窄宽度、长文本、多语言、状态层级。
- CLI subject：typed subject、opaque subject_ref、ambiguous 不 mutation、unsupported 不 mutation。
- CLI action：list、resolve、get policy、dry-run、confirm apply、dangerous blocked。
- Safety：不 provider、不权限请求、不 TCC reset、不 System Settings、不 Finder、不 App launch、不 command execution。
- Low-sensitive output：默认不输出完整路径清单、home path、真实 command arguments、secret、token、Authorization、cookie、session、JWT、webhook、TCC raw requirement、System Settings URL、Finder open token、launchctl mutation token、shell execution token、provider route / upload token、图片原始字节或图标 binary dump。

## 16. P13E Hard Gate

Step 5 必须提供 P13E 或等价 fail-closed gate。P13E 是进入开发验收的 hard gate，不是建议。

P13E 至少覆盖：

1. 当前事实源必须指向 Step 5 PRD / 技术方案 / 开发记录。
2. UI scan scope 不超出三目录受控递归。
3. `.app` bundle 是枚举叶子，不扫描 bundle 内部。
4. helper / login item / command path 不默认进入 UI。
5. search / filter / sort / large-list fixture 完整。
6. duplicate name、duplicate bundle id、missing bundle id、damaged、hidden、unsupported、icon failed fixture 完整。
7. UI policy mutation 状态和 duplicate bundle id 影响范围 fixture 完整。
8. CLI typed subject、ambiguity、dry-run、confirm、dangerous blocked、JSON schema fixture 完整。
9. missing bundle id、damaged、hidden、unsupported、path conflict、policy failed 的 CLI fixture 完整。
10. ambiguous subject 不执行 mutation。
11. dry-run 不改变事实源。
12. `--confirm` / `--yes` 只确认本 App policy mutation。
13. dangerous action 即使带 confirm 也 hard-block。
14. verifier 输出不包含真实完整路径清单、home path、secret、Authorization、Bearer、token、password、OTP、private key、cookie、session、JWT、webhook、TCC raw requirement、System Settings URL、Finder open token、launchctl mutation token、shell execution token、provider route / upload token、真实 command arguments、图片原始字节或图标 binary dump。
15. 不触发 provider、真实权限请求、TCC reset、System Settings、Finder、App launch、真实系统状态变更或 command execution。
16. 性能阈值存在并被引用；缺少 large-list count、readiness、search/filter response、refresh、icon loading 稳定性数值时 fail。

## 17. 需要技术方案回答的问题

1. 受控递归最大深度、跳过规则、symlink / alias / unreadable directory 处理。
2. 图标读取、缓存、stale / missing / failed 状态和 fallback 来源。
3. `AppInstance` / `PolicySubject` / `PolicyRule` 的实际字段与事实源。
4. `bundle_id` 与 `app_path` rule precedence；是否支持 path-scoped override。
5. duplicate bundle id mutation 的 UI 确认和 CLI 输出。
6. missing bundle id / damaged App 是否支持 path-scoped 策略。
7. CLI `subject_ref` 生成规则和稳定性。
8. CLI 受控枚举源和显式 typed input 边界。
9. JSON schema、audit schema、verification evidence schema。
10. P13E 的具体 verifier 组合和性能数值阈值。

## 18. 保留边界

PRD v1 保留 Step 5 正确边界：

- UI 默认三目录真实 `.app`。
- CLI 管理 UI 外广义对象，但只管理本 App 隐私策略事实源。
- 不上传 provider。
- 不静默权限。
- 不 TCC reset。
- 不打开 System Settings / Finder。
- 不启动 App。
- 不执行命令。
- 不做登录项 / helper / CLI 工具生命周期管理。
