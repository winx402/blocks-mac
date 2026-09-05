# 积木 AI 工具箱

状态：初始化
最后审阅：2026-07-05

本仓库是「积木 AI 工具箱」项目的独立项目空间，简称「积木工具」。`blocks` 是 P2 阶段暂定技术前缀，用于 CLI、spike 和 action namespace；它不代表最终品牌定稿。初始资料来自 `/Users/bot/Documents/管家/docs/项目管理库/AI-native-Mac工具集合/`，后续本仓库应作为该项目的主要工作空间和文档归属地。

## 项目定义

本项目探索一个面向 macOS 的 AI-native 工具箱：把高频桌面工具做深，同时让工具能力可以被人通过 UI 使用，也可以被本地 agent 通过 CLI / MCP / App Intents 等入口稳定调用。

当前判断是：方向有可操作性，但不应按“复制所有独立工具”的方式推进。更稳妥的切入是“本地 action core + 少数深做工具 + AI/agent 调用协议”。

## 当前入口

- [文档总览](docs/index.md)
- [项目管理库](docs/项目管理库/index.md)
- [工具重命名项目](docs/项目管理库/001_工具重命名/index.md)
- [品牌重命名方案：旧称到积木工具 / blocks](docs/项目管理库/001_工具重命名/品牌重命名方案-旧称到积木工具-2026-07-05.md)
- [项目视图改造前归档](docs/项目管理库/000_归档/2026-07-05_项目视图改造前/index.md)
- [P8-F 苹果风格页面布局规范](docs/调研与验证库/2026-07-03-P8-F苹果风格页面布局规范/README.md)
- [P8-H 产品细节审计](docs/调研与验证库/2026-07-03-P8-H产品细节审计/README.md)
- [剪贴板历史：当前产品与实现逻辑](docs/产品知识库/工具/文本/剪贴板历史-当前产品与实现逻辑.md)
- [V1 交互规格草案](docs/产品知识库/交互整合/V1交互规格草案.md)
- [V1 视觉方向草案](docs/产品知识库/交互整合/V1视觉方向草案.html)
- [产品定位](docs/产品知识库/产品定位.md)
- [MVP 范围假设](docs/产品知识库/MVP范围假设.md)
- [技术边界与架构假设](docs/技术知识库/技术边界与架构假设.md)
- [正式 App Scaffold 架构 v0](docs/技术知识库/正式AppScaffold架构-v0.md)
- [AI / Agent / CLI / Hook 能力边界](docs/技术知识库/AI-agent-CLI-Hook能力边界.md)
- [AI Capability Provider Layer v0](docs/技术知识库/AI-Capability-Provider-Layer-v0.md)
- [Action Schema v0](docs/技术知识库/Action-Schema-v0.md)
- [Hook Manifest v0](docs/技术知识库/Hook-Manifest-v0.md)
- [Provider Secret Handling v0](docs/技术知识库/Provider-Secret-Handling-v0.md)
- [macOS 权限与分发风险清单](docs/技术知识库/macOS权限与分发风险清单.md)
- [分发与运行形态 v0](docs/技术知识库/分发与运行形态-v0.md)
- [Sandbox-first 与分发渠道](docs/决策记录库/2026-07-01-sandbox-first与分发渠道.md)
- [JSON Schema 校验策略](docs/决策记录库/2026-07-02-JSON-Schema校验策略.md)
- [正式 App Scaffold 架构](docs/决策记录库/2026-07-02-正式AppScaffold架构.md)
- [Blocks 正式 macOS App](apps/Blocks/README.md)
- [初始资料导入记录](docs/调研与验证库/2026-06-29-初始资料导入.md)
- [P2 技术验证记录](docs/调研与验证库/2026-07-01-P2-技术验证记录.md)
- [P2-K 批量技术验证记录](docs/调研与验证库/2026-07-02-P2-K批量技术验证记录.md)
- [Blocks Login Item Probe](tools/spikes/blocks_login_item_probe/README.md)

## 当前边界

- V1 正式 PRD、正式 UX Spec 和 Epics & Stories 已形成第一版需求、体验与开发拆分基线；Implementation Readiness 曾给出 `NEEDS WORK`，P2-Q 已收敛剪贴板数据所有权、翻译快捷键、provider 默认策略和 PRD 过期 open questions。正式 App 已进入 P8 产品打磨阶段：当前工程为 `apps/Blocks/Blocks.xcodeproj`，形态为 `SwiftUI + AppKit + sandbox-first + helper stub + shared action core`，已完成截图区域/窗口/全屏纵切、截图 OCR/Translate/Summarize route-ready、Bob 风格翻译浮层、`Control + Option + A/V/D` 快捷入口、快捷键自定义录入与全局修饰键、稳定签名权限诊断、Accessibility 独立请求、AI Capability Provider Layer 骨架、OpenAI-compatible 翻译 runtime gate、Keychain 低敏测试门禁和三语 UI 本地化基础。剪贴板当前已从 redacted recorder / fixture 面板推进到本地内存态 live capture：`ClipboardLiveCaptureService` 轮询 `NSPasteboard` 捕获文本、RTF、URL、file URL 和 PNG/TIFF 图片，`ClipboardController` 负责 preview、筛选、来源聚合和 ingest 去重，bottom/side 浮层直接展示内容或缩略图，并通过 `ClipboardAutoPasteCoordinator` 写回系统剪贴板和触发粘贴。P8-I/P8-J/P8-K/P8-L 已收敛 Settings 行模型、右侧控件列、全屏布局和 Clipboard bottom 高度锚定；P8-M 已完成剪贴板面板、筛选、卡片、详情、自动粘贴、settings key 和 controller 的模块化；P8-N 代码门禁已覆盖自写入抑制、live ingest 策略裁剪和条目内容字体设置。仍未完成的是生产级剪贴板持久化仓库、保存前 capture policy、完整 Pinboard 编辑、Paste Stack、文本/富文本编辑、真实 OCR/图片外发和正式 packaging/notarization。商业模式和最终发布渠道仍未锁死。
- 除已进入决策记录库的事项外，架构与 MVP 内容均为 `proposed` 或 `待验证`。
- P2 第一轮技术验证与 P2-L 架构收敛已基本完成；P2-K 证明了截图边界、复杂剪贴板 fixture、helper recorder roundtrip、provider 设置确认和 Swift validator 候选的 spike 路径，但不等于正式 App、长期 recorder、多屏/权限撤销或真实 provider 调用已完成。
