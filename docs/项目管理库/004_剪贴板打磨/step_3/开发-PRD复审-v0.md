# Step 3 开发 PRD 复审 v0

状态：approve-with-changes
日期：2026-07-07
角色：开发
对象：`产品经理-PRD-v0.md`

## 1. 结论

Step 3 PRD v0 的阶段边界基本正确：聚焦剪贴板面板交互与布局打磨，没有把 Step 1 搜索/OCR 底座、Step 2 标签事实源、Step 4 详情编辑或 Step 5 隐私页 App 管理提前并入。

开发结论为 `approve-with-changes`。进入技术方案前需要补清几个可执行契约：Step 1 / Step 2 尚未实现时的依赖顺序，筛选组 hover 的实现形态和延迟收起规则，选中反馈的状态更新顺序和低敏证据，toolbar 的宽度优先级与窄窗口降级，单击/双击显性控件到底替换面板顶部菜单还是设置页控件，条目密度对滚动/动态高度/OCR 状态的约束，以及 Step 3 专属 verifier 的最低断言。

## 2. 当前代码事实

抽样核对当前代码后，PRD 指向的问题有真实实现落点：

- `ClipboardFilterClickGroup` 当前在 expanded 状态下通过 `onHover(false)` 直接触发 `onExpandedHoverExit()`，没有延迟取消、再进入取消收起或安全区域 corridor。
- 顶部工具区在 `ClipboardFloatingPanelView.header` 中由 search bar、filter strip、spacer、paste activation menu、清除筛选、设置、关闭按钮组成；目前 search bar 和 filter strip 都有 `frame(maxWidth:)`，但没有明确的 toolbar grid / fixed trailing action contract。
- `pasteActivationModeControl` 当前是面板顶部 `Menu`，而不是显性 segmented / radio 控件；`ClipboardSettingsPane` 当前没有对应的单击/双击设置行。
- record row/card 通过 `highPriorityGesture(TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() })` 触发粘贴，仅在 doubleClick 模式的普通 tap 中调用 `onSelect()`；这可能是选中反馈滞后或单击模式下选中态不稳定的来源之一，需要运行时证据确认。
- 侧边列表使用 `ScrollView + LazyVStack`，底部托盘使用 `ScrollView + LazyHStack` 和固定卡片宽高；密度调整需要分别处理 list row 和 bottom tray card，不能只改一套 padding。

## 3. 必须改

### 3.1 明确 Step 3 与 Step 1 / Step 2 的实现顺序

PRD v0 多处表述为“已有明文展示、搜索底座和标签/收藏信息结构之上”。从项目状态看，Step 1 / Step 2 仍在方案复审和技术方案阶段，未进入实现。开发前需要明确：

- 如果 Step 3 在 Step 1 / Step 2 实现之后做，验收可以直接覆盖搜索状态、OCR 状态和标签筛选布局。
- 如果 Step 3 先行实现，只能在当前旧 pinboard/filter/search UI 上做布局适配，并把 Step 1/2 之后的集成回归列为 residual risk。
- PRD / 技术方案不得要求 Step 3 自行补标签事实源、搜索索引或 OCR 状态生成逻辑。

推荐口径：

> Step 3 只承接 Step 1 / Step 2 已接受的用户可见状态布局；若实现顺序早于 Step 1 / Step 2，使用 synthetic view-state fixture 或当前实现占位验证布局，最终搜索/OCR/标签状态需在 Step 6 或对应集成 Gate 回归。

### 3.2 单击/双击显性控件的替换范围必须明确

当前 active 入口是面板顶部 `pasteActivationModeControl` 的 `Menu`；PRD v0 主要写“剪贴板设置中的单击和双击行为选择”。这会导致开发可能只在设置页新增控件，却保留面板顶部旧下拉菜单。

必须明确：

- Step 3 是否要替换面板顶部 `Menu`。
- 是否还要在 `ClipboardSettingsPane` 增加同一设置的显性控件。
- 如果两个位置都存在，二者必须绑定同一个 setting key：`clipboard.panel.pasteActivationMode`。
- 所有 active UI 中不得继续存在用于单击/双击切换的下拉菜单或 `Menu`。

开发建议：

