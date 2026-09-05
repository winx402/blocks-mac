---
stepsCompleted:
  - step-01-validate-prerequisites
  - step-02-design-epics
  - step-03-create-stories
  - step-04-final-validation
inputDocuments:
  - prds/prd-Mac 工具集-2026-07-02/prd.md
  - prds/prd-Mac 工具集-2026-07-02/addendum.md
  - architecture/p2-l-app-scaffold-architecture/ARCHITECTURE-SPINE.md
  - ../../../技术知识库/正式AppScaffold架构-v0.md
  - ux-designs/ux-Mac 工具集-2026-07-02/DESIGN.md
  - ux-designs/ux-Mac 工具集-2026-07-02/EXPERIENCE.md
  - ../../../技术知识库/Action-Schema-v0.md
  - ../../../技术知识库/Provider-Secret-Handling-v0.md
  - ../../../技术知识库/macOS权限与分发风险清单.md
updated: 2026-07-02
---

# Mac 工具集 - Epic Breakdown

## Overview

This document provides the complete V1 epic and story breakdown for Mac 工具集 / 奇点 AI 工具箱, decomposing the requirements from the PRD, UX design contract, and architecture requirements into implementable stories.

本文是开发前规划产物，不替代 PRD、UX Spec 或 Architecture。V1 拆分范围为完整 V1：formal scaffold、截图、剪贴板、翻译、设置、AI/provider、CLI/agent、hook 草稿与审计。

## Requirements Inventory

### Functional Requirements

FR-1: 用户可以从菜单栏打开截图、剪贴板、翻译、暂停剪贴板记录、最近状态和设置入口。

FR-2: 用户可以配置、禁用、恢复默认截图、剪贴板和翻译快捷键，并看到冲突提示。

FR-3: 用户可以在设置页看到屏幕录制、辅助功能、剪贴板 recorder、文件访问、登录项和 provider 配置状态，并获得可恢复引导。

FR-4: 用户可以在设置页清理截图历史、剪贴板历史、翻译历史、AI Action 记录和审计摘要，且清理不会误删 Keychain secret。

FR-5: 用户可以通过截图快捷键进入截图选择视图，并选择区域、窗口或全屏截图。

FR-6: 截图完成后，用户看到包含图片预览和功能组的轻量浮层。

FR-7: 用户可以对截图执行复制、保存、另存为、拖拽和重新截图。

FR-8: 用户可以从截图结果浮层进入 OCR、翻译、总结和内容识别，外发前必须确认。

FR-9: 系统保存截图结果摘要和后续 Action 摘要，供用户在历史或审计中找回。

FR-10: 用户可以开启、暂停、恢复剪贴板记录，并设置保存时间和数量上限。

FR-11: 用户可以通过剪贴板快捷键打开历史面板，按时间倒序浏览并搜索 Clipboard Item。

FR-12: 系统保存文本、富文本、图片、链接、文件引用的可恢复表示，并能恢复可用格式。

FR-13: 用户可以固定、分组、删除单条或批量清理 Clipboard Item，Pinned Item 不受普通过期策略影响。

FR-14: 用户可以排除指定 App，命中排除时系统不读取内容快照。

FR-15: 用户可以对单条 Clipboard Item 执行翻译、改写、总结或敏感信息识别，且只处理当前条目。

FR-16: 用户可以从手动输入、选中文本、当前剪贴板、剪贴板历史条目和截图 OCR 文本发起翻译。

FR-17: 用户看到原文/译文对照、来源、目标语言、provider、处理状态和操作按钮。

FR-18: V1 至少支持中英互译，并保留自动检测语言入口。

FR-19: 用户可以从截图 OCR 文本进入翻译，OCR 文本必须先可见。

FR-20: Agent 可以通过 `jdtool.translate.text` 提交结构化翻译任务，并获得统一 JSON envelope。

FR-21: 用户可以配置本地 CLI provider 和 API provider 的名称、模型、base URL、Keychain account alias、超时和启用状态。

FR-22: 任何外部 provider、API 或 CLI 可能接收用户内容前，系统必须展示 `external_transfer` 确认。

FR-23: 读取完整剪贴板内容、真实截图或本地敏感内容预览前，系统必须使用 `preview` 确认或已有显式授权策略。

FR-24: 系统为敏感 Action 生成 Audit Log，用户可以查看和清理。

FR-25: CLI 可以列出 Action、查看 schema、执行 Action，并返回统一 JSON envelope。

FR-26: Agent 读取完整剪贴板、截图内容、选中文本或外发内容时，不得绕过 Confirmation。

FR-27: Action 输出的结果可以被用户复用，也可以被 agent 继续处理；失败时保留结构化错误。

FR-28: 用户可以在设置页查看 agent 生成的 Hook 草稿。

FR-29: 用户启用、阻断、修改、删除或自动外发类 Hook 前，必须通过 `destructive_or_hook` 确认。

FR-30: V1 App UI 支持 `zh-Hans`、`en`、`ja`，默认跟随 macOS 系统语言，并在设置页提供语言偏好入口；CLI/action JSON 机器接口不本地化。

### NonFunctional Requirements

NFR-1 Performance: 截图选择、结果浮层、剪贴板历史面板、翻译面板必须给出快速首屏反馈；具体延迟预算在 P3 scaffold 和后续实现中量化。

NFR-2 Privacy: 默认不静默上传截图、剪贴板、选中文本或文件引用；所有外发都必须经过 Confirmation。

NFR-3 Security: API secret 进入 Keychain；普通配置和日志不得保存 secret、token、完整订阅链接、验证码、私钥或完整支付信息。

NFR-4 Reliability: 权限缺失、provider 失败、OCR 失败、保存失败、CLI 错误必须返回可恢复路径。

NFR-5 Accessibility: 核心面板和设置页必须支持键盘操作；快捷键冲突和权限状态不能只依赖颜色表达。

