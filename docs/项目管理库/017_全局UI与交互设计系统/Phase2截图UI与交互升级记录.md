# Phase 2 截图 UI 与交互升级记录

## 范围

本阶段只处理截图的视觉单轨、交互反馈、动效、直接操作流畅度和历史 UI 实现清理。截图捕获、文档、渲染和输出语义保持不变；真实验收发现的现有缺陷可以在不改变产品口径的前提下修复。

## 已实施

- 捕获参数条、编辑器状态条、主工具条、属性条、更多工具、OCR 面板、钉图工具条和长截图 HUD 统一使用 `BlocksSurfaceRole` 与共享紧凑控件。
- 删除截图私有的工具分组、更多工具焦点按钮和多套选中样式；SwiftUI 与 AppKit 仍保留各自必要的输入桥接，但视觉状态统一由共享 Design Foundation 解析。
- 捕获遮罩立即出现；参数条使用短淡入；捕获到编辑器使用短交接淡入。裁剪、拖动、缩放、绘制和命中保持零补间。
- 状态条的选中背景、描边和裁剪形状统一，删除高亮溢出路径；更多工具打开时不再把键盘焦点误当作工具选择。
- Canvas 引入不可变快照字段比较；普通状态更新不再无条件整画布 `needsDisplay`。悬浮变化只失效旧、新命中脏区，过期渲染继续由 revision 拒绝。
- 捕获悬浮更新按受影响显示器失效，不再让稳定指针移动重绘全部屏幕；钉图悬浮工具条只在目标可见性变化时更新，持续 `mouseMoved` 不再重复启动动画任务。
- 属性区按工具／选择状态做短淡入，不移动主工具条和截图区域；OCR 结果和错误使用固定尺寸面板，不挤压截图 Chrome。
- 修复文字工具首次点击后立即输入丢失：文字创建不再先抢占画布焦点；若 AppKit 在同一鼠标事件末尾仍把首个按键交给画布，画布会把完整事件转交给真实 `NSTextView`。同时把活动文本编辑器加入画布自定义的无障碍子节点，避免画布的合成对象树遮蔽真实输入控件。

## 安装版真实验收

使用当前安装版和低敏空白区域完成：

- 更多工具打开时无默认选中；选择“更多”工具后按钮正确高亮，切换到快捷工具后高亮立即清除。
- 状态条对象部件可以选择并用删除键删除；固定的尺寸和圆角部件不进入删除路径。
- 普通区域裁剪框整体移动只改变裁剪位置，标注保持原始文档坐标；一次撤销恢复原裁剪位置。
- 尺寸面板、圆角开关、工具选择、属性条、OCR 失败面板和关闭／放弃流程均保持稳定几何。
- 真实水印路径发现预览按整个可见源图平铺，而不是限制在当前裁剪框。根因是编辑器预览把 `previewVisibleRect` 同时当作渲染输出范围和水印裁剪范围；现已拆分为独立 `watermarkClipRect`，并增加像素回归测试。
- 文字工具首次点击后，安装版 AX 树立即出现真实的“文本输入区”并成为焦点；新增首个按键转交和延迟焦点恢复两条 AppKit 回归测试。Computer Use 对自定义文本编辑器的键盘注入并非等同真实硬件事件，因此这里只把 AX 第一响应者和真实 AppKit 事件测试记为已取得证据，不把自动注入结果冒充硬件键盘验收。

为避免保存用户工作区内容，本轮没有把包含桌面的审查截图写入仓库；验收以当前会话的真实 AX 状态、运行日志和像素测试为证据。未取得的真实平台路径继续列为待验证，不以自动化代替。

## 自动化与构建

- `script/test_ui_design_system.sh`：通过，截图旧样式入口和历史别名为零。
- 完整 `BlocksAppTests`：923 项执行、4 项跳过、0 失败。
- 完整 `BlocksScreenshotCoreTests`：221 项执行、0 失败；新增编辑器预览水印裁剪像素测试。
- Debug 和 Release 构建通过；最终 Debug 安装版位于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID 7571，CDHash `a6941b41a4f6df4ab88031b642afe42c4d363828`。
- 补丁后的安装版已复核水印裁剪、更多工具状态、区域移动和文字输入控件的 AX 焦点。
- 本机 CoreSimulator 版本比当前 Xcode 低一个修订，仅影响模拟器发现；macOS 构建和测试继续执行。

