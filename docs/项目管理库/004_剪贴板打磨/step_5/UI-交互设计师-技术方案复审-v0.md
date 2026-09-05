# UI/交互设计师技术方案复审 - Step 5 App 隐私列表

日期：2026-07-07

结论：`approve`

P0：0
P1：0
P2：4

本轮只复审 Step 5 技术方案 v0，不进入开发、真实运行或系统动作验证。基于 `App架构师-技术方案-v0.md`、`项目负责人-技术方案预审-v0.md`、`产品经理-PRD-v1.md` 和上一轮 UI/交互 PRD v1 复审判断：技术方案已覆盖 PRD v1 中 UI 可写策略、固定 row、duplicate confirmation、issue overflow、失败重试/取消、partial/loading 和低敏 evidence 的主要体验契约。未发现阻塞进入开发准备的 UI/交互 P0/P1，也不建议仅因 UI/交互问题要求技术方案 v1。

## 复审边界

已读输入：

- `docs/项目管理库/004_剪贴板打磨/step_5/App架构师-技术方案-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-技术方案预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/UI-交互设计师-PRD-v1复审-v0.md`

边界：

- 未修改业务代码、PRD 或技术方案正文。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、command execution 或真实系统状态变更。
- 未做真实 UI / VoiceOver / 截图验收；相关内容只按技术方案和 fixture 口径判断。

## 定向复审结论

### 1. Policy control 使用 menu button

结论：可接受。

技术方案将 policy control 放在固定 trailing column，并选择 menu button 承载 Default / Allowed / Restricted、unsupported、saving、failed、duplicate confirmation 等状态。这个取舍比三段 segmented control 更适合当前信息密度：状态不仅是三选一，还包含 confirm-required、disabled reason、失败恢复和低敏影响范围说明。

需要开发派发吸收：

- menu button 的 label 应始终显示当前 confirmed policy 或 pending target，不能只显示通用“Policy”。
- unsupported 时不要保留可点击菜单外观，建议使用 disabled label + reason 或 disabled menu button + explicit reason。
- saving / failed / pending 不应改变 trailing column 宽度；spinner、error、Retry / Cancel 必须在同一行级区域内稳定呈现。

### 2. Duplicate confirmation、issue overflow、failed retry/cancel

结论：足够进入开发。

技术方案已定义 UI 状态机：confirmed -> pending -> saving -> saved / failed，failed 可 retry 或 cancel，pending 可 cancel，unsupported 不 mutation。duplicate bundle id 在 plan 阶段计算 affected count，确认界面展示 bundle id、affected count、sourceDirectory/pathSummary 摘要，最多 5 条，其余显示 count。该口径足以避免用户误解为“只改当前一行”。

Issue overflow 方案也从 PRD 的“详情、tooltip 或 popover”收敛为“最多 2 个 chip，更多进入 popover”，比 PRD v1 更可实现。技术方案还要求 Esc 可关闭 popover/detail/filter menu，基本覆盖键盘关闭路径。

P2 细化：

- duplicate confirmation 的按钮文案建议固定为 `Apply to shared bundle id` / `Cancel` 或等价含义，不建议只用泛化 `Apply`。
- issue popover 需要在开发派发中明确 keyboard focus 初始位置、Esc 关闭、VoiceOver 标题和每条 issue 的 label。
- failed 行内错误建议固定结构为短错误摘要 + Retry + Cancel；不要只在 tooltip 中放错误。

### 3. Partial / loading / no result 文案与状态

结论：无 P1。

技术方案明确 refresh 时保留上一代列表，状态切换为 refreshing / partial；首次加载无缓存时显示 loading skeleton / partial count；单个 row 失败不清空列表。性能阈值也要求 refresh no-blank、partial result count 和 3000 synthetic apps 下 search/filter 响应。该体验契约能避免大列表白屏、伪装最终数量或单项失败拖垮整页。

P2 细化：

