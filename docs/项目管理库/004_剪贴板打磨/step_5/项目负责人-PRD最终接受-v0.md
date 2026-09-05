# Step 5 PRD 最终接受 v0

状态：accepted-for-technical-plan
日期：2026-07-07
角色：项目负责人
对象：`step_5/产品经理-PRD-v1.md`

## 1. 结论

结论：接受 Step 5 PRD v1，允许进入 Step 5 技术方案阶段。

四个角色对 PRD v1 的定向复审结论均为 `approve`，P0/P1 清零。当前仅保留 P2 级落地细化项，均应在技术方案、P13E 设计、后续开发和验收中处理，不阻塞 PRD 接受。

PRD v1 没有把 Step 1-4 或 Step 6 拉回 Step 5；Step 5 范围保持为隐私页真实 App 清单与 CLI 广义对象管理。

## 2. 接受依据

- [产品经理 PRD v1](产品经理-PRD-v1.md)
- [项目负责人 PRD v1 预审 v0](项目负责人-PRD-v1预审-v0.md)
- [UI/交互设计师 PRD v1 复审 v0](UI-交互设计师-PRD-v1复审-v0.md)：`approve`
- [App 架构师 PRD v1 复审 v0](App架构师-PRD-v1复审-v0.md)：`approve`
- [测试/质量 PRD v1 复审 v0](测试-质量-PRD-v1复审-v0.md)：`approve`
- [安全合规顾问 PRD v1 复审 v0](安全合规顾问-PRD-v1复审-v0.md)：`approve`

## 3. 固定产品边界

技术方案不得改变以下 PRD v1 产品事实：

- UI 默认展示 `/Applications`、`~/Applications`、`/System/Applications` 三个 root 下受控枚举到的真实 `.app`。
- 受控枚举遇到 `.app` bundle 后视为叶子，不扫描 bundle 内部。
- UI 首版支持 App 级策略变更，策略只写本 App 自己的隐私策略事实源。
- UI 策略变更必须覆盖 pending、saving、saved、failed、retry、cancel、unsupported。
- duplicate bundle id 场景必须展示 shared-policy / affected count 等影响范围，mutation 前需要用户确认。
- `AppInstance` / `PolicySubject` / `PolicyRule` 是三层产品事实模型。
- UI 与 CLI 必须共享同一隐私策略事实源；不得引入双事实源。
- CLI subject 是本 App 隐私策略 subject，不是系统对象生命周期控制器。
- `subject_ref` 必须是稳定 opaque id 或低敏 hash，不等同于完整真实路径。
- CLI / audit / verification JSON / 日志 / 开发记录 / 验收记录默认低敏，不输出完整真实路径清单。
- `--confirm` / `--yes` 只确认本 App policy mutation。
- dangerous action 即使带 confirm 也 hard-block。
- P13E 或等价 fail-closed gate 是 Step 5 hard gate。
- 技术方案必须给出性能数值阈值；缺数值不得进入开发。

## 4. 技术方案必须吸收的 P2 输入

### 4.1 UI / 交互

- 固定 policy control 的首版控件形态和 trailing column 结构，避免状态变化造成行高或列宽跳动。
- 固定 issue overflow 的承载方式，说明鼠标、键盘、VoiceOver 的打开 / 关闭路径。
- 给出 duplicate bundle id confirmation、missing bundle id unsupported、damaged row failed、large-list partial count、narrow width、long app name / bundle id、VoiceOver label / value / hint 的低敏 evidence 口径。
- 给出 no result、partial result、loading with old results、row failed 等低敏文案样例。

### 4.2 App 架构

- 明确受控递归最大深度、目录跳过规则、symlink / alias、unreadable directory 和 partial 状态。
- 明确图标读取、缓存 key、stale / missing / failed 状态、fallback 图标来源。
- 明确 `app_path` override 是否进入首版；若不进入，duplicate / missing bundle id 的 UI 与 CLI mutation 必须按 PRD 降级为 Unsupported 或 confirm-required。
- 明确 `subject_ref` 生成规则、policy store schema、UI / CLI 单一事实源访问边界。

### 4.3 测试 / 质量

- 先定义 P13E evidence schema、fixture data shape、forbidden token / pattern、fail-closed 条件，再进入实现拆解。
- 将 UI 策略状态机转成 deterministic fixture / event evidence。
- 固化 CLI JSON schema，覆盖 ambiguous、unsupported、dangerous blocked 和 dry-run no mutation。
- 冻结 large-list count、first page readiness、search / filter response、refresh、icon loading 稳定性和 output bound。

### 4.4 安全合规

- P13E sanitizer 需覆盖 TCC raw requirement / csreq / auth_value / auth_reason / indirect object identifier 等 TCC dump 常见字段。
- 显式 full-path / sensitive-output 参数必须默认关闭，CLI help 标记为 sensitive；P13E、开发记录、验收记录和 golden fixture 禁止使用该参数产生证据。
- login_item / helper / launch_label 的允许解析来源必须列白名单；未列入白名单的系统登记源不得读取。
- dangerous_action_blocked 输出不得给出可复制 shell、launchctl、tccutil、open System Settings 等危险命令。

## 5. 下一步

派发 App 架构师产出 Step 5 技术方案 v0。

技术方案完成后，项目负责人将组织 UI/交互、测试/质量、安全合规进行技术方案复审；必要时再回架构师产出 v1。技术方案通过前，不进入开发。

## 6. 本轮验证

项目负责人已读取四份 PRD v1 定向复审文档，并运行：

```bash
git diff --check
```

结果：PASS。
