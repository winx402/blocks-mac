# P8-H 体验审计报告

状态：draft
日期：2026-07-03
审计方式：当前稳定签名 App 真实运行观察 + 代码路径核对

## 1. 审计环境

- App：`/Users/bot/Applications/BlocksDev/Debug/Blocks.app`
- Bundle ID：`app.blocks.app`
- 运行方式：`./script/build_and_run.sh --verify`
- 当前可靠快捷键基线：`Control + Option + A/V/D`
- 本轮未新增功能代码，只记录问题、原因和修复方案。

## 2. 证据索引

| 编号 | 截图 | 说明 |
| --- | --- | --- |
| E-01 | [01-settings-screenshot-page.png](screenshots/01-settings-screenshot-page.png) | 主窗口 Screenshot 页。P8-G 后 shell 已分组，但内容区仍是大卡片和阶段化文案。 |
| E-02 | [02-clipboard-settings.png](screenshots/02-clipboard-settings.png) | Clipboard 设置页。控件仍纵向堆叠，没有形成 Apple 风格左右设置行。 |

## 3. 运行态观察

### 3.1 Settings 侧边栏

事实：

- 侧边栏 badge 尺寸为 28x28，行最小高度为 44。
- 分组间距为 18，组内 spacing 为 7，按钮自身还有外部 padding。
- 运行态视觉上，图标和行距比系统设置更“粗”，左侧菜单占用纵向空间偏多。

代码证据：

- `ContentView.swift` 中 `SidebarSectionButton` 使用 `minHeight: 44`。
- `SidebarIconBadge` 使用 `.frame(width: 28, height: 28)`。

产品影响：

- 侧边栏密度低，视觉权重压过 detail 内容。
- 对高频设置工具来说，导航应清晰但克制；当前更像展示卡片，不像设置导航。

### 3.2 Settings 内容区

事实：

- Clipboard 设置页中，保留时间、最大条目、清理固定条目、应用策略、面板位置、筛选行为等控件都堆在 section 内。
- 控件没有统一右对齐，也没有每行分隔符。
- section 仍是厚卡片：图标、标题和内容包在一个 rounded surface 里。

代码证据：

- `SettingsView.swift` 中 Clipboard 页直接在 `SettingsSection` 里放 `Picker`、`Toggle`、`Text`、`HStack Button`。
- `SettingsSection` 使用固定 icon `slider.horizontal.3`，导致不同设置区图标语义不一致。

背后原因：

- 当前没有统一的 `SettingsFormRow` / `SettingsTableSection` 抽象。
- P8-F 已定义“设置行模型”，但 P8-G 只做 shell，没有改逐页内容结构。

产品影响：

- 页面不能随窗口宽度自然适配。
- 用户扫视成本高：左侧 label 和右侧 control 没有稳定锚点。
- 看起来像工程调试面板，而不是 macOS 设置页。

### 3.3 Clipboard 设置页的“位置”设置

事实：

- 当前 Clipboard 设置页仍把 `底部 / 左侧 / 右侧` 作为主要 segment 展示。
- 最新反馈要求 Clipboard 里需要调整面板高度，不需要调整面板位置。

判断：

- 需要区分“主设置”和“高级布局模式”。
- V1 主路径应固定为 bottom tray，设置页只暴露高度、卡片大小、筛选清空策略等与主路径相关的设置。
- left/right 可以保留，但应收进高级或实验区域，避免和主体验冲突。

### 3.4 Clipboard 浮层入口

事实：

- 在当前 App 前台执行 `Control + Option + V`，未打开 Clipboard 浮层。
- 通过状态菜单点击 `剪贴板` 后，Computer Use 仍只看到主窗口，未观察到浮层窗口。
- 状态菜单确实存在 `剪贴板` 菜单项。

推断：

- 可能存在快捷键注册焦点问题、状态菜单触发后 panel 立即被 dismiss monitor 关闭、或 `NSApp.activate / orderOutRegularAppWindows` 与状态菜单事件冲突。
- 这不是视觉 polish，可以直接影响用户打开核心工具。

处理原则：

- 进入 P8-H 的 P1 修复，先保证入口稳定。
- 修复时需要把“打开来源”区分为 keyboard / status menu / settings preview，并避免当前点击事件触发新 panel 的 outside-click dismiss。

### 3.5 Clipboard 条目内容与图片展示

事实：

- 代码已有 `ClipboardRecordPreview` 与 `ClipboardContentThumbnail`。
- 图片只在 `fixtureOwned` 且存在 `pngDataBase64` 的 payload 时渲染为 `NSImage`。
- 非 fixture 的真实用户图片当前只有摘要，不会显示图片。

判断：

- 对 V1 体验而言，条目卡片必须先显示“内容本身”：文本内容、富文本视觉、图片缩略图、URL 主信息、文件名。
- 但真实用户图片缩略图需要数据策略支撑。若未来记录可恢复图片 payload，就可以在本地显示缩略图；若仍只保存 redacted summary，则无法凭空展示真实图片。

验收标准：

- Fixture / 可恢复图片：卡片展示图片缩略图。
- 不可恢复真实图片：卡片必须清楚显示“图片摘要 / 未保存缩略图”，不能只显示泛用说明。
- 文本 / 富文本：直接展示内容片段，而不是“fixture placeholder”类说明。

### 3.6 Clipboard 筛选展开

事实：

- 当前 `ClipboardFloatingPanelView` 中 `filterStrip` 是第一行图标。
- `expandedFilterOptions` 是单独视图，放在 header 下方，因此展开会成为第二行。

与产品期望冲突：

- 期望是“筛选项图标向右展开，并将其他图标向右挤压”，不应新开一行。

修复方向：

- 把展开内容纳入同一个 horizontal layout。
- 当前展开组从 compact button 变为 `expanded filter group chip`，内部横向展示选项。
- 其他 filter icon 保持在同一行右侧，被自然挤压；超宽时横向滚动或收缩，不新增第二行。

### 3.7 旧验收与当前现实的偏差

事实：

- P8-G acceptance record 明确写了 `Full Settings visual redesign` 为 `deferred`。
- 当前用户反馈正是 deferred 的部分。

处理：

- P8-H 不应继续把 shell redesign 说成“完成整体美化”。
- 后续实现必须以真实截图人工复核为 gate，而不是只通过静态脚本。

## 4. 结论

P8-H 应拆成两个实现切片：

1. **P8-H1 Settings Form System**：压缩侧边栏、重建设置行模型、把 Clipboard 设置页改成 Apple 风格左右行。
2. **P8-H2 Clipboard Panel System**：修复浮层入口稳定性、改 inline filter expansion、把条目渲染从摘要说明推进到内容优先。

这两项应先于新增 Pinboard / Stack / Agent 授权细节继续推进，否则 UI 复杂度会继续叠在不稳定的基础上。