NFR-6 Observability: 关键 Action 必须有 audit_id 和 warnings，便于用户和 agent 理解失败原因。

NFR-7 Scope Safety: V1 不做录屏、云端截图库、跨设备同步、长文档翻译、文件图片批处理、真实支付、账号系统或无约束 hook 脚本。

NFR-8 Distribution Safety: Direct Download 和 App Store 双出口仍不锁死；正式 App 从一开始按 sandbox-first 设计。

NFR-9 Platform Visuals: macOS 26+ 使用系统 Liquid Glass 渐进增强；macOS 14-25 使用原生 material / `NSVisualEffectView` 回退；截图选区 overlay 不使用重毛玻璃。

NFR-10 Localization Safety: App UI 多语言不扩大翻译工具语言覆盖；翻译工具语言能力仍由 FR-18 约束，CLI/action 字段、action 名和 `error.code` 保持稳定英文机器值。

### Additional Requirements

- 正式 scaffold 起步形态为 `SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core`，但不代表最终分发渠道、商业模式或完整依赖冻结。
- Main App 拥有菜单栏、浮层、设置页、权限引导、快捷键配置、confirmation cards、Keychain 配置、provider 设置、审计展示和数据清理入口。
- Helper 优先承载剪贴板 recorder、后台心跳、轻量事件采集；默认不执行外部 CLI provider、不运行 hook、不做自动粘贴、不上传内容。
- UI、helper、CLI、agent 和 hook 都必须通过 Shared Action Core 进入能力边界。
- `jdtool.*` action schema 是 UI、CLI、agent 和 hook 的接口事实源；V1 至少要覆盖 `jdtool.screenshot.capture`、`jdtool.clipboard.search`、`jdtool.translate.text`。
- CLI 使用 `jdtool` 前缀和统一 JSON envelope；需要确认时返回或触发 `requires_confirmation`。
- `preview`、`external_transfer`、`destructive_or_hook` 三级确认是正式 runtime 的安全分界。
- 第一方 action 使用 Swift typed model / `Codable` / 显式业务校验；CLI 外部输入、agent 外部输入和 hook manifest 进入 enabled 或执行路径前必须走完整 validator adapter 或等价严格校验。
- Keychain 保存 API secret；普通配置最多保存 provider 名称、模型名、base URL 和 Keychain account alias。
- P2 spike 代码不得直接搬入正式工程；P3 需要正式 scaffold 计划和截图纵切端到端路径。
- 多屏、权限撤销、第三方复杂剪贴板样本、长期 helper 功耗、真实 API provider 调用、App Store 审核边界仍是复测项，不得写成已完成。
- P3-A 当前可见 UI 文案进入 String Catalog 或等价本地化资源，首批语言为简体中文、英文、日文；品牌名「奇点工具」暂保持中文。
- Liquid Glass / 毛玻璃能力必须集中在统一 wrapper 或等价容器中，避免分散自绘透明背景；旧系统 fallback 必须可读且不崩溃。

### UX Design Requirements

UX-DR-1: 实现 DESIGN.md 中的基础 design tokens：颜色、系统字体、4px 间距、紧凑圆角、浮层、侧边栏、确认卡片、danger card 和 info badge。

UX-DR-2: 使用 Mac 原生、轻量、高密度、低打扰的界面风格；禁止营销 hero、卡片套卡片、装饰渐变背景和独立 AI 聊天入口。

UX-DR-3: 实现 Floating Panel 行为：`Esc` 关闭、主行动唯一、关闭不丢失最近摘要、风险操作嵌入确认卡片。

UX-DR-4: 实现菜单栏、截图选择、截图结果、剪贴板历史、翻译面板、确认卡片、设置页、审计视图八个核心 surface。

UX-DR-5: 实现截图体验状态：区域/窗口/全屏、权限缺失、处理、成功、失败、截图后历史摘要。

UX-DR-6: 实现剪贴板体验状态：空历史、搜索无结果、暂停记录、排除 App、格式恢复失败、固定项不过期。

UX-DR-7: 实现翻译体验状态：手动输入、选中文本、剪贴板、截图 OCR、agent action、provider 超时、切换 provider、重试。

UX-DR-8: 实现设置页分区：Shortcuts、Permissions & Privacy、Clipboard、Privacy Exclusions、AI Providers、CLI / Agent、Hooks、Data & Audit。

UX-DR-9: 实现确认卡片行为：展示 level、reason、redacted preview、继续/取消；高风险确认默认焦点不得在继续。

UX-DR-10: 实现键盘操作：`Esc`、`Enter`、`Tab` / `Shift+Tab`、上下箭头、剪贴板 `/` 搜索焦点；确认卡片不能跳过取消按钮。

UX-DR-11: 实现可访问性下限：按钮和状态有 accessibility label，权限/状态可被 VoiceOver 朗读，动态状态可感知公告，Reduce Motion 禁用强位移动效。

UX-DR-12: 实现 responsive/platform 约束：主要面向 macOS 桌面；窄窗口设置页可压缩；跨屏选区未实现时必须结构化提示并允许重选单屏区域。

UX-DR-13: 实现 App UI 本地化基础：`zh-Hans`、`en`、`ja` 三语言当前可见 UI 覆盖、默认跟随系统、设置页语言偏好和重启生效提示。

UX-DR-14: 实现 macOS 26 Liquid Glass 渐进增强：结果浮层、确认卡片、设置页重点面板使用统一 glass container；macOS 14-25 使用原生 material 回退；截图选区 overlay 保持清晰。

### FR Coverage Map

FR-1: Epic 1 Story 1.3, Epic 5 Story 5.1 - 菜单栏入口和全局状态。

FR-2: Epic 1 Story 1.4, Epic 5 Story 5.1 - 快捷键注册、设置、禁用、恢复默认和冲突提示。

