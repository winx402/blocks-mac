# P8-F 页面布局与视觉规范方案

状态：pending review
创建日期：2026-07-03
适用范围：Blocks 正式 macOS App 主窗口、设置页、Clipboard 浮层、Translation 浮层、Screenshot 入口与结果浮层

## 0. 本轮边界

本轮只产出方案和规范，不进入开发。本文不是最终高保真设计稿，也不替代现有 V1 PRD / UX Spec；它是后续 P8-G / P8-H / P8-I 实现的评审基线。

参考来源：

- Apple Human Interface Guidelines: [Foundations](https://developer.apple.com/design/human-interface-guidelines/foundations)
- Apple Human Interface Guidelines: [macOS](https://developer.apple.com/design/human-interface-guidelines/macos)
- Apple Human Interface Guidelines: [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- Apple Human Interface Guidelines: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- Apple Human Interface Guidelines: [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- Apple Developer Documentation: [SwiftUI `glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:isenabled:))

说明：Apple 文档页面为动态站点，本轮采用其稳定的设计原则作为约束：原生控件优先、内容优先、清晰层级、低打扰、平台一致性、可访问性和系统材质渐进增强。

## 1. 当前页面问题诊断

### 1.1 事实

- 当前主窗口使用固定左侧栏 + detail 结构：`ContentView` 中左侧宽度为 220，右侧根据 `AppSection` 切换 `ScreenshotHomeView` 或不同 mode 的 `SettingsView`。
- 当前侧边栏已有彩色图标 badge，但所有入口在同一层级里平铺：Screenshot、Clipboard、Clipboard Privacy、Translation、Shortcuts、Providers、Permissions、Settings。经用户确认，Clipboard Privacy 不应作为一级侧边栏入口；它属于 Clipboard 内的隐私排除子页面。
- 当前 Settings 内容由一个长 `ScrollView` 和多个 `SettingsSection` 组成；不同页面 mode 通过 `showsClipboard`、`showsProviders` 等布尔控制同一个视图。
- Clipboard 浮层已经进入 P8-B/E：搜索 + 顶部筛选图标组 + 横向卡片 tray + hover detail + context menu。
- Translation 浮层已经是左右分割结构，但 header、语言选择、状态信息和调试信息仍有工程化痕迹。

### 1.2 推断

- 现在的问题不是单个按钮样式，而是缺少一套统一的页面系统：导航层级、设置表单、浮层、状态文案、材质使用和图标语义没有被同一套规范约束。
- `SettingsView` 继续用一个大文件承载所有设置，会让布局、滚动、分区和视觉样式越来越难统一。
- Apple 风格不是“更多毛玻璃”或“更像 System Settings 的图标”，而是稳定的层级、克制的材料、原生控件和明确任务路径。

### 1.3 主要问题

| 编号 | 问题 | 背后原因 | 影响 |
| --- | --- | --- | --- |
| UX-01 | 主侧边栏分类语义不稳定 | 工具入口和设置入口混在同一层，但 Clipboard / Translation 的主入口实际是浮层 | 用户不知道点击侧边栏是打开工具还是配置工具 |
| UX-02 | Settings 内容像堆叠表单 | 各设置项按实现阶段堆在一个 `ScrollView`，缺少页面级任务结构 | 页面显得不高级，滚动和查找成本高 |
| UX-03 | 图标与内容区风格不一致 | 侧边栏有彩色 icon badge，内容区仍是普通 Label / Toggle 混排 | 左右视觉语言割裂 |
| UX-04 | Provider / Agent / OCR / Translation provider 边界不清 | Provider 页面承载 LLM、翻译、OCR、CLI、Keychain、测试连接和诊断 | 用户无法快速判断要配置哪类服务 |
| UX-05 | Clipboard / Translation 浮层仍有工程残留 | route、diagnostic、audit、fixture 等信息容易进入主视觉 | 高频工具不像工具，更像调试面板 |
| UX-06 | 材质层级不清 | `.ultraThinMaterial`、glass surface、section card 容易叠加 | 看起来厚、灰、闷，而不是轻的系统玻璃 |
| UX-07 | 设置项缺少统一行模型 | picker、toggle、button、说明文字随意堆叠 | 信息密度和对齐不稳定 |
| UX-08 | 状态和错误文案没有分层 | 普通状态、诊断、高风险确认放在同一视觉层 | 用户容易忽略真正重要的权限/外发/删除风险 |

## 2. 设计目标

P8-F 后续实现要达到三个目标：

1. **像一个 macOS 系统工具**：结构稳定、控件熟悉、内容密度高，但不凌乱。
2. **三大工具各自清楚**：Screenshot、Clipboard、Translation 都有独立设置页和独立浮层，主窗口不再混淆“工具入口”和“设置入口”。
3. **诊断退到二级**：provider route、audit id、fixture、adapter、runtime gate 等工程信息默认折叠，只在高级或详情里出现。

## 3. 总体信息架构

### 3.1 主窗口侧边栏

建议将主窗口定义为 **Settings / Control Center hybrid**，不再叫“工具主页”。侧边栏使用分组，但每组标准明确。

| Group | Items | 说明 |
| --- | --- | --- |
| Tools | Screenshot, Clipboard, Translation | 三大工具的配置与状态页。真正高频操作仍由快捷键/菜单栏浮层触发。 |
| System | Shortcuts, Permissions | 系统级输入和权限。 |
| Intelligence | Providers, Agent & CLI, Hooks | LLM / 翻译 / OCR provider、agent 访问、hook 草稿。 |
| Data | Data & Audit | 历史清理、审计、导出和数据管理。 |
| App | General | 语言、外观、关于、诊断。 |

为什么恢复 `Tools` 分组：之前的问题是“Tools 里只有 Screenshot”，语义不完整。解决方式不是永久取消分组，而是让 Screenshot / Clipboard / Translation 三个工具都进入 Tools，并明确它们是设置/状态页，不是浮层本身。

### 3.2 顶部状态区

侧边栏顶部保留轻量状态区，但不做大 logo。

建议内容：

- App icon + “积木工具”
- 小状态 badge：`Ready` / `Recorder Paused` / `Permission Needed`
- 当前快捷键摘要：`⌃⌥A / ⌃⌥V / ⌃⌥D`

不放：

- 产品口号
- P 阶段名
- 大面积品牌色
- provider / audit 调试信息

### 3.3 页面路由

| Route | 页面职责 | 主行动 |
| --- | --- | --- |
| Screenshot | 截图模式、结果行为、权限状态、AI 入口偏好 | Start Region Capture |
| Clipboard | 记录策略、面板显示、筛选行为、Pinboards、Stack / 编辑候选 | Open Clipboard Panel |
| Translation | 默认语言、剪贴板预填、自动翻译、结果行为 | Open Translation Panel |
| Shortcuts | 全局修饰键、单功能快捷键、冲突状态 | Restore Defaults |
| Permissions | Screen Recording、Accessibility、Login Item、文件访问 | Open System Settings |
| Providers | LLM / Translation / OCR / CLI profile 管理 | Test Connection |
| Agent & CLI | CLI 能力、MCP/agent 读取授权、范围/时长 | Review Access |
| Hooks | Draft / Enabled / Disabled hook 管理 | Review Draft |
| Clipboard > Privacy | 从 Clipboard 页点击 `Manage Excluded Apps...` 进入；App 列表 toggle、最近来源 App、手动 bundleId 高级入口；顶部可返回 Clipboard | Add App |
| Data & Audit | 历史清理、审计列表、导出/删除 | Clear Selected Data |
| General | 语言、外观、更新、关于 | None |

## 4. 视觉系统规范

### 4.1 页面尺寸

| Surface | 推荐尺寸 |
| --- | --- |
| Main window min | 980 x 680 |
| Main window preferred | 1080 x 740 |
| Sidebar width | 248 |
| Detail max content width | 760 到 840 |
| Settings row min height | 44 |
| Sidebar row height | 46 |
| Floating panel header height | 42 到 48 |

主窗口 detail 不应贴顶。页面标题区顶部留白 24，内容区左右留白 28。

### 4.2 材质与层级

| Layer | Material | 用法 |
| --- | --- | --- |
| Window background | `.windowBackground` / clear glass fallback | 主窗口底色，不承载内容 |
| Sidebar | sidebar material / `.ultraThinMaterial` | 左侧导航，只一层 |
| Detail page | transparent / grouped background | 不做整页卡片 |
| Section group | light grouped surface | 每组设置一层，不嵌套卡片 |
| Floating panel | glass container | Clipboard / Translation / Screenshot result |
| Popover / confirmation | stronger material + border | hover detail、确认卡片、权限辅助 |

规则：

- 不在 section 内再套 glass card：`SettingsGroup` 本身可以有一层很轻的 grouped surface，但组内每一行不要再包一层玻璃卡片。否则会变成“卡片里面套卡片”，材质采样重复、边框太多、页面发灰发厚。
- 不给每个 row 单独加玻璃。
- 毛玻璃只用于“浮在当前任务之上”的临时层；设置页主要靠分组和留白。
- macOS Reduce Transparency 或系统玻璃本身克制时，允许透明感较弱，不用自绘伪玻璃。

### 4.3 色彩

侧边栏图标可以彩色，但要使用系统风格的小色块，不做大渐变。

建议语义：

| 功能 | 色彩 |
| --- | --- |
| Screenshot | Orange |
| Clipboard | Mint / Green |
| Translation | Indigo / Blue |
| Shortcuts | Purple |
| Permissions | Red |
| Providers | Teal |
| Agent & CLI | Cyan |
| Hooks | Pink / Red only when enabled risk |
| Data & Audit | Gray / Blue |
| General | Gray |

内容区 section icon 使用同一色彩系统，不能一边是彩色 badge，一边是普通黑白 Label。

### 4.4 字体

| Role | Size / Weight |
| --- | --- |
| Page title | 28 / semibold |
| Section title | 13 / semibold |
| Row title | 13 / regular or medium |
| Row secondary | 11-12 / regular |
| Toolbar / badge | 11-12 / medium |
| Monospace metadata | 11-12 / SF Mono |

不要在设置页大面积使用 headline。紧凑页的高级感来自对齐和层级，不来自大字。

## 5. Settings 页面规范

### 5.1 页面骨架

每个设置页统一：

```text
Detail Page
├── PageHeader
│   ├── icon badge
│   ├── title
│   ├── one-line purpose
│   └── optional primary action
├── StatusBanner?        // only if attention is needed
├── SettingsGroup*
│   ├── group title
│   ├── SettingsRow*
│   └── group footnote?
└── AdvancedDisclosure?  // diagnostics, audit id, raw ids
```

### 5.2 SettingsGroup

每组应是“用户任务”而不是“实现对象”。

示例：

- Clipboard → `Recording`、`Panel`、`Filters`、`Pinned Groups`、`Data`
- Providers → `Model Services`、`Translation Services`、`OCR Services`、`Local CLI`、`Advanced Diagnostics`
- Permissions → `Required for Screenshot`、`Required for Auto Paste`、`Optional Background Items`

### 5.3 SettingsRow

统一行模型：

```text
Icon  Title + secondary description             Control / Status
```

规则：

- 左侧 icon 20 或 24，使用与 sidebar 一致的色彩语义。
- title 不超过一行；secondary 最多两行。
- 控件右对齐，宽度稳定。
- Toggle / Picker / Segmented / Button 不混排在同一行，除非是明确的复合设置。
- 高级诊断永远进入 Disclosure，不占默认首屏。

### 5.4 Clipboard 设置页

页面分区：

1. **Recording**
   - Retention：segmented `7 / 30 / 90 / Forever`
   - Max Items：segmented `200 / 500 / 1000 / 2000`
   - Preserve pinned：toggle
   - 清理影响摘要

2. **Panel**
   - Position：bottom / left / right
   - Bottom height：仅 bottom 可见
   - Left/right width：仅侧边模式可见

3. **Filters**
   - Clear filters after close：immediately / 15s / 30s / 1m / never
   - Remember search：toggle
   - Show active labels：toggle

4. **Pinned Groups**
   - Group list：name / color / count
   - Create group
   - Rename / reorder 进入二级 sheet

5. **Stack & Editing**
   - Paste Stack：toggle + ordering behavior
   - Text/Rich Text editing：toggle / entry point
   - Image editing：disabled with “Later”

6. **Data**
   - Clear unpinned
   - Export summary
   - Advanced diagnostics disclosure

隐私排除不要作为主侧边栏一级入口，也不要把完整 App 列表塞进 Clipboard 页主体。Clipboard 页只放一个入口：`Manage Excluded Apps...`。点击后进入 Clipboard 的二级子页面 `Clipboard Privacy`，顶部提供返回 Clipboard。

### 5.5 Clipboard Privacy 子页面

页面目标：让用户不需要理解 bundleId 也能管理排除 App。

布局：

```text
Back: Clipboard
PageHeader: Clipboard Privacy
Search apps...

Recently Seen
  AppRow icon name bundleId source lastSeen toggle

Suggested Sensitive Apps
  Password managers / Messages / Mail / Browsers

Manual Bundle Identifier
  Disclosure
```

AppRow 规则：

- 主信息：App icon + App name
- 次信息：bundleId、最近记录时间、来源
- 右侧：toggle
- 行高：52
- bundleId 只作为 secondary，不让用户默认编辑。

### 5.6 Providers 页面

Provider 不能只按技术实现分组。建议按能力分：

1. **Model Services**
   - OpenAI-compatible
   - LiteLLM / Gateway
   - Local Mock

2. **Translation Services**
   - LLM-backed translation
   - Dedicated translation API
   - Local Mock

3. **OCR Services**
   - Apple Vision
   - Cloud OCR
   - Local Mock

4. **Local CLI**
   - Codex / Claude Code / Copilot / Qoder / opencode
   - CLI path / detected status / test command

5. **Secrets**
   - Keychain alias
   - Save / Verify / Delete

6. **Advanced**
   - route resolution
   - raw error code
   - audit id

默认页面只展示 readiness 和简短错误，不展示 adapter、fixture、schema 等内部词。

### 5.7 Shortcuts 页面

不要用长堆叠卡片。使用紧凑表格：

| Function | Effective Shortcut | Source | Enabled | Conflict | Actions |
| --- | --- | --- | --- | --- | --- |
| Screenshot | Control + Option + A | Global | On | None | Record / Reset |
| Clipboard | Control + Option + V | Global | On | None | Record / Reset |
| Translation | Control + Option + D | Global | On | None | Record / Reset |

顶部放全局修饰键：

- Global modifier: Control + Option / Option / Control / Shift / Command / Custom combo
- 单功能自定义优先级高于 global。

### 5.8 Permissions 页面

权限页按“任务需要什么”分组：

1. **Screenshot**
   - Screen Recording
   - status / current app path / request / check again

2. **Clipboard Auto Paste**
   - Accessibility
   - status / request / pending paste retry

3. **Background Recorder**
   - Login Item
   - helper status

4. **Diagnostics**
   - signing identity
   - Team ID
   - bundle id
   - app path
   - TCC caveat

Permission Assist 只在用户点击授权后出现，不常驻设置页。

## 6. 主工具页面规范

### 6.1 Screenshot 页面

主页面不再写 `P3-B` 等阶段名。改为任务语言。

结构：

```text
Screenshot
Capture a region, window, or display.

[Region] [Window] [Fullscreen]       Status: Screen Recording granted

Recent Captures
  compact list: mode / size / time / last action

AI Actions
  OCR / Translate / Summarize route-ready cards
```

注意：

- 结果浮层仍是主体验，主页面只是状态和入口。
- 权限缺失时页面顶部用 banner，不让用户点击后才失败。

### 6.2 Clipboard 页面

Clipboard 页面是设置/状态页，不是历史主面板。

主行动：

- `Open Clipboard Panel`
- `Pause / Resume Recording`

页面主体：

- Recorder status
- Recent summary counts
- Policy summary
- Pinned groups preview
- Link to Privacy Exclusions

真正历史浏览在 `Control + Option + V` 浮层里。

### 6.3 Translation 页面

Translation 页面是偏好/状态页，不是翻译工作台。

主行动：

- `Open Translation Panel`

页面主体：

- Clipboard prefill setting
- Default target language
- Auto-detect behavior explanation
- Selected translation engine summary
- Runtime gate state

真正翻译在 `Control + Option + D` 浮层里。

## 7. Floating Panel 规范

### 7.1 通用规则

浮层是临时工具，不是普通窗口。

规则：

- 点击外部关闭。
- Esc 关闭。
- 右上角设置按钮进入对应设置页。
- 打开 Clipboard 时关闭 Translation；打开 Translation 时关闭 Clipboard。
- 不主动把 Settings 窗口一起带到前台。
- 高级/诊断信息默认折叠。

### 7.2 Clipboard bottom panel

保留 P8-B/E 方向，但进一步规范：

```text
Bottom Tray
├── Top bar: search + filter icon groups + clear filters + settings + close
├── Expanded filter row? only while hover/active
├── Horizontal card tray
└── No persistent footer
```

卡片：

- 主信息：内容预览
- 次信息：时间
- 小图标：格式 / pinned / excluded
- 不常驻显示 source、hash、bundleId、restore 状态
- 右键菜单：paste、copy plain text、pin/unpin、move group、rename、delete

Hover detail：

- 跟随卡片锚点或鼠标附近。
- 不被 panel 边界裁切。
- 展示来源、格式、大小、可恢复、hash、URL 本地解析等次级信息。

### 7.3 Translation panel

结构：

```text
Header: title + auto translate state + settings + close

Language row aligned to text panes:
[Source picker / detected source]   [swap]   [Target picker]

Split body:
left source editor                 right result

Footer:
short status / copy / replace clipboard / details disclosure
```

规则：

- 译文是右侧主体，不被 route/audit 抢占。
- `auto` 左侧应显示检测到的有效语言。
- 交换按钮是双向箭头，不是“结果”文字。
- 输入变更 debounce 自动翻译，不要求手动点击。
- 错误只显示短文案，route/audit 进入 details。

### 7.4 Screenshot result panel

结构：

```text
Preview image
Metadata: mode / size / source / time
Actions: Copy / Save As / Retake / Close
AI row: OCR / Translate / Summarize
```

规则：

- 图片预览优先，按钮靠近预览底部。
- AI action 是次级，不压过 Copy / Save。
- 权限/失败状态使用 banner，不显示空白预览。

## 8. Component Library 草案

后续开发应先抽组件，再改页面。

| Component | 用途 | 关键参数 |
| --- | --- | --- |
| `AppSidebar` | 主窗口左侧导航 | groups, selectedRoute, statusBadge |
| `AppSidebarRow` | 单个菜单项 | icon, color, title, subtitle?, badge? |
| `PageHeader` | 设置页/工具页顶部 | icon, title, subtitle, primaryAction? |
| `SettingsGroup` | 设置分组 | title, footer?, rows |
| `SettingsRow` | 标准设置行 | icon, title, detail, control, status |
| `StatusBanner` | 权限/外发/失败提醒 | level, title, detail, action |
| `InlineDisclosure` | 高级诊断 | title, content |
| `GlassFloatingPanel` | Clipboard/Translation/Result | material, closeBehavior, sizePolicy |
| `ContentCard` | Clipboard 条目 | preview, kind, time, badges |
| `HoverInspector` | Hover 详情 | anchor, content, screenClamp |
| `ProviderServiceCard` | provider profile | capability, status, action |
| `PermissionAssistOverlay` | 权限辅助 | sessionState, targetFrame, arrowDirection |

## 9. 文案规范

### 9.1 禁止默认出现的工程词

默认 UI 不出现：

- P3 / P4 / P5 / P8 阶段名
- fixture
- adapter
- route resolution
- schema
- smoke
- runtime gate
- debug path
- audit_id

这些词只能在 Advanced / Diagnostics / Developer Details 里出现。

### 9.2 用户任务语言

| 工程词 | 用户文案 |
| --- | --- |
| Recorder runtime gate | Clipboard Recording |
| Provider route resolution | Service status |
| External transfer confirmation | Send text to service |
| Fixture record | Sample item |
| Audit event | Activity record |
| Unsupported capability | Not available for this service |

## 10. 开发拆分建议

### P8-G Settings Shell Redesign

目标：统一主窗口侧边栏、页面 header、SettingsGroup / SettingsRow。

范围：

- 新 `AppSidebar` 分组模型。
- 新 `PageHeader`、`SettingsGroup`、`SettingsRow`。
- 重排 Screenshot / Clipboard / Translation / Shortcuts / Permissions / Providers / General。
- 不改业务逻辑。

验收：

- 侧边栏分组语义清晰。
- 所有页面顶部留白稳定。
- 内容区可滚动，滚动条可见。
- 工程词默认不出现。

### P8-H Floating Panel Visual System

目标：统一 Clipboard / Translation / Screenshot result 的浮层骨架。

范围：

- `GlassFloatingPanel`
- `HoverInspector`
- Clipboard hover detail 防裁切
- Translation language row 对齐
- Screenshot result action hierarchy

验收：

- 三个浮层都有一致关闭/设置/外部点击行为。
- 主内容优先，诊断信息折叠。
- macOS 26 和旧系统材质回退都可读。

### P8-I Provider / Agent / Privacy Productization

目标：把 provider、agent、隐私排除做成用户可理解的设置。

范围：

- Providers 按 Model / Translation / OCR / Local CLI 分组。
- Agent & CLI 独立页面。
- Clipboard 内的 Privacy 子页面 App 列表完善。
- 高级诊断折叠。

验收：

- 用户能判断“我要配置翻译服务”还是“我要配置 OCR 服务”。
- Agent 默认摘要、完整内容授权边界清楚。

### P8-J Product Audit Closure

目标：对 P8-G/H/I 做真实截图审计和问题关闭。

范围：

- 截图证据。
- P0/P1/P2 问题台账。
- 对照本文逐项验收。

## 11. 需要你确认的决策

1. 主窗口侧边栏是否采用本文建议的 5 组结构：Tools / System / Intelligence / Data / App？
2. Clipboard / Translation 是否继续定义为“主入口是浮层，主窗口页面是设置和状态”？
3. Provider 是否拆为 Model Services / Translation Services / OCR Services / Local CLI，而不是一个大杂烩页面？
4. 已确认：Clipboard Privacy 属于 Clipboard 内的二级页面，从 Clipboard 设置页进入并可返回 Clipboard；不作为主侧边栏 Data 组一级入口。
5. 后续是否先做 P8-G Settings Shell Redesign，再做 P8-H 浮层视觉系统？

## 12. 当前未解决项

- 本文没有做高保真视觉稿。
- 本文没有重新截图当前 App；当前问题判断基于源码结构、P7-J 审计记录和 P8-B/E 实现状态。
- Liquid Glass 的实际透明感仍受系统版本、Reduce Transparency、窗口背后内容和材质层级影响；后续需要真机截图复核。
- Pinboard 完整编辑器、Paste Stack、文本/富文本编辑仍需要单独交互规格。
