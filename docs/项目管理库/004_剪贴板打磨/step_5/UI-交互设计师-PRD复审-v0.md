# Step 5 UI/交互设计师 PRD 复审 v0

状态：`approve-with-changes`
日期：2026-07-07
角色：UI/交互设计师
对象：004_剪贴板打磨 Step 5 PRD v0

## 1. 结论

结论：`approve-with-changes`。

P0：0。
P1：2，需要在进入技术方案前回写 PRD v1。
P2：若干，可进入技术方案后细化或在验收样例中补充。

PRD v0 对 Step 5 的范围判断基本正确：UI 默认展示 Applications 三目录真实 `.app`，CLI 承接登录项、helper、命令行工具等广义对象；未重开 Step 1-4，也未把 Step 6 最终回扫提前拉入当前阶段。主要缺口不是方向错误，而是隐私页 App list 的行级信息结构、策略操作语义、键盘 / VoiceOver / 窄宽度验收仍停留在“需要复审的问题”，尚未成为可执行的产品验收口径。

本轮只做 PRD 复审，未读取源码，未触发真实 App、真实系统剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。

## 2. 复审输入

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD派发-Step5-v0.md`
- `docs/项目管理库/004_剪贴板打磨/需求覆盖矩阵-v0.md`

未做：

- 未读取业务源码。
- 未运行 App、CLI 或 verifier。
- 未修改 PRD 正文。

## 3. P0 findings

无 P0。

PRD v0 没有发现会导致阶段方向错误、明显越界或必须退回需求澄清的 UI/交互阻断。

## 4. P1 findings

### P1-1：App row 的信息结构和策略操作语义还不够可执行

问题：

PRD v0 已列出 row 至少展示真实图标 / fallback、App 名、策略状态、bundle id、来源目录 / 路径摘要、身份异常标记，但尚未明确行内信息层级、长文本截断规则、异常标记数量控制、路径展开 / 复制入口，以及策略状态是只读展示还是可在 row 内编辑。

风险：

- 真实图标、名称、bundle id、路径摘要、策略状态和异常标记全部塞入一行时，开发很容易做成高密度但不可扫读的表格。
- 长 App 名、长 bundle id、长路径摘要和多异常标记可能挤压策略状态，导致用户看不到真正要判断的 allow / restricted / unknown。
- 重复 bundle id 情况下，如果策略控件在单行内可改，但没有“共享策略影响范围”的确认或解释，用户会误以为只修改当前这一行。
- 如果 PRD 不声明策略操作控件是否进入 Step 5，技术方案无法判断 pending / saving / failed feedback 应放在哪里。

建议回写口径：

```md
### App row 信息结构与操作口径

每个 App row 使用固定高度或稳定自适应高度，不因图标异步加载、状态变化或异常标记出现而跳动。

默认层级：
- Leading：固定尺寸真实 App 图标；读取失败时使用同尺寸 fallback。
- Primary：App display name，单行优先，过长时中间或尾部截断，hover / 详情 / 显式展开可看完整名称。
- Secondary：bundle id 与来源目录 / 路径摘要，最多两行；完整路径不默认显示，只能通过显式 copy / reveal / detail 查看，验收证据低敏化。
- Trailing：策略状态 chip / control，状态文案、图标、颜色三者不能互为唯一信息来源。
- Issues：重复名称、重复 bundle id、missing bundle id、damaged、hidden、icon failed 等异常以最多 1-2 个紧凑标记展示，更多异常进入详情或 tooltip / popover；不能挤压策略状态。

如果 Step 5 支持在 UI 中修改 App 级策略：
- row 必须有 pending / saving / saved / failed 状态。
- 失败反馈必须行内可见，并保留原策略状态，不得静默回滚。
- 重复 bundle id 或共享策略影响多个 App 时，修改前必须显示影响范围说明或确认，不得让用户误以为只改当前行。

如果 Step 5 UI 首版只展示策略状态、不修改策略：
- PRD 必须明确写成只读，并把策略 mutation 留给 CLI 或后续阶段。
```

### P1-2：键盘、VoiceOver、窄宽度和长文本验收没有进入最低验收矩阵

问题：

PRD v0 在角色复审问题中提到长 App 名、长 bundle id、长路径摘要、多语言、键盘导航和 VoiceOver，但 `11.3 最低验收矩阵` 与 `14. 建议门禁方向` 没有把这些列为硬验收。对一个高密度 App 列表来说，这会导致开发和验收阶段只覆盖数据 fixture，不覆盖用户是否能扫读、导航和理解状态。

风险：

- 大量 App 列表中，仅支持鼠标扫描会降低可用性；键盘用户无法稳定移动焦点、打开详情、复制标识或切换策略。
- VoiceOver 如果只读出 App 名而不读策略状态 / 异常状态，隐私页的核心信息不可访问。
- 窄宽度下路径摘要、bundle id、状态 chip 可能重叠或被隐藏，尤其中文 / 英文 / 日文长句和长 bundle id 混排时。

建议回写口径：

```md
### 键盘、VoiceOver 与响应式验收

