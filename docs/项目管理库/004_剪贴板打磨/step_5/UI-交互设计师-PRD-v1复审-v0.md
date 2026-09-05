# UI/交互设计师 PRD v1 定向复审 - Step 5 App 隐私列表

日期：2026-07-07

结论：`approve`

P0：0
P1：0
P2：4

本轮是 PRD v1 定向复审，不重做 v0 全量复审，不进入技术方案或实现。基于 `产品经理-PRD-v1.md`、`项目负责人-PRD-v1预审-v0.md`、上一轮 UI 复审和 PRD 复审收敛记录判断：上一轮 UI/交互提出的 P1 已关闭；当前仅剩 P2 级技术方案落地细化项，可以进入 Step 5 技术方案阶段。

## 复审输入与边界

已读输入：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD-v1预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/UI-交互设计师-PRD复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD复审收敛-v0.md`

边界：

- 只做 PRD v1 UI/交互定向复审。
- 不修改 PRD 正文和业务代码。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。

## 上一轮 UI P1 关闭情况

### P1-1：App row 信息结构与策略操作语义不足

状态：已关闭。

PRD v1 已把 UI 首版从“只读展示”明确为“支持 App 级隐私策略变更”，并补齐 Default / Allowed / Restricted 的行内控制、pending / saving / saved / failed / retry / cancel / unsupported 等状态。失败路径明确不产生部分提交，Retry 复用同一 mutation plan，Cancel 回到已确认状态；duplicate bundle id 的共享策略影响范围也要求在确认前说明 affected count、bundle id、低敏路径摘要和来源目录。

App row 信息结构也已明确：固定 icon/fallback、主标题、二级 bundle id / source / path summary、trailing policy control、issues overflow。该口径足以进入技术方案，由技术方案继续细化具体控件形态和状态机。

### P1-2：键盘、VoiceOver、窄宽度和长文本验收不足

状态：已关闭。

PRD v1 已把固定行高、长文本不挤压 policy control、窄宽度降级、中文/英文/日文长文本 fixture、键盘 Tab / Shift-Tab / arrows / Enter / Space / Esc、VoiceOver row label / value / hint 和 issue 非颜色唯一表达写入最低验收。P13E hard gate 也要求覆盖 row accessibility、narrow width、long text i18n 和 UI policy mutation fixture。

PRD 层面已经具备可验收口径；真实 UI 截图、VoiceOver 实测和长文本实物证据应保留到技术方案与开发验收阶段。

## 定向复核结论

### 1. UI 首版可写策略

结论：足够。

PRD v1 明确 UI 支持 App 级策略变更，而不是只读列表；同时约束 mutation 只写入本 App 隐私策略事实源，不触发系统权限、Finder、System Settings、App launch 或 command execution。行内状态、失败反馈、Retry / Cancel、duplicate bundle id 的共享影响范围都已从“风险点”变成“验收要求”。

建议技术方案吸收：

- 把 policy control 明确成一个稳定 trailing column 控件，避免状态变化导致行高或列宽跳动。
- 对 failed 状态给出固定结构：错误摘要、Retry、Cancel 或回退到 confirmed state 的规则。
- duplicate bundle id confirmation 需要支持键盘到达和 VoiceOver 朗读，文案必须包含 shared policy、affected count、bundle id、低敏 path summary/source directory。

### 2. App row 信息结构、异常标记和可访问性

结论：足够。

PRD v1 对 row 密度和信息层级已经明确：真实图标或 fallback、主名称、bundle id、来源目录、path summary、policy 状态/控件和最多 1-2 个 inline issue。duplicate name、duplicate bundle id、missing bundle id、damaged、hidden、unsupported、path conflict、policy failed 均进入统一 edge case matrix。长文本、窄宽度、键盘和 VoiceOver 都有最低验收。

建议技术方案吸收：

- 对 issue overflow 固定一种首版承载方式，例如 detail popover 或 tooltip-like detail，并明确键盘/VoiceOver 如何打开和关闭。
- 对 path summary、bundle id 和 app name 的截断规则给出样例，确保 policy control 不被挤压。
- hidden / damaged / unsupported 的标记文案建议使用“状态 + 简短原因”，避免只显示图标或颜色。

### 3. 搜索、过滤、排序、partial/loading 组合状态

结论：无 P1。

PRD v1 已明确搜索字段、过滤维度、同维度 OR / 不同维度 AND、清除 search / filter / all、partial result count、稳定排序和 icon loading 不影响排序。性能与稳定性验收要求 large-list 下先显示 loading / partial，不阻塞或白屏；refresh 有旧结果时保留旧列表直到新结果可用或明确显示 partial。

建议技术方案吸收：

- 明确 toolbar 中搜索、filter chips、sort、clear all、loading/partial count 的优先级，避免窄宽度时主操作被挤出。
- 给出 no result、partial result、loading with old results、row failed 四类低敏文案样例。

### 4. Step 5 边界

结论：未发现明显越界。

PRD v1 清楚保留 Step 5 边界：UI 默认只扫描三目录真实 `.app`，CLI 管理 UI 外广义对象但仅管理本 App 隐私策略事实源；不上传 provider、不静默权限、不 TCC reset、不打开 System Settings / Finder、不启动 App、不执行命令、不做登录项/helper/CLI 工具生命周期管理。该边界符合 Step 5“隐私页 App 列表与策略管理”的范围，没有把 Step 1-4 或 Step 6 功能拉入 UI 首版。

## Findings

### P0

无。

### P1

无。

上一轮 UI P1 均已关闭，未发现新的 P1。

### P2

1. Policy control 的具体控件形态仍需在技术方案固定。
   - 建议：技术方案明确使用 segmented / menu button / popover 中的一种首版形态，并给出 default、pending、saving、saved、failed、unsupported、duplicate confirmation 的同位状态布局。

2. Issue overflow 的承载和可访问性还需技术方案细化。
   - 建议：固定首版 overflow 入口，说明鼠标、键盘、VoiceOver 三种打开/关闭路径；不要让 issue 文案挤压 trailing policy column。

3. 搜索/过滤/排序组合状态需要补文案样例。
   - 建议：技术方案给出 `No results`、`Partial results`、`Loading while keeping previous results`、`Some rows unavailable` 的中英日长句验收样例。

4. 真实 UI 证据仍是开发验收残余风险，不阻塞 PRD。
   - 建议：后续低敏 evidence 至少覆盖 duplicate bundle id confirmation、missing bundle id unsupported、damaged row failed、large-list partial count、narrow width、long app name / bundle id、VoiceOver label/value/hint。

## 可直接吸收进技术方案的口径

- App row 首版应保持固定行高和固定 trailing policy column；图标加载、policy 状态变化、issue 出现/消失都不得造成行高跳动。
- Duplicate bundle id 的 policy mutation 必须在确认前显示共享影响范围；`Continue` / `Apply` 只在用户确认后执行，取消后保持原状态。
- Missing bundle id / damaged / unsupported 不能静默使用不可靠策略；UI 应显示 Unsupported 或 row-failed，并说明不能在当前行修改策略。
- Search/filter/sort 的组合状态以“保留旧列表 + partial/loading 标记”为优先，不应在 refresh 中闪成空白列表。
- VoiceOver 至少朗读 app name、policy status、bundle id availability、source directory、main issue；policy control 需要 label、value、hint。

## 是否可进入技术方案

可以。

当前 PRD v1 已经把上一轮 UI P1 转化为可执行的验收口径。技术方案需要把控件形态、状态机、文案样例、低敏 fixture 和 P13E 覆盖方式写实；这些属于 P2 级落地细化，不阻塞 Step 5 进入技术方案。
