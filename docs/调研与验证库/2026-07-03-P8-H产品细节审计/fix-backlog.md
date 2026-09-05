# P8-H 修复 Backlog

状态：draft
原则：每项必须有复现证据、根因判断、修复方向和验收标准。未开发项不得写成已关闭。

## P0 / P1

### P1-01 Clipboard 浮层入口不稳定

来源反馈：类似细节很多，需要仔细 check。

复现：

- 当前 App 前台按 `Control + Option + V` 未打开 Clipboard 浮层。
- 通过状态菜单点击 `剪贴板` 后，也未观察到浮层出现。

代码线索：

- `MenuBarCommandsView` 的 `剪贴板` 菜单项调用 `appState.showClipboardFloatingPanel`。
- `ClipboardHistoryPanelPresenter.present` 打开 panel 后立刻启动 outside click dismiss monitor，且调用 `NSApp.activate(ignoringOtherApps: true)`。

推断根因：

- 状态菜单 click 事件可能在新 panel 打开后被 global dismiss monitor 识别为外部点击。
- 快捷键路径可能存在注册状态和前台窗口焦点冲突。

修复方案：

- 为 panel presenter 增加 `openSource`：keyboard / statusMenu / settingsPreview。
- 状态菜单路径延迟一轮 runloop 后启动 dismiss monitor，避免打开事件反向关闭 panel。
- 打开 Clipboard panel 时不激活主窗口，不 order out 正在需要对照的普通窗口，除非明确从浮层设置按钮进入设置。
- Shortcuts 页面显示实时 registration result 和最近触发时间。

验收标准：

- `Control + Option + V` 在 Blocks 前台、TextEdit 前台、System Settings 非前台三种情况下都能打开或聚焦 Clipboard panel。
- 状态菜单 `剪贴板` 能打开 panel。
- 打开后点击外部才关闭，打开瞬间不能自关。

本轮处理记录（2026-07-03）：

- 已修复：`ClipboardHistoryPanelPresenter` 打开浮层后延迟启动 outside-click monitor，避免打开事件被反向识别为外部点击。
- 已修复：默认快捷键迁移升级到 `Control + Option + A/V/D`，并补充 `.v2` 迁移键，清理历史 `Option` 默认残留。
- 已验证：稳定签名开发版运行后，`Control + Option + V` 触发 `剪贴板历史` 浮层窗口。
- 待补验：TextEdit 前台、System Settings 非前台和状态菜单入口仍需下一轮真实交互复测。

状态：partial implemented / pending broader interaction verification

### P1-02 Settings 内容区不是 Apple 风格设置行

来源反馈：

- “菜单内容不会随着窗口自适应；菜单内容应该是用左右布局，将开关/内容放在单行的右边；菜单内容每一行有分隔符，像苹果一样。”

复现：

- [02-clipboard-settings.png](screenshots/02-clipboard-settings.png) 显示 Clipboard 设置页仍是纵向控件堆叠。

代码线索：

- `SettingsView.swift` 中各页面直接把 `Picker` / `Toggle` / `Button` 放进 `SettingsSection`。
- `SettingsSection` 只有标题 + VStack content，没有 row abstraction。

修复方案：

- 新增 `SettingsTableSection` 和 `SettingsFormRow`：
  - 左侧：小图标、主标题、可选说明。
  - 右侧：Toggle / Picker / Button / Value / Status。
  - 每行固定最小高度 34-40，行间用 hairline divider。
  - control 区固定对齐右侧，宽窗口时拉开，窄窗口时保持可读换行。
- Clipboard、Shortcuts、Permissions、Providers 先迁移到新行模型。
- `SettingsSection` 不再默认给每个 section 放同一个 `slider.horizontal.3` 图标。

验收标准：

- Clipboard 设置页每个主要设置项都是一行，control 在右侧。
- 行与行之间有细分隔符。
- 窗口变宽时，label/control 距离自然拉开；窗口变窄时不会挤压到不可读。