FR-3: Epic 1 Story 1.5, Epic 5 Story 5.2 - 权限状态模型和设置页引导。

FR-4: Epic 5 Story 5.5 - 数据清理与审计摘要管理。

FR-5: Epic 2 Story 2.1 - 区域、窗口、全屏截图选择。

FR-6: Epic 2 Story 2.2 - 截图结果浮层。

FR-7: Epic 2 Story 2.3 - 截图复制、保存、另存为、拖拽和重新截图。

FR-8: Epic 2 Story 2.4 - 截图 OCR、翻译、总结和内容识别入口。

FR-9: Epic 2 Story 2.5, Epic 5 Story 5.4 - 截图历史摘要和审计。

FR-10: Epic 3 Story 3.1, Epic 5 Story 5.3 - 剪贴板 recorder 控制和保存策略。

FR-11: Epic 3 Story 3.2 - 剪贴板历史面板与搜索。

FR-12: Epic 3 Story 3.3 - 格式保留与恢复。

FR-13: Epic 3 Story 3.4 - 固定、分组、删除和清理。

FR-14: Epic 3 Story 3.5, Epic 5 Story 5.3 - 隐私排除 App。

FR-15: Epic 3 Story 3.6, Epic 6 Story 6.4 - 单条剪贴板 AI 处理。

FR-16: Epic 4 Story 4.1 - 翻译多入口。

FR-17: Epic 4 Story 4.2 - 翻译结果面板。

FR-18: Epic 4 Story 4.3 - 中英互译、自动检测和目标语言配置。

FR-19: Epic 2 Story 2.4, Epic 4 Story 4.4 - 截图 OCR 翻译。

FR-20: Epic 4 Story 4.5, Epic 6 Story 6.2 - agent 翻译 action。

FR-21: Epic 4 Story 4.6, Epic 5 Story 5.4 - provider 设置和 Keychain alias。

FR-22: Epic 6 Story 6.4 - 外发确认。

FR-23: Epic 6 Story 6.4 - 完整内容和真实截图 preview 确认。

FR-24: Epic 5 Story 5.5, Epic 6 Story 6.5 - Audit Log。

FR-25: Epic 1 Story 1.2, Epic 6 Story 6.1 - action catalog、schema、run 和 envelope。

FR-26: Epic 6 Story 6.3 - 敏感 agent 请求不能绕过确认。

FR-27: Epic 6 Story 6.2, Epic 6 Story 6.5 - 结果复用、warnings、error 和 audit_id。

FR-28: Epic 6 Story 6.6 - Hook 草稿审阅。

FR-29: Epic 6 Story 6.7 - Hook 启用确认。

FR-30: Epic 1 Story 1.6, Epic 5 Story 5.1 - App UI 本地化、语言设置和 CLI/action 机器接口不本地化边界。

### User Journey Coverage Map

UJ-1: Epic 2 Stories 2.1, 2.2, 2.3 - 林从快捷键截图、看到结果浮层并复制图片。

UJ-2: Epic 2 Story 2.4 and Epic 4 Story 4.4 - 周从截图 OCR 进入翻译，并在外发前确认。

UJ-3: Epic 3 Stories 3.2, 3.3 - 许搜索历史并恢复富文本格式。

UJ-4: Epic 3 Story 3.4 - 陈固定常用回复并放入分组。

UJ-5: Epic 3 Story 3.6 and Epic 6 Story 6.4 - 赵对单条剪贴板内容做 AI 改写，并确认外发范围。

UJ-6: Epic 4 Stories 4.1, 4.2, 4.3 - 王划词翻译并复制或替换剪贴板。

UJ-7: Epic 4 Story 4.5 and Epic 6 Stories 6.1, 6.2, 6.3 - Agent 请求剪贴板摘要或翻译 action，完整内容读取触发确认。

UJ-8: Epic 6 Stories 6.6, 6.7 and Epic 5 Story 5.5 - 用户审查 hook 草稿，启用前确认，并可查看审计。

### UX Design Coverage Map

UX-DR-1: Epic 1 Story 1.1 and Epic 5 Story 5.1 - design tokens、基础外壳和设置页样式基线。

UX-DR-2: Epic 1 Story 1.1, Epic 2 Story 2.2, Epic 3 Story 3.2, Epic 4 Story 4.2 - Mac 原生、轻量、高密度、低打扰，不做独立 AI 聊天入口。

UX-DR-3: Epic 2 Story 2.2, Epic 3 Story 3.2, Epic 4 Story 4.2, Epic 6 Story 6.4 - Floating Panel 行为和确认卡片嵌入。

UX-DR-4: Epic 1 Story 1.3, Epic 2 Stories 2.1-2.5, Epic 3 Stories 3.1-3.6, Epic 4 Stories 4.1-4.6, Epic 5 Stories 5.1-5.5, Epic 6 Stories 6.1-6.7 - 八个核心 surface。

UX-DR-5: Epic 2 Stories 2.1-2.5 - 截图状态。

UX-DR-6: Epic 3 Stories 3.1-3.5 - 剪贴板状态。

UX-DR-7: Epic 4 Stories 4.1-4.6 - 翻译状态。

UX-DR-8: Epic 5 Stories 5.1-5.5 - 设置页分区。

UX-DR-9: Epic 1 Story 1.5 and Epic 6 Story 6.4 - 确认卡片。

UX-DR-10: Epic 1 Story 1.4, Epic 3 Story 3.2, Epic 5 Story 5.1, Epic 6 Story 6.4 - 键盘操作。

UX-DR-11: Epic 1 Story 1.5, Epic 5 Story 5.2, Epic 6 Story 6.4 - 可访问性下限。

UX-DR-12: Epic 2 Story 2.1 and Epic 5 Story 5.1 - macOS 桌面、窄窗口和跨屏未实现提示。

