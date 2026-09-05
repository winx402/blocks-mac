# Phase 7 主题与辅助功能验收记录

日期：2026-08-02  
分支：`codex/global-ui-phase7-theme-accessibility`  
安装版基线：`main@e3a8c3b9`

## 本轮范围

- 跟随系统深色、显式浅色、显式深色。
- 降低透明度、提高对比度、减少动态效果。
- 设置窗口和剪贴板面板的激活／失活对照。
- 设置、剪贴板和翻译三个共享表面消费者的真实安装版回归。
- 设计系统历史兼容入口与私有结构样式门禁复核。

本轮不把键盘全路径、VoiceOver、多语言、多屏、混合 DPI、截图编辑器真实捕获和性能长测写成通过；它们继续保留在 Phase 7 后续矩阵。

## 真实安装版结论

| 场景 | 结果 | 证据 |
|---|---|---|
| 跟随系统深色 | 设置、剪贴板和翻译使用一致的语义表面；未出现固定浅色或黑底漂移 | `01-settings-follow-system-dark.jpeg`、`08-translation-system-dark.jpeg`、`09-clipboard-system-dark.jpeg` |
| 显式浅色 | 外观立即切换；设置页几何、滚动位置和侧栏选择保持稳定 | `02-settings-explicit-light.jpeg` |
| 显式深色 | 外观立即切换；完成后已恢复“跟随系统” | `15-settings-explicit-dark.jpeg` |
| 降低透明度 | 原生材质回退为实色，文字和边界仍可读，页面几何不变 | `03-settings-reduce-transparency.jpeg` |
| 提高对比度 | 设置分区与剪贴板卡片边界增强，没有高饱和整块背景或布局变化 | `04-settings-increase-contrast.jpeg`、`10-clipboard-increase-contrast.jpeg` |
| 减少动态效果 | 设置与翻译面板状态切换未出现位移、缩放或内容挤压 | `05-settings-reduce-motion.jpeg`、`07-translation-reduce-motion.jpeg` |
| 激活／失活 | 设置与剪贴板在失活后保持可读且没有几何变化；非激活剪贴板面板未获取外部目标 App 焦点 | `11-clipboard-active.jpeg`～`14-settings-inactive.jpeg` |

证据目录：`evidence/phase7-theme-accessibility/`。

## 自动化与门禁

- `AppAppearanceTests`：40 项执行、0 失败。
- 完整 `BlocksAppTests`：930 项执行、4 项按真实外部环境要求跳过、0 失败。
- `BlocksScreenshotCoreTests`：221 项执行、0 失败。
- `./script/test_ui_design_system.sh`：通过；旧兼容别名、模块私有 ButtonStyle、结构性字面样式和无作用域动画均保持为零。
- 自动化覆盖共享 Surface 的不透明回退、高对比度／失活几何不变、Reduce Motion 降级、设置真实 HostingView 对齐以及通知不改变焦点。

测试宿主在销毁 AppKit／SwiftUI 测试视图时仍输出 `NSCGS` 事务警告。它没有出现在当前安装版普通操作路径中，本轮不把它归因成生产缺陷。

## 运行时日志归因

普通启动并静置 6 秒没有出现负尺寸几何、发布期状态修改或主线程无响应诊断。随后单独调用 UI 自动化的 AX／截图快照，能稳定触发六条 AppKit `Invalid view geometry`（宽、高各三条）。因此当前事实是：

- 该日志与 UI 控制通道的快照读取严格相关；普通启动没有复现。
- 不能据此宣布真实用户路径存在负尺寸布局，也不能把它简单归为业务页面根因。
- Computer Use 顶部的紫色控制标记同样属于验收通道，不作为 App 视觉缺陷。
- VoiceOver 仍需在不依赖该自动化快照的真实辅助功能路径中复核；在取得证据前保持待验证。

## 待验证与阻断

- 截图捕获／编辑器真实主题矩阵被系统 Developer Tools Access 授权框阻断；本轮只保留既有截图 Chrome 证据和代码契约，不冒充实机通过。
- 键盘全路径与 VoiceOver 未完成。
- 英文、日文、窄／宽、多屏、负坐标、混合 DPI 和性能长测进入后续 Phase 7 子阶段。