- 开发派发应补低敏文案样例：首次 loading、refreshing with previous results、partial count、no result with clear search、row failed。
- no result 应区分“搜索无结果”和“过滤后无结果”，并提供 Clear search / Clear filters / Clear all 中对应动作。

### 4. `all settings` 只展示 privacy summary / entry

结论：符合体验预期。

技术方案建议 `SettingsShellView(mode: .clipboardPrivacy)` 进入完整 `PrivacySettingsPane()`，而 `SettingsShellView(mode: .all)` 只展示摘要和入口，避免 all settings 页面直接加载 3000 行列表。这个处理符合 Settings 信息密度：全量页保持概览，隐私专项页承载大列表和策略操作，避免用户进入设置首页时被大列表性能和空间占用打断。

建议开发派发吸收：

- all settings 摘要需要显示低成本状态，例如 App policy rules count、scan status summary 或“Open Privacy Apps”，不要在 all settings 中触发完整扫描和图标加载。
- 如果摘要状态不可用，应显示 neutral 文案，不要显示 0 apps 造成误解。

### 5. 固定 row、trailing policy column、icon 状态与可访问性 evidence

结论：足够进入开发准备。

技术方案明确 fixed icon slot 32x32 或 36x36、图标加载前后尺寸不变、icon 完成不改变排序、trailing policy control 固定宽度、issue 最多 2 个 chip、更多进 popover。P13E required scenarios 覆盖 duplicate、missing bundle id、damaged、hidden、icon success/failed、large list、policy mutation success/failed、duplicate confirm、path override、row a11y、narrow width 和 long text i18n。

真实 VoiceOver 仍未覆盖，这是本阶段允许的证据边界，不构成 P1。后续开发验收需要补低敏 UI evidence，不能用 P13E fixture 代替真实辅助技术检查。

## Findings

### P0

无。

### P1

无。

未发现新的 UI/交互 P1；技术方案 v0 从 UI/交互角度可以进入开发准备。

### P2

1. Menu button 的具体 label / value / hint 需在开发派发中固定。
   - 建议：每个状态至少定义 visible label、VoiceOver label、value、hint。pending / saving / failed 不应只靠颜色或 spinner。

2. Duplicate confirmation 与 issue popover 的键盘和 VoiceOver 细节仍需落地。
   - 建议：confirmation 默认 focus 在取消或主操作上的选择需要明确；popover 应有标题、列表语义、Esc 关闭和焦点回到触发 row。

3. partial/loading/no result 文案样例还不够具体。
   - 建议：开发记录或派发中补中英日低敏长句样例，覆盖 no result、partial result count、refreshing 保留旧结果、row failed。

4. 真实 UI / VoiceOver / 窄宽度实物证据仍是开发验收残余风险。
   - 建议：开发验收至少保留低敏截图或可审查 evidence，覆盖 3000 行 fixture 不白屏、长 App 名/长 bundle id、policy failed、unsupported、duplicate confirmation 和 VoiceOver label/value/hint。

## 可直接吸收的开发准备建议

- 开发派发可以沿用技术方案 v0，不需要单独因 UI/交互生成技术方案 v1；但应把本复审 P2 写入开发验收清单。
- Batch C 的 UI 验收应显式要求：menu button 状态稳定、Retry / Cancel 同位、duplicate confirmation 不误导作用范围、issue popover 键盘可关闭。
- P13E 可以覆盖结构和状态合同，但不能声称完成真实 VoiceOver 验收；真实辅助技术检查应由测试/质量或后续低敏 UI evidence 记录补足。
- `all settings` 中隐私摘要应保持轻量，不触发完整 3000 row 加载和真实 icon 扫描；完整列表只在 `clipboardPrivacy` pane 中加载。

## 是否可以进入开发准备

可以。

从 UI/交互角度，当前技术方案 v0 已达到开发准备标准。剩余问题均为 P2 级实现细节和验收证据要求，适合进入开发派发与验收清单，不阻塞 Step 5 开发准备。
