# Phase 1 设置 UI 与交互升级记录

## 范围

本阶段只收口设置导航、页面层级、设置行、二级页、Sheet、反馈、危险操作、主题与无障碍契约，不改变截图、剪贴板、翻译、Provider 或插件的业务语义。

## 已完成的结构改造

- 删除设置详情页对 `selectedSection` 的强制重建，为 11 个主路由分别保存滚动位置。
- 保留原生 Source List 的 5 个分组和 11 个可选路由；分组仍不可选，定向导航仍会将当前项滚入可见区域。
- 设置内容宽度上限改为 1120pt，尾列改为 220–360pt 自适应区间。
- 用户验收发现原实现按“标题＋说明”整体居中，导致值控件视觉上落入第二行；共享 `SettingsRowShell` 已改为标题首行和值控件首行对齐。820pt 最小窗口继续保持横向设置行，不再自动上下堆叠。
- 建立并使用共享 `SettingsSection` 、设置行、导航行、危险操作行、固定反馈槽、状态页、二级页返回头和 Sheet 壳层。
- 设置分区不再使用独立毛玻璃表面；改为共享语义内容底色、轻边界和行分隔。
- 插件安装确认和截图工具配置迁入固定标题／滚动内容／底部操作的共享 Sheet 壳层。

## 2026-08-02 对齐与控件语义返修

- 根因确认：旧 `SettingsSection` 标题位于分区外边缘，内容额外内缩 16pt，造成模块标题与设置行标题不在同一基线。
- `SettingsSectionHeader` 与分区内容改为共用 `SettingsLayout.sectionContentHorizontalInset`；标题操作和设置值控件同时贴齐内容尾边缘。
- `SettingsRowShell` 强制通过 `SettingsValueColumn` 承载尾部控件，删除页面层的 `SettingsTrailingControl` 补丁。
- 全部旧 `SettingsTableSection` 迁移到唯一 `SettingsSection`。
- 持久二态设置统一使用 `SettingsBooleanSwitch`；一次性风险确认与多选项继续使用 checkbox。
- 长期规则迁入[产品知识库 UI 与交互规范](../../产品知识库/UI与交互规范/index.md)，017 只保留项目实施和证据。

## 页面收口

- 通用：外观、语言和默认收起的材质诊断合并为“应用外观”。
- 截图：删除整页手工透明度；水印管理进入二级页；工具配置使用统一 Sheet。
- 剪贴板：标签管理进入二级页；隐私改为整行导航；“清空未收藏”移入底部危险操作区。
- 剪贴板隐私：加载、空、修改结果和重试使用稳定反馈区，修改结果不再推动列表。
- 翻译：翻译源、Apple 语言资源和兼容取词授权进入二级页；二级路由保存于当前窗口会话。
- 翻译收藏：保留内容浏览器结构，改用语义内容表面，保存搜索和当前选择。
- 快捷键：注册状态收敛为一行摘要；重新注册上移为分区操作；反馈改用固定槽位。
- 权限：每个权限的状态和必要操作合并到同一行；重复请求入口已删除；技术诊断保持默认收起。
- AI 服务：总览仅展示能力和连接摘要；连接、凭据、测试和高级生命周期进入二级详情。
- 本地自动化：按后台服务、数据访问和 CLI 工具保持三段式结构，共享行契约提高关系可读性。
- 插件：目录搜索和筛选保存于窗口会话；详情返回目录后恢复原条目位置；去除详情头部的私有玻璃卡。
- 数据与审计：摘要收敛为普通设置行；空态使用共享状态页；清空移入底部危险操作区并保留取消／确认路径。

## 代码门禁

- 设置范围禁止回归固定 280pt 尾列、页面私有尾列和私有行壳。
- 禁止恢复 `.id(appModel.selectedSection)` 强制重建。
- 兼容别名、设置私有行布局、模块私有 `ButtonStyle`、无作用域动画和 Reduce Motion 绕过必须为零。
- 结构性 Material、背景、描边、阴影和圆角只能来自 Foundation；截图像素、图片预览等真实内容绘制使用明确白名单。

## 验证结果

### 自动化与构建