Step 5 UI 最低验收必须覆盖：

- 键盘导航：列表可用 Tab / Shift-Tab 进入和退出；方向键或等价机制可移动 row focus；Enter / Space 可触发主要动作；Esc 可关闭 popover / detail / filter menu。
- Focus：focused、selected、hover、active filter 状态视觉层级可区分，且不只依赖颜色。
- VoiceOver：每个 App row 至少读出 App 名、策略状态、bundle id 可用性、来源目录、主要异常标记；策略控件需要 label / value / hint。
- 长文本：长 App 名、长 bundle id、长路径摘要、多异常标记不重叠；完整值有显式复制或详情入口。
- 窄宽度：在窄设置页宽度下 row 降级为单列或两行布局，策略状态仍可见，异常标记不遮挡主要信息。
- 多语言：中文 / 英文 / 日文长名称和长状态文案均纳入低敏 fixture。

P13E 或等价门禁应包含低敏截图 / snapshot / static accessibility evidence，不能只验证数据模型存在。
```

## 5. P2 findings

### P2-1：搜索 / 过滤 / 排序控件需要补充默认 UI 规则

PRD 已定义搜索字段、过滤维度和稳定排序，但还可以补充控件层口径：

- 搜索框应显示本地搜索占位文案，例如 `Search apps, bundle IDs, folders, or status`。
- active filters 应以 chips / token / summary 展示，并提供 `Clear all`。
- 搜索和过滤组合后应显示结果数量，例如 `23 apps` / `No apps match current filters`。
- 大量 App 部分加载时，搜索结果应标注 `partial`，避免用户误以为结果完整。
- 排序入口应显示当前排序规则；刷新后排序不因图标加载或策略状态异步更新而跳动。

这些可作为技术方案细化，不阻塞 PRD v1，但建议回写一段简短控件规则，减少后续设计分歧。

### P2-2：身份异常标记的文案 taxonomy 可以更统一

PRD 中同时出现 `duplicate bundle id`、`missing bundle id`、`damaged / unreadable`、`hidden`、`icon failed` 等英文状态。建议 PRD v1 指定：

- 面向用户的状态文案：短文案、说明文案、VoiceOver value。
- 面向 fixture / CLI 的稳定 code：`duplicate_bundle_id`、`missing_bundle_id`、`damaged`、`hidden`、`icon_failed`。
- 行内最多展示几个 issue，更多 issue 如何折叠。

### P2-3：hidden App 默认展示可能让用户误解，需要轻量解释

PRD 规定隐藏 App 如位于三目录且可识别 `.app`，默认纳入列表并标记 hidden。建议补充：

- hidden 标记的说明：这是文件系统隐藏状态，不代表系统权限隐藏。
- filter 可以快速隐藏 / 显示 hidden apps。
- hidden 不影响策略状态读取，除非 identity 读取失败。

### P2-4：CLI 与 UI 的“关联对象由 CLI 管理”提示建议保持非默认

PRD 已把关联对象提示留给后续 UI / 技术方案确认。UI 侧建议首版不要默认在每个 App row 展示 helper / command 关联提示，避免隐私页过载。可以在详情或异常区显示“CLI-managed related subjects exist”一类非阻塞提示，且必须可关闭或不影响主列表扫读。

## 6. 范围复核

未发现 Step 5 PRD v0 把 Step 1-4 已接受内容重新拉回。

- Step 1 明文展示 / 搜索 / OCR：未重开。
- Step 2 标签 / 收藏：未重开。
- Step 3 面板 hover / toolbar / 布局：未重开。
- Step 4 详情编辑 / dirty guard：未重开。
- Step 6 最终回扫：只作为后续验收边界出现，未提前纳入当前实现范围。

PRD v0 同时覆盖 UI App 清单和 CLI 广义对象管理，与 Step 5 派发一致，不属于越界。

## 7. 建议 PRD v1 最小回写清单

进入技术方案前建议至少回写：

1. App row 信息结构：leading icon、primary title、secondary identity、trailing status / control、issues overflow。
2. 策略操作口径：Step 5 UI 是只读状态展示，还是支持 App 级策略修改；如支持，补 pending / saving / saved / failed 与重复 bundle id 影响范围说明。
3. 长文本 / 窄宽度 / 多语言：明确截断、展开、复制、降级布局和低敏 fixture。
4. 键盘 / VoiceOver：加入最低验收矩阵和 P13E 门禁方向。
5. 搜索 / 过滤 / 排序控件：active filters、clear all、result count、partial loading 下的结果说明。

完成这些回写后，UI/交互侧可接受 PRD 进入技术方案阶段。
