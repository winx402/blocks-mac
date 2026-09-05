# Step 5 PRD 复审收敛 v0

状态：prd-v1-required
日期：2026-07-07
角色：项目负责人
对象：`step_5/产品经理-PRD-v0.md`

## 1. 结论

结论：要求产品经理产出 `step_5/产品经理-PRD-v1.md`，吸收本轮 P1 后再进入技术方案。

本轮四个角色复审均为 `approve-with-changes`，未发现 P0，也未发现 Step 5 PRD v0 把 Step 1-4 或 Step 6 明显拉回当前阶段。PRD v0 的方向成立：UI 聚焦三目录真实 `.app` 清单，CLI 承接 UI 之外的广义对象管理，且不上传 provider、不静默请求权限、不做系统生命周期执行器。

但当前 P1 均属于进入技术方案前必须写硬的产品边界。如果不回写，后续架构和开发会替产品决定 UI 是否可写策略、策略事实源、duplicate bundle id 影响范围、CLI subject 解析、路径低敏输出和 dangerous action 语义。

## 2. 复审输入

- [UI/交互设计师 PRD 复审 v0](UI-交互设计师-PRD复审-v0.md)：`approve-with-changes`
- [App 架构师 PRD 复审 v0](App架构师-PRD复审-v0.md)：`approve-with-changes`
- [测试/质量 PRD 复审 v0](测试-质量-PRD复审-v0.md)：`approve-with-changes`
- [安全合规顾问 PRD 复审 v0](安全合规顾问-PRD复审-v0.md)：`approve-with-changes`
- [项目负责人 PRD 预审 v0](项目负责人-PRD预审-v0.md)
- [产品经理 PRD v0](产品经理-PRD-v0.md)

## 3. 必须回写到 PRD v1 的 P1

### P1-1：明确 Step 5 UI 策略状态是否可写

PRD v1 必须二选一：

- UI 只读：隐私页只展示策略状态、读取失败、刷新和异常状态；策略变更仅由 CLI 管理。
- UI 可写：隐私页支持 App 级策略变更，并必须定义 `Default / Allowed / Restricted` 切换、pending、saving、saved、failed、retry、cancel、失败不部分提交、duplicate bundle id 共享影响提示。

未选择前，技术方案和开发不得自行决定 UI 是否可写策略。

### P1-2：补齐 App row 信息结构与可访问性硬验收

PRD v1 需要把 App row 的信息层级写成硬口径：

- leading 固定尺寸真实图标 / fallback，异步加载不改变行高或排序。
- primary App display name，长文本有截断和完整值查看 / 复制路径。
- secondary bundle id、source directory、path summary，默认不展示完整真实路径。
- trailing policy status / control，状态不能只靠颜色或图标表达。
- issues 区展示 duplicate、missing bundle id、damaged、hidden、icon failed 等异常，行内数量受控，更多进入详情或 tooltip / popover。

最低验收必须覆盖键盘导航、VoiceOver、长 App 名、长 bundle id、长路径摘要、中文 / 英文 / 日文长文本、窄宽度布局和 active filter / focused / selected / hover 状态层级。

### P1-3：明确三目录 `.app` 的受控枚举范围

PRD v1 必须定义 `/Applications`、`~/Applications`、`/System/Applications` 的“下”是直系 `.app` 还是受控递归。

项目负责人建议采用受控枚举口径：

- root 仅限三目录。
- 可在 root 内做 bounded recursion 以覆盖用户通常认为属于该 root 的 `.app`，但不得进入任意用户目录或全盘扫描。
- 遇到 `.app` bundle 后把它视为叶子，不扫描 bundle 内部。
- 技术方案必须定义最大深度、symlink / alias / unreadable directory、单目录失败和 partial 状态。

如果产品经理选择只扫描直系 `.app`，需要明确写出不包含 Utilities 等子目录，并接受由此带来的“所有 App”预期偏差。

### P1-4：把 AppInstance / PolicySubject / PolicyRule 写成产品事实模型

PRD v1 需要把 identity 和策略分层，避免 UI / CLI 双事实源：

- `AppInstance`：UI row 事实源，包含 displayName、bundleID?、canonicalPath、sourceDirectory、iconState、identityStatus。
- `PolicySubject`：策略绑定对象，首版至少明确 `bundle_id` 与 `app_path` 的支持口径；其他类型主要由 CLI 使用。
- `PolicyRule`：Allowed / Restricted / Default 等策略事实。

UI 与 CLI 必须共享同一隐私策略事实源。UI 是 `.app` AppInstance 的可视化子集，CLI 是 PolicySubject 的广义管理入口。不得写成“同一或可映射”的双事实源弹性口径。

PRD v1 还必须定义：

- bundle id 唯一时的默认策略映射。
- duplicate bundle id 的共享策略提示和 mutation 影响范围。
- missing bundle id 是 path-scoped、Unsupported，还是只读 Unknown。
- damaged / unreadable app 的展示、策略状态和 mutation 禁止规则。
- path-scoped rule 与 bundle_id rule 的 precedence；如果暂不支持 override，需要写明 mutation unsupported 或 confirm-required。

### P1-5：补硬 CLI typed subject、`subject_ref` 和本地解析边界

PRD v1 必须明确 CLI subject 是本 App 的隐私策略 subject，不是系统对象生命周期控制器。

必须回写：

