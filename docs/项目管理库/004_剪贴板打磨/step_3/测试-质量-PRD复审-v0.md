# 测试/质量 PRD 复审：Step 3 面板交互与布局打磨

日期：2026-07-07
角色：测试/质量
复审对象：`产品经理-PRD-v0.md`、`项目负责人-PRD预审-v0.md`，并对照 `step.md` 与 `需求覆盖矩阵-v0.md`

## 结论

`approve-with-changes`

Step 3 PRD 范围正确，聚焦 hover 容错、筛选/搜索空间、选中反馈、单击/双击显性控件、条目密度和布局抗压，没有提前修改 Step 1 搜索/OCR 底座、Step 2 标签事实源、Step 4 详情编辑或 Step 5 隐私页 App 管理。

当前主要缺口是部分体验验收仍停留在“用户可见结果”层，还需要在进入开发前补成可执行的 pass/fail：hover 延迟/安全区样例、明显离开收起条件、右侧操作清单与视口矩阵、选中反馈即时性的低敏证据口径、键盘/VoiceOver 检查清单、以及 Step 1 搜索状态和 Step 2 单标签筛选的回归边界。

## 必须改

1. Hover 容错需要可执行阈值或事件规则。
   PRD 已定义“短暂移出不误收、明显离开会收起”，但测试需要可复跑规则。建议在 PRD 或技术方案中固定：
   - 从 trigger 到展开内容区的移动路径样例。
   - “短暂移出”的最大时间或事件规则，例如在安全区内短暂停留不收起。
   - “明显离开”的判定，例如离开安全区且超过延迟后收起。
   - 展开/收起动画期间不得阻断右侧操作。
   具体毫秒数可由 UI/开发定，但最终验收前必须存在，否则录屏无法判定 pass/fail。

2. 右侧关键操作清单和窗口尺寸矩阵需要补清。
   PRD 写到“不遮挡右侧关键操作”，但没有列出当前关键操作和测试尺寸。建议明确：
   - 右侧关键操作包括哪些按钮、清除入口、状态提示或等价控件。
   - 至少覆盖宽窗口、默认窗口、窄窗口、最小可用窗口四类尺寸。
   - 每类尺寸下搜索框、筛选组、右侧操作不重叠，且右侧操作可读、可点、可键盘聚焦。

3. 选中反馈即时性需要低敏运行时证据口径。
   PRD 正确避免臆断原因，但测试需要证据标准。建议采用至少一种：
   - 低敏录屏：点击帧后选中态在下一帧或可接受短阈值内出现。
   - 事件日志：`mouseDown/click`、`selectedRecordID` 更新、耗时动作开始/结束的时序。
   - 截图时序：点击前、点击后即时状态、耗时动作完成后状态。
   pass/fail 重点是选中态不等待粘贴、复制、详情加载、OCR 或搜索状态更新。

4. Fixture 矩阵需要具体化。
   PRD 已列长文本、长标签、长来源 App、多语言和 OCR/索引状态，但建议固定最小 synthetic fixture：
   - text / URL / rich text / file URL / image。
   - OCR pending / running / done / failed / retry。
   - long text、long URL、long file name、long source app。
   - long tag、multi-tag、favorite + ordinary tag。
   - 中文、英文、日文长句。
   - search indexing / partial indexing 状态。
   这些 fixture 只用于布局和状态承载，不重新验收 Step 1/2 底层算法。

5. 键盘路径和 VoiceOver 检查需要 pass/fail 清单。
   PRD 已列语义要求，但需要明确失败条件：
   - Tab 顺序无法从搜索框到筛选组、条目列表、设置控件，fail。
   - 筛选组无法用键盘展开/选择/清除，fail。
   - 单击/双击显性控件不能用 Space/Enter 或等价方式切换，fail。
   - VoiceOver 只读出颜色/图标而不读标签名、active 状态、selected 状态、OCR 状态，fail。
   - focus ring 与 selected/hover/active filter 状态混淆，fail。