UX-DR-13: Epic 1 Story 1.6 and Epic 5 Story 5.1 - App UI 多语言、语言偏好和当前可见 UI 本地化覆盖。

UX-DR-14: Epic 1 Story 1.6, Epic 2 Story 2.2 and Epic 5 Story 5.1 - Liquid Glass 渐进增强、material fallback 和截图 overlay 清晰度。

## Epic List

### Epic 1: Formal App Scaffold & Shared Action Core

用户可以启动一个 sandbox-first 的正式 Mac App 基线，通过菜单栏、快捷键和 `jdtool` action core 进入三类工具能力；后续截图、剪贴板、翻译和 agent 能复用同一权限、确认、审计和 JSON envelope。

**FRs covered:** FR-1, FR-2, FR-3, FR-25, FR-30

### Epic 2: Screenshot Vertical Slice

用户可以从快捷键完成区域、窗口或全屏截图，获得结果浮层，复制或保存图片，并在可确认的边界内进入 OCR、翻译、总结和历史摘要。

**FRs covered:** FR-5, FR-6, FR-7, FR-8, FR-9, FR-19

### Epic 3: Clipboard Recorder & History

用户可以安全地记录、搜索、恢复、固定、分组和清理剪贴板历史；非排除 App 默认在本机 App 数据内可恢复，排除 App 不读取内容快照，agent 默认只能读取摘要。

**FRs covered:** FR-10, FR-11, FR-12, FR-13, FR-14, FR-15

### Epic 4: Translation & Provider Flow

用户可以从手动输入、选中文本、剪贴板、截图 OCR 和 agent action 发起翻译，看到原文/译文对照，并通过 BYOK/API 或本地 CLI provider 完成可审计处理。

**FRs covered:** FR-16, FR-17, FR-18, FR-19, FR-20, FR-21

### Epic 5: Settings, Permissions, Data, Audit

用户可以在设置页管理快捷键、权限、剪贴板保存策略、隐私排除、provider、CLI/agent、hook 草稿、数据清理和审计摘要。

**FRs covered:** FR-1, FR-2, FR-3, FR-4, FR-9, FR-10, FR-14, FR-21, FR-24, FR-28, FR-30

### Epic 6: CLI / Agent / Hook Safety

Agent 可以通过 `jdtool` 结构化调用工具能力，但完整内容读取、外发、hook 启用和破坏性行为必须经过确认、预览和审计。

**FRs covered:** FR-15, FR-20, FR-22, FR-23, FR-24, FR-25, FR-26, FR-27, FR-28, FR-29

## Epic 1: Formal App Scaffold & Shared Action Core

Epic 目标：建立一个可运行、sandbox-first、可扩展的正式 App 基线，让用户和 agent 能通过同一 action core 进入工具能力，并让后续纵切不各自发明权限、确认、审计和错误结构。

### Story 1.1: Minimal Sandbox-First App Shell

As a Mac 用户,
I want 一个最小可启动的奇点工具 App shell,
So that 后续截图、剪贴板和翻译可以在正式 App 边界内实现。

**Acceptance Criteria:**

**Given** 本地开发环境打开正式工程
**When** 开发者构建并运行 App
**Then** App 以 sandbox-first 配置启动，显示菜单栏入口和最小设置入口
**And** 不创建真实支付、账号、云服务、真实 provider 调用或完整三工具 UI。

**Given** App 首次启动
**When** 用户打开菜单栏入口
**Then** 用户能看到 Screenshot、Clipboard、Translation、Pause Recorder、Settings 的占位入口
**And** 未实现能力以明确状态展示，不静默失败。

### Story 1.2: Shared Action Core Envelope

As a 本地 agent 或 UI 调用方,
I want 截图、剪贴板和翻译 action 使用统一 JSON envelope,
So that UI、CLI、agent 和 hook 能复用同一成功、失败、确认和审计结构。

**Acceptance Criteria:**

**Given** `jdtool.screenshot.capture`、`jdtool.clipboard.search`、`jdtool.translate.text` 的最小 action 定义存在
**When** 调用方执行 action
**Then** 返回包含 `ok`、`action`、`result`、`warnings`、`audit_id` 的统一 envelope
**And** 未知 action 返回结构化错误而不是崩溃。

**Given** action 需要用户确认
**When** CLI 或 agent 请求该 action
**Then** envelope 返回 `requires_confirmation`，包含 level、reason、redacted preview
**And** 不返回完整截图、完整剪贴板内容、secret 或 provider 原始敏感输出。

### Story 1.3: Menu Bar Entry and App Status

As a Mac 高频工具用户,
I want 菜单栏展示工具入口和关键状态,
So that 我可以在不打开完整窗口的情况下启动工具或排障。

**Acceptance Criteria:**

**Given** App 正在运行
**When** 用户点击菜单栏图标
**Then** 菜单显示 Screenshot、Clipboard、Translation、Pause Recorder、Recent Status、Settings
**And** 状态能表达正常、权限缺失、剪贴板暂停、provider 不可用。

**Given** 某个工具因为权限或 provider 不可用无法执行
**When** 用户从菜单栏查看状态
**Then** 菜单提供到 Settings 对应分区的入口
**And** 不用颜色作为唯一状态表达。

### Story 1.4: Global Hotkey Registration and Conflict States

As a Mac power user,
I want 配置截图、剪贴板和翻译快捷键,
So that 三类工具可以从当前上下文快速触发。

**Acceptance Criteria:**

**Given** App 已启动
**When** 快捷键系统初始化
**Then** Screenshot 默认尝试 `Option + A`，Clipboard 默认尝试 `Option + V`，Translation 默认未设置
**And** 注册失败或冲突以可见状态记录到菜单栏和 Settings。

