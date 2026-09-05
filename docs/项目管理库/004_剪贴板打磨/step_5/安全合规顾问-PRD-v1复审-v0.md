# Step 5 安全合规顾问 PRD v1 定向复审 v0

状态：role-review-complete
日期：2026-07-07
复审角色：安全合规顾问
复审对象：004_剪贴板打磨 Step 5 PRD v1：隐私页真实 App 清单与 CLI 广义对象管理

## 结论

结论：`approve`

P0：0
P1：0
P2：4

上一轮安全合规复审提出的两个 P1 已关闭。PRD v1 已明确 CLI / audit / verification JSON / 日志 / 开发记录 / 验收记录默认低敏，不输出真实完整路径清单；也已明确 `--confirm` / `--yes` 只确认本 App 自己隐私策略事实源的 policy mutation，不能解锁系统权限、Finder / System Settings、App launch、command execution、launchctl 或登录项 / helper / CLI 工具生命周期管理。

本轮未发现新的 P0 / P1，也未发现 PRD v1 把 Step 1-4 或 Step 6 拉回 Step 5。安全合规视角建议项目负责人允许 Step 5 PRD 进入技术方案阶段；下列 P2 建议可在技术方案或 PRD 小修中吸收，不阻塞进入技术方案。

## 复审范围

按任务要求定向读取：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD-v1预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/安全合规顾问-PRD复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD复审收敛-v0.md`

本轮不是 v0 全量重审；未进入技术方案、开发或真实运行验证；未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作；未修改 PRD 正文或业务代码。

## 上一轮 P1 关闭情况

### 已关闭：P1-1 CLI / audit 默认输出缺少完整路径低敏合同

PRD v1 第 10-11 节已补齐：

- `subject_ref` 必须是稳定 opaque id 或低敏 hash，不等同于完整真实路径。
- path-like subject 默认输出 `subject_ref`、`path_summary`、`source_directory`、`path_hash` 或 `path_redacted=true`。
- UI 主列表、CLI 默认 JSON、audit、日志、verification JSON、开发记录和验收记录默认不得输出真实完整路径清单。
- 完整 canonical path 只能通过用户显式 reveal / copy 或显式敏感输出参数查看。
- 完整 canonical path 不得进入开发记录、验收记录、fixture golden file、日志或 provider payload。
- 错误信息不得包含完整路径、真实命令参数、权限数据库细节或系统配置 dump。
- bundle id / team id 与真实 App 图标缓存也补了默认低敏边界。

判断：关闭。该口径足以进入技术方案，由技术方案细化 schema、flag 名称、sanitizer 和 P13E 实现。

### 已关闭：P1-2 dangerous action hard-block 与 confirm 语义不清

PRD v1 第 12 节已补齐：

- `--confirm` / `--yes` 只允许确认本 App 自己隐私策略事实源中的 allow / restrict / default policy mutation。
- TCC reset、权限请求或授予、System Settings、Finder、App launch、command_path execution、shell、`launchctl load` / `unload` / `kickstart`、登录项 / helper / 命令行工具启停 / kill / 删除 / 安装 / 卸载、系统登录项或 launch agent 状态修改均为 hard-block。
- hard-blocked action 返回 `dangerous_action_blocked` 等稳定错误码，并包含 `low_sensitive_reason`、`blocked_capability`、`required_future_review=true`。
- 错误不得输出完整路径、真实命令行参数、权限数据库细节或系统配置 dump。

判断：关闭。PRD v1 已把 confirmable policy mutation 与 hard-blocked system action 分开，避免把 Step 5 CLI 扩大成系统自动化执行器。

## 新增 P0 / P1

无。

## P2 Findings

### P2-1：P13E denylist 建议显式加入 TCC csreq / raw requirement 同义项

PRD v1 已要求 P13E 不输出 `TCC raw requirement`，但技术方案中建议把 `csreq`、`auth_value`、`auth_reason`、`indirect_object_identifier` 等 TCC dump 常见字段也列为 low-sensitive denylist 或 redaction pattern。

可吸收口径：

```text
P13E sanitizer 需覆盖 TCC raw requirement / csreq / auth_value / auth_reason / indirect object identifier 等 TCC dump 常见字段；任何 TCC 数据库原始行、二进制 requirement 或权限状态 dump 都不得进入 verifier JSON、日志或验收文档。
```

### P2-2：显式敏感路径输出参数需要技术方案定义不可入证据规则

PRD v1 允许完整 canonical path 通过用户显式 reveal / copy 或显式敏感输出参数查看。该方向可接受，但技术方案需要防止此参数被测试、agent 或默认脚本误用。

可吸收口径：

```text
显式 full-path / sensitive-output 参数必须默认关闭，CLI help 标记为 sensitive，本地交互使用时输出 warning；P13E、开发记录、验收记录和 golden fixture 禁止使用该参数产生证据。
```

### P2-3：login item / helper / launch_label 枚举源需在技术方案列白名单

PRD v1 已规定无法无权限、低敏、稳定枚举时仅支持已有策略记录或显式 typed 输入。技术方案阶段仍需把允许读取的本地登记源列成白名单，避免开发临时扩大为系统状态扫描。

可吸收口径：

```text
技术方案必须列出 login_item / helper / launch_label 的允许解析来源；未列入白名单的系统登记源不得读取。禁止为了发现 subject 而遍历 LaunchAgents / LaunchDaemons / Login Items、执行 launchctl、读取命令输出或扫描 PATH。
```

### P2-4：hard-blocked action 的错误输出不要给出可复制的危险命令

PRD v1 已禁止执行危险动作并要求低敏错误。建议技术方案进一步要求错误输出不要附带 `launchctl`、`tccutil`、`open x-apple.systempreferences:`、shell 片段等可复制命令。

可吸收口径：

```text
dangerous_action_blocked 输出只说明 blocked_capability、reason code 和 required_future_review，不给出可复制 shell / launchctl / tccutil / open System Settings 命令。
```

## 关键边界确认

- UI 默认只展示三目录真实 `.app`，并采用受控递归；`.app` bundle 是叶子，不扫描 bundle 内部。
- UI 首版可写策略只写本 App policy store，不触发系统权限申请或系统状态变化。
- UI 与 CLI 共享 `AppInstance` / `PolicySubject` / `PolicyRule` 分层事实模型，不允许双事实源弹性口径。
- CLI subject 是本 App 隐私策略 subject，不是系统对象生命周期控制器。
- `command_path` 不全盘扫描、不扫描 PATH、不执行命令、不读取命令输出、不解析 shell alias / function、不展开 glob / alias / shell；相对路径、shell 片段、带参数 command string 默认 rejected。
- `login_item` / `helper` / `launch_label` 如无法无权限、低敏、稳定枚举，首版仅支持已有策略记录或显式 typed 输入。
- ambiguous subject 只返回候选，不执行 mutation；mutation 必须使用精确 `subject_ref` 或完整 typed subject。
- P13E 已被写成 Step 5 hard gate，覆盖 scan scope、helper / login item / command path 不进 UI、CLI JSON、dangerous blocked、低敏输出、provider / 权限 / TCC / System Settings / Finder / App launch / command execution 禁止项。

## 是否建议进入技术方案

建议进入 Step 5 技术方案阶段。当前 P0/P1 清零，P2 均为技术方案可吸收的落地细化项，不需要阻塞 PRD 接受。