- 完整 `BlocksAppTests`：共 918 项，其中 914 项通过、4 项按测试环境设计跳过、0 失败。跳过项不计作通过；新增覆盖包括真实 `NSHostingView` 设置几何和 Source List 程序化选中不会覆盖目标路由。
- 完整 `BlocksScreenshotCoreTests`：执行 220 项，0 失败。
- 仓库仍不存在独立 `BlocksCoreTests` scheme；`BlocksCore` scheme 未配置 test action。本阶段实际执行后得到 exit 66，因此不把该计划项伪写为通过。Core 代码已由 AppTests、依赖构建和 Analyze 覆盖。
- Debug、Release 构建和 Xcode Analyze 均通过；Analyze 仅报告本机 CoreSimulator 版本落后于当前 Xcode 的环境警告，macOS 分析目标正常完成。
- `script/test_ui_design_system.sh` 与 `git diff --check` 通过；门禁已从“遗留数量不增长”改为“单一正规路径、历史别名为零”。
- 本轮新增静态门禁确认：设置业务页面不再直接创建原始 `Toggle`，没有布尔 `Picker`／单选标签，旧 `SettingsTableSection`、`SettingsTrailingControl` 和 `SettingsLabeledToggle` 均已清零。

### 安装版证据

- 已采集默认宽度下 11 个设置主路由及翻译收藏页的真实界面证据。
- 已采集 820pt 最小窗口、默认窗口和宽窗口证据。用户指出的“设置值落在标题第二行”已在共享行组件修复；`narrow-screenshot-aligned.png` 和 `default-screenshot-aligned.png` 证明标题与值控件首行对齐。
- 已采集深色和显式浅色宽窗口证据；测试后已恢复“跟随系统”。
- 已真实验证翻译源、水印二级页保持原侧栏路由，返回后恢复对应主页面滚动位置。
- 已真实验证主路由切换后的滚动位置恢复、分组标题点击不改变当前路由，以及设置单例窗口不会因二级导航生成第二个窗口。
- 2026-08-02 对齐返修后，使用最新安装版再次巡检 11 个主路由，并复核水印、标签、剪贴板隐私、翻译源和插件详情二级页；截图、剪贴板、翻译、插件和通用页的分区标题／行标题左基线与尾列右边缘均保持一致。
- 宽窗口复核确认内容使用 1120pt 最大宽度居中，设置值仍贴齐内容区尾端，没有因窗口放大漂移到页面中部。

旧阶段证据目录：`evidence/phase1-settings/`。

本次单轨收口安装版证据：

- `evidence/phase1-settings-single-path/installed-wide-general-settings.png`
- `evidence/phase1-settings-single-path/installed-wide-screenshot-settings.png`
- `evidence/phase1-settings-single-path/installed-wide-clipboard-settings.png`

## 尚未闭合的真实平台证据

- 降低透明度、提高对比度、减少动态效果未在本轮修改系统辅助功能开关；当前只有共享组件契约和自动化门禁证据。
- 英文、日文资源已编译并通过本地化测试，但本轮没有重启安装版采集完整逐页截图。
- VoiceOver 读取顺序和长时间键盘连续操作没有取得完整录屏；已有 AX 结构、真实点击和自动化契约不能替代这两项平台证据。

## 2026-08-03 设置模块最终复核

### 本轮发现与修复

- 最新安装版逐页复核没有发现新的分区基线、尾列对齐或窄窗口溢出问题；本轮没有为了增加动效而给设置路由增加装饰性转场，继续保持原生 Source List 的即时反馈。
- SwiftUI 分区标题补充二级标题语义；AppKit Source List 的五个不可选分组补充 `AXHeading` 语义。分组点击仍不会改变当前路由，11 个业务路由仍是唯一可选择项。
- `SettingsSourceListNativeView` 过去会在每次布局时重复写入相同的 Outline View frame 和列宽，并在选中项已经可见时继续请求滚动。现改为只在几何实际变化或目标不可见时提交，减少窗口缩放和路由切换中的无效布局／滚动失效。
- 未增加第二套导航、动画或页面状态实现；修改继续落在现有唯一 Source List 与共享 Settings 组件路径上。

### 当前验证

