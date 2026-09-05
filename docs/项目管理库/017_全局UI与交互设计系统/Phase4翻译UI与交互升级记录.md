# Phase 4 翻译 UI 与交互升级记录

## 范围

本阶段只收口翻译面板、结果卡和翻译收藏的视觉层级、稳定几何、直接操作、动效边界、主题与历史私有样式。语言检测、翻译服务协议、Helper、OCR、收藏和持久化业务语义保持不变。

## 已实施

- 原文与语言栏继续固定在结果区上方；滚动协调器忽略不足 1pt 的布局抖动，避免几何回写造成无意义重绘。
- 空输入、无可用服务和运行中状态统一使用全局状态组件；设置恢复动作仍保留，不再维护翻译私有空态布局。
- 语言交换、收藏搜索、收藏详情和结果卡操作迁移到共享紧凑操作组件；删除翻译私有图标命中尺寸和原始按钮样式。
- 结果列表使用全局间距 Token；等待、运行、成功和失败状态保留稳定的最小正文空间，异步状态变化不会抖动 Header。
- 结果卡拖动时只改变透明度和语义表面状态，不再缩放卡片；拖放继续是直接操作，不使用补间动画。
- 合并重复的结果状态监听，终态播报与复制反馈复位只沿一条状态变更链执行。
- 翻译收藏的加载、空、错误与详情状态统一使用共享状态组件；收藏复制和导出成功改为居中的紧凑确认，不再展示完整通知卡。

## 安装版真实验收

使用最新 Debug 安装版完成：

- 手动翻译空态首帧中输入框获得真实第一响应者；标题、原文、语言栏和结果区域之间没有动态占位造成的变形。
- 输入低敏文本 `hello` 后，腾讯、MyMemory、Google 与 Apple 四张结果卡按固定顺序显示成功结果；每张卡的状态、标题、操作区和译文基线稳定。
- 通过无障碍“下移服务／上移服务”动作完成即时重排并恢复用户原顺序；当前会话不重跑翻译。
- 显式浅色、显式深色均检查空态和控件对比度；验收结束后恢复“跟随系统”。
- 运行日志没有出现新的 SwiftUI 发布期变更、负尺寸几何或主线程无响应诊断。

Computer Use 的瞬时坐标拖动没有建立可观察的系统 Drag Session，因此“物理鼠标拖动预览、插入线和投放”继续列为人工复核项；本记录不把无障碍排序证据替代为真实鼠标通过。

## 自动化与构建

- 翻译定向测试：232 项执行、1 项外部 Helper 环境跳过、0 失败。
- 新增滚动抗抖断言；共享命中尺寸、结果顺序事务、拖放载荷、固定 Header 和主题无关几何继续受现有测试覆盖。
- `script/test_ui_design_system.sh`：通过。
- Debug 安装版完成签名和权限核验，CDHash 为 `2fa557f25b976e55a8e2a7f3ed35b3fd6f4845a3`。
- 本机 CoreSimulator 比当前 Xcode 低一个修订，只影响模拟器发现，不影响 macOS 构建和测试。

## 待闭合

- 使用真实物理鼠标完成结果卡首、中、尾投放，验证拖动预览、2pt 插入线、边缘滚动、设置同步及重启保持。
- 使用独立低敏截图完成 Option+S、OCR 无文字／错误／重截的完整视觉状态；使用外部 App 完成 Option+D 的选区、Helper 故障和焦点矩阵。
- 在 Phase 7 补齐日文、提高对比度、降低透明度、减少动态效果、多屏负坐标和四源连续 20 轮性能采样。

## 2026-08-02 二次收口

- 空态安装版实测确认：标题栏、原文、语言栏和结果区的几何关系稳定；面板高度来自用户之前手动调整后的恢复值，不是空态子视图撑大，因此没有擅自覆盖用户尺寸。
- 结果卡折叠和连接详情展开统一使用 `BlocksMotionRole.reveal`；开启“减少动态效果”时自动降级为短淡变。结果卡拖动与排序仍保持零补间。
- 全局外观套件 40 项全部通过，包括系统字体、共享交互表面、主题几何不变和 Reduce Motion 契约。
- 翻译定向回归首轮执行 219 项，1 项 Helper 环境跳过；其中 OCR 空结果测试出现一次“状态已终结但会话清理尚未完成”的时序失败，单项立即重跑通过。当前记为测试时序待继续观察，不写成翻译功能全部通过。

## 2026-08-02 第三次收口

### 本轮发现并修复的真实问题