## 环境恢复

- App 外观已恢复“跟随系统”。
- macOS“降低透明度”“提高对比度”“减少动态效果”均恢复为关闭。
- App 已恢复为普通安装版启动，不保留测试入口环境变量。

## 2026-08-02 浮层生命周期子阶段

本子阶段建立了 AppKit 浮层单一展示边界，并先迁移剪贴板与翻译主面板：

- 面板在进入可见状态前先获得最终正尺寸 frame，避免零尺寸首帧和位置跳变。
- 用户主动关闭使用共享面板淡出；截图翻译交接、会话替换、自动粘贴和 App 退出保持立即关闭，避免动画遮挡选区或延误目标焦点。
- 剪贴板面板只隐藏打开前真实可见的 Blocks 普通窗口，关闭后只恢复这些窗口；固定面板后立即恢复原窗口上下文。
- 动画完成使用 generation 拒绝迟到回调，旧面板不得关闭或恢复新会话。

自动化与安装版证据：

- `ScreenshotAppStateTests`：341 项、0 失败。
- `TranslationEntryBridgeTests`：87 项执行、1 项真实 Helper 环境跳过、0 失败。
- 合并定向运行：428 项执行、1 项跳过、0 失败。
- 完整 `BlocksAppTests`：953 项执行、4 项真实外部环境跳过、0 失败。
- `test_ui_design_system.sh` 与 `git diff --check` 通过。
- 最新安装版连续 5 轮翻译面板打开／关闭均成功，剪贴板面板关闭后设置窗口真实恢复。

负尺寸日志完成了进一步归因。LLDB 在生产安装版真实触发时捕获到 `d0 = -1, d1 = -1`，调用栈来自 AppKit 的 `NSWindowSharingSessionRecipientIndicator → NSThemeFrame`，即 macOS 屏幕共享标题栏提示器，而不是 Blocks 内容视图。证据见 `evidence/phase7-window-lifecycle/negative-geometry-root-cause.txt`。因此不再为该系统日志修改业务布局；此前两项试探性布局改动已回滚。

## 2026-08-02 全局 UI 与交互返修终验

本子阶段针对浮层生命周期、截图 Chrome、剪贴板详情交互、翻译滚动桥接以及系统支持页面完成单轨收口。验收使用重新构建并安装的真实 Debug App，不以测试产物代替安装版。

### 安装版身份

- 安装路径：`/Users/bot/Applications/BlocksDev/Debug/Blocks.app`
- 运行 PID：`56554`
- Bundle Identifier：`app.blocks.app`
- Team Identifier：`LOCAL_TEAM_ID_REDACTED`
- CDHash：`bf260baccdb3ddaf94e8ab95c7cb494683ab7ca3`
- 签名：`Apple Development: 89931215@qq.com (B8S8FZ59TW)`
- 安装后 Screen Recording 与 Accessibility TCC 行均继续匹配稳定签名。

### 真实界面结论

| 模块 | 真实操作 | 结论 |
|---|---|---|
| 设置 | 进入 Provider 详情、本地自动化和数据与审计 | 一次性确认使用 Checkbox，不再伪装为持久化 Switch；本地 CLI 状态和反馈拥有稳定槽位；页面切换没有重建第二个窗口或丢失侧栏选择 |
| 剪贴板 | 打开主面板、选择文字记录、进入详情、连续 Esc 返回 | 搜索框首帧获得真实焦点；详情状态先关闭，再关闭主面板并恢复原设置窗口；没有卡死、迟到详情重新出现或旧窗口回调干扰 |
| 翻译 | 输入低敏“你好”，四源并发完成；结果区上下滚动 | 四张结果卡顺序稳定且未崩溃；向上滚动先将原文从默认高度收缩到最小高度，同一次滚轮事件继续交给结果区；反向滚动恢复原文高度，语言栏和操作按钮位置不变 |
| 截图 | 创建普通区域截图、打开“更多工具”、再选择快捷矩形工具 | 编辑器状态条、选区和底栏锚定实际裁剪范围；更多面板打开时没有默认工具高亮；选择快捷工具后面板关闭且只保留矩形选中态，属性条在底栏下方稳定出现 |
| 主题 | 跟随系统深色 → 显式浅色 → 跟随系统 | 设置和翻译浮层的语义色、边界和几何均稳定；切换后没有焦点丢失、滚动跳变或额外窗口；验收结束已恢复用户原设置 |

