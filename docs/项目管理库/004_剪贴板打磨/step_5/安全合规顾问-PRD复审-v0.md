# Step 5 安全合规顾问 PRD 复审 v0

状态：role-review-complete
日期：2026-07-07
复审角色：安全合规顾问
复审对象：004_剪贴板打磨 Step 5 PRD v0：隐私页真实 App 清单与 CLI 广义对象管理

## 结论

结论：`approve-with-changes`

P0：0
P1：2
P2：4

PRD v0 的方向可以继续收敛，不需要回到用户重新澄清，也不需要推翻 Step 5 范围。当前文档已经明确本地枚举、本地展示、不上传 provider、不静默请求 ScreenCapture / Accessibility / Automation / Full Disk Access、不执行 TCC reset、不打开 System Settings，并且没有把 Step 1-4 或 Step 6 范围拉入 Step 5。

但进入技术方案或开发前，建议产品经理在 PRD v1 中补两个安全 P1：CLI / audit 默认输出的路径低敏合同，以及 dangerous action 的 hard-block 与 confirm 语义边界。两者都属于可直接回写的边界补强，不是产品方向返工。

## 复审范围

按任务要求，只读取并复审以下文档：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD派发-Step5-v0.md`
- `docs/项目管理库/004_剪贴板打磨/需求覆盖矩阵-v0.md`

本轮未进入技术方案、开发或真实运行验证；未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作；未修改 PRD 正文或业务代码。

## P0 Findings

无。

## P1 Findings

### P1-1：CLI / audit 默认输出缺少完整路径低敏合同

事实依据：

- PRD 已要求 UI 主列表不默认完整展示真实本机长路径，完整路径只能显式复制、展开或详情查看。
- PRD 已要求验收证据使用 synthetic / low-sensitive fixture，不把真实完整路径清单写入文档。
- 但 CLI typed subject model 中 `primary_identifier` 对 `app_path`、`command_path` 可为 canonical path；结构化输出要求包含 `subject`、`policy_before`、`policy_after`、warnings、errors，尚未明确默认 JSON / audit / dry-run 是否允许输出完整真实路径。

风险：

- Step 5 的 CLI 面向本地 agent，默认 JSON 很容易被开发记录、验收记录、日志或 agent transcript 复制进仓库文档。
- 如果 default CLI 输出直接包含 `~/Applications/...`、命令行工具真实路径、helper 路径或 launch agent 路径，会把本机用户名、目录结构、企业软件痕迹或敏感工具路径扩散到低敏证据之外。

必须回写的推荐口径：

```text
CLI / audit / verification JSON 默认不得输出完整本机路径清单。所有 path-like subject 默认输出 path_summary、source_directory、path_hash 或 subject_ref；完整 canonical path 只能在用户显式 reveal / copy / --include-full-paths / --show-sensitive-paths 等动作下输出，且不得写入开发记录、验收记录、fixture golden file、日志或 provider payload。

subject_ref 必须是稳定 opaque id 或低敏 hash，不得直接等于完整路径。dry-run / confirm / applied / failed 输出默认使用 subject_ref + path_summary。错误信息不得包含完整路径；需要定位时输出 low-sensitive code、source directory 和 hash。

UI 可以在本地用户显式详情或复制动作中显示完整路径，但默认列表、截图、日志、verification JSON 和 PRD/验收样例只能使用路径摘要或 synthetic path。
```

### P1-2：dangerous action 需要区分 hard-block 与 confirmable policy mutation

事实依据：

- PRD 8.5 写明危险或批量动作必须 dry-run 预览并要求 `--confirm` / `--yes`。
- PRD 8.6 又写明本阶段默认禁止删除、启停、kill、安装、卸载登录项 / helper / 命令行工具，禁止静默授权权限、TCC reset、打开 System Settings、启动 App 或执行命令来探测身份。
- 当前文本没有明确说明 `--confirm` 只能用于本 App 自己的隐私策略事实源 mutation，不能解锁系统权限、系统设置、生命周期管理或命令执行类危险动作。

风险：

- 开发或 agent 调用方可能把 `--confirm` 理解成危险系统动作的通用解锁器。
- 这会把 Step 5 从“管理本 App 自己的隐私策略事实源”扩大为系统自动化 / 权限 / launch services 操作器，超出 PRD 当前边界。

必须回写的推荐口径：

```text
Step 5 CLI 的 --confirm / --yes 只允许确认本 App 自己隐私策略事实源中的 allowed policy mutation，例如对已解析 subject 设置 allow/restrict/default。以下动作在 Step 5 必须 hard-block，即使提供 --confirm / --yes 也不得执行：TCC reset、请求或授予 ScreenCapture / Accessibility / Automation / Full Disk Access、打开 System Settings、打开 Finder、启动 App、执行 command_path、运行 shell、launchctl load/unload/kickstart、启停/kill/删除/安装/卸载登录项、helper 或命令行工具、修改系统登录项或 launch agent 状态。

