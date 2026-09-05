# Step 3 产品经理 PRD v1：面板交互与布局打磨

状态：prd-revision-v1
修订日期：2026-07-07
起草角色：产品经理
所属项目：004_剪贴板打磨
所属阶段：Step 3
来源级别：基于 `../step.md`、`../需求覆盖矩阵-v0.md`、`产品经理-PRD-v0.md`、`项目负责人-PRD预审-v0.md`、`UI-交互设计师-PRD复审-v0.md`、`测试-质量-PRD复审-v0.md`、`开发-PRD复审-v0.md`、`项目负责人-PRD复审收敛-v0.md` 修订。

## 1. 修订结论

Step 3 继续只覆盖剪贴板面板交互与布局打磨。PRD v1 吸收项目负责人收敛意见，把 v0 中较抽象的体验目标补成可执行的首版规则、状态顺序、窗口矩阵、证据矩阵和 Step 3 专属门禁。

本阶段不进入技术方案或开发实现，不触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

## 2. 阶段目标

在 Step 1 明文展示 / 搜索 / OCR 底座和 Step 2 标签 / 收藏模型已接受的基础上，Step 3 打磨高频面板操作体验：

- 筛选组 hover 展开更稳定，不因轻微移出误收起。
- 搜索框、筛选组和右侧关键操作在宽窄窗口下不重叠。
- 条目点击后 selected / focused 反馈先于 paste、detail、OCR retry 等动作出现。
- 单击 / 双击行为切换改为显性点击控件，不再用下拉作为 active 切换入口。
- side list row 与 bottom tray card 分别做密度优化，扩大核心内容区域且不牺牲点击目标。
- 用低敏 fixture、截图 / 录屏、键盘和 VoiceOver 矩阵保证体验验收可复跑。

## 3. 依赖状态与回归边界

### 3.1 当前事实

- Step 1 已验收接受。
- Step 2 已验收接受。
- Step 3 不再写“如果 Step 1 / Step 2 尚未闭合”的实现分支。
- Step 3 只承载 Step 1 / Step 2 已接受的用户可见状态和回归边界，不修改搜索 / OCR 底座或标签事实源。

### 3.2 来自 Step 1 的可承载状态

Step 3 可以在布局中承载：

- 面板真实可读内容预览。
- 搜索输入、搜索结果、无结果、索引中、局部索引中等状态。
- OCR pending / running / done / failed / retry 状态。
- 搜索清除入口、OCR 状态提示和 OCR retry 入口，如果这些入口已在当前面板中可见。

Step 3 不重新定义：

- 搜索字段、索引算法、OCR 队列、Vision 调用、OCR 重试逻辑。
- 日志、CLI、provider、自动化输出边界。

### 3.3 来自 Step 2 的可承载状态

Step 3 可以在布局中承载：

- 单标签筛选。
- `全部` 或等价未筛选状态。
- 收藏默认第一。
- 普通标签按 Step 2 已接受排序展示。
- active filter、清除筛选 / 回到全部、长标签和多标签展示。

Step 3 不重新定义：

- 标签数据模型、record-tag 关系、收藏 built-in identity。
- 标签创建、重命名、颜色、排序、合并、右键标签关系。
- 多标签 OR / AND 筛选。

## 4. 需求覆盖矩阵对齐

### 4.1 Step 3 必须覆盖

| 矩阵 ID | PRD v1 覆盖口径 |
| --- | --- |
| R3 | 筛选组 hover 采用安全桥 + 短延迟收起 + 明显离开收起，并提供 pass/fail 样例。 |
| R4 | 点击条目时 selected / focused 先写，paste / detail / OCR retry 等动作后做，并有低敏证据口径。 |
| R5 | 筛选组展开宽度与右侧关键操作通过空间优先级和窗口矩阵验收。 |
| R6 | 搜索框适度缩短，但保留最小可读宽度和长查询处理方式。 |
| R10 | 至少替换面板顶部 active 单击 / 双击 `Menu`，改为显性互斥控件。 |
| R11 | side list row 与 bottom tray card 分别做密度验收，要求前后对照、点击目标不退化、状态不跳动。 |
| C10 | 选中反馈延迟作为用户可见问题验收，不臆断原因，但要求状态顺序证据。 |
| C17 | 通过布局、状态、键盘、VoiceOver、截图 / 录屏和低敏 fixture 矩阵体现页面质感。 |