安全截图证据位于 `evidence/phase7-global-ui-final/`。截图编辑器的底图包含当前桌面内容，仅做本机目视验收，不写入仓库证据。

### 自动化、构建与运行时

- 完整 `BlocksAppTests`：952 项通过、4 项外部环境跳过、0 失败；结果包为 `Test-BlocksAppTests-2026.08.02_17-52-23-+0800.xcresult`。
- 完整 `BlocksScreenshotCoreTests`：221 项通过、0 跳过、0 失败；结果包为 `Test-BlocksScreenshotCoreTests-2026.08.02_17-54-14-+0800.xcresult`。
- Debug、Release、Xcode Analyze、`test_ui_design_system.sh` 和 `git diff --check` 均通过。
- 安装版连续操作期间没有新的 `Publishing changes from within view updates`、AppKit 事务重入、Main Thread Checker、崩溃或 hang 诊断。
- `Invalid view geometry` 仍会在屏幕共享标题栏指示器刷新时由系统 `com.apple.appkit.xpc.ThemeWidgetControlViewService` 成组输出；该时序和此前 LLDB 的 `NSWindowSharingSessionRecipientIndicator` 调用栈一致，不归因于 Blocks 内容布局。
- 真实交互结束时进程 CPU 为 0.0%，未见持续忙循环；本轮没有足够的 Instruments 数据支持宣称真实 p95，自动化性能阈值与安装版无卡顿观察分开记录。

### 仍待真实平台条件

- 当前只有一块 `1920 × 1080 @ 60Hz` 显示器；负坐标、多屏和混合 DPI 已由几何测试覆盖，但没有本轮真实硬件证据。
- AX 树已验证角色、状态、焦点和键盘动作入口；未开启系统 VoiceOver 做完整朗读顺序验收。
- 本轮没有修改用户的“降低透明度”“提高对比度”“减少动态效果”等 macOS 全局设置；相应契约继续由既有真实证据和自动化覆盖。

## 2026-08-02 多结果固定区域压缩返修与最终门禁

安装版四源翻译终验发现了自动化此前未覆盖的真实几何缺陷：四张结果卡完成后，原文与语言控制区会参与 SwiftUI 纵向压缩，源语言和目标语言控件仍存在于 AX 树中，但视觉上只剩一条空白表面。该问题不是翻译数据缺失，而是固定控件与结果列表共同争夺高度。

- 固定控件区现在使用由全局面板指标计算的显式高度；原文仍按既定规则从 `72pt` 收缩到 `48pt`，结果视口成为唯一弹性区域。
- 最新安装版输入低敏文本 `hello` 后，腾讯、Google、Apple 和 MyMemory 四张结果卡均完成，语言栏保持完整可见；继续滚动时仅原文框收缩，语言控件的高度和命中不变。
- 定向几何回归覆盖手动展开、手动收缩和截图 OCR 三种固定区高度，1 项执行、0 失败。

最终自动化与构建结果：