- 安装版真实滚轮测试发现，结果区滚动会直接移动结果列表，原文框没有先从默认高度收缩到最小高度。根因是 SwiftUI 背景中的桥接视图不是结果 `NSScrollView` 的后代，旧实现通过 `enclosingScrollView` 永远取不到真实滚动容器。现改为根据事件位置命中窗口中的真实 `NSScrollView`，并在本地事件范围内消费收缩量。
- 重新验证后确认滚动顺序为：原文框 `72pt → 48pt`，原文和语言栏保持可见；继续滚动才移动结果列表；结果返回顶部后反向滚动恢复原文默认高度。原文编辑器自身滚动不触发外层收缩。
- 面板关闭监控、Carbon Escape、外部点击和系统交互保护从 Presenter 中拆为唯一 `TranslationPanelDismissalController`，删除 Presenter 与 View 中重复的监听、透明命中层和关闭补丁。
- 结果排序删除手写 `mouseDown/mouseDragged/NSDraggingSession` 状态机及透明 AppKit 覆盖层，统一为系统 Drag Session 的结构化载荷与单一 Drop Delegate；载荷携带真实服务 ID，投放后仍只调用一次现有原子排序接口。取消会话由统一生命周期清理，不再遗留高亮状态。
- 收藏页删除内外两层等价表面，列表与详情改为内容页层级；空态、搜索和详情切换不再改变外层几何。
- 主菜单补齐“翻译／截图翻译”，使界面入口和快捷键能力一致；Helper 状态及插件能力名称改为普通用户可理解的本地化文本。

### 安装版证据

- 浅色空态：[01-panel-empty-light.jpeg](evidence/phase4-translation/01-panel-empty-light.jpeg)
- 深色收藏空态：[02-favorites-empty-dark.jpeg](evidence/phase4-translation/02-favorites-empty-dark.jpeg)
- 翻译面板设置按钮准确路由到翻译设置：[03-settings-routing-dark.jpeg](evidence/phase4-translation/03-settings-routing-dark.jpeg)
- 四源结果卡稳定布局：[04-results-four-sources-dark.jpeg](evidence/phase4-translation/04-results-four-sources-dark.jpeg)
- 安装版实测确认：面板设置按钮在主窗口已存在时准确选中“翻译”；浅色主题切换不改变输入焦点和面板结构；验收结束后恢复用户原“跟随系统”设置。
- 最近 15 分钟真实运行日志未出现新的 `Publishing changes from within view updates`、负尺寸几何或主线程无响应诊断。

### 自动化与构建

- 翻译定向：194 项执行、1 项外部 Helper 环境跳过、0 失败。
- 完整 `BlocksAppTests`：950 项执行、4 项环境相关跳过、0 失败。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- UI 设计系统门禁：通过，遗留别名为零。
- Debug 与 Release 构建：通过；本机 CoreSimulator 修订差异仍只影响模拟器发现，不影响 macOS 目标。
- Xcode Analyze：通过。
- 最终安装版进程为 `36973`，路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，Identifier 为 `app.blocks.app`，TeamIdentifier 为 `LOCAL_TEAM_ID_REDACTED`，CDHash 为 `5de1e4b90398d4dad861f62e8c3f778eb58c54d7`。
- 最终安装版再次验证：手动入口的原文编辑器为真实第一响应者；输入 `Hello` 后 MyMemory、腾讯网页源、Google 网页源和 Apple 本地翻译均返回 `你好`；面板设置按钮准确打开并选中“翻译设置”。

### 仍需人工证据

- 当前自动化环境能验证结构化载荷、一次提交、键盘/VoiceOver 排序和持久化，但 Computer Use 的瞬时拖动没有形成可观察的持续系统 Drag Session。因此首／中／尾真实物理鼠标投放仍保持为人工复核项，不把代码路径或无障碍排序冒充物理鼠标通过。
- 翻译设置仍包含插件生命周期管理的历史区块。其业务归属应在 Phase 5 插件模块中迁移到统一插件中心；本阶段不复制或重写插件业务 Store，避免形成第三套生命周期。

## 2026-08-02 滚动相位与状态反馈返修

- 定向回归基线为 193 项通过、1 项外部 Helper 环境跳过；没有发现新的翻译业务失败。本轮继续只处理可证明的 UI／交互问题。
- 发现原文收缩协调器以布尔值吞掉整次滚轮事件：当一次鼠标滚轮增量超过剩余收缩距离时，多余距离不会传给结果区，用户需要再次滚动，形成明显的停顿感。
- 协调器改为返回“原文实际消费距离／结果剩余距离”。原文达到最小高度的同一滚轮事件会把正向剩余量直接交给结果 `NSScrollView`；结果未回到顶部时反向滚动仍不会提前展开原文，输入框内部滚动仍不进入该链路。
- 结果卡状态图标在固定命中框内使用全局 selection 动效完成短过渡；不改变 Header 宽度，不动画流式文本、卡片排序或直接滚动，并自动遵循“减少动态效果”。
- 当前改动完成代码与自动化验证后仍需在最终安装版用鼠标滚轮／触控板复核连续手感；未取得该证据前不更新既有安装版签名记录。

