---
name: 奇点 AI 工具箱 V1
description: macOS 原生内容处理工具箱；轻量、高密度、低打扰，服务截图、剪贴板和翻译三类日常任务。
status: final
sources:
  - {planning_artifacts}/prds/prd-Mac 工具集-2026-07-02/prd.md
  - {planning_artifacts}/prds/prd-Mac 工具集-2026-07-02/addendum.md
  - ../../../../../产品知识库/交互整合/V1交互规格草案.md
  - ../../../../../产品知识库/交互整合/V1视觉方向草案.html
updated: 2026-07-02
colors:
  bg-base: '#F4F5F2'
  surface-base: '#FFFFFF'
  surface-raised: '#FBFBFA'
  surface-subtle: '#F8F8F5'
  overlay-scrim: '#1F2428'
  text-primary: '#1F2428'
  text-secondary: '#6F777D'
  text-disabled: '#A5ADB2'
  border-subtle: '#D9DDD7'
  border-strong: '#B9C0BA'
  accent: '#2E7D6F'
  accent-soft: '#E0F1ED'
  warning: '#B7791F'
  warning-soft: '#FFF4D7'
  danger: '#B64747'
  danger-soft: '#FAE7E7'
  info: '#5B6FA8'
  info-soft: '#ECEFF9'
  focus-ring: '#2E7D6F'
typography:
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", sans-serif'
    fontSize: 24px
    fontWeight: '680'
    lineHeight: '1.22'
    letterSpacing: 0
  panel-title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
    fontSize: 17px
    fontWeight: '680'
    lineHeight: '1.28'
    letterSpacing: 0
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
    fontSize: 13px
    fontWeight: '400'
    lineHeight: '1.45'
    letterSpacing: 0
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
    fontSize: 12px
    fontWeight: '590'
    lineHeight: '1.35'
    letterSpacing: 0
  caption:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
    fontSize: 11px
    fontWeight: '400'
    lineHeight: '1.35'
    letterSpacing: 0
  mono:
    fontFamily: '"SF Mono", ui-monospace, Menlo, monospace'
    fontSize: 12px
    fontWeight: '400'
    lineHeight: '1.4'
    letterSpacing: 0
rounded:
  sm: 4px
  md: 6px
  lg: 8px
  xl: 10px
  full: 9999px
spacing:
  '1': 4px
  '2': 8px
  '3': 12px
  '4': 16px
  '5': 20px
  '6': 24px
  '7': 32px
  panel-gutter: 14px
  settings-sidebar: 220px
  floating-panel-width: 560px
components:
  floating-panel:
    background: '{colors.surface-base}'
    border: '{colors.border-subtle}'
    radius: '{rounded.lg}'
    shadow: '0 18px 42px rgba(31, 36, 40, 0.14)'
  glass-panel:
    macos26: 'System Liquid Glass / glassEffect'
    fallback: '.regularMaterial / .ultraThinMaterial / NSVisualEffectView'
    radius: '{rounded.lg}'
  sidebar:
    background: '{colors.surface-subtle}'
    border: '{colors.border-subtle}'
    width: '{spacing.settings-sidebar}'
  toolbar-button:
    background: '{colors.surface-base}'
    foreground: '{colors.text-primary}'
    border: '{colors.border-subtle}'
    radius: '{rounded.md}'
  primary-action:
    background: '{colors.accent}'
    foreground: '#FFFFFF'
    radius: '{rounded.md}'
  confirmation-card:
    background: '{colors.warning-soft}'
    border: '{colors.warning}'
    radius: '{rounded.lg}'
  danger-card:
    background: '{colors.danger-soft}'
    border: '{colors.danger}'
    radius: '{rounded.lg}'
  info-badge:
    background: '{colors.info-soft}'
    foreground: '{colors.info}'
    radius: '{rounded.full}'
---

# 奇点 AI 工具箱 V1 — Design Spine

本文定义 V1 UX Spec 的视觉契约。它承接既有低保真 HTML 草案，但不锁死最终品牌、图标、动效或高保真视觉。实现、mock 和后续设计稿与本文冲突时，以本文和 `EXPERIENCE.md` 为准。

## Brand & Style

奇点工具是 macOS 原生工作流工具，不是营销型桌面应用。视觉表达要像一个常驻系统工具：轻、准、安静，默认不抢用户当前上下文。

设计姿态：

- **原生优先**：优先使用 Apple 平台熟悉的窗口、浮层、列表、设置页和键盘焦点模式。
- **高密度但可扫读**：剪贴板历史、设置项、action 审计都应能快速比较，不做大面积宣传卡片。
- **低打扰**：截图结果、翻译结果和确认卡片是短暂停靠，不成为全屏工作台。
- **安全可见**：涉及外发、完整内容读取、hook 生效时，视觉层级必须高于普通工具按钮。

避免把 V1 做成聊天产品、启动器、云协作内容库或高装饰品牌页。

## Colors

V1 使用中性浅色 Mac 工具盘面，配一个低饱和绿色作为主行动色。

- **`{colors.bg-base}`** 是设置页和主窗口背景。它比纯白更柔和，避免长时间配置时刺眼。
- **`{colors.surface-base}` / `{colors.surface-raised}` / `{colors.surface-subtle}`** 形成浮层、列表和侧边栏的层级。层级来自色调与边线，不靠大阴影。
- **`{colors.accent}`** 只用于主行动、当前选中、有效焦点和确认后的可执行动作。不要把它铺成大面积品牌背景。
- **`{colors.warning}`** 表示需要用户理解后继续：外发 provider、完整内容预览、权限影响说明。
- **`{colors.danger}`** 表示删除、清空、禁用 hook、不可恢复的数据操作。
- **`{colors.info}`** 表示只读状态、摘要、来源、provider 或审计元信息。