### 4.2 不属于 Step 3

| 矩阵 ID | 所属阶段 | Step 3 处理方式 |
| --- | --- | --- |
| R1.1、R1.2、R2、C1、C3、C4、C11、C12、C13 | Step 1 | 只做用户可见状态承载和回归边界，不改搜索 / OCR / 输出控制。 |
| R7、R8、C2、C5、C6、C7 | Step 2 | 只做单标签筛选 UI、active filter 和布局回归，不改标签事实源。 |
| R12、R13、C9、C14、C15 | Step 4 | 不做详情编辑、保存 / 取消、富文本编辑和详情元数据组织。 |
| R9、C8 | Step 5 | 不做隐私页真实 App 清单、图标枚举或 CLI 广义对象管理。 |
| P5 | Step 6 | 不做最终全量覆盖回扫。 |

## 5. 明确非目标

本阶段不覆盖：

- 重新设计 Step 1 搜索 / OCR 底座。
- 修改搜索字段、搜索排序、索引更新、OCR 队列或 Vision 调用。
- 修改 Step 2 标签事实源、收藏 built-in identity、右键标签关系或设置页标签管理。
- 详情编辑、保存 / 取消、富文本编辑和 OCR 文本编辑。
- 隐私页真实 App 清单、系统 App 图标和 CLI 广义对象管理。
- 旧 pinboard / pinned 迁移或兼容。
- 全量面板视觉重设计。
- 高级动效、标签搜索、标签分页、复杂三角 corridor 等后续优化。

## 6. 功能需求

### 6.1 Hover 容错首版规则

筛选组展开采用首版规则：触发区到内容区的安全桥 + 短延迟收起 + 明显离开收起。

必须满足：

- 触发区与展开内容区之间有连续安全区域，不允许出现 hover 断裂窄缝。
- 鼠标从触发区斜向移动到展开内容区时，展开内容不收起。
- 鼠标短暂离开展开边界后返回时，展开内容不收起或按技术方案定义的可预测规则恢复。
- 鼠标明显离开筛选相关区域并超过延迟后，展开内容收起。
- 点击筛选选项、切换到另一个筛选组、按 Escape、关闭面板或窗口失焦时，展开内容立即收起。
- 延迟只用于容错，不得让展开层长期遮挡搜索框、列表或右侧关键操作。
- 展开层不得捕获不相关区域点击，导致右侧关键操作或搜索框不可用。

Pass / fail 样例：

| 场景 | Pass | Fail |
| --- | --- | --- |
| trigger -> content | 鼠标斜向从筛选触发区移动到第三个标签项，展开内容保持可用。 | 因触发区与内容区之间窄缝立即收起。 |
| brief leave | 鼠标短暂越过展开边缘后返回，展开内容仍可操作。 | 轻微抖动或短暂越界即收起。 |
| obvious leave | 鼠标移动到列表空白区或搜索框并停留，展开内容在可预测延迟内收起。 | 展开层长时间停留并遮挡其他操作。 |
| action close | 点击选项、Esc、失焦或关闭面板后，展开状态被清理。 | 关闭条件后仍残留展开层。 |

技术方案待确认：具体延迟毫秒数、hit-test 区域、距离阈值和动画曲线由 UI / 开发确认。该项不影响开发前验收边界，因为 PRD 已定义首版行为和 pass/fail。

### 6.2 Toolbar 空间优先级

顶部工具区至少承载搜索框、筛选组和右侧关键操作。空间优先级固定为：

1. 右侧关键操作可见、可读、可点击、可键盘聚焦。
2. 搜索框保留最小可读宽度。
3. 筛选组在剩余空间内展开更多内容。

右侧关键操作清单：

- paste activation 显性控件，即本阶段替换原 active `Menu` 的单击 / 双击切换入口。
- 清除筛选 / 显示全部入口，如果当前处于 active filter。
- 设置入口。
- 关闭面板入口。
- 其他当前面板已经固定在右侧的操作入口，如存在，必须纳入同一固定操作区，不得被筛选展开层覆盖。

搜索清除入口如果位于搜索框内部，也必须保持可见可点，但不计入右侧固定操作区。

必须满足：