hard-blocked action 必须返回 stable error code，例如 dangerous_action_blocked，并输出 low-sensitive reason、blocked_capability 和 required_future_review=true；不得输出完整路径、真实命令行参数、权限数据库细节或系统配置 dump。
```

## P2 Findings

### P2-1：bundle id 与 team id 的输出敏感级别需要口径统一

bundle id 通常可作为 App 身份字段展示，但在企业、内测或个人签名场景中仍可能暴露组织或个人命名信息。建议 PRD v1 写明：UI 本地展示 bundle id 可接受；日志、验收和截图默认可展示 synthetic bundle id 或 hash；真实 bundle id 进入文档前需低敏化，除非它来自系统公开 App 且项目负责人明确接受。

推荐补充：

```text
bundle id / team id 是本地 identity 字段，不视为 secret，但验收文档默认使用 synthetic 值或 hash。真实第三方 / 企业 / 个人 bundle id 不进入 fixture golden file、日志样例或 provider payload。
```

### P2-2：真实 App 图标缓存与验收图片需要低敏边界

PRD 已要求真实系统 App 图标和 fallback，但未细化图标缓存 / 截图证据。App 图标本身通常不是 secret，但真实 App 清单截图会暴露用户安装软件画像。

推荐补充：

```text
图标缓存仅用于本地 UI，不上传 provider，不写入验收文档。验收截图优先使用 synthetic app fixture 或可公开系统 App；如使用真实本机 App 截图，必须裁剪 / 打码非必要 App 名、bundle id、路径摘要和策略状态。
```

### P2-3：CLI subject 枚举范围应避免“扫描所有文件系统”的误读

PRD 已写“CLI 不默认扫描所有文件系统路径”，但登录项、helper、command path 的受控枚举边界还可以更硬。建议补充：CLI list / resolve 只能读取技术方案明确列出的本地登记源或调用方显式给定 subject；不得递归扫描 `$HOME`、`/usr/local`、`/opt` 或任意 PATH 目录来发现 command。

推荐补充：

```text
CLI 只能解析显式输入 subject 或受控枚举源返回的 subject。command_path 不触发 PATH 全目录扫描，不执行二进制，不解析 shell alias/function，不展开 glob，不读取命令输出。相对路径、shell 片段、带参数 command string 默认 rejected。
```

### P2-4：Step 5 专属门禁 P13E 建议纳入低敏输出 denylist

PRD 已建议 P13E，但低敏 denylist 还可以更具体，便于技术方案直接落地。

推荐补充：

```text
P13E 至少 fail closed 检查：完整 home path、真实用户目录、真实完整 App 清单、Authorization / Bearer / token / password / OTP / private key / cookie / session / JWT / webhook、TCC raw requirement / csreq、System Settings URL、Finder open token、launchctl mutation token、shell execution token、provider route / upload token、真实 command arguments、图片原始字节或图标 binary dump。
```

## 已确认安全边界

- UI 默认范围收敛为 `/Applications`、`~/Applications`、`/System/Applications` 下可识别 `.app`，未扩大为任意用户目录或全文件系统扫描。
- PRD 明确图标读取失败不得启动 App、不得请求权限，使用稳定 fallback。
- PRD 明确不上传 App 清单、图标、路径、策略或 CLI 输出到 provider。
- PRD 明确不静默请求 ScreenCapture、Accessibility、Automation、Full Disk Access，不 TCC reset，不静默打开 System Settings。
- PRD 明确 CLI 使用 typed subject model，冲突时返回候选，不静默选择第一个。
- PRD 明确 mutating action 支持 dry-run，输出 action、dry_run、requires_confirmation、subject、policy_before、policy_after、warnings、errors。
- PRD 明确危险动作被 blocked，并建议 `privacy_cli_dangerous_blocked_004` fixture。
- PRD 没有重开 Step 1 明文展示 / 搜索 / OCR、Step 2 标签 / 收藏、Step 3 面板布局、Step 4 详情编辑或 Step 6 集成验收。

## 可直接吸收进 PRD v1 的补充内容

建议在 PRD v1 增加一个“低敏输出与 dangerous action 语义”小节，直接吸收以下口径：

```text
默认输出低敏：
- UI 主列表、CLI 默认 JSON、audit、日志、verification JSON、开发记录和验收记录默认不得输出真实完整路径清单。
- path-like subject 默认输出 subject_ref、path_summary、source_directory 和 path_hash；完整 path 仅可由用户显式 reveal/copy 或显式 sensitive flag 输出，且不得进入验收文档或 provider payload。
- bundle id / team id 可作为本地 identity 展示，但 fixture 和验收样例默认 synthetic / hash。

confirm 语义：
- --confirm / --yes 只确认本 App 自己策略事实源的 allow/restrict/default mutation。
- TCC reset、权限请求/授权、System Settings、Finder、App launch、command execution、shell、launchctl mutation、登录项/helper/CLI 工具生命周期管理均为 Step 5 hard-blocked action。
- hard-blocked action 即使带 --confirm / --yes 也不执行，只返回 dangerous_action_blocked、blocked_capability、required_future_review=true。

CLI subject 安全：
- command_path 是策略 subject，不是可执行动作。
- 不执行 command，不读取 command output，不展开 shell/glob/alias，不默认扫描 PATH 或任意目录。
- ambiguous subject 不执行 mutation；mutating action 必须使用精确 subject_ref 或完整 typed subject。
```

## 是否建议进入下一步

建议项目负责人要求产品经理产出 PRD v1，吸收上述 P1 后再进入技术方案准备。若 PRD v1 明确默认路径低敏和 dangerous action hard-block 语义，本角色预计可以转为 `approve`。