6. Step 1 / Step 2 回归边界需要写成验收口径。
   Step 3 只承载搜索状态和单标签筛选 UI，不应改底层事实源。建议补清：
   - Step 1 搜索状态 fixture 只验收布局承载，不验收搜索字段、OCR 队列或索引算法。
   - Step 2 单标签筛选只验收 filter UI active/clear/layout，不引入多标签 OR/AND。
   - 如果 Step 1/2 实现尚未闭合，Step 3 可用 mock state 或 fixture state 做布局验收，但必须记录底层依赖未验证。

## 可优化

1. Hover 的具体安全区形状、像素距离和动画曲线可由 UI/开发技术方案决定，不需要 PRD 直接写死。

2. 搜索框最小宽度和筛选组最大宽度可按当前面板实现确定；测试只要求每个断点可复跑。

3. 条目密度不必在 PRD 阶段规定具体 px 值。只要技术方案能提供基线对比和点击目标不退化证据即可。

4. 单击/双击控件使用 segmented control、radio group 或等价控件均可，不应由测试侧指定组件。

5. 多语言可先覆盖中文、英文、日文长句的布局不溢出；完整本地化质量可以后续 UI/交互继续打磨。

## 可吸收建议

### 1. Hover pass/fail 推荐样例

| 场景 | Pass | Fail |
| --- | --- | --- |
| trigger -> content | 鼠标从筛选触发区斜向移动到展开内容区，展开内容保持可用 | 移动过程中因触发区和内容区缝隙立即收起 |
| brief leave | 鼠标短暂离开展开边界后返回，仍保持展开或在可预测规则内恢复 | 轻微抖动或短暂越界立即收起 |
| obvious leave | 鼠标明显离开安全区并超过延迟，展开内容收起 | 长时间停留展开，遮挡其他操作 |
| right action | 展开时右侧关键操作可见、可点击、可聚焦 | 展开层遮挡右侧操作或导致按钮不可点 |
| layout stability | 展开/收起不导致搜索框和右侧操作大幅跳动 | 工具区元素跳动到不可读或不可操作 |

建议低敏证据：用 synthetic 标签名录屏鼠标轨迹，不包含真实剪贴板内容。

### 2. 选中反馈推荐证据

推荐至少记录以下任一证据：

- 低敏录屏：点击普通文本、图片/OCR、搜索结果、筛选结果条目，选中态即时出现。
- 事件日志：`click_record_id`、`selected_record_id_changed`、`expensive_action_started`、`ocr_state_changed`，证明 selected 先于耗时动作。
- 截图时序：点击前、点击后即时、后续动作完成后。

推荐 fail 条件：

- 点击后 selected/focused 等待 OCR 状态、搜索状态、复制/粘贴或详情加载完成才出现。
- 快速连续点击 A/B 时，选中态滞留在旧 A。
- hover、selected、focused 和 active filter 视觉层级无法区分。

### 3. 布局 fixture 推荐矩阵

| fixtureID | 用途 | 验收点 |
| --- | --- | --- |
| `txt_alpha_004` | 普通文本 | 密度收窄后正文仍可读，不被标签/来源覆盖 |
| `url_step3_long_004` | 长 URL | host/path 可识别，不撑破条目 |
| `rtf_plain_004` | 富文本 plain text | 显示 plain text，不与标签重叠 |
| `file_url_report_004` | file URL | 文件名可见，路径摘要有界 |
| `image_ocr_pending_004` | OCR 待处理 | 图片状态/OCR 状态不遮挡操作 |
| `image_ocr_failed_004` | OCR failed/retry | 失败/重试入口可见可达 |
| `long_text_004` | 长文本 | 截断或换行，不横向撑破 |
| `long_tag_004` | 长标签 | 标签截断/换行，不挤压主体内容 |
| `many_tags_004` | 多标签展示 | 多个标签不覆盖来源、时间、操作 |
| `long_source_app_004` | 长来源 App | 截断或 accessibility label 保留语义 |
| `zh_long_004` / `en_long_004` / `ja_long_004` | 多语言 | 工具区、条目、设置控件不溢出 |
| `search_indexing_004` | 搜索索引中 | indexing / OCR 状态提示不遮挡内容 |