- 右侧关键操作作为固定操作区或等价稳定区域，不被筛选组 overlay / popover / scroll 内容遮挡。
- 搜索框有最小可读宽度；长查询使用输入框内部滚动、截断或等价方式处理，不撑破 toolbar。
- 筛选组有最大展开宽度；标签过多时使用内部横向滚动、截断、折叠或更多入口，不推挤右侧关键操作。
- 筛选组展开 / 收起不得造成搜索框、右侧关键操作或列表大幅跳动。
- side panel 与 bottom panel 两种面板位置都要验收；不能只证明一种布局可用。

### 6.3 窗口矩阵

具体像素断点由技术方案给出。PRD 验收按宽、常规、窄、最小可用四类窗口矩阵执行。

| 窗口类别 | Toolbar 要求 | 筛选组要求 | 搜索框要求 | 右侧关键操作要求 |
| --- | --- | --- | --- | --- |
| 宽窗口 | 单行稳定展示，空间利用充分。 | 展开后可显示多个标签。 | 查询可读，清除入口可用。 | 全部固定操作可见可点。 |
| 常规窗口 | 搜索框、筛选组、右侧操作弹性分配且不重叠。 | 可展开，必要时内部滚动或截断。 | 保持最小可读宽度。 | 设置、关闭、active 控件和清除筛选可达。 |
| 窄窗口 | 不允许重叠或横向撑破。 | 折叠、内部滚动、截断或更多入口。 | 长查询在输入框内处理。 | 固定操作不被遮挡，可键盘聚焦。 |
| 最小可用窗口 | 核心路径仍可达，不追求完整展示。 | `全部` 和收藏不得丢失；普通标签可进入更多入口。 | 可输入和辨识当前查询的核心片段。 | 关闭、设置和 active 控件仍可访问；清除筛选有等价路径。 |

### 6.4 状态层级

条目和筛选状态必须使用清晰的语义层级：

- `selected` 是条目持久选择状态，优先级高于 hover。
- `focused` 是键盘焦点，可以与 selected 并存，不能只靠 selected 替代。
- `hover` 是鼠标临时指向状态，不覆盖 selected。
- `active filter` 属于 toolbar / filter 状态，不与条目 selected 使用同一语义或造成混淆。
- OCR / indexing / excluded / skipped 等状态属于条目或搜索状态承载，不应覆盖 selected / focused 语义。

验收样例：

- hover 非选中条目时，已选中条目仍保持 selected。
- 键盘移动时 focus ring 或等价焦点样式可见，并可被 VoiceOver 理解。
- 选择某个标签筛选后，toolbar 的 active filter 不会让某个条目看起来被选中。

### 6.5 选中反馈顺序

点击条目时，状态顺序必须是 selected / focused 先写，paste / copy / detail load / OCR retry / hover detail / async completion 后做。

必须满足：

- 鼠标 down 或 click 后，selected / focused 在用户感知上即时出现。
- selected / focused 不等待粘贴、复制、详情加载、OCR 状态变化、搜索状态变化或 payload 读取完成。
- single-click paste 模式下，也必须先写 selected / focused，再发起 paste request；如果面板随 paste 立即关闭，低敏事件证据仍需证明状态先写。
- double-click paste 模式下，第一次 click 选择 / 聚焦，第二次 click 触发 paste。
- 快速连续点击不同条目时，selected 跟随最新点击，不被旧 paste / detail / OCR completion 回写覆盖。

证据口径：

- 可使用低敏录屏、事件日志或截图时序。
- 事件日志只能输出 synthetic record id、事件名和相对时间，不输出剪贴板正文、payload、真实路径或 OCR 原文。
- 推荐事件顺序示例：

```text
pointerDown(record=clip_text_alpha) -> selected(record=clip_text_alpha) -> pasteRequested(record=clip_text_alpha)
pointerDown(record=clip_image_vision) -> selected(record=clip_image_vision) -> detailRequested(record=clip_image_vision)
```

### 6.6 单击 / 双击显性控件

Step 3 至少替换面板顶部 active 的单击 / 双击切换 `Menu`。不得继续以当前下拉菜单或 `Menu` 作为 active 切换入口。

必须满足：

- 面板顶部 active 切换使用显性互斥控件，当前值常显。
- 短选项可使用 segmented control。
- 长选项或多语言文案较长时，可使用 radio group 或等价按钮组。
- 单击行为和双击行为的语义清晰，不把互斥动作混在难以理解的下拉入口中。
- 支持键盘导航、Space / Enter 或等价切换。
- VoiceOver 能读出当前值、可选项和互斥关系。
- 中文、英文、日文长文案下不溢出；可换行、缩短视觉标签并补 accessibility label，但不能回退为下拉。

