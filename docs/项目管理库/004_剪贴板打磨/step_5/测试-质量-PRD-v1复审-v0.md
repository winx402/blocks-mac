# 004_剪贴板打磨 Step 5 测试/质量 PRD v1 定向复审 v0

日期：2026-07-07
角色：测试/质量
对象：`step_5/产品经理-PRD-v1.md`
范围：Step 5 PRD v1 定向复审，只判断上一轮测试/质量 P1 是否关闭、是否可转入技术方案；不进入技术方案、开发或真实运行验证。

## 1. 结论

结论：`approve`。

上一轮测试/质量提出的 P1 已关闭。PRD v1 已将 UI 可写策略、P13E hard gate、CLI edge fixture、性能阈值要求、搜索/过滤/排序规则、统一 identity edge matrix 和低敏输出 fail-closed 写成可转化为技术方案与验收门禁的口径。

本轮未发现新的 P0 / P1，未发现明显 Step 5 越界。剩余问题为 P2：建议在技术方案和 P13E 设计时进一步表格化、数值化和 schema 化，不阻塞进入 Step 5 技术方案。

## 2. 上一轮 P1 关闭情况

| 上一轮问题 | v1 关闭判断 | 依据 |
| --- | --- | --- |
| P1-1 UI 策略状态是否可变更不够硬 | 已关闭 | PRD v1 明确 UI 首版可写，定义 `Default / Allowed / Restricted`，并补 pending、saving、saved、failed、retry、cancel、unsupported 与 duplicate bundle id 影响范围。 |
| P1-2 P13E 需要升为 hard gate | 已关闭 | PRD v1 第 16 节明确 P13E 或等价 fail-closed gate 是 Step 5 hard gate，不是建议，并列出事实源、fixture、安全、低敏和性能 fail 条件。 |
| P1-3 性能与大量 App pass/fail 需要最小数值口径 | 已关闭 | PRD v1 第 13 节要求技术方案必须量化 large-list count、readiness、search/filter response、refresh、icon loading、output bound，缺数值不得进入开发。 |
| P1-4 CLI fixture 覆盖不足 | 已关闭 | PRD v1 第 15.2 节补齐 missing bundle id、damaged、hidden、unsupported、path conflict、policy failed、dry-run、confirm、dangerous blocked、low-sensitive output 等 CLI fixture。 |

## 3. P0 / P1 / P2

### P0

无。

### P1

无。

### P2-1：UI 可写策略建议在技术方案中转成场景矩阵

PRD v1 的 UI 状态机已足够进入技术方案，但后续 P13E / UI evidence 应避免只检查 token 存在。

建议技术方案或 P13E 直接吸收：

```text
UI policy mutation acceptance matrix:
- Default -> Allowed: pending -> saving -> saved。
- Default -> Restricted: pending -> saving -> saved。
- Allowed / Restricted -> Default: pending -> saving -> saved。
- failed: 原策略保持，row 内错误可见，Retry 重试同一 mutation plan。
- cancel: pending 或 failed 草稿取消后回到最近一次已确认策略。
- duplicate bundle id: mutation 前显示 affected count、bundle id、source directory / path summary；确认后同一 bundle_id PolicySubject 下相关 row 状态一致。
- saving: 禁止重复提交。
```

### P2-2：P13E 建议要求 evidence schema，而不仅是检查清单

PRD v1 已能转化为 P13E hard gate。为降低假 PASS，建议技术方案把 P13E 输出固定为可审计 schema。

建议补充：

```text
P13E output should include:
- current_fact_sources: prd / technical_plan / development_record paths。
- fixture_coverage: UI fixtures, CLI fixtures, identity edge cases, policy mutation cases。
- denied_runtime_actions: provider, TCC, System Settings, Finder, App launch, command execution。
- low_sensitive_scan: forbidden token/pattern result and sanitized sample count。
- performance_thresholds: required numeric thresholds and measured fixture results。
- ok=false when any required section is missing.
```

### P2-3：性能阈值由技术方案定义是可接受的，但必须在开发前冻结

PRD v1 没有写死具体毫秒数，作为 PRD 阶段可以接受，因为它已明确“缺数值不得进入开发”。技术方案阶段必须补齐并经复审，避免开发后再争论性能 pass/fail。

建议技术方案至少给出：