- `subject_ref` 是稳定 opaque id 或低敏 hash，不等同于完整真实路径。
- app bundle / bundle id / app path 可来自 UI 三目录 App index、已有策略事实源或显式 typed 输入。
- command_path 默认只接受显式输入或受控 fixture / allowlisted enumeration，不全盘扫描、不扫描 PATH、不执行命令、不读取命令输出、不展开 glob / alias / shell。
- login item / helper / launch label 如无法无权限、低敏、稳定枚举，首版仅支持已有策略记录或显式 typed 输入。
- ambiguous 时只返回候选，不执行 mutation；mutation 必须使用精确 subject_ref 或完整 typed subject。

### P1-6：低敏输出合同必须覆盖 CLI / audit / verification JSON

PRD v1 必须明确默认输出不含完整本机路径清单。

必须回写：

- UI 主列表、CLI 默认 JSON、audit、日志、verification JSON、开发记录和验收记录默认不得输出真实完整路径清单。
- path-like subject 默认输出 `subject_ref`、`path_summary`、`source_directory`、`path_hash` 或 `path_redacted=true`。
- 完整 canonical path 只能通过用户显式 reveal / copy 或显式敏感输出参数查看，且不得进入开发记录、验收记录、fixture golden file、日志或 provider payload。
- 错误信息不得包含完整路径、真实命令参数、权限数据库细节或系统配置 dump。
- bundle id / team id 可作为本地 identity 展示，但验收文档默认使用 synthetic 值或 hash；真实第三方 / 企业 / 个人 bundle id 不进入 fixture golden file、日志样例或 provider payload。

### P1-7：dangerous action 语义必须 hard-block

PRD v1 必须区分 confirmable policy mutation 与 hard-blocked system action：

- `--confirm` / `--yes` 只允许确认本 App 自己隐私策略事实源的 allow / restrict / default mutation。
- 以下动作 Step 5 必须 hard-block，即使提供 `--confirm` / `--yes` 也不得执行：TCC reset、请求或授予 ScreenCapture / Accessibility / Automation / Full Disk Access、打开 System Settings、打开 Finder、启动 App、执行 command_path、运行 shell、launchctl load / unload / kickstart、启停 / kill / 删除 / 安装 / 卸载登录项、helper 或命令行工具、修改系统登录项或 launch agent 状态。
- hard-blocked action 返回稳定错误码，例如 `dangerous_action_blocked`，包含 low-sensitive reason、blocked_capability、required_future_review=true。

### P1-8：P13E 或等价门禁必须升为 Step 5 hard gate

PRD v1 必须把 P13E 或等价 fail-closed gate 写成 Step 5 必需验收，而不是建议。

P13E 至少覆盖：

- 当前事实源必须指向 Step 5 PRD / 技术方案 / 开发记录。
- UI scan scope 不超出三目录，helper / login item / command path 不默认进入 UI。
- search / filter / sort / large-list fixture 完整。
- duplicate name、duplicate bundle id、missing bundle id、damaged、hidden、unsupported、icon failed fixture 完整。
- CLI typed subject、ambiguity、dry-run、confirm、dangerous blocked、JSON schema fixture 完整。
- missing bundle id、damaged、hidden、unsupported、path conflict、policy failed 的 CLI fixture 完整。
- verifier 输出不包含真实完整路径清单、home path、secret、Authorization、Bearer、token、password、OTP、private key、cookie、session、JWT、webhook、TCC raw requirement、System Settings URL、Finder open token、launchctl mutation token、shell execution token、provider route / upload token、真实 command arguments、图片原始字节或图标 binary dump。
- 不触发 provider、真实权限请求、TCC reset、System Settings、Finder、App launch、真实系统状态变更或 command execution。

### P1-9：补最低性能和稳定性验收口径

PRD v1 不一定要给最终性能数值，但必须要求技术方案给出数值阈值；缺数值不得进入开发。

最低需要量化：

- large-list fixture count。
- initial visible list readiness 或 first page readiness。
- search / filter response after index loaded。
- refresh 不清空旧列表的行为。
- icon loading 不改变行高或排序。
- verifier output 只汇总 counts，不 dump full app list。

## 4. P2 可吸收建议

以下建议不阻塞 PRD v1，但产品经理可择优吸收：

- 搜索默认 case-insensitive，bundle id 支持 segment/token match，path summary 只匹配低敏摘要。
- 同一维度多选 filter 用 OR，不同维度组合用 AND；明确 clear search / clear filters / clear all。
- 排序 tie-breaker 不依赖图标加载；重复 display name + bundle id 使用 source directory priority 和低敏 path hash。
- hidden App 的说明要区分文件系统隐藏状态和权限隐藏状态。
- CLI 与 UI 的关联对象提示不要默认塞进每个 row，可留在详情或异常提示中。
- 真实 App 图标缓存仅本地使用，验收截图优先使用 synthetic app fixture 或公开系统 App。

## 5. 给产品经理的 v1 任务边界

产品经理产出 PRD v1 时只做 Step 5，不进入 Step 6，不写技术方案，不写实现。

PRD v1 必须保留 Step 5 原有正确边界：

- UI 默认只展示三目录真实 `.app`。
- CLI 管理 UI 外广义对象，但只管理本 App 隐私策略事实源。
- 不上传 App 清单、图标、路径、策略或 CLI 输出到 provider。
- 不静默请求系统权限，不做 TCC reset，不打开 System Settings，不打开 Finder，不启动 App。
- 不执行命令，不读取命令输出，不做登录项 / helper / CLI 工具生命周期管理。

PRD v1 完成后，项目负责人再组织必要复审。PRD v1 复审通过前，不派发 Step 5 技术方案。

## 6. 本轮验证

项目负责人已读取四份复审文档，并运行：

```bash
git diff --check
```

结果：PASS。