## 2026-08-02 结果排序真实交互返修

- 前一轮“统一为 SwiftUI Drop Delegate”的结论经安装版复核证明不成立：拖动源能够启动，但非激活 SwiftUI Panel 中的投放目标没有接收到完整 AppKit Drag Destination 生命周期。排序 Store、持久化和插入位置算法并非根因。
- 结果卡标题改为唯一 AppKit `NSDraggingSession` 拖动源；同一协调器登记当前可见标题的真实屏幕坐标，并在系统拖动会话移动、结束时解析目标和首／尾半区。松手后只提交一次既有原子排序接口，不重启翻译任务。
- 删除本轮排查中未生效的卡片级 Destination、列表级 Destination、SwiftUI Frame Preference 和重复拖动表面，共清理约 700 行试验代码；运行时只保留一条拖动链路。
- Computer Use 真实启动系统拖动会话，将 MyMemory 从第 1 位移动到第 4 位；结果面板立即变更，翻译设置同步显示 `腾讯 → Google → Apple → MyMemory`，重启 App 后顺序保持。
- 当前 Computer Use 驱动在原生 Drag Session 中不会自动产生最终 mouse-up，验收时用下一次明确点击完成会话；这是测试驱动限制。真实物理鼠标的单次按下、拖动、松手手感仍需最终人工复核，不能据此提前宣称完全闭合。
- 新增真实 `NSWindow/NSView` 坐标测试，覆盖目标上／下半区、伪造载荷、区域外取消及一次提交；定向 4 项全部通过。UI 设计系统门禁与 `git diff --check` 同步通过。
- 最终复验安装版路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID 为 `86619`，Identifier 为 `app.blocks.app`，TeamIdentifier 为 `LOCAL_TEAM_ID_REDACTED`，CDHash 为 `8c1e26a83c3dbecfbbcb9cc0eb0a46c7f399fd36`。

## 2026-08-02 焦点反馈与标题拖动单轨收口

- 安装版空态复审确认标题栏、原文、语言栏和结果区没有新增几何漂移；用户此前保存的面板高度继续保留，不把大尺寸恢复误判为子视图撑高。
- 原文编辑器此前使用“内容分区”表面，取得真实第一响应者后仍没有明确的语义焦点反馈。现由 AppKit 文本编辑桥接上报开始／结束编辑，SwiftUI 只据此切换全局 `interactive + focused` 表面；文字、选择和焦点所有权仍保持单一数据源。
- 翻译私有 `TranslationPanelWindowDragArea` 与全局 Panel 直接操作契约重复。已提取为共享 `BlocksPanelWindowDragArea`，窗口背景继续禁止拖动，只有标题空白区可移动；结果卡标题排序、输入和按钮不会与窗口移动竞争。
- 新增真实 AppKit 焦点回调和共享拖动区命中测试；3 项定向回归通过。最终安装版焦点描边和标题拖动仍在本阶段安装新产物后补证，不沿用旧 CDHash 冒充通过。

### 最新安装版复验

- 最新产物安装于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，Identifier 为 `app.blocks.app`，TeamIdentifier 为 `LOCAL_TEAM_ID_REDACTED`，CDHash 为 `56d652d1fe6e9f18b338d17576820d3d468e64a7`。
- 手动入口首次显示后，无障碍树中的真实第一响应者为 `AXTextArea`；输入框使用共享交互表面显示焦点反馈，未改变原文区高度。
- 真实系统鼠标事件从标题空白区拖动后，面板位置由 `(621, 200)` 移到 `(701, 240)`；随后在原文输入区拖动，面板位置保持 `(701, 240)`，第一响应者仍为 `AXTextArea`。标题移动和内容直接操作已分离。
- 最新进程日志未出现 `Publishing changes from within view updates`、`Invalid view geometry` 或主线程无响应诊断。
- 翻译定向回归共执行 231 项，1 项外部 Helper 环境跳过、0 失败；UI 设计系统门禁与 `git diff --check` 通过。

## 2026-08-02 终验发现的结果态压缩问题