不要使用渐变球、装饰光斑、大面积紫蓝渐变或营销式 hero 背景。

## Typography

字体继承 macOS 系统字体。V1 不引入品牌字体。

- **`{typography.title}`** 仅用于设置页标题、主窗口标题或关键空状态，不用于紧凑面板内部。
- **`{typography.panel-title}`** 用于截图结果浮层、剪贴板历史面板和翻译面板标题。
- **`{typography.body}`** 是默认正文、列表内容和说明文字。
- **`{typography.label}`** 用于设置项标题、表头、按钮标签和状态标签。
- **`{typography.caption}`** 用于时间、来源、provider、audit_id 摘要等辅助信息。
- **`{typography.mono}`** 用于快捷键、action 名称、schema 标识和短哈希。

所有字距为 0。不要用 viewport 宽度缩放字体；紧凑界面要靠布局换行和截断规则，而不是动态放大缩小。

## Layout & Spacing

布局采用 4px 基础节奏，主要间距来自 `{spacing.1}` 到 `{spacing.7}`。

- **浮层**：宽度默认不超过 `{spacing.floating-panel-width}`，靠近触发上下文，保留关闭和键盘退出路径。
- **设置页**：左侧固定导航约 `{spacing.settings-sidebar}`，右侧为分区表单；不使用卡片套卡片。
- **历史面板**：搜索栏固定在顶部，Pinned 和 Today 分区用分隔线与标题区分，详情区不挤压列表主轴。
- **确认卡片**：嵌入当前工具面板，不跳到独立聊天或单独页面。

页面区块应是全宽带或未包裹布局；卡片只用于独立条目、浮层、确认卡片和工具面板。

## Elevation & Depth

深度只服务临时性和可关闭性。

- **`{components.floating-panel}`** 用于截图结果、剪贴板历史、翻译结果和确认浮层。
- **`{components.glass-panel}`** 是正式 App 的统一毛玻璃容器：macOS 26+ 使用系统 Liquid Glass，macOS 14-25 使用原生 material 回退。
- 设置页主窗口不使用重阴影；用侧边栏、分隔线和行间距建立层次。
- 选区 overlay 使用半透明遮罩，但选区内保持可辨认；不要模糊用户屏幕内容。

阴影不得成为装饰。浮层关闭后，底层工作上下文应立即恢复。

## Platform Materials

V1 视觉采用渐进增强，最低部署版本仍为 macOS 14。

- **macOS 26+**：截图结果浮层、确认卡片、设置页重点面板优先使用系统 Liquid Glass / `glassEffect`。相关控件应放入同一 glass container，避免每个按钮或小块独立采样导致视觉碎裂。
- **macOS 14-25**：使用 `.regularMaterial`、`.ultraThinMaterial` 或窄范围 `NSVisualEffectView` 回退，保持文字对比和低打扰。不要用固定透明度色块、自绘 blur 或厚重阴影伪造毛玻璃。
- **截图选区 overlay**：不使用重毛玻璃，只保留半透明遮罩、清晰边框、尺寸/取消提示，避免干扰用户识别被截图内容。
- **品牌与颜色**：Liquid Glass 是系统材质增强，不等于重新定义品牌色；V1 仍保持轻量、高密度、低打扰。

## Shapes

V1 使用紧凑圆角：`{rounded.sm}`、`{rounded.md}`、`{rounded.lg}`。

- 工具按钮、输入框、分段控制使用 `{rounded.md}`。
- 浮层、确认卡片、设置面板使用 `{rounded.lg}`。
- 状态 badge 可使用 `{rounded.full}`，但不要把普通按钮做成大 pill。

圆角不超过 10px，除非是系统控件或状态 badge。

## Components

- **Floating panel**：使用 `{components.floating-panel}`。必须包含标题、当前状态、主内容和一组可键盘访问动作。
- **Glass panel**：使用 `{components.glass-panel}`。只包裹浮层、确认卡片、设置页重点面板等需要系统材质的容器，不包裹截图选区 overlay。
- **Toolbar button**：使用 `{components.toolbar-button}`。图标优先，文本只用于不熟悉或风险动作；必须有 tooltip 或可访问标签。
- **Primary action**：使用 `{components.primary-action}`。每个浮层同一时刻最多一个主行动。
- **Confirmation card**：使用 `{components.confirmation-card}`。展示 reason、level、redacted preview 和继续/取消。
- **Danger card**：使用 `{components.danger-card}`。用于删除、清空、hook 高风险变更。
- **Sidebar**：使用 `{components.sidebar}`。设置页导航使用稳定分区，不做营销式说明页。
- **Info badge**：使用 `{components.info-badge}`。用于 provider、本地/外发、来源、权限状态、audit 摘要。

## Do's and Don'ts

| Do | Don't |
| --- | --- |
| 让截图、剪贴板、翻译都像 Mac 原生工具 | 做成网页 SaaS dashboard 或营销首页 |
| macOS 26+ 使用系统 Liquid Glass，旧系统使用原生 material 回退 | 自绘固定透明度伪毛玻璃或把所有小控件分散套玻璃 |
| 用 `{colors.warning}` 明确外发和完整内容读取 | 让 AI 操作与普通复制/保存视觉等价 |
| 保持列表密度，支持扫读和键盘移动 | 用大卡片堆满历史和设置 |
| 在浮层内完成确认和失败恢复 | 把 AI 做成独立聊天入口 |
| 把低保真 mock 当布局参考 | 把旧 HTML 草案当最终视觉实现 |