**Given** 用户在 Settings 编辑快捷键
**When** 用户录入、禁用或恢复默认快捷键
**Then** 变更只影响对应工具
**And** 冲突不能静默保存，必须提示重新录入或取消。

### Story 1.5: Permission and Confirmation Foundation

As a 用户,
I want 在使用敏感能力前看到权限原因和确认路径,
So that 我知道工具会处理什么数据以及如何撤销。

**Acceptance Criteria:**

**Given** Screen Recording、Accessibility、Login Item、文件访问或 provider 配置缺失
**When** 用户触发相关能力
**Then** UI 显示权限名称、为什么需要、会处理什么数据、如何打开系统设置或稍后再说
**And** 不进入半成品流程。

**Given** action 需要 `preview`、`external_transfer` 或 `destructive_or_hook`
**When** 用户看到确认卡片
**Then** 默认展示 redacted preview，并提供继续和取消
**And** 高风险确认默认焦点不得落在继续按钮。

### Story 1.6: UI Localization and Platform Glass Foundation

As a Mac 用户,
I want App UI 能跟随我的系统语言并使用符合当前 macOS 的原生材质,
So that 奇点工具在不同语言和系统版本下都像一个稳定的 Mac 原生工具。

**Acceptance Criteria:**

**Given** P3-A scaffold 的当前可见 UI
**When** App 构建资源
**Then** 菜单栏、主窗口、Settings 占位、截图入口、权限提示、选区状态、结果浮层按钮和错误文案进入 String Catalog 或等价本地化资源
**And** `zh-Hans`、`en`、`ja` 三种语言都有对应文案。

**Given** 用户打开 Settings
**When** 用户查看 Language 区块
**Then** 看到 Follow System、简体中文、English、日本語
**And** P3-A 可以先保存偏好并提示重启生效。

**Given** CLI 或 agent 调用 `jdtool`
**When** UI 语言切换
**Then** JSON 字段名、action 名称、schema、`error.code`、audit_id 和短哈希保持未本地化的机器稳定值。

**Given** App 运行在 macOS 26+
**When** 展示截图结果浮层、确认卡片或设置页重点面板
**Then** 使用统一 glass container / Liquid Glass 渐进增强
**And** macOS 14-25 使用原生 material 回退，不崩溃、不降低可读性。

**Given** 用户进入截图选区 overlay
**When** 屏幕内容需要被判断和拖拽
**Then** overlay 不使用重毛玻璃，只保留清晰遮罩、边框和取消提示。

## Epic 2: Screenshot Vertical Slice

Epic 目标：用户可以从快捷键完成截图主路径，并在结果浮层中复制、保存、重新截图或进入受控 OCR/翻译/总结流程。

### Story 2.1: Screenshot Selection Modes

As a Mac 用户,
I want 通过快捷键选择区域、窗口或全屏截图,
So that 我可以快速截取当前上下文中需要分享或处理的内容。

**Acceptance Criteria:**

**Given** Screen Recording 权限可用且 Screenshot 快捷键启用
**When** 用户触发截图
**Then** 进入 Screenshot Selection，支持 Region、Window、Fullscreen 三种模式
**And** Region 显示选区边界、尺寸、重选和取消。

**Given** 用户选择 Window 模式
**When** 鼠标悬停在候选窗口上
**Then** UI 给出窗口高亮或候选反馈
**And** 无可捕获窗口时显示结构化失败和重选路径。

### Story 2.2: Screenshot Result Overlay

As a 截图用户,
I want 截图后看到轻量结果浮层,
So that 我能立即判断图片是否正确并选择下一步。

**Acceptance Criteria:**

**Given** 截图成功
**When** 捕获结果返回
**Then** 显示包含图片预览、模式、尺寸和 action 摘要的 Screenshot Result Overlay
**And** 浮层使用 DESIGN 的 floating panel 行为，`Esc` 可关闭但不丢失最近摘要。

**Given** 截图失败或权限中断
**When** 结果无法生成
**Then** 用户看到失败原因和重试/设置入口
**And** 不保存空历史或损坏图片。

### Story 2.3: Basic Screenshot Output Actions

As a 截图用户,
I want 复制、保存、另存为、拖拽或重新截图,
So that 截图可以快速进入聊天、文件或后续处理流程。

**Acceptance Criteria:**

**Given** 结果浮层显示有效图片
**When** 用户点击 Copy
**Then** 系统剪贴板可粘贴该图片
**And** 成功状态可见。

**Given** 用户选择 Save、Save As 或 Drag
**When** 文件路径或权限失败
**Then** 当前截图仍保留在浮层内
**And** UI 显示路径或权限问题及恢复动作。

### Story 2.4: Screenshot OCR, Translate, and Summary Actions

As a 阅读截图内容的用户,
I want 从截图结果进入 OCR、翻译、总结或内容识别,
So that 我不用手动抄写图片中的信息。

**Acceptance Criteria:**

**Given** 截图结果浮层中有图片
**When** 用户点击 OCR
**Then** 先展示 OCR 原文或识别摘要
**And** OCR 失败时保留原图并允许重试或重新选择区域。

**Given** OCR 文本要进入外部 provider 翻译或总结
**When** 用户点击 Translate 或 Summarize
**Then** 显示 `external_transfer` 确认卡片，包含 provider、来源、字符数和处理目的
**And** 用户确认前不外发内容。

### Story 2.5: Screenshot History and Audit Summary

As a 用户,
I want 截图和后续 action 留下可找回摘要,
So that 我能回顾最近截图和敏感处理结果。

**Acceptance Criteria:**

**Given** 截图成功或截图后执行 action
**When** action 完成或失败
**Then** 历史摘要记录时间、尺寸、来源模式、后续 action 类型和 audit_id
**And** 不把完整 base64 图片写入普通日志。