- 最新安装版真实输入低敏文本 `hello` 后，四个结果卡能正常完成，但语言选择栏被压成一条只剩表面的空白细条。AX 树中的源语言和目标语言控件仍然存在，因此排除了数据或条件渲染缺失。
- 根因是固定控件区与结果 `ScrollView` 共同参与 SwiftUI 垂直压缩协商；多结果的固有高度会迫使前者压缩，而原有纯数学测试没有覆盖真实容器的布局优先级。
- 原文与语言控件区现使用由全局尺寸指标计算的显式高度；原文仍可按既定 `72pt → 48pt` 收缩，结果视口是唯一剩余弹性区。没有恢复第二套滚动或裁剪实现。
- 安装新产物后重新输入 `hello`，腾讯、Google、Apple 和 MyMemory 四卡完成时，源语言与目标语言仍完整显示；向上滚动后原文框收缩，语言栏保持高度和命中。
- 新增固定区域展开／收缩高度回归，定向测试 1 项通过。最新安装版为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `17466`，CDHash `04eb673c7df4dbb10f0a0701ae821b67edd7589a`。
- 本轮 Computer Use 每次读取屏幕状态时仍会在同一时刻产生 AppKit `Invalid view geometry` 诊断；无独立用户交互时间点的对应证据，与既有自动化控制通道归因一致，不写成业务视图已引发负尺寸。

## 2026-08-03 真实约束容器复核

- 重新以本轮最新构建产物启动隔离翻译面板后，确认四源结果完成时语言栏压缩问题来自 SwiftUI 的真实垂直空间协商，而不是翻译任务、语言状态或条件渲染。固定控件区虽已声明相同的最小／最大高度，但没有布局优先级，结果 `ScrollView` 的高固有尺寸仍能迫使它参与压缩。
- 固定控件区现声明高于结果视口的布局优先级；原文区继续按既定 `72pt → 48pt` 收缩，语言栏保持 `44pt`，结果视口承担剩余空间。没有增加遮罩、透明命中层或第二套滚动容器。
- 新增真实 `NSHostingView` 约束测试：在仅 `260pt` 高的容器内注入四个高结果占位，直接测量语言栏渲染边界为 `44pt`。这补上了此前只测公式、没有测 SwiftUI 实际压缩结果的覆盖缺口。
- 使用 Computer Use 在最新构建产物中输入低敏文本 `hello`，四个结果卡完成后语言栏仍完整；继续滚动时原文先收缩，语言栏不移动，随后仅结果区滚动。复制按钮会在原位切换为完成反馈，折叠卡片不会改变相邻卡片操作区基线。
- 当前代码审查没有发现未引用的翻译 UI 类型；面板关闭、标题拖动、结果排序和滚动相位各自只有一条运行链路。本轮没有为追求删代码而移除仍承担兼容或运行职责的翻译适配器。

### 本轮证据

- 空态与真实焦点：[05-current-empty.png](evidence/phase4-translation/05-current-empty.png)
- 四源完成后固定语言栏：[07-four-source-languagebar-fixed.png](evidence/phase4-translation/07-four-source-languagebar-fixed.png)
- 原文收缩后独立滚动结果区：[08-source-collapsed-results-scroll.png](evidence/phase4-translation/08-source-collapsed-results-scroll.png)

### 本轮自动化

- 翻译 UI、通知、焦点、拖放协调器定向回归：10 项执行、0 失败。
- `TranslationStoreTests`、`TranslationCoreTests` 与 `LocalVisionOCRServiceTests`：155 项执行、0 失败。
- 包含真实 Selection Helper 环境用例的整类测试在 Xcode 测试宿主退出阶段发生环境等待，本轮主动终止；该结果不记作通过或产品失败，后续在 Phase 7 以独立 Helper 门禁复核。

## 2026-08-03 四源结果的子视图压缩与无障碍语义返修

- 前一轮只给固定区外层增加布局优先级，结论不完整。安装版再次输入低敏文本 `hello` 后，四个结果卡完成时语言栏仍会被压成细条。新证据表明：外层高度已稳定，但其内部的 AppKit 文本编辑器仍可参与 SwiftUI 子视图压缩，继而抢占同层语言栏的可见高度。
- 原文分区和语言栏现在分别持有由同一 `TranslationPanelSourceLayout` 计算的精确高度；语言栏固定为 `44pt` 并拥有高于结果区的布局优先级。这里没有增加遮罩、透明命中层或第二套滚动逻辑。
- 渲染回归不再用 `Color.clear` 伪造原文区，而是真实嵌入 `TranslationSourceTextEditor`，直接覆盖 AppKit `NSScrollView` 与 SwiftUI 定高容器的约束交互。
- 结果卡根结点的旧无障碍标识和上／下移动作会被 SwiftUI 传播到复制、朗读、连接详情和收起按钮，导致一张卡片的所有子控件对 VoiceOver 声称自己是拖动源。标识和排序动作现在只属于服务标题拖动区，右侧操作恢复独立语义。
- 免配置社区翻译源的连接测试不再以易被误解为“网络类型”的地球图标常驻；转入稳定尾列的省略菜单，运行中继续占用同一 `28pt` 槽位，不推动开关。