设置页边界：

- 如果设置页也提供同一设置，必须与面板顶部使用同一个持久化 key：`clipboard.panel.pasteActivationMode`。
- 如果 Step 3 不在设置页新增该控件，PRD 不要求设置页同步增加；但面板顶部旧 active `Menu` 仍必须退出 active 切换入口。
- 如果两个位置并存，不允许出现绑定不同状态、显示不一致或互相覆盖的问题。

### 6.7 条目密度拆分验收

条目密度必须分别覆盖 side list row 与 bottom tray card，不能只调整一套 padding 后视为完成。

side list row 必须覆盖：

- row padding、分隔线、缩略图尺寸、标题 / 时间 / 正文 / badge 的纵向节奏。
- 主体内容区域比基线更大。
- 点击主体、缩略图或 row 可点击区域仍能稳定选择。
- context menu target 不因 padding 收窄变得难点。

bottom tray card 必须覆盖：

- card padding、固定 card height、body line limit、缩略图 / 图片预览区、resize handle 或等价结构。
- card 在 hover / selected / focused / OCR 状态变化时不改变尺寸。
- 横向滚动和卡片间距保持稳定，不因状态文字出现导致相邻卡片跳动。

共同要求：

- 提供同一组低敏 fixture 的基线与调整后截图、录屏或等价记录。
- 核心内容区域增加，但点击目标不退化。
- hover / selected / focused 状态不改变 row / card 尺寸。
- OCR / indexing / excluded / skipped 状态不引发动态高度抖动。
- 长文本、长 URL、file URL、长标签、长来源 App、多语言长句不重叠。
- 文本、标签、来源 App、时间、状态和操作按钮不得互相覆盖。

技术方案待确认：具体 px、最小高度、lineLimit、缩略图尺寸和点击目标数值由 UI / 开发确认。该项不影响开发前验收边界，因为 PRD 已定义前后对照、点击目标不退化和状态不跳动。

## 7. Fixture 与证据矩阵

所有验收证据必须使用 synthetic / fixture 内容，不得包含真实剪贴板正文、真实 home path、邮箱、secret、Authorization header、二维码、验证码、真实文件路径或真实 OCR 隐私图片。

### 7.1 内容 fixture

| fixtureID | 类型 | 用途 |
| --- | --- | --- |
| `txt_alpha_004` | text | 普通文本密度、选中反馈和搜索承载。 |
| `url_step3_long_004` | URL | 长 URL 截断 / 内部布局。 |
| `rtf_plain_004` | rich text plain text | 富文本纯文本预览布局，不验收富文本编辑。 |
| `file_url_report_004` | file URL | 文件名 / 路径摘要有界展示，不使用真实路径。 |
| `image_ocr_pending_004` | image | OCR pending 状态槽位。 |
| `image_ocr_running_004` | image | OCR running 状态槽位。 |
| `image_ocr_done_004` | image | OCR done 状态槽位，短 token 可用 `VISION-004`。 |
| `image_ocr_failed_004` | image | OCR failed / retry 入口布局。 |

### 7.2 压力 fixture

| fixtureID | 用途 | 验收点 |
| --- | --- | --- |
| `long_text_004` | 长文本 | 截断或换行，不横向撑破。 |
| `long_url_004` | 长 URL | host / path 可识别，不撑破条目。 |
| `long_file_name_004` | 长文件名 | 文件名摘要可读，不展示真实路径。 |
| `long_source_app_004` | 长来源 App | 视觉截断或 accessibility label 保留语义。 |
| `long_tag_004` | 长标签 | 截断 / 换行，不挤压主体内容。 |
| `many_tags_004` | 多标签 | 不覆盖来源、时间和操作按钮。 |
| `zh_long_004` | 中文长句 | 工具区、条目、控件不溢出。 |
| `en_long_004` | 英文长句 | 长单词和长句不撑破。 |
| `ja_long_004` | 日文长句 | 设置控件和条目不溢出。 |
| `search_indexing_004` | search indexing | indexing / partial indexing 状态不遮挡内容。 |

### 7.3 截图 / 录屏矩阵