**Given** 用户从 Settings 或 Audit View 查看截图相关记录
**When** 选择一条记录
**Then** 用户看到 redacted summary 和可清理入口
**And** 清理操作显示影响范围。

## Epic 3: Clipboard Recorder & History

Epic 目标：用户可以以本地可恢复方式保存非排除 App 的剪贴板历史，并安全搜索、恢复、固定、分组、清理或对单条内容执行 AI 处理。

### Story 3.1: Clipboard Recorder Controls and Retention

As a 剪贴板历史用户,
I want 开启、暂停、恢复 recorder 并设置保留策略,
So that 我能控制哪些内容被记录以及保留多久。

**Acceptance Criteria:**

**Given** helper 可运行且 recorder 已启用
**When** 用户复制文本、富文本、图片、URL 或文件引用
**Then** 非排除 App 的条目进入本地历史索引，并保存支持类型的本地可恢复表示
**And** 记录包含类型、时间、来源候选和可恢复状态，不进入普通日志或 agent 默认结果。

**Given** 用户暂停 recorder
**When** 新剪贴板事件发生
**Then** 不保存新内容快照
**And** 菜单栏和历史面板显示暂停状态，旧历史仍可搜索。

### Story 3.2: Clipboard History Panel and Search

As a 高频复制用户,
I want 打开剪贴板历史面板并搜索条目,
So that 我能找回刚才复制过的内容。

**Acceptance Criteria:**

**Given** 历史中有条目
**When** 用户按 `Option + V` 或自定义快捷键
**Then** Clipboard History Panel 打开，搜索栏自动聚焦，条目按时间倒序展示
**And** 支持键盘上下移动选中项。

**Given** 历史为空或搜索无结果
**When** 用户打开或搜索
**Then** UI 显示明确空状态或无结果状态
**And** 提供开启 recorder、清除搜索或检查权限的下一步。

### Story 3.3: Format Preservation and Restore

As a 内容整理用户,
I want 恢复文本、富文本、图片、链接和文件引用的可用格式,
So that 历史不是只剩纯文本摘要。

**Acceptance Criteria:**

**Given** 条目为 text、RTF、image、URL 或 file URL
**When** 用户在详情区点击 Copy 或 Paste
**Then** 系统写回可恢复表示，富文本保留可用格式，图片保留尺寸和格式
**And** 文件引用默认只显示 basename 和类型摘要，不向 agent 暴露完整路径。

**Given** 格式恢复失败
**When** fallback 可用
**Then** UI 提供纯文本或摘要 fallback
**And** 告知用户格式无法完整恢复但原历史摘要仍保留。

### Story 3.4: Pin, Group, Delete, and Cleanup

As a 复用片段用户,
I want 固定、分组、删除和清理剪贴板条目,
So that 常用内容能长期保留，临时内容能按策略清理。

**Acceptance Criteria:**

**Given** 用户选中一个 Clipboard Item
**When** 用户点击 Pin
**Then** 条目进入 Pinned 分区并不受普通过期策略清理
**And** 可加入已有 Group 或创建新 Group。

**Given** 用户删除单条、清空搜索结果或清空历史
**When** 操作会影响可恢复内容或 pinned 条目
**Then** UI 显示影响范围和确认
**And** 不误删未选中的 pinned 内容。

### Story 3.5: Privacy Exclusions

As a 注重隐私的用户,
I want 排除指定 App 的剪贴板记录,
So that 密码管理器或敏感来源不会被读取内容快照。

**Acceptance Criteria:**

**Given** 用户在 Privacy Exclusions 中添加 App
**When** 该 App 是 source app candidate 且剪贴板变化
**Then** recorder 只记录 skipped 状态、来源候选和时间
**And** 不读取内容摘要、原文、RTF、图片 base64、URL 原值或真实文件路径。

**Given** 用户移除排除 App
**When** 后续剪贴板事件发生
**Then** recorder 按普通保存策略处理新事件
**And** 既有 skipped 记录不被反向补全。

### Story 3.6: Clipboard Item AI Processing

As a 写作或支持用户,
I want 对单条剪贴板内容翻译、改写、总结或识别敏感信息,
So that 我能处理当前条目而不暴露完整历史。

**Acceptance Criteria:**

**Given** 用户选中一条 Clipboard Item
**When** 用户点击 Translate、Rewrite、Summarize 或 Detect Sensitive
**Then** 只处理当前选中条目
**And** 完整内容进入外部 provider 前显示 `external_transfer` 和 redacted preview。

**Given** provider 超时或不可用
**When** AI 处理失败
**Then** 原条目和历史不丢失
**And** 用户可以重试、切换 provider、复制原文或取消。

## Epic 4: Translation & Provider Flow

Epic 目标：用户可以从多个本地来源进入翻译，并在 BYOK/API 或本地 CLI provider 边界内获得可复制、可重试、可审计的译文。

### Story 4.1: Translation Input Sources

As a 阅读外语内容的用户,
I want 从手动输入、选中文本、剪贴板、历史条目和截图 OCR 发起翻译,
So that 不同上下文都能进入同一个翻译流程。

**Acceptance Criteria:**

**Given** 用户打开 Translation Panel
**When** 用户选择手动输入、选中文本、当前剪贴板、剪贴板历史条目或截图 OCR 文本
**Then** 每个任务记录来源类型
**And** 截图 OCR 和剪贴板来源在外发前展示预览。

**Given** 选中文本读取失败
**When** 用户触发划词翻译
**Then** UI 提供复制桥接或手动输入替代路径
**And** 不静默读取当前 App 内容。

### Story 4.2: Translation Result Panel

As a 翻译用户,
I want 看到原文/译文对照和可操作结果,
So that 我能复制、替换剪贴板、保存历史或重试。

**Acceptance Criteria:**