## 待闭合

- 步骤和标注气泡的双向缩放、颜色保持和最近端点已有自动化覆盖，仍需要在全 App 终验阶段补真实鼠标矩阵。
- 长截图、钉图和完成／保存终态需要使用隔离的合成内容完成安装版证据，避免污染用户剪贴板与截图历史。
- 菜单栏状态项在首次被辅助审查读取时出现 AppKit 负尺寸诊断；截图捕获和编辑交互期间未复现。该问题归入 Phase 6 的菜单栏／全局窗口生命周期排查，不在没有根因证据时修改截图代码。

## 2026-08-02 二次收口

- 应用 Chrome 字体从强制 PingFang 收敛为 macOS 系统字体；截图文档与最终输出中的用户字体保持原有语义，不受影响。
- Canvas 将“工具选择、交互启停、文字样式”等非绘制状态从整画布失效键中剥离；文字拖动预览只失效新旧预览区域的并集，不再每帧重绘整张源图。
- 保存、完成、钉住、重截等输出命令增加单一在途状态；渲染等待期间禁止竞争命令，按钮和进度状态不再提前恢复。
- 钉图悬浮工具条迁移到共享 AppKit 紧凑按钮，补齐悬浮、按压、选中和主题语义。
- `BlocksScreenshotCoreTests` 221 项通过；截图编辑与长截图 App 测试 357 项执行、355 项通过、2 项默认资源用例跳过。两个约 58.5MP 用例随后以显式启用方式单独执行，2 项均通过，证据位于 `/tmp/blocks-ui-module-closeout/scrolling-58mp-active-1785632645.xcresult`。
- 最新安装版路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，最终重新安装后的 CDHash 为 `68f86d7d3743698b91cd77b54e2f1afb5ddbfbcb`。真实截图编辑器仍受系统 Developer Tools 授权对话框阻断，因此未把该路径写成已通过。

## 2026-08-02 UI／流畅度专项复审

- 将剪贴板、翻译、权限辅助、通知 HUD 和截图即时提示中重复的 `NSPanel` 窗口级配置收敛为语义角色；各功能继续独立持有焦点、关闭、定位和业务状态，避免共享组件越权接管交互。
- 截图画布失效从“快照任意可绘制字段变化即整画布重绘”细分为：源图、裁剪、视口和输出外观变化整画布重绘；对象、选区、草稿和 OCR 区域变化只重绘新旧源坐标边界的并集。手柄、虚线框和连接控制点使用固定视图点扩张，混合 DPI 下视觉命中范围保持稳定。
- 删除 `ScreenshotEditorStore` 中与 `@Published` 属性重复的手工 `objectWillChange`，保留偏好 Store 和 OCR 协调器两个真实跨对象转发入口。没有引入第二套渲染、动效或状态路径。
- 直接操作继续保持零补间；本轮没有为拖动、缩放、裁剪或文字编辑增加动画，优化来自减少重复发布和缩小绘制脏区。

### 回归证据