| 维度 | 必须覆盖 |
| --- | --- |
| 视口 | 宽、常规、窄、最小可用。 |
| 面板位置 | side panel、bottom panel。 |
| 面板状态 | 默认、搜索中、搜索无结果、筛选展开、active filter、OCR / indexing 状态、长内容。 |
| hover 交互 | 斜向移动、短暂移出、明显离开、Esc / 失焦 / 点击选项收起。 |
| 点击反馈 | 普通列表、搜索结果、筛选结果、图片 / OCR 条目、快速连续点击。 |
| 单击 / 双击控件 | 中文、英文、日文长文案；键盘和 VoiceOver 可用。 |
| 密度 | side list row 调整前后、bottom tray card 调整前后。 |

最低证据要求：

- 至少 4 组 toolbar 截图：宽、常规、窄、最小可用。
- 至少 2 段 hover 录屏或等价事件证据：斜向移动 / 短暂移出 / 明显离开。
- 至少 1 段点击反馈录屏或事件证据：selected / focused 先写。
- 至少 2 组密度前后对照：side list row、bottom tray card。
- 至少 1 组键盘路径记录和 1 组 VoiceOver 检查记录。

## 8. 键盘与 VoiceOver 验收

### 8.1 键盘路径

Pass 条件：

- Tab 可到达搜索框、筛选组、清除筛选 / 显示全部、条目列表、面板顶部 active 控件、设置入口和关闭入口。
- 筛选组可用 Space / Enter 或等价方式展开。
- 展开后可到达 `全部`、收藏和普通标签。
- Enter / Space 或等价方式可选择标签。
- Esc 或等价方式可关闭筛选展开层。
- 条目列表可用键盘移动 focused / selected 状态。
- 面板顶部 active 单击 / 双击控件可用键盘切换。
- OCR retry 入口如果可见，则可键盘聚焦和触发。

Fail 条件：

- 键盘无法清除筛选或回到全部。
- focus trap 在筛选展开层或 active 控件中。
- focus ring 与 selected / hover / active filter 状态混淆。
- 可见操作无法键盘聚焦。

### 8.2 VoiceOver

Pass 条件：

- 搜索框读出 label 和当前查询。
- 筛选组读出当前 active 标签或 `全部`。
- 展开 / 收起状态、选中标签、清除筛选动作可理解。
- 条目读出 selected / focused、主要内容摘要、标签名、来源 App、时间和 OCR 状态。
- 收藏五角星同时有文本语义，不只读图标。
- 面板顶部 active 控件读出当前值、选项和互斥关系。
- 长标签视觉截断时，accessibility label 或等价语义保留完整标签名。

Fail 条件：

- 颜色、图标或 hover 背景是唯一信息来源。
- selected 和 focused 无语义差异。
- OCR 状态、active filter 或 favorite 只能通过视觉猜测。

## 9. Step 3 专属门禁：P13C

进入开发验收时，Step 3 需要 P13C 或等价门禁。门禁名称可由技术方案调整，但最低断言不得少于以下内容：

1. PRD / 复审 / 开发记录使用当前 Step 3 文档；旧草稿或旧 story 只能作为 baseline reference。
2. Hover 容错不再是即时 `onHover(false)` 收起，必须存在安全桥、短延迟收起、再进入取消收起或等价规则。
3. 面板顶部 active 单击 / 双击设置不再使用 `Menu` / 下拉作为切换入口。
4. 如设置页提供同一设置，必须使用同一 key：`clipboard.panel.pasteActivationMode`。
5. selected / focused state 更新先于 paste、detail、OCR retry 或其他耗时动作。
6. 快速连续点击不同条目时，旧异步 completion 不覆盖最新 selected。
7. Toolbar 存在 search min width、filter max width、fixed trailing actions 或等价约束。
8. 右侧关键操作在宽、常规、窄、最小可用窗口下可见、可点、可键盘聚焦。
9. side list row 与 bottom tray card 均有稳定尺寸和状态槽位约束。
10. hover / selected / focused / OCR / indexing / excluded / skipped 状态不改变 row / card 尺寸。
11. 低敏截图、录屏、snapshot fixture 或事件日志不含真实剪贴板正文、真实路径、邮箱、secret、Authorization header、二维码或验证码。
12. Step 1 搜索 / OCR 状态承载和 Step 2 单标签筛选 UI 作为回归边界验证；P13C 不重新定义底层搜索算法、OCR pipeline 或标签事实源。