**Given** 翻译任务成功
**When** Translation Panel 展示结果
**Then** 用户看到来源、源语言、目标语言、provider、原文、译文和处理状态
**And** 提供 Copy、Replace Clipboard、Save、Retry。

**Given** provider 返回失败、超时或不可解析结果
**When** 结果面板展示错误
**Then** 原文保留，错误摘要可读
**And** 用户可以重试、切换 provider 或打开设置页。

### Story 4.3: Language Controls

As a 翻译用户,
I want 配置目标语言并使用自动检测,
So that 中英互译和常见输入能快速完成。

**Acceptance Criteria:**

**Given** 用户进入翻译面板或 Settings
**When** 查看语言设置
**Then** V1 至少支持中英互译，目标语言默认中文
**And** 保留自动检测语言入口。

**Given** 自动检测失败或不可信
**When** 用户展开语言控制
**Then** 用户可以手动选择源语言
**And** 新设置只影响当前任务或用户明确保存的默认值。

### Story 4.4: Screenshot OCR Translation Bridge

As a 截图翻译用户,
I want 从截图 OCR 文本进入翻译面板,
So that 图片中的文字可以被检查后再翻译。

**Acceptance Criteria:**

**Given** 截图 OCR 产生文本
**When** 用户点击 Translate
**Then** OCR 文本先可见，用户确认后进入 Translation Panel
**And** 任务来源记录为 screenshot。

**Given** OCR 置信不足或失败
**When** 用户尝试翻译
**Then** UI 提示检查原文、重新选择区域或手动输入
**And** 不直接把不可信 OCR 文本外发。

### Story 4.5: Agent Translation Action

As a 本地 agent,
I want 调用 `jdtool.translate.text`,
So that 我能在用户授权边界内获得结构化译文。

**Acceptance Criteria:**

**Given** agent 调用 `jdtool.translate.text` 且 provider 为 mock 或本地允许路径
**When** action 成功
**Then** 返回统一 JSON envelope，包含 source_language、target_language、text、warnings、audit_id
**And** 失败时返回 error code 和 message。

**Given** 请求使用非 mock provider 或敏感来源
**When** agent 发起翻译
**Then** action 返回或触发 `requires_confirmation`
**And** 用户确认前不外发内容。

### Story 4.6: Provider Settings and Connection Test

As a 用户,
I want 配置 BYOK/API 和本地 CLI provider,
So that 翻译、总结和改写能力可替换且不泄露凭据。

**Acceptance Criteria:**

**Given** 用户进入 Settings → AI Providers
**When** 用户新增或编辑 provider
**Then** 可以设置 provider 名称、模型、base URL、Keychain account alias、超时和启用状态
**And** API secret 只进入 Keychain，不写入普通配置文件。

**Given** 用户测试 provider
**When** 测试连接执行
**Then** 输出只显示 redacted 状态、耗时和错误摘要
**And** 不记录完整 provider 原始敏感输出或 CLI token。

## Epic 5: Settings, Permissions, Data, Audit

Epic 目标：用户可以在一个 Mac 原生设置页中理解和管理快捷键、权限、剪贴板策略、provider、CLI/agent、hook、数据清理和审计记录。

### Story 5.1: Settings Shell and Shortcuts Section

As a 用户,
I want 在设置页集中管理三类工具快捷键,
So that 我能解决冲突、禁用不需要的快捷键或恢复默认。

**Acceptance Criteria:**

**Given** 用户打开 Settings
**When** 进入 Shortcuts 分区
**Then** 显示 Screenshot、Clipboard、Translation 三行状态
**And** Translation 默认为 Not set，Screenshot 和 Clipboard 显示默认或当前配置。

**Given** 用户编辑快捷键
**When** 录入组合键冲突
**Then** UI 提示冲突，不能静默保存
**And** 用户可以重新录入、禁用或恢复对应工具默认。

### Story 5.2: Permissions and Privacy Guidance

As a 用户,
I want 看到每项权限的状态和解释,
So that 我能决定是否授权或撤销。

**Acceptance Criteria:**

**Given** 用户进入 Permissions & Privacy
**When** 查看 Screen Recording、Accessibility、Clipboard recorder、File access、Login Item、Provider 状态
**Then** 每行显示状态、为什么需要、会处理什么数据、打开系统设置和撤销说明
**And** 权限状态不只依赖颜色。

**Given** 某权限缺失
**When** 用户从工具入口跳转到设置页
**Then** 对应权限行被聚焦或高亮
**And** 提供返回原工具流程的恢复路径。

### Story 5.3: Clipboard Policy and Privacy Exclusion Settings

As a 剪贴板用户,
I want 配置保存策略、暂停记录和隐私排除 App,
So that 本地可恢复历史和隐私边界可控。

**Acceptance Criteria:**

**Given** 用户进入 Clipboard 设置
**When** 修改保留时间、数量上限、固定项不过期或暂停记录
**Then** 新策略应用于后续清理和 recorder 状态
**And** 固定项不会因普通策略被删除。

**Given** 用户进入 Privacy Exclusions
**When** 添加或移除 App
**Then** 命中排除的后续事件不读取内容快照
**And** UI 显示 skipped 规则和影响范围。

### Story 5.4: Provider, CLI, and Agent Settings

As a power user,
I want 在设置页检查 provider、CLI 和 agent 可用性,
So that 本地 agent 能可靠调用工具而不读取 secret。

**Acceptance Criteria:**

**Given** 用户进入 AI Providers 或 CLI / Agent 分区
**When** 查看配置
**Then** UI 显示 provider 类型、模型、base URL 摘要、Keychain account alias、超时、CLI 可检测状态
**And** 不展示 secret、token 或完整 provider 原始输出。

**Given** provider 不可用
**When** 用户执行测试或工具请求 provider
**Then** UI 显示 provider unavailable 或 timeout 的可读错误
**And** 提供切换 provider、编辑配置或禁用的入口。