- `AppAppearanceTests`：45 项执行，0 失败；覆盖分组不可选、标题语义、真实 `NSHostingView` 基线和尾列几何。
- 完整 `BlocksAppTests`：968 项执行，4 项因真实 Helper／外部环境不可用按设计跳过，0 失败。
- 完整 `BlocksScreenshotCoreTests`：221 项执行，0 跳过、0 失败。
- Debug 安装构建、Release 构建、Xcode Analyze、`script/test_ui_design_system.sh` 和 `git diff --check` 均通过。
- 最新安装版位于 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，PID `54372`，CDHash `7509dcbbe03266bcef8e485533d35024d57e3bd8`。
- 真实界面复核确认：820pt 窄窗口下分区标题、行标题和值控件保持稳定；点击“工具”等分组标题不会切换路由；在“通用／截图”之间往返时选中态、滚动区和窗口数量保持稳定。
- 本轮启动及真实导航后的统一日志中未出现新的 `Publishing changes from within view updates`、负尺寸几何或主线程卡顿诊断。

本轮证据目录：`evidence/phase1-settings-current-audit/`，其中 `15-installed-latest-screenshot-settings.jpeg` 为修复后最新安装版截图。

### 仍待全 App 终验

- 真实 VoiceOver 连续朗读和全键盘长路径仍归 Phase 7，不以 AX 树和自动化替代。
- 多屏、负坐标和混合 DPI 是全 App 窗口与浮层矩阵，不在设置模块内伪造完成。

## 2026-08-03 侧栏滚动与整行居中口径返修

### 根因与单轨修复

- Source List 沿用了 `NSOutlineView` 的浮动分组默认值，因此“工具”会在滚动时吸顶；同时滚动条虽隐藏，横向弹性和文档宽度仍允许产生水平偏移。
- 旧设置契约要求值控件对齐标题首行，与本轮用户确认的“设置值在完整设置行中上下居中”冲突。共享 `SettingsRowShell` 已删除标题首行 Alignment Guide，Switch、Picker、分段控件、Slider、按钮和输入框统一通过整行中心与 `SettingsValueColumn` 尾端布局。
- Source List 现在明确关闭浮动分组、横向弹性和横向滚动条，并在布局时把文档宽度锁定到可视区、把水平原点钳制为零；没有增加第二套侧栏实现。
- 剪贴板“清理方式”迁入共享 `SettingsSegmentedRow`，整个分段控件贴齐尾列；分段内部文字继续使用系统原生居中。

### 自动化证据

- AppKit Source List 集成测试覆盖分组不吸顶、横向滚动能力关闭和水平偏移为零。
- 真实 `NSHostingView` 几何测试覆盖一行、多行说明和“清理方式”，验证值控件与整行中心误差不超过 1pt，全部尾端误差不超过 1pt。
- 旧 `settingsTitleLineCenter` 路径由设计门禁禁止恢复。
- 最新安装版将设置窗口缩短后真实滚动侧栏，“工具”分组与其路由一起离开可视区，未再吸顶；随后执行横向滚动手势，内容未产生水平位移，AX 只暴露纵向滚动动作。
- 剪贴板设置实看确认“清理方式”分段控件贴齐尾列；多行“清理时保留收藏”与其他 Switch 在完整设置行内垂直居中。

## 2026-08-03 滚动指示与可见控件几何复核

- 设置主内容、插件二级页、翻译收藏详情、设置 Sheet 和 Debug Gallery 继续支持纵向滚动，但统一隐藏滚动指示条；侧栏也隐藏纵向滚动条。
- 侧栏增加只允许纵轴的 `NSClipView`。它在 AppKit 处理斜向手势和惯性滚动时直接把水平原点钳制为零，不再只依赖隐藏滚动条或布局后的补救复位。
- “清理方式”分段控件先按自身可见宽度布局，再贴齐共享尾列，修复透明 220pt 容器对齐、可见分段却仍偏左的假对齐。
- 实渲染几何测试改为测量可见 Switch、分段控件、文本框和 Slider 组，而不是只测外层尾列容器；这些控件与完整设置行垂直中心、共享右边缘的误差均不超过 1pt。

### 最新安装版证据