```text
- large-list fixture target: one explicit count from 500 / 1000 / 3000。
- first page readiness threshold。
- search/filter response after index loaded threshold。
- refresh no-blank behavior threshold or event sequence。
- icon load layout stability assertion。
- verifier output max row/sample count。
```

### P2-4：CLI JSON / error code 建议列最小字段合同

PRD v1 已写 typed subject 和低敏输出字段，技术方案应将它固化为 JSON schema，以便 P13E 不靠文本描述判断。

建议最小字段：

```text
CLI JSON acceptance:
- action, ok, error_code?, subject.type, subject.subject_ref, subject.display_name, subject.identity_status, subject.policy_status。
- path-like subject must include path_redacted=true or path_hash/path_summary, not canonicalPath by default。
- ambiguous result must include candidates_count and low-sensitive candidates summary, with mutation_performed=false。
- dangerous action must include error_code=dangerous_action_blocked, blocked_capability, required_future_review=true。
```

## 4. 定向判断

### 是否足以转化为 P13E hard gate

是。PRD v1 已给出 P13E 的 hard gate 地位、当前事实源要求、UI scan scope、fixture 完整性、CLI typed subject、dangerous action、低敏输出和性能阈值 fail 条件。

测试/质量建议技术方案阶段不要把 P13E 拆成只读静态扫描；P13E 至少应包含静态边界检查、synthetic fixture evidence、JSON schema 检查、forbidden token / pattern 低敏扫描和性能阈值存在性检查。真实 App / 真实剪贴板 / TCC / provider / Finder / System Settings 仍不得作为 PRD 阶段验证输入。

### UI / CLI fixture、edge case、性能、低敏输出是否可测

可测。

- UI fixture 覆盖三目录、bounded recursion、icon success/failure、duplicate name、duplicate bundle id、missing bundle id、damaged、hidden、large list、policy failed、policy mutation success/failure、a11y、窄宽度、长文本和多语言。
- CLI fixture 覆盖 typed subject、missing bundle id、damaged、hidden、unsupported、path conflict、policy failed、login item、helper、command path、dry-run、confirm、dangerous blocked、JSON 和低敏输出。
- edge case matrix 已把 UI / CLI / Policy expected 放到同一张表，能防 UI 和 CLI 双事实源。
- 性能阈值在 PRD 层以“技术方案必须量化，缺数值不得进入开发”形式闭合。
- 低敏输出合同覆盖 UI、CLI、audit、日志、verification JSON、开发记录和验收记录，并列明 forbidden token / pattern。

### UI 可写策略是否还需要额外 pass/fail 矩阵

不构成 PRD P1。PRD v1 已足够明确 UI 可写策略的产品边界；额外 pass/fail 矩阵建议作为技术方案 / P13E 设计输入，见 P2-1。

### 是否有 Step 5 越界

未发现明显越界。PRD v1 保留了 Step 5 边界：

- UI 默认三目录真实 `.app`。
- CLI 管理 UI 外广义对象，但只管理本 App 隐私策略事实源。
- 不上传 provider，不静默权限，不 TCC reset，不打开 System Settings / Finder，不启动 App，不执行命令，不做登录项 / helper / CLI 工具生命周期管理。

## 5. 建议进入技术方案前保留的质量门禁

建议项目负责人允许进入技术方案，并在技术方案派发中明确以下非阻断但必须落地的质量输入：

1. P13E-first：技术方案先定义 P13E evidence schema、fixture data shape、forbidden token / pattern、fail-closed 条件，再进入实现拆解。
2. 数值冻结：large-list count、readiness、search/filter response、refresh、icon loading 稳定性、output bound 必须在技术方案阶段给出数值或明确计算口径。
3. UI mutation matrix：将 PRD 状态机转成 deterministic fixture / event evidence。
4. CLI schema：将 typed subject 和 error code 固化为 JSON schema，并覆盖 ambiguous、unsupported、dangerous blocked 和 dry-run no mutation。
5. 低敏证据：开发记录、验收记录、verification JSON 默认只记录 counts、hash、summary、synthetic identity，不记录真实完整路径清单、真实 command arguments、图标 binary dump 或系统配置 dump。

## 6. 复审边界

本轮读取：

- `step_5/产品经理-PRD-v1.md`
- `step_5/项目负责人-PRD-v1预审-v0.md`
- `step_5/测试-质量-PRD复审-v0.md`
- `step_5/项目负责人-PRD复审收敛-v0.md`

未读取业务代码，未运行 App，未触发真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。