### Story 5.5: Data Management and Audit View

As a 用户,
I want 查看和清理历史、AI action 记录和审计摘要,
So that 我能控制本地数据生命周期。

**Acceptance Criteria:**

**Given** 用户进入 Data & Audit
**When** 查看记录
**Then** 显示 screenshot history、clipboard history、translation history、AI action、audit summary 的分区摘要
**And** audit row 至少包含 audit_id、action、时间、来源、provider、确认级别和 redacted preview。

**Given** 用户执行清理操作
**When** 清理会影响历史或审计
**Then** UI 展示影响范围并要求确认
**And** 不删除 Keychain secret，除非用户进入 provider 凭据管理路径。

## Epic 6: CLI / Agent / Hook Safety

Epic 目标：本地 agent 能通过 `jdtool` 安全调用 V1 能力；完整内容读取、外发、hook 生效和破坏性行为必须经过确认、预览和审计。

### Story 6.1: `jdtool` Action Catalog and Schema Commands

As a 本地 agent,
I want 列出 action、查看 schema 和执行 action,
So that 我能用结构化接口调用奇点工具能力。

**Acceptance Criteria:**

**Given** `jdtool` CLI 可用
**When** agent 调用 action list 或 schema 命令
**Then** CLI 返回 `jdtool.screenshot.capture`、`jdtool.clipboard.search`、`jdtool.translate.text` 和对应 schema 信息
**And** 输出不包含 secret 或真实敏感内容。

**Given** agent 调用未知 action
**When** CLI 处理请求
**Then** 返回 `unknown_action` 结构化错误
**And** 进程不崩溃。

### Story 6.2: Agent Result Reuse and Error Handling

As a 本地 agent,
I want action 结果包含 audit_id、warnings 和结构化错误,
So that 我能安全串联后续任务并向用户解释失败。

**Acceptance Criteria:**

**Given** agent 调用任意 V1 action
**When** action 成功
**Then** envelope 包含可复用 result、warnings 和 audit_id
**And** 用户可在 UI 中查看相关审计摘要。

**Given** action 失败
**When** error code 为 invalid_input、permission_denied、provider_unavailable、provider_timeout 或 provider_invalid_output
**Then** CLI 返回可读 message
**And** 不丢失用户原始内容或泄露完整敏感内容。

### Story 6.3: Sensitive Agent Request Boundary

As a 用户,
I want agent 默认只能读取剪贴板和截图摘要,
So that agent 无法绕过 UI 获取完整敏感内容。

**Acceptance Criteria:**

**Given** agent 调用 `jdtool.clipboard.search` 且未请求完整内容
**When** action 返回结果
**Then** 只返回条目 ID、类型、时间、来源候选和摘要
**And** 不返回完整文本、RTF、图片 base64、URL 原值或真实文件路径。

**Given** agent 请求 `include_content=true` 或等价完整内容
**When** action 处理请求
**Then** 返回或触发 `preview` 确认
**And** 用户确认前 agent 不能获得完整内容。

### Story 6.4: Unified Confirmation Cards for External Transfer and Preview

As a 用户,
I want 所有完整内容读取和外发都通过一致确认卡片,
So that 我能理解风险并取消操作。

**Acceptance Criteria:**

**Given** 外部 provider、API 或 CLI 可能接收用户内容
**When** 用户或 agent 发起相关 action
**Then** UI 展示 `external_transfer`，包含 provider、来源、字符数或条目 ID、处理目的
**And** 默认不展示完整敏感内容。

**Given** 操作要读取完整剪贴板、真实截图或本地敏感内容预览
**When** 触发确认
**Then** UI 展示 `preview`，包含 redacted preview 和展开查看路径
**And** 用户取消后 action 不执行。

### Story 6.5: Audit Trail for Agent, Provider, and AI Actions

As a 用户,
I want 所有敏感 action 都留下审计摘要,
So that 我能回看 agent、provider 和 hook 做过什么。

**Acceptance Criteria:**

**Given** action 涉及完整内容、外发、hook 或 provider
**When** action 完成、失败或被取消
**Then** Audit Log 记录 audit_id、action、时间、来源、provider、确认级别、redacted preview 和结果状态
**And** 不保存完整 secret、完整截图 base64、完整剪贴板历史或 provider 原始敏感输出。

**Given** 用户清理审计摘要
**When** 清理执行
**Then** UI 展示影响范围
**And** 清理不会删除 Keychain secret 或未选中的历史内容。

### Story 6.6: Hook Draft Review

As a 自动化探索用户,
I want 在设置页审查 agent 生成的 hook 草稿,
So that hook 不会在我理解前运行。

**Acceptance Criteria:**

**Given** agent 生成 hook manifest
**When** Main App 接收并校验草稿
**Then** Hook 在 Settings → Hooks 中显示为 draft
**And** 展示名称、触发点、权限、输入范围、输出效果和风险级别。

**Given** hook manifest 无效或风险信息缺失
**When** 用户查看 Hooks 分区
**Then** UI 显示校验错误并禁止启用
**And** helper 默认不运行该 hook。

### Story 6.7: Hook Enablement Confirmation

As a 用户,
I want 启用、修改、阻断、删除或自动外发类 hook 前必须确认,
So that 自动化不能静默改变我的内容。

**Acceptance Criteria:**

**Given** 用户点击 Enable Hook 或执行高风险 hook 操作
**When** hook 可能阻断、修改、删除或自动外发内容
**Then** UI 展示 `destructive_or_hook` 确认，包含影响预览和撤销路径
**And** 用户确认前 hook 保持 draft 或原状态。

**Given** hook 已启用
**When** 用户禁用或查看审计
**Then** Settings 显示 enabled / disabled 状态和相关 audit rows
**And** 禁用后 helper 不继续执行该 hook。