> Step 3 至少替换面板顶部 active `Menu` 为 segmented control 或同等显性点击控件；设置页如新增同一设置，也必须复用同一 AppStorage key。若只做设置页，PRD 应明确面板顶部旧入口退出或降级为只读状态展示。

### 3.3 hover 容错需要写成可验证的事件规则

PRD 已定义短暂移出不误收、明显离开会收起，但技术方案前还需要把最低事件规则写清：

- 展开区和触发区之间应有连续 hit-test 区域，不能存在窄缝。
- 离开展开区时启动短延迟收起，而不是立即收起。
- 延迟期间鼠标重新进入触发区、展开区或安全区域时取消收起。
- 点击选项、切换筛选组、按 Escape、关闭面板、窗口失焦时应立即收起。
- 收起延迟和动画不能阻塞右侧按钮点击。

实现上可选 overlay、popover 或自定义 hit-test layer，但 PRD / 技术方案应禁止只依赖 expanded group 自身的即时 `onHover(false)` 作为最终方案。

### 3.4 选中反馈要补“状态先写、动作后做”的契约

“即时”是正确的用户目标，但开发需要可执行顺序：

- 点击条目时应先更新 selected/focused state，再触发 paste、copy、detail load、hover detail、OCR retry 或其他耗时动作。
- single-click paste 模式下也应有可见 selected/focused feedback；如果产品希望单击立即粘贴并关闭面板，仍应定义是否需要短暂选中反馈或跳过此验收。
- double-click 模式下第一次 click 应选择，第二次 click 才粘贴。
- 快速连续点击不同条目时，selected state 应跟随最新输入，不被旧 paste/detail completion 回写覆盖。

建议 PRD v1 把验收证据写成低敏事件序列，例如只输出 fixture recordID、event name 和相对时间，不输出剪贴板正文：

```text
pointerDown(record=A) -> selected(record=A) -> pasteRequested(record=A)
pointerDown(record=B) -> selected(record=B)
```

具体毫秒阈值可由测试/质量和技术方案确认，但必须能证明 selected state 不等待 payload/OCR/search 完成。

### 3.5 toolbar 宽度优先级要形成布局契约

PRD 已要求搜索框、筛选组和右侧操作不重叠，但技术方案前需要确定优先级，否则 SwiftUI `Spacer`、`maxWidth` 和 ScrollView 很容易在窄窗口下互相挤压。

推荐写入 PRD v1 或技术方案：

- 右侧关键操作是 fixed trailing column，不能被筛选组 overlay 遮挡。
- search bar 有最小宽度；低于最小宽度时内部滚动或尾部截断，不撑破 toolbar。
- filter strip 有最大展开宽度；标签过多时内部横向滚动或更多入口，不推挤右侧操作。
- 清除筛选、设置、关闭按钮属于固定操作区，必须保留点击目标。
- 需要覆盖 bottom panel 和 side panel 两种 position；两者当前 minWidth/minHeight 不同，不能只验收一种。

如果不想在 PRD 中写具体像素，可至少要求技术方案给出断点、min/max width 和右侧操作清单。

### 3.6 条目密度要拆 list row 与 bottom tray card

当前面板有两类条目容器：侧边 `ClipboardFloatingRecordRow` 和底部 `ClipboardFloatingRecordCard`。PRD v0 的“条目上下边框或内边距收窄”需要拆成两个验收面：

- side list：row padding、缩略图尺寸、标题/时间/正文/badge 的纵向节奏。
- bottom tray：card padding、固定 card height、body line limit、resize handle、thumbnail/image preview 区域。

必须保持：

- hover / selected / focused 状态不改变 row/card 尺寸。
- OCR / indexing / excluded / skipped 等状态不引发动态高度抖动。
- 点击目标和 context menu target 不因 padding 收窄变得难点。
- 长标签、长 App 名、长 URL、file path 摘要和 OCR 状态不覆盖主要内容。

建议技术方案使用稳定最小高度、固定缩略图尺寸、状态槽位和 lineLimit，而不是根据 hover/selected 动态增减内容。

### 3.7 需要 Step 3 专属 verifier / 证据门禁

PRD v0 有验收样例，但缺少开发可落地的门禁名称和最低断言。建议新增 P13C 或等价 Step 3 gate：