- 最新安装版使用真实触控板动作确认：主内容可继续纵向滚动，主内容和侧栏均不展示滚动条；对侧栏执行横向／斜向滚动后，菜单内容的水平位置保持不变。
- 剪贴板设置实看确认：“清理方式”的可见分段控件与 Switch、Picker、输入框和 Slider 组共享右边缘；设置值与完整设置行上下居中。
- 完整 `BlocksAppTests` 执行 990 项，4 项因外部 Helper 环境按设计跳过，0 失败；`BlocksScreenshotCoreTests` 执行 221 项，0 跳过、0 失败。Release 构建、Xcode Analyze、设计系统门禁和 `git diff --check` 均通过。
- 安装版路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`；本轮验收签名为 `TeamIdentifier=LOCAL_TEAM_ID_REDACTED`、`CDHash=fcc3f023b37dceb4b65675365fbf6d21affd9c6b`。
- 首次使用 AX 验收通道读取安装版时仍能触发既有的 AppKit Theme Widget 冷启动负尺寸诊断；重启后不读取 AX 时不出现，首次 AX 枚举时出现。该现象与本文件前述 Theme Widget 结论一致，当前没有证据将其归因于本轮滚动或对齐改动。

证据：`evidence/2026-08-03-settings-clipboard-plugin/settings-clipboard-alignment.jpg`。

## 2026-08-02 设置原生化与全设计系统单轨收口

### 已实施

- 分区标题改为系统 `headline semibold primary`，与行标题共用 16pt 内缩。
- 普通表单改为 820pt 居中上限，翻译收藏、插件目录等内容页保留 1120pt，Sheet 表单为 640pt。
- 分区使用无阴影、常态无描边的系统分组底色；提高对比度时才增加语义边界。
- 新增标题首行视觉中心 Alignment Guide，Switch、Picker、输入框、Slider 和按钮统一交由 `SettingsValueColumn` 对齐，删除经验像素补偿。
- 删除翻译源、剪贴板标签、截图水印等私有行布局，迁移到共享表单行、状态行和 Sheet 壳层。
- 删除 `settingsSection`、`floatingPanel` 及旧 Spacing／CornerRadius／Motion 别名；截图、剪贴板、翻译和设置的图标按钮共用唯一 `BlocksIconButtonStyle`。
- 删除 Foundation 外的结构阴影、字面圆角和直接 Material；仅图片预览与截图像素等真实内容绘制保留明确白名单。
- 增加 `SettingsDesignSystemGallery`，覆盖表单、Switch、Picker、文本框、Slider、状态、导航、操作、危险和空态行。

### 验证状态

- `AppAppearanceTests` 定向执行 34 项，0 失败；其中真实 `NSHostingView` 覆盖 820、980、1440pt，渲染后测量标题、首行中心和值控件尾缘，误差不超过 1pt。
- 完整 `BlocksAppTests` 共 918 项：914 通过、4 项因真实 Helper／外部环境不可用而按设计跳过、0 失败。
- 完整 `BlocksScreenshotCoreTests` 共 220 项：220 通过、0 跳过、0 失败。
- Debug、Release、Xcode Analyze、设计系统零容忍门禁和 `git diff --check` 均通过。唯一构建环境提示为本机 CoreSimulator framework 1051.54 与 Xcode 1051.55 的版本差异，不影响 macOS 目标构建、测试或分析结果。
- 最新安装版已巡检 11 个主设置路由；普通表单在宽窗口保持 820pt 居中，翻译收藏和插件目录使用内容型宽布局。分区标题、行标题、标题栏操作和值控件分别共用左右基线，浅色与跟随系统切换不改变几何。
- 真实外观切换曾复现 SwiftUI `Publishing changes from within view updates`。根因是 Picker setter 在视图更新事务内同步发布 `AppAppearanceStore`；现改为下一次 MainActor 调度提交，安装版复测未再产生该警告。
- 真实定向打开设置曾复现目标页面被首个 Source List 项覆盖。根因是 `NSOutlineView.reloadData()` 在 `allowsEmptySelection = false` 下同步产生选择回调；程序化重载与选中现由同一抑制区保护，并增加回归测试。
- 安装版首次执行 AX 树读取时仍可能出现一次 AppKit `Invalid view geometry` 诊断。事件序列确认它与 `com.apple.appkit.xpc.ThemeWidgetControlViewService` 首次连接同步发生，在通用页和截图页均可复现，重复 AX 读取不再出现；因此记录为 AppKit 主题控件桥接冷启动噪声，不将其误归因为业务页面几何，也不以隐藏日志代替修复。