### 4. 窗口尺寸推荐矩阵

建议技术方案固定项目当前面板的实际尺寸；测试至少按以下类别验收：

- 宽窗口：筛选组展开显示多个标签，不遮挡右侧操作。
- 默认窗口：搜索框可输入并显示可识别查询，筛选组可展开。
- 窄窗口：筛选组内部滚动、截断或折叠，不与搜索框/右侧操作重叠。
- 最小可用窗口：核心路径仍可达；如部分标签隐藏到更多菜单，不能丢失“全部”和 favorite。

### 5. 键盘路径推荐清单

Pass：

- Tab 可到达搜索框、筛选组、清除筛选、条目列表、单击/双击控件。
- 筛选组可用 Space/Enter 或等价方式展开。
- 展开后可用方向键或 Tab 移动到 `全部`、favorite、普通标签。
- Enter/Space 选择标签；Esc 或等价方式可关闭展开。
- 条目列表可用键盘移动 selected/focused 状态。
- 单击/双击控件可键盘切换。

Fail：

- 键盘无法清除筛选或回到全部。
- focus trap 在展开筛选组或设置控件中。
- OCR retry 入口可见但不可键盘聚焦。

### 6. VoiceOver 推荐清单

Pass：

- 搜索框读出 label 和当前查询。
- 筛选组读出当前 active 标签或 `全部`。
- 展开状态、选中标签、清除筛选动作可理解。
- 条目读出 selected/focused、主要内容摘要、标签名、来源 App、时间、OCR 状态。
- 单击/双击控件读出当前值、选项、互斥关系。
- favorite 五角星同时有文本语义，不只读图标。

Fail：

- 颜色、图标或 hover 背景是唯一信息来源。
- 长标签只截断视觉文本且无 accessibility label。
- selected 和 focused 状态无语义差异。

### 7. Step 1 / Step 2 回归边界

Step 3 验收建议分为“承载验证”和“底层回归验证”：

- 承载验证：用 mock/fixture 状态检查 search results、empty、indexing、OCR pending/running/failed/retry 在布局中不重叠。
- Step 1 底层回归：只运行或引用 Step 1 已接受门禁，确认搜索/OCR 底座未被 Step 3 改坏；不在 Step 3 重新定义搜索字段。
- Step 2 底层回归：确认 filter UI 仍是单标签筛选，favorite first，active/clear 正常；不引入 OR/AND。
- 若 Step 1/2 实现未完成，Step 3 验收记录必须写明底层依赖未验证，不能把 mock 承载验收写成底层通过。

## 建议最终验收矩阵

实现完成后建议串行记录：

1. Step 3 专用 hover / layout / selected feedback verifier 或手工低敏录屏证据。
2. Step 3 专用 keyboard / VoiceOver checklist。
3. Step 1 搜索状态与 OCR 状态承载 smoke，若 Step 1 已实现则运行对应门禁；未实现则使用 mock state 并记录残余依赖。
4. Step 2 单标签筛选和 favorite first smoke，若 Step 2 已实现则运行对应门禁；未实现则使用 mock tag state 并记录残余依赖。
5. Blocks App build。
6. `git diff --check`。

不应在 Step 3 PRD 复审或后续自动化中读取真实剪贴板内容、触发真实 OCR、provider、Keychain、TCC、系统设置、Show in Finder 或 restart。

## 残余风险

1. Hover 容错如果没有明确延迟/安全区规则，后续验收会依赖主观录屏判断。
2. 选中反馈即时性如果没有事件日志或帧级录屏，容易被“看起来还行”误判。
3. Step 1/2 并行推进时，mock state 可以验证布局承载，但不能证明搜索/OCR 或标签事实源真实闭合。
4. 长标签、多语言和窄窗口容易在实现后才暴露，需要至少一次低敏截图矩阵。