- 当前 PRD 和复审文档存在，旧草稿 / 旧 story 只能作为 baseline。
- 筛选组存在延迟收起或安全区域实现，不是即时 hover exit collapse。
- active 单击/双击设置不再使用 `Menu` / 下拉。
- selected state update 与 paste/detail action ordering 可静态或低敏运行时验证。
- toolbar 有 search min width、filter max width、fixed trailing actions 或等价约束。
- list row 与 bottom tray card 均有稳定尺寸约束，hover/selected/OCR 状态不改变容器尺寸。
- 低敏截图/录屏或 snapshot fixture 不含真实剪贴板正文、真实路径、邮箱、secret、Authorization header、二维码、验证码。

旧 P7/P8/P9 如迁移为 Step 3 阻断证据，必须使用当前 Step 3 PRD、开发记录和当前代码事实源；旧归档只能 baseline reference。

## 4. 可优化

- hover 容错可以先做“trigger + expanded union hit-test + 150-250ms delayed collapse”，复杂三角 corridor 可后续优化；但延迟取消和明显离开收起必须首版可验。
- 选中反馈可以优先解耦 selection 与 paste action，不必先引入完整 telemetry。若需要证据，使用低敏 in-memory event recorder 或 UI test fixture。
- toolbar 可先采用 `ViewThatFits` / fixed trailing action group / bounded horizontal scroll 的组合，避免在 PRD 阶段指定像素。
- 单击/双击控件优先复用现有 `SettingsFormRow` + segmented `Picker` 模式；面板顶部可用 compact segmented control 或两个 icon buttons。
- 条目密度可以先收敛 padding 和 lineLimit，不建议在 Step 3 引入新的虚拟列表框架。
- OCR 状态在 Step 3 只预留布局槽，不实现 OCR pipeline；测试 fixture 可用短 token 状态模拟。

## 5. 可吸收到 PRD / 技术方案的建议口径

### 5.1 hover 验收样例

建议补充：

- 从触发区斜向移动到展开内容区，不收起。
- 离开展开区 100ms 内返回，不收起。
- 明显离开筛选区域并移动到列表区，可预测收起。
- 切换到另一个筛选组，旧展开区立即收起，新组展开。
- 面板关闭、失焦或 Escape 后，展开状态清理。

### 5.2 选中反馈证据

建议补充：

- 使用 synthetic record id，例如 `clip_text_alpha`、`clip_image_vision`。
- 记录低敏事件：pointer/tap、selectedID 更新、paste/detail request、async completion。
- 验证 selectedID 更新早于 paste/detail request，且 async completion 不覆盖最新 selectedID。
- 验证 single-click 和 double-click 两种模式。

### 5.3 toolbar 布局矩阵

建议补充至少三档：

- 宽窗口：搜索框、多个标签筛选、右侧按钮全部可见。
- 中等窗口：搜索框保持可识别查询，筛选组内部滚动，右侧按钮固定。
- 窄窗口：筛选组折叠或更多入口，搜索框不小于最小可用宽度，设置/关闭可达。

### 5.4 条目密度矩阵

建议补充：

- side list row 与 bottom tray card 分别验收。
- text、URL、rich text、image/OCR、file URL、excluded/skipped 状态分别验收。
- 长文本、长标签、长 App 名、多语言长句分别验收。
- hover、selected、focused 状态切换不导致尺寸跳动。

### 5.5 单击/双击设置口径

建议补充：

- active panel header 中的单击/双击切换不得继续是下拉菜单。
- 设置页如提供同一设置，必须与 panel header 使用同一持久化 key。
- 选项文案过长时可以换行或用短标签 + accessible label，不回退为菜单。

## 6. 残余风险

- 如果 Step 3 先于 Step 1 / Step 2 实现，搜索/OCR/tag 状态只能用 fixture 或当前旧实现占位验收；最终仍需 Step 6 集成回归。
- hover、selected feedback 和滚动性能需要低敏运行时证据，仅靠静态扫描不足以接受。
- 条目密度收窄容易引入文字截断和点击目标退化，需要 UI/测试共同确认最小目标和多语言样例。
- 面板顶部和设置页的单击/双击入口如果并存，必须防止两个控件绑定不同状态。
