# Step 3 项目负责人 PRD 复审收敛 v0

状态：revision-requested
日期：2026-07-07
角色：项目负责人
对象：`step_3/产品经理-PRD-v0.md`

## 1. 结论

Step 3 PRD v0 范围正确，但进入技术方案前需要产品经理产出 `产品经理-PRD-v1.md`。

本阶段继续只覆盖面板交互与布局打磨，不进入 Step 1 搜索/OCR 底座、Step 2 标签事实源、Step 4 详情编辑或 Step 5 隐私页 App 管理。

当前复审结论：

- UI/交互设计师：`approve-with-changes`
- 测试/质量：`approve-with-changes`
- 开发：`approve-with-changes`

项目负责人判断：没有需要回到用户澄清的问题；问题均可通过 PRD v1 收敛。

## 2. 必须回写 PRD v1

### 2.1 更新依赖状态

PRD v1 应按当前事实更新依赖口径：

- Step 1 已接受。
- Step 2 已接受。
- Step 3 不再需要写“如果 Step 1 / Step 2 尚未闭合”的实现分支。
- Step 3 仍只承载 Step 1 / Step 2 已接受的用户可见状态和回归边界，不修改搜索/OCR 底座或标签事实源。

### 2.2 Hover 容错首版规则

补成可执行的首版规则：

- 采用“触发区到内容区的安全桥 + 短延迟收起”。
- 鼠标从触发区斜向移动到展开内容区不收起。
- 短暂离开展开边界后返回不收起。
- 明显离开筛选相关区域后可预测收起。
- 点击选项、切换筛选组、按 Escape、关闭面板或窗口失焦时应立即收起。
- 延迟用于容错，不得让展开层长期遮挡其他操作。

PRD 不需要写死毫秒数或像素形状，但必须要求技术方案给出可验收的延迟、hit-test 区域或等价规则。

### 2.3 Toolbar 空间优先级与窗口矩阵

补清：

- 右侧关键操作清单。
- 空间优先级：右侧关键操作可见可点 > 搜索框最小可读宽度 > 筛选组展开内容。
- 宽 / 常规 / 窄 / 最小可用窗口矩阵。
- 筛选组窄宽度降级策略：内部滚动、截断、折叠或更多入口。
- 搜索框长查询处理方式：输入框内部滚动、截断或等价方案，不撑破 toolbar。
- 展开 / 收起不能造成搜索框、右侧操作或列表大幅跳动。

### 2.4 状态层级与选中反馈顺序

补清视觉和事件契约：

- `selected` 是条目持久选择状态，优先级高于 hover。
- `focused` 是键盘焦点，可与 selected 并存，不能只靠 selected 替代。
- `hover` 是临时指向状态，不覆盖 selected。
- `active filter` 属于 toolbar / filter 状态，不与条目 selected 混用。
- 点击条目时先更新 selected / focused，再触发 paste、copy、detail load、OCR retry 或其他耗时动作。
- single-click paste 和 double-click paste 两种模式都要定义选中反馈行为。
- 快速连续点击不同条目时，selected 跟随最新点击，不被旧异步 completion 回写覆盖。

验收证据可采用低敏录屏、事件日志或截图时序；不得依赖“看起来还行”的主观描述。

### 2.5 单击 / 双击显性控件范围

必须明确：

- Step 3 至少替换面板顶部 active 的单击 / 双击切换 `Menu`，不得继续以当前下拉菜单作为 active 切换入口。
- 如设置页也提供同一设置，必须与面板顶部使用同一个持久化 key：`clipboard.panel.pasteActivationMode`。
- 单击行为和双击行为需要显性互斥控件；短选项可用 segmented control，长选项或多语言较长时用 radio group 或等价按钮组。
- 当前值常显，支持键盘和 VoiceOver。

### 2.6 条目密度拆分验收

PRD v1 需要分别覆盖：

- side list row。
- bottom tray card。

必须补清：

- 基线与调整后的低敏截图或等价对照。
- 核心内容区域增加，但点击目标不退化。
- hover / selected / focused 状态不改变 row/card 尺寸。
- OCR / indexing / excluded / skipped 状态不引发动态高度抖动。
- 长文本、长 URL、file URL、长标签、长来源 App、多语言长句不重叠。

### 2.7 Fixture、截图/录屏、键盘与 VoiceOver 矩阵

PRD v1 必须把验收证据写成矩阵：

- 视口：宽、常规、窄、最小可用。
- 内容 fixture：text、URL、rich text plain text、file URL、image。
- 状态 fixture：OCR pending / running / done / failed / retry，search indexing / partial indexing。
- 压力 fixture：long text、long URL、long file name、long source app、long tag、many tags、中文 / 英文 / 日文长句。
- 交互：hover 斜向移动、短暂移出、明显离开、点击选中、快速连续点击。
- 键盘：搜索框、筛选组、清除筛选、条目列表、单击 / 双击控件可达可操作。
- VoiceOver：搜索框、active filter、selected/focused、标签名、来源 App、时间、OCR 状态、favorite 图标语义可读。

证据必须使用 synthetic / fixture 内容，不得包含真实剪贴板正文、真实 home path、邮箱、secret、Authorization header、二维码、验证码或真实文件路径。

### 2.8 Step 3 专属门禁

PRD v1 需要提出 Step 3 最低门禁要求，可命名为 P13C 或等价：

- hover 容错不再是即时 `onHover(false)` 收起。
- active 单击 / 双击设置不再使用 `Menu` / 下拉。
- selected state 更新先于 paste/detail 等耗时动作。
- toolbar 存在 search min width、filter max width、fixed trailing actions 或等价约束。
- side list row 与 bottom tray card 均有稳定尺寸和状态槽位约束。
- 低敏截图 / 录屏 / snapshot fixture 不含敏感内容。
- Step 1 搜索/OCR 状态承载和 Step 2 单标签筛选 UI 作为回归边界验证，不重新定义底层算法或标签事实源。

## 3. 可优化但不阻塞 PRD v1

- 具体 hover 延迟毫秒数、距离阈值、动画曲线可留给技术方案。
- 复杂三角 corridor、标签搜索、分页和高级动效可后续优化。
- 具体像素断点可由技术方案确定，PRD 只需定义宽 / 常规 / 窄 / 最小可用矩阵。
- 条目密度不需要写死 px 值，但必须要求前后对照和点击目标不退化。

## 4. 当前不需要新增角色复审

Step 3 是面板交互与布局专项，已有 UI/交互、测试/质量和开发复审足以支撑 PRD v1 修订。

App 架构师可在 PRD v1 接受后参与技术方案或实现风险评估，重点看事件顺序、SwiftUI 布局边界、状态流和 verifier 设计；不要求现在补 PRD 复审。

## 5. 下一步

派发产品经理基于本收敛文档产出：

- `step_3/产品经理-PRD-v1.md`

PRD v1 完成后，项目负责人先做复核；若以上 must-change 均已吸收，可接受 PRD 并进入技术方案阶段。若仍缺可执行规则或证据矩阵，则继续退回产品经理修订。