### 安装版证据

- 四源完成后语言栏保持完整：[01-four-source-language-bar.jpeg](evidence/phase4-translation/2026-08-03-layout/01-four-source-language-bar.jpeg)
- 翻译源设置的拖动、更多操作和开关尾端稳定：[02-source-settings-actions.jpeg](evidence/phase4-translation/2026-08-03-layout/02-source-settings-actions.jpeg)
- AX 真实树中，四个服务标题各自拥有唯一 `translation.panel.result.<serviceID>` 和排序动作；复制、朗读、信息、收起按钮不再继承该标识或排序动作。
- 本轮安装版路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `71074`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `423e2cddf92607872f3e8e1ae93e1ccf92f40ab6`。

## 2026-08-03 原生投放生命周期与终态反馈纠正

- 前述“拖动源根据屏幕坐标解析目标并在源会话结束时提交”的实现仍不完整：它绕过了 AppKit Drag Destination 的命中和投放契约，也会在非激活面板的系统拖动期间触发隐式关闭。该路径现已删除，不再保留屏幕坐标端点表、源侧提交或 30 秒兜底超时。
- 结果卡标题现在同时是标准 `NSDraggingSource` 与 `NSDraggingDestination`：拖动载荷只携带稳定服务 ID，目标卡在自己的本地坐标中判断前／后插入位，`performDragOperation` 只提交一次既有原子排序操作；伪造载荷、区域外投放、自身投放和取消均不修改顺序。
- 拖动协调器由窗口 Presenter 唯一持有。原生拖动进行时暂停外部点击和失活引发的隐式关闭，拖动结束后恢复原关闭策略；SwiftUI 视图不再另建一份拖动状态。
- 四源结果中的语言栏问题还包含第二层原因：两个系统 Picker 自身可以参与垂直压缩。现在实际 Picker 使用小型原生控件并固定垂直固有尺寸，真实四源完成态下源语言和目标语言继续可见，而不是只保证外层 44pt 容器存在。
- 结果卡终态删除重复文字：成功仅保留完成图标，失败仅保留可操作的刷新按钮；“已完成／失败”不再与图标重复。等待、运行和流式状态仍保留必要文字说明。

### 自动化与真实证据边界

- 翻译 Core、Store 与入口桥接定向回归：220 项执行、1 项独立 Selection Helper 环境跳过、0 失败。
- 真实 AppKit 投放测试覆盖结构化载荷、目标本地命中、首尾半区、区域外、伪造载荷和一次提交；UI 设计系统门禁与 `git diff --check` 通过。
- Computer Use 能启动真实原生 Drag Session，运行日志确认拖动源进入会话；当前驱动不会产生 Drag Session 所需的最终 mouse-up，因此本轮没有把物理鼠标首／中／尾投放写成已通过。该项继续保留为人工复核，而不是用程序化协调器测试替代真实鼠标证据。

### 最新安装版复验

- 最新产物位于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `70568`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `a1f216c59180571681e4f764090f22e842d11664`。
- 通过手动入口打开面板后，`translation.panel.sourceEditor` 内的真实 `AXTextArea` 是第一响应者；输入低敏文本 `hello` 后，腾讯、Google、Apple 与 MyMemory 四个结果卡均返回 `你好`，语言栏两个 Picker 全程可见且可访问。
- 使用 Computer Use 启动结果标题的原生拖动会话后，翻译面板保持可见；随后用明确点击结束测试驱动未释放的会话，输入焦点和四张结果卡保持稳定。此证据只证明拖动期间的窗口生命周期修复，不替代真实物理鼠标投放验收。
- 最近十分钟安装版日志未出现 `Publishing changes from within view updates`、`Invalid view geometry`、Main Thread Checker 或主线程卡顿诊断。
- 完整 `BlocksAppTests` 执行 987 项、4 项环境型跳过、0 失败；`BlocksScreenshotCoreTests` 执行 221 项、0 失败。Debug 安装构建、Release 构建、Xcode Analyze、UI 设计系统门禁与 `git diff --check` 均通过。