P13C 可以由静态检查、fixture snapshot、低敏事件日志、截图 / 录屏和必要 build gate 组合完成。仅靠主观描述“看起来正常”不能作为通过证据。

## 10. 验收样例

### 10.1 Hover

- Pass：鼠标从筛选触发区斜向移动到第三个标签，展开层不收起。
- Pass：鼠标短暂移出展开边界后返回，展开层仍可操作。
- Pass：鼠标明显离开筛选相关区域并停留到列表区域，展开层按规则收起。
- Fail：轻微越界立即收起。
- Fail：展开层长期遮挡右侧设置 / 关闭 / active 控件。

### 10.2 Toolbar

- Pass：宽窗口下筛选展开显示多个标签，搜索框可读，右侧关键操作可点击。
- Pass：常规窗口下三者不重叠。
- Pass：窄窗口下筛选组内部滚动、截断、折叠或更多入口，右侧固定操作仍可达。
- Pass：最小可用窗口下 `全部`、收藏、搜索输入、设置、关闭、active 控件仍有可达路径。
- Fail：筛选展开层覆盖设置或关闭按钮。
- Fail：长查询撑破 toolbar。

### 10.3 状态与点击反馈

- Pass：hover 非选中条目时，已选中条目仍保持 selected。
- Pass：点击搜索结果条目后 selected / focused 先出现，再触发 paste / detail。
- Pass：single-click paste 和 double-click paste 模式都有状态顺序证据。
- Pass：快速点击 A 后点击 B，最终 selected 为 B，旧 completion 不回写 A。
- Fail：点击后等待 OCR / 搜索 / detail 完成才出现 selected。

### 10.4 单击 / 双击控件

- Pass：面板顶部 active 切换不是 `Menu` / 下拉，当前值常显。
- Pass：键盘可切换，VoiceOver 可读当前值和互斥关系。
- Pass：设置页如提供同一设置，与面板顶部 key 一致。
- Fail：面板顶部仍保留下拉作为 active 切换入口。
- Fail：面板顶部和设置页显示不同状态。

### 10.5 密度与长内容

- Pass：side list row 调整后核心内容区域比基线更大，点击目标不退化。
- Pass：bottom tray card 调整后主体内容更清晰，card 尺寸稳定。
- Pass：OCR failed / retry 状态不压住操作按钮。
- Pass：长标签、长来源 App、长 URL、file URL 摘要和多语言长句不重叠。
- Fail：hover / selected / OCR 状态出现时 row / card 高度跳动。

## 11. 技术方案待确认项

以下事项由技术方案确认，不由 PRD 写死；它们不影响开发前验收边界：

1. Hover 延迟毫秒数、hit-test 区域、距离阈值和动画曲线。
   - 不影响原因：PRD 已定义安全桥、短延迟、明显离开、立即关闭条件和 pass/fail。
2. 窗口矩阵的具体 px 断点、search min width、filter max width 和固定操作区尺寸。
   - 不影响原因：PRD 已定义四类窗口、空间优先级和可达性要求。
3. 显性控件采用 segmented control、radio group、按钮组或等价控件。
   - 不影响原因：PRD 已定义常显、互斥、键盘、VoiceOver 和不得使用下拉。
4. side list row 与 bottom tray card 的具体 padding、lineLimit、最小高度、缩略图尺寸和状态槽位尺寸。
   - 不影响原因：PRD 已定义前后对照、点击目标不退化、状态不跳动。
5. P13C 的具体脚本名称和实现方式。
   - 不影响原因：PRD 已定义最低断言，技术方案可选择静态、fixture、截图 / 录屏和事件日志组合。

## 12. 进入技术方案前的复核重点

项目负责人复核 PRD v1 时，建议只检查以下 gate：

- 是否已按当前事实写明 Step 1 / Step 2 已接受。
- 是否不再保留 Step 1 / Step 2 未闭合实现分支。
- 是否完整吸收 hover 首版规则。
- 是否补清右侧关键操作清单、空间优先级和四类窗口矩阵。
- 是否补清 selected / focused / hover / active filter 层级和状态先写契约。
- 是否明确替换面板顶部 active `Menu`，并约束设置页同 key。
- 是否拆分 side list row 与 bottom tray card 密度验收。
- 是否有 fixture、截图 / 录屏、键盘、VoiceOver 矩阵。
- 是否定义 P13C 或等价 Step 3 专属门禁最低断言。