- 完整 `BlocksAppTests`：961 项执行、6 项真实外部环境相关跳过、0 失败。结果包：`DerivedData/FinalUIAppTests/Logs/Test/Test-BlocksAppTests-2026.08.02_22-42-23-+0800.xcresult`。
- 完整 `BlocksScreenshotCoreTests`：221 项执行、0 失败。结果包：`DerivedData/FinalUIScreenshotCore/Logs/Test/Test-BlocksScreenshotCoreTests-2026.08.02_22-42-23-+0800.xcresult`。
- Release 构建、Xcode Analyze、UI 设计系统门禁和 `git diff --check` 全部通过。
- 当前安装版路径为 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`，运行 PID 为 `17466`，Identifier 为 `app.blocks.app`，TeamIdentifier 为 `LOCAL_TEAM_ID_REDACTED`，CDHash 为 `04eb673c7df4dbb10f0a0701ae821b67edd7589a`。

证据边界：

- 本轮真实打开并检查了设置、插件目录与详情、Provider、本地自动化、剪贴板主面板、翻译四源结果和截图捕获遮罩；未发现新的 `Publishing changes from within view updates`、崩溃或持续忙循环。
- 当前自动控制通道未能稳定展示剪贴板附属详情 Panel，因此该窗口的完整视觉路径仍保留为人工复核项；已有详情焦点与生命周期自动化通过，不能替代实机视觉证据。
- `Invalid view geometry` 只在 Computer Use 读取 AX／截图状态的同一时刻出现，与此前确认的屏幕共享标题栏指示器链路一致；没有独立用户操作时间点证据支持归因到 Blocks 业务视图。

## 2026-08-02 外观测试生命周期与语言会话收口

- 设置中的语言说明明确约定“保存后于下次启动生效”。`L10n` 现在在进程启动时捕获一次语言偏好，AppKit 面板、SwiftUI 页面和窗口标题不会在当前会话中分别读取不同偏好而出现混合语言；新进程仍会读取最新保存值。
- 定向测试发现旧的窗口外观用例会在完整 App 测试宿主中创建第二个 `AppAppearanceStore`，与真实宿主 Store 竞争写入 `NSApplication.shared.appearance`。竞争导致断言偶发失败后，当前 XCTest 又在主线程记录失败时自锁，表现为套件永久无输出。
- 删除该非隔离全局竞争，测试改为分别验证“偏好到原生 Appearance 的映射”以及“Window／Panel 不设置局部 Appearance、继续继承应用外观”两条契约。该调整不弱化主题覆盖，真实浅／深主题继承仍由安装版矩阵证明。
- `AppAppearanceTests` 41 项全部通过；其中语言会话、外观映射和 Window／Panel 继承契约 3 项定向复跑通过。测试宿主仍会在销毁真实 HostingView 时输出既有 NSCGS 事务警告，该日志未出现在安装版普通路径中。

## 2026-08-03 主题矩阵与用户语言最终复核

- 使用隔离数据启动当前 Debug 产物，真实切换“跟随系统 → 显式浅色 → 跟随系统”，依次检查通用页和 Provider 二级页。侧栏、分组表面、表单尾列、输入框和反馈槽位没有发生几何跳变，窗口没有重复创建，验收结束已恢复“跟随系统”。
- Provider 二级页仍残留“metadata”“provider”“request”等面向实现的术语。它们已改为“填写此 AI 服务提供的 API 地址／模型名称”，中英日三种语言使用相同的普通用户语义，不改变配置或连接流程。
- 新增用户文案契约测试，禁止上述两项生产说明重新暴露内部术语；`AppAppearanceTests` 45 项执行、0 失败。
- 完整 `BlocksAppTests` 执行 968 项、6 项因外部环境条件跳过、0 失败；完整 `BlocksScreenshotCoreTests` 执行 221 项、0 失败。跳过项不冒充安装版证据。
- Release 构建和 Xcode Analyze 均通过；UI 设计系统门禁、字符串目录 JSON 校验与 `git diff --check` 通过。测试宿主仍输出既有 CoreSimulator 版本提示和 HostingView 销毁阶段 NSCGS 事务警告；两者均没有对应安装版业务路径异常，本轮不通过隐藏日志伪装修复。
- 已精确替换安装 `/Users/bot/Applications/BlocksDev/Debug/Blocks.app`。最新进程 PID `50972`，Identifier `app.blocks.app`，TeamIdentifier `LOCAL_TEAM_ID_REDACTED`，CDHash `85d7131b8333be97a20422ed431a03ac1bc755b5`。安装版从截图页进入 Provider 二级页后，中文说明已显示为普通用户语言，侧栏选中、返回、输入控件和值尾列几何稳定。
- Computer Use 首次读取该窗口的 AX 树时仍同步产生 3 组 `ThemeWidgetControlViewService` 负尺寸诊断；其时间线与既有最小 SwiftUI 对照一致，只发生在 AX 控制通道读取时，未观察到对应可见错位、卡顿或崩溃。它继续作为 macOS 26 AppKit／AX 工具链边界记录，不伪装成 Blocks 业务视图已修复或新回归。