本轮处理记录（2026-07-03）：

- 已修复：Clipboard 设置页改为 `SettingsTableSection` / `SettingsFormRow` / `SettingsActionRow`，主要 control 移到单行右侧。
- 已修复：行间加入 hairline divider，保留左侧 icon badge、主标题和次级说明。
- 已验证：运行态进入 Clipboard 设置页后可看到保留策略、面板显示、筛选行为、固定分组等已按行布局呈现。
- 范围说明：本轮先迁移 Clipboard 设置页；Shortcuts / Permissions / Providers 的完整 row-level 产品化仍留后续切片。

状态：partial implemented / Clipboard page verified

## P2

### P2-01 侧边栏图标和行距偏大

来源反馈：

- “菜单栏图标感觉有点大，行间距也有点大。”

复现：

- [01-settings-screenshot-page.png](screenshots/01-settings-screenshot-page.png) 显示侧边栏 icon badge 和行高偏展示化。

代码线索：

- `SidebarIconBadge` 为 28x28。
- `SidebarSectionButton` 最小高度 44。
- group spacing 为 18。

修复方案：

- 将 icon badge 调整为 22x22 或 24x24。
- 行高调整为 34-38。
- group spacing 调整为 12-14。
- 选中态从厚 rounded card 改为更轻的系统 sidebar selection。

验收标准：

- 13 寸窗口高度下所有一级设置项可完整浏览，滚动更少。
- 侧边栏视觉权重低于 detail 内容。

本轮处理记录（2026-07-03）：

- 已修复：侧边栏宽度从 248 调到 224，icon badge 从 28x28 调到 24x24，行高从 44 调到 36，分组间距同步收紧。
- 已验证：运行态侧边栏视觉权重降低，菜单项不再像大卡片。

状态：implemented

### P2-02 Clipboard 设置页应优先调整高度，不应突出位置

来源反馈：

- “粘贴板里面，需要调整面板的高度，不需要调整面板的位置。”

复现：

- Clipboard 设置页当前直接显示 `剪贴板面板位置：底部 / 左侧 / 右侧`。

修复方案：

- Clipboard 主设置页的 `Panel Display` 改为：
  - `Panel height`：滑杆或分段选项，默认、中、高。
  - `Show height handle`：是否允许在浮层顶部拖动高度。
  - `Reset panel height`。
- `bottom / left / right` 移到 `Advanced layout` 折叠区域，默认不显示或标记实验性。

验收标准：

- 用户进入 Clipboard 设置页第一眼看到的是高度与显示密度，不是位置模式。
- bottom 主路径不会被 left/right 模式干扰。

本轮处理记录（2026-07-03）：

- 已修复：Clipboard 设置页首屏改为 `Panel height` 滑杆和 `Reset panel height`。
- 已修复：`bottom / left / right` 位置选择移入 `Advanced layout` 折叠区，不再作为主设置优先项。

状态：implemented

### P2-03 Clipboard 筛选展开方式错误

来源反馈：

- “筛选项展开不是另一行展开，而是图标向右展开，并将其他图标向右挤压。”

复现：

- 当前实现中 `expandedFilterOptions` 位于 header 下方，会生成第二行。

修复方案：

- 删除 header 下方 `expandedFilterOptions` 独立行。
- 重建 `filterStrip`：
  - compact：每组只显示图标。
  - hover / active：当前组变成横向 expanded chip，内部展示该组可选项。
  - 其他组保持 compact，并在同一行被推到右侧。
  - 超出宽度时整条 filter strip 横向滚动，不换行。

验收标准：

- hover 格式筛选时，格式选项在同一行展开。
- 时间 / 分组 / 来源筛选同样同一行展开。
- 搜索框到卡片 tray 的垂直距离减少，不再出现第二行导致的空白。

本轮处理记录（2026-07-03）：

- 已修复：删除独立第二行筛选展开路径，filter strip 改为同一横向行内展开。
- 已修复：hover / click 当前筛选组时，该组在原位置扩展为横向 chip，其他筛选图标被推到右侧。
- 已验证：构建通过；运行态截图显示搜索框与筛选按钮同在顶部紧凑区域。