- 浮层窗口契约、画布局部失效、首次对象／文字拖动、区域裁剪移动、气泡文字框双向缩放与颜色、步骤说明拖动事务：7 项通过。
- `ScreenshotAppStateTests` 与 `ScrollingScreenshotAppTests`：358 项执行、2 项按既有资源策略跳过、0 失败。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- 完整 `BlocksAppTests`：931 项执行、4 项按既有环境／资源策略跳过、0 失败。
- `script/test_ui_design_system.sh`：通过，未恢复历史设计别名或模块私有结构样式。
- Release 构建与 Xcode Analyze 均通过；`git diff --check` 通过。
- 最新 Debug 安装版 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app` 已完成真实鼠标冒烟：状态条位于选区上方，工具／属性栏位于选区下方；矩形创建、选择手柄、属性状态和撤销即时更新，未观察到整画布闪烁或几何跳动。安装包 CDHash 为 `32af25dff889ad4f6df161f3279de573cdb4ce33`。
- 捕获期间出现的 Developer Tools Access 对话框来自 macOS 系统授权，不属于截图 Chrome；本轮没有将该外部状态误归因并修改业务逻辑。
- Xcode 仍报告本机 CoreSimulator 补丁版本不匹配；该提示不阻断 macOS 构建与测试，未将其误记为 Blocks UI 回归。

## 2026-08-02 安装版布局返修

### 真实问题与根因

- 全屏截图编辑器把状态条和底部工具栏覆盖在截图内容之上。布局模型虽然已经声明顶部／底部安全间距，但投影函数始终返回全画布，安全间距从未参与实际画布 frame 计算。
- 文字等高密度属性条在窄宽度下被 SwiftUI 压缩，而不是形成真实横向溢出，因此右侧控件被截断且溢出导航按钮不会出现。
- 长截图 HUD 按阶段增减按钮，导致暂停、继续、完成等状态切换时按钮位置跳动。
- 编辑器单独悬浮的“正在渲染”胶囊覆盖截图内容，并与输出按钮进度和全局错误通知形成重复反馈。

### 修复口径

- 只有当前裁剪投影无法同时容纳顶部状态条和底部工具栏时，才把展示画布收敛到安全区域；普通区域截图继续使用原画布投影。该调整只改变编辑展示比例，不改变裁剪文档、导出尺寸或输出像素。
- 状态条和属性条内容使用固有宽度参与横向滚动，窄宽度下由既有渐隐和左右导航承接，不压缩或截断稳定控件。
- 长截图 HUD 固定为四个语义槽位：主操作、次操作、完成和取消。无对应命令的槽位保留几何但不命中、不进入无障碍树。
- 删除编辑器重复渲染胶囊；在途输出继续由对应命令按钮反馈，错误继续走全局 HUD。裁剪、拖动、缩放和绘制仍为零补间。

### 自动化证据

- `ScreenshotAppStateTests`：338 项执行、0 失败；新增全屏安全布局和长截图 HUD 稳定槽位回归。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- 完整 `BlocksAppTests`：950 项执行、4 项按既有环境／资源策略跳过、0 失败。
- 最新安装版完成真实全屏捕获：截图内容缩放后完整位于状态条和底栏之间，左右中性留边对称，导出文档坐标未改变。
- 真实选择文字工具后，属性条显示尾部溢出按钮；点击后可进入行距和透明度尾部控制，再返回首部。修复过程中发现 SwiftUI 横向 `ScrollView` 内的坐标偏好返回零 frame，最终改为 AppKit 测量内容固有宽度并由按钮状态维护首／尾边缘，删除失效的偏好测量双轨。
- 最终安装版位于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID 18092，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `341946b07e29d432cec271956ba9be5fc3b817bd`。真实证据保存在 `/tmp/blocks-screenshot-fullscreen-editor-final.png`、`/tmp/blocks-screenshot-text-properties-final-2.png` 和 `/tmp/blocks-screenshot-text-properties-trailing-crop.png`；未写入包含桌面画面的仓库文件。

## 2026-08-02 Chrome 状态边界与更多工具生命周期收口

### 真实问题与根因

- “更多工具”只在面板内部选择工具时主动关闭；从快捷工具、撤销／重做或输出命令切换时没有共同的关闭路径，Popover 状态可能残留到下一次工具状态。
- 编辑器宿主、统一编辑器、主工具条和属性条同时观察同一个 `ScreenshotEditorStore`。画布拖动必须让统一编辑器更新，但工具条和属性条不需要再分别订阅同一轮发布；重复观察会增加 Chrome 的无效刷新机会。

### 修复口径

- 新增单一 `ScreenshotMoreToolsPresentationState`，统一处理触发、所有工具条动作、工具分区变化和视图退出；快捷工具、更多工具、撤销／重做、关闭和输出命令全部先关闭 Popover，再进入既有文字提交／画布动作链。
- 更多工具按钮继续只在当前选中项真实属于“更多”区时显示选中态；Popover 的打开状态不冒充工具选中态。
- 主工具条只消费不可变的 `ScreenshotEditorToolbarState` 和宿主提供的插件槽内容，不再直接观察或读取完整 Store。
- 编辑器宿主和属性条删除重复的 `@ObservedObject` 订阅；统一编辑器继续作为截图视图树唯一 Store 观察入口。裁剪、拖动、缩放、绘制和命中仍保持零补间，业务动作与文档状态不变。

### 自动化证据

- `ScreenshotAppStateTests`：342 项执行、0 失败；新增更多工具触发切换、工具动作关闭、分区清空关闭和视图退出关闭契约。
- `git diff --check`：通过。
- 安装版真实截图编辑器与完整 App 回归将在全模块合并后的统一安装版验收中执行；本条不提前写成已取得安装版证据。

## 2026-08-02 OCR 面板与截图终态复核

### 真实问题与修复

- 手动 OCR 成功面板为 `360×260pt`，失败面板为 `360×150pt`。识别失败、重试和成功之间切换时，悬浮面板会改变高度并重新贴边，形成明显跳动。
- 成功状态在剪贴板写入暂不可用时会直接移除复制按钮，底部操作区随状态收缩，进一步破坏稳定几何。
- 现已由 `ScreenshotManualOCRPanelLayout` 为成功和失败状态返回同一 `360×260pt` 几何；不可用的复制操作保留布局槽位，但不命中且不进入无障碍树。识别、失败、重试和复制能力变化只更新内容与状态，不移动截图 Chrome。

### 安装版体验复核

- 使用最新安装版完成普通区域截图，真实鼠标打开“更多工具”；面板没有默认高亮第一项，选择快捷工具后“更多”按钮不会残留选中态。
- 选择 OCR 并真实框选区域后，结果面板出现，截图状态条、画布和底栏没有位移。
- 选择水印后，属性条能够稳定展示预设、文字、颜色、字号、密度、角度、透明度、删除和保存预设；水印属于文档状态，不遮挡普通对象命中。
- 点击“钉住”后，钉图按原截图区域的逻辑尺寸和相对位置出现；悬浮底部工具栏能够显示并关闭。该操作不作为完成／保存写入用户数据的替代证据。

### 自动化证据

- `ScreenshotAppStateTests` 与 `ScrollingScreenshotAppTests`：384 项执行、2 项按既有资源策略跳过、0 失败；新增 OCR 成功／失败固定几何回归。两个约 58.5MP 资源用例此前已显式单独执行通过。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- `script/test_ui_design_system.sh` 与 `git diff --check`：通过。
- 完成、保存、钉住、重截、关闭、剪贴板历史及失败路径已有单一在途状态、迟到结果拒绝、归档和取消测试。本阶段据此关闭 017 的截图 UI／交互项；`006_截图功能完善` 对长截图产品级最终输出和资源边界的专项验收仍独立保留，不能由本记录替代。

## 2026-08-02 Tooltip 生命周期单轨返修

- 复审发现截图编辑器仍私有维护完整的即时 Tooltip 实现：环境键、SwiftUI Modifier、AppKit 子 Panel、屏幕边界定位和鼠标／窗口观察器均定义在巨型截图 View 中；设置预览、捕获参数条、编辑器和长截图 HUD 又共同依赖它。这造成“视觉 Token 已统一、生命周期代码仍分叉”的历史双轨。
- 将其迁入共享 `BlocksImmediateTooltipHostModel` 与 `blocksImmediateTooltip` 组件。截图模块现在只提供文案和锚点；非激活子 Panel、屏幕收敛、点击／失焦关闭、主题表面和焦点隔离由全局组件唯一负责。
- 删除截图中未被任何运行入口使用的 `ScreenshotWindowDragArea`／`ScreenshotWindowDragView` 死代码，并在设计门禁中禁止恢复截图私有 Tooltip 路径。
- Tooltip 子 Panel 与窗口失焦清理的真实 AppKit 测试 2 项通过；迁移未改变捕获、画布、文档或输出语义。
- `ScreenshotAppStateTests` 与 `ScrollingScreenshotAppTests`：385 项执行、2 项按既有 58.5MP 资源策略跳过、0 失败；`BlocksScreenshotCoreTests`：221 项执行、0 失败。
- `script/test_ui_design_system.sh` 与 `git diff --check`：通过。最终 Debug 安装版位于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID 90114，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `8548fccbc88277c522de3d2ce4d15904534a5ab5`。
- Computer Use 当前不能对透明截图选区层执行真实 hover，因此没有把 Tooltip 的鼠标悬浮路径冒充安装版通过；该路径由真实 AppKit 子 Panel 生命周期测试和此前截图 Chrome 安装版证据共同约束，最终全模块验收仍保留真实鼠标复核项。

## 2026-08-02 全局按钮与动效 Token 单轨复核

- 截图模块仍保留 `ScreenshotCommandEmphasis` 和 `ScreenshotChromeMotion` 两层转发包装；它们没有独立产品语义，只是将全局按钮强调状态和动效时长再映射一次，存在后续偏离全局规范的风险。
- 删除这两层历史包装：截图工具按钮、长截图 HUD 和捕获参数操作直接消费 `BlocksCompactIconButtonEmphasis`；捕获工具条入场与编辑器交接直接消费 `BlocksMotionRole`。
- 画布拖动、缩放、裁剪、绘制仍使用 `directManipulation` 的零时长路径，没有为直接操作增加补间。
- 截图画布失效、Chrome 安全布局、工具条宽度、更多工具关闭、OCR 面板稳定几何、渲染过期结果拒绝和全局动效共 9 项定向回归通过；设计系统单轨门禁通过。

## 2026-08-02 窗口与控件动效执行入口单轨收尾

- 复审发现截图编辑器首帧显示、捕获参数条入场和钉图悬浮工具条仍各自直接创建 `NSAnimationContext`，虽然时长已取自全局 Token，但取消、曲线和 Reduce Motion 执行仍有三条路径。
- 将窗口透明度与 AppKit 子视图透明度统一收口到 `BlocksAppKitMotion`；截图模块不再直接创建 `NSAnimationContext`。截图选区、裁剪、绘制、对象拖动与钉图窗口拖动继续即时执行，不经过该反馈动效边界。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。`ScreenshotAppStateTests` 与 `ScrollingScreenshotAppTests`：386 项执行、2 项按资源策略跳过、0 失败；两个 58.5MP 用例随后通过修改 `.xctestrun` 环境显式执行，2 项均通过。
- 动效收口后 `ScreenshotAppStateTests` 347 项重跑通过；`script/test_ui_design_system.sh` 与 `git diff --check` 通过。
- 最新安装版真实操作验证了：更多工具无默认高亮、快捷工具切换、文字首击编辑、状态条删除、钉图原比例／原位置、全屏编辑中性留边。安装路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，安装时 PID 28584，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `662d0c846f45b08e380603edbb81f2ab32334801`。

## 2026-08-03 截图模块最终复核

### 本轮发现与修复

- 最新安装版复核确认截图状态条位于裁剪区域上方、底部工具条位于裁剪区域下方；“更多工具”打开时无默认选择，切回快捷工具后不会残留高亮。矩形创建、移动、属性变化与撤销均保持直接跟手，本轮没有为画布直接操作增加补间动画。
- 长截图“可能结束”倒计时在每次继续滚动时都会创建一个无所有者的异步状态重置；快速连续滚动会产生重复任务，旧会话的迟到重置也可能触碰新会话状态。现将其收敛为单一、可取消并可合并的任务，所有状态写入携带预期 session ID，取消、终态和 teardown 统一回收。
- 曲率控制点反馈过去使用固定延时和几何放大，未消费全局 Reduce Motion 语义。现直接使用 `BlocksMotionRole.hoverFocus`，以颜色／线条强调提供短反馈，不再缩放控制点；延时任务改为有所有者、可取消的 `Task`，退出或切换减少动态效果时不会残留迟到重绘。
- 本轮没有基于推测拆分第二套 Canvas 或渲染器；只删除和收敛有真实重复任务、迟到状态或动效规范漂移证据的路径。

### 当前验证

- 新增长截图重复重置、无活动倒计时跳过和旧 session 拒绝写入 3 项回归；曲率反馈全局动效／Reduce Motion 契约 1 项回归。4 项定向测试全部通过。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- 完整 `BlocksAppTests`：972 项执行、4 项因真实 Helper／外部环境不可用按设计跳过、0 失败。
- `script/test_ui_design_system.sh`、Release 构建、Xcode Analyze 和 `git diff --check` 均通过。Xcode 只报告本机 CoreSimulator 补丁版本落后于当前 Xcode 的既有环境提示，不影响 macOS 目标。
- 安装版截图编辑器已用真实鼠标完成更多工具、快捷工具、矩形创建／移动、属性反馈和关闭放弃流程；未把包含用户桌面的截图写入仓库。
- 最终 Debug 安装版位于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `60071`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `9b06f5d9dcca7f1fbf98fda2138a7e471f773720`。真实操作还验证了普通区域裁剪移动只改变裁剪框、对象保持原文档坐标，一次撤销恢复裁剪位置；关闭后按确认丢弃临时内容，未写入截图历史或用户文件。
- 最新安装版启动、创建对象、裁剪移动、撤销和关闭后的统一日志中未出现 `Publishing changes from within view updates`、负尺寸几何、崩溃或主线程卡死诊断。

### 仍待全 App 终验

- 长截图真实滚动到“可能结束”倒计时、继续滚动恢复及最终拼接仍需要在隔离合成页面补完整安装版录屏；本轮自动化已闭合任务所有权和迟到 session 写入，但不冒充真实长页面证据。
- 真实 VoiceOver 连续朗读、全键盘长路径及多屏混合 DPI 继续归 Phase 7，不以 AX 结构或单元测试替代。

## 2026-08-03 状态条删除与历史门禁最终补验

### 真实问题与根因

- 安装版真实鼠标路径复现：状态条内选中对象并按 Delete 后，当前对象能删除，但相邻对象没有进入选中态，状态部件无高亮，画布也无缩放手柄。
- 第一次修复只在 SwiftUI 状态条的 `onDeleteCommand` 内异步选择相邻对象，单元测试通过但安装版仍失效。进一步证据确认：点击状态部件后，真实第一响应者仍是 AppKit Canvas，Delete 实际走 `ScreenshotEditorCanvas.onDelete → ScreenshotEditorStore.deleteSelection()`，而不是 SwiftUI 的状态条回调。
- 现将“可见对象顺序／删除后相邻对象”抽为单一 `ScreenshotEditorSelectionModel`，并将删除与后续选择收口为 Store 的一次文档事务。Canvas 键盘路径和状态条路径现在消费同一套顺序和状态语义，不再依赖下一帧异步补选。
- 复核同时发现复合气泡的“说明”与“连接线”无障碍名称使用原始本地化 key；已补齐中英日文案，不改变画布几何或输出。

### 自动化与安装版证据

- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- 截图 App 回归：393 项执行、391 通过、2 项按资源策略跳过、0 失败；删除顺序、Store 原子删除和 Canvas Delete 三项定向测试再次通过。
- 两个约 58.5MP 资源用例显式执行通过：历史提交约 174ms、PNG 约 1.17MB、RSS 增量约 117MB；输出 finalize 约 193ms、PNG 约 301ms、JPEG 约 201ms、TIFF 约 50ms，输出 RSS 增量约 588MB。该数据只用于本机回归比较，不作为跨机性能承诺。
- P14-B／P14-C／P14-D 从旧截图实现名迁移到当前单路径架构契约；P14-E 的独立 Swift 夹具补入其实际依赖的 `BlocksPluginPlatform.swift`。P11-A、P14、P15、P16、P3 和 P7-Q 最终门禁全部通过。
- 最新安装版用真实鼠标创建两个矩形，点击前一个状态部件并按 Delete；删除后仅剩的矩形状态部件立即高亮，画布同时出现八个缩放手柄。安装路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，安装时 PID `82899`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `c419e329434ad760e8b6e59d4988a3b57f3ed13f`。
- 真实验收还覆盖普通区域、窗口、全屏、状态条／工具条／属性条安全布局、更多工具选中态、文字与气泡移动／双向缩放／颜色保持、撤销与关闭放弃。全屏编辑器使用对称中性背景，未再暴露棋盘格。

### 证据边界

- 真实桌面上“完全被前窗口遮挡”的窗口不可选、实体多显示器混合 DPI、真实长页面滚动拼接和 VoiceOver 连续朗读仍缺当前安装版的完整平台证据；只记录为待 Phase 7 终验，不写成已通过。

## 2026-08-03 尺寸属性焦点与长截图编排单轨返修

### 真实问题与根因

- 尺寸属性条在进入自定义模式、退回预设模式和非文字焦点回收时，分别维护 `80ms`、`120ms` 的 wall-clock 重试。旧请求可在新控件出现后迟到抢回第一响应者，交互结果依赖设备负载而非窗口生命周期。
- 现在由 `ScreenshotFocusRequestCoordinator` 统一持有单调 generation，只在目标视图进入窗口或窗口成为 Key 时尝试应用最新焦点；旧 generation 不得覆盖新请求。属性条不再使用时间重试或额外主线程跳转。
- 安装版首轮真实操作进一步暴露了命令路由缺陷：自定义模式已正确聚焦到“比例”分段控件，但宿主 Panel 在把 Esc 交给第一响应者之前就直接关闭编辑器。现新增 `ScreenshotEditorLocalEscapeHandling` 契约：焦点控件先消费局部 Esc，未消费时才交由编辑器全局关闭。
- 长截图 Capture Coordinator 又增长到 720 行，纯状态可完成判断、健康错误文案和 HUD 状态投影重新混入会话编排。本轮没有放宽行数门禁，而是将三段纯映射移回 `ScrollingScreenshotCaptureSupport`，Coordinator 收敛为 699 行。
- P15-C、P15-E 和 P16-C 仍检查已删除的 OCR token、旧 ActionRegistry 全量列表与截图私有 Toolbar Group。门禁已迁移到当前单路径，不恢复旧兼容名或私有组件。

### 自动化与安装版证据

- 焦点生命周期、真实第一响应者、局部 Esc 优先和全局 Esc 回退共 5 项定向 AppKit 回归通过。
- `BlocksScreenshotCoreTests`：221 项通过。截图 App 回归：399 项执行、397 项通过、2 项资源用例默认跳过、0 失败；两个约 58.5MP 用例通过 `.xctestrun` 显式注入环境后 2 项均通过。长截图 Support 拆分后单独重跑 42 项，40 项通过、2 项资源用例按默认策略跳过、0 失败。
- P14-A～P14-F、P15-A～P15-E、P16-A～P16-E、P7-Q 与设计系统单轨门禁通过；`git diff --check` 通过。
- 最新 Debug 安装版以 Option+A 进入普通区域截图，通过裁剪范围的 AX “选择”动作进入尺寸属性条：点击“自定义”后，真实 `AXFocusedUIElement` 为“比例”；按一次 Esc 仅退回预设，编辑器继续存在，焦点回到“自定义”；再按 Esc 才关闭编辑器。
- 安装路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `12510`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `6322b7c6891dfd401670449163119b23fc2d7b37`。本次操作后统一日志未出现 SwiftUI view-update 发布警告、应用负尺寸几何、崩溃或主线程卡死。

## 2026-08-03 文字编辑焦点单轨返修

### 历史问题与收口

- 文字编辑仍单独维护“立即 `makeFirstResponder`、下一轮重复聚焦、固定 50ms 重试、私有 generation 和私有 Task”五段状态；尺寸属性等控件已经使用生命周期焦点协调器，因此截图内部存在两套焦点恢复逻辑。
- 固定 50ms 不是产品交互时长，也不对应 AppKit 生命周期。机器负载变化时，它可能过早无效或在用户已切换目标后迟到抢焦点。
- `ScreenshotFocusRequestCoordinator` 现在支持当前鼠标事件结束后的单调请求校验。文字编辑只保留“立即申请＋下一轮生命周期校验”，提交或取消时统一 detach；私有重试 Task、generation 和墙钟延迟全部删除。
- 首键事件转交仍保留为输入安全网，但它不再负责驱动第三次延时聚焦，也不会形成第二套焦点状态。

### 自动化与安装版证据

- 焦点协调器、真实第一响应者、文字创建下一轮校验和首键转交 4 项定向 AppKit 测试通过。
- 截图 App 回归 401 项执行、399 项通过、2 项按既有大资源策略跳过、0 失败；`BlocksScreenshotCoreTests` 221 项执行、0 失败；Release 构建、Xcode Analyze、设计系统门禁和 `git diff --check` 通过。
- 完整 `BlocksAppTests` 在无并发负载下 983 项执行、979 项通过、4 项外部环境跳过、0 失败。此前与截图／Core 并行运行后的首轮完整套件仅有 Vision 真实语料 `latin` 用时 8.075 秒，超过 8 秒性能阈值 75ms；同项单独复跑和无并发完整复跑均通过，因此未修改或放宽性能阈值。
- 最新安装版真实执行普通区域截图：选择文字工具、首次点击画布、立即输入首字符；真实 `NSTextView` 保持第一响应者且字符未丢失。一次 Esc 只退出局部文字编辑，第二次 Esc 才关闭编辑器。
- 复核同时覆盖普通区域与全屏编辑器：状态条、截图和底栏维持安全布局，更多工具打开／关闭没有残留选中态，直接操作继续为零补间。
- 安装版路径 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `36304`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `6aa463577ffea0931ef45c6fadb988a06a733e4a`。
- Computer Use 读取 AX 时仍触发已归因的系统 `NSWindowSharingSessionRecipientIndicator` 负尺寸日志；同一时间没有 SwiftUI 发布期修改、崩溃或 Main Thread Checker 诊断，本轮不把工具链日志伪装成截图布局缺陷。

## 2026-08-03 状态条内容宽度与 Chrome 几何单轨收口

### 真实问题与根因

- 最新安装版的顶部状态条即使只有“尺寸／圆角”两个固定项，也会被强制拉伸到底部主工具条的宽度，形成大面积无意义毛玻璃空白。
- 根因不在材质或透明度，而是 `ScreenshotEditorCropChromeLayout` 只接收一个 `chromeWidth`，将“信息密度随文档变化的状态条”与“需要稳定容纳命令的主工具条”误当为同一几何角色。

### 修复与历史逻辑清理

- 状态条与工具条现在独立计算宽度，各自围绕当前裁剪区域中心对齐，贴近屏幕边缘时也独立收敛。
- 状态条优先使用真实测量内容宽度，首帧使用同一字体与间距 Token 的可预测估算；只在超过安全宽度后启用既有渐隐和横向滚动，不因少量对象保留空白。
- 只对状态部件数量变化使用全局 `reflow` 动效；裁剪、缩放、拖动、绘制与内容测量仍为零补间，不让视觉反馈干预直接操作。
- 将 Chrome Token、状态条测量、裁剪周边几何和浮层定位从巨型 `ScreenshotEditorView` 抽离到纯布局文件，删除重复的 `CGRect.area` 帮助路径；运行时只保留一套 Chrome 几何计算。

### 自动化与安装版证据

- `ScreenshotAppStateTests`：361 项执行、0 失败；新增状态条内容收缩、溢出上限及状态条／工具条独立边缘收敛回归。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。`ScrollingScreenshotAppTests`：42 项执行，40 通过、2 项按默认资源策略跳过；随后显式执行两个 58.5MP 用例，2 项均通过。
- 完整 `BlocksAppTests` 共 985 项，首轮仅 Vision OCR 拉丁语料冷启动用时 8.035 秒，超过 8 秒门槛 35ms；该项单独复跑为 0.155 秒并通过。本轮未放宽阈值，也未将该冷启动抖动归因到 Chrome 改动。
- UI 设计系统单轨门禁、Release 构建、Xcode Analyze 和 `git diff --check` 通过。
- 真实安装版全屏截图编辑中，状态条仅包裹“尺寸／圆角”；创建矩形后只增加一个对象部件，底部工具条和截图区域几何不变。“更多工具”无默认高亮，切回快捷工具后不残留选中态。
- 本轮真实验收后未新增截图编辑期间的 SwiftUI 发布期修改、负尺寸、崩溃或主线程卡死诊断。Computer Use 读取界面前的系统负尺寸日志与上述已记录的系统分享指示器时序一致，本轮未将它伪装成 Blocks Chrome 问题。
- 功能提交快进合并到 `main` 后已重新构建、签名和安装。最终安装版路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `58210`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `6aa1fc58b7e44b2a12d3810533aa31f618448078`。真实桌面画面只用于当次低敏验收，未写入仓库。