状态：implemented / visual follow-up recommended

### P2-04 Clipboard 条目应内容优先，图片应显示缩略图

来源反馈：

- “粘贴面板的条目需要实现内容，如果是图片需要显示图片。”

当前事实：

- 代码已支持 `preview.image`，但只有 fixture-owned PNG payload 会生成图片。
- 文本 / URL 当前依赖 `summary` 和 fixture payload，真实不可恢复记录仍是摘要。

修复方案：

- 定义 `ClipboardCardContentModel`：
  - text：直接显示文本片段。
  - rich text：显示带格式摘要和文本片段，后续再加富文本预览。
  - image：若有本地 payload/thumbnail，展示缩略图；否则展示“图片 · 未保存缩略图”。
  - url：显示 host + path，默认不联网解析。
  - file：显示文件名/数量，不显示完整路径。
  - excluded：只显示来源和时间占位。
- 真实图片缩略图需要数据层支持，不得凭空显示。

验收标准：

- Fixture 图片卡片在面板中展示图片，不只是 photo 图标。
- 文本卡片第一视觉是内容片段，不是格式说明。
- 不可恢复真实图片有明确状态，不伪装成已显示图片。

本轮处理记录（2026-07-03）：

- 已验证：当前 fixture 图片卡片已能在底部 tray 内显示缩略图，不再只是普通说明文本。
- 已确认限制：真实用户图片是否可显示缩略图取决于 recorder/store 是否保存安全 thumbnail；该数据层能力不能用 UI 伪造。

状态：partial verified / real-data thumbnail pipeline pending

### P2-05 Hover detail 的位置和裁切需要重新验证

来源反馈：

- 之前已提出 hover detail 要跟鼠标且不能被面板裁切。

当前事实：

- 代码用 SwiftUI `.popover` 绑定 hover。
- 对底部 panel 卡片使用 `arrowEdge: .bottom`，位置由系统决定，仍可能与 panel 或屏幕边缘冲突。

修复方案：

- 改为自管 `NSPanel` 或 anchor-aware popover controller：
  - 以鼠标位置 / 卡片 global frame 计算详情位置。
  - 优先显示在卡片上方。
  - 边界避让屏幕可见区，不被 Clipboard panel 裁切。

验收标准：

- 第一张、最后一张、靠屏幕边缘的卡片 hover detail 都完整可见。
- 鼠标移动到相邻卡片时 detail 跟随切换，不闪烁。

状态：pending

## P3

### P3-01 P8-G 验收语言过乐观

问题：

- P8-G 完成的是 settings shell，不是完整 Apple 风格页面系统。
- 用户反馈显示“整体美化”没有完成，验收记录中也写了 full visual redesign deferred。

修复方案：

- 在看板和后续 story 中明确：P8-H1 才是 row-level settings productization。
- 不再用静态脚本替代真实截图复核。

验收标准：

- 每个 P8 UI story 都必须有运行态截图和人工视觉检查项。

本轮处理记录（2026-07-03）：

- 已修正 backlog 口径：本轮只关闭 Clipboard 设置页行模型、侧边栏密度、Clipboard 浮层入口迁移和同排筛选，不把完整 Apple 风格页面系统写成已完成。

状态：partially addressed

## 建议执行顺序

1. P8-H1：Settings Form System
   - 先修侧边栏密度、设置行模型、Clipboard 设置页高度设置。
2. P8-H2：Clipboard Panel Entry + Inline Filters
   - 先修入口稳定，再改 filter strip 同行展开。
3. P8-H3：Clipboard Content Cards
   - 按内容模型逐类重做卡片渲染，先文本/URL/image fixture，再扩展真实可恢复图片。
4. P8-H4：Screenshot-based visual QA
   - 每次改完用同一窗口尺寸截图，对照 P8-F 规范和本 backlog 验收。
