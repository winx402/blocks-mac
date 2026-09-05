# 文档总览

状态：active
最后审阅：2026-07-11
来源级别：authoritative definition

本目录是「积木 AI 工具箱」项目的文档入口。当前项目处于初始化阶段，文档重点是保存来源、明确边界、拆出待验证问题，而不是提前固化实现方案。`blocks` 是 P2 阶段暂定技术前缀，不代表最终品牌定稿。正式 macOS App scaffold 已进入 P8/P9 产品化打磨：截图区域/窗口/全屏纵切已完成当前桌面真实验收，截图结果浮层已有 OCR / Translate / Summarize route-ready 卡片；翻译已有 provider profile、confirmation preview、本地 mock 结果、Translation Engine router、OpenAI-compatible 翻译 runtime gate、Bob 风格独立浮层、检测语言/目标语言修正和记住上次目标语言；Settings 已形成 `Control + Option + A/V/D` 快捷入口、自定义录入、Provider / Shortcuts / Permissions / Clipboard / Translation / Agent & CLI / Hooks / Data & Audit 设置 route、稳定签名权限诊断、Accessibility 独立请求、Permission Assist 状态机、AI Capability Provider Layer、LLM adapter boundary、用户 API key Keychain 保存门禁、OpenAI-compatible test connection、内存态 provider audit summary 和三语 UI 本地化基础。剪贴板当前事实以代码为准：`ClipboardLiveCaptureService` 捕获系统 `NSPasteboard` 里的文本、RTF、URL、file URL 和 PNG/TIFF 图片，`ClipboardController` 承接 preview、筛选、source options 和 ingest 去重，浮层直接展示真实 payload 或图片缩略图，P8-M/P8-N 已完成模块化、自写入抑制、策略裁剪和条目内容字体设置，P9 已将生产级 `ClipboardRepository`、SQLite storage、payload 持久化、Pinboard metadata、删除和策略裁剪接入 AppState。仍未完成完整 V1：完整 Pinboard 编辑、Paste Stack、文本/富文本编辑、真实 OCR/provider 图片外发、packaging/notarization、多屏和权限撤销复测仍是后续项。

截图能力的后续规划以 [006_截图功能完善](项目管理库/006_截图功能完善/index.md) 为当前入口。006 已将智能截图、A/B 编辑器和统一设计语言回写第一阶段 PRD/UED；当前等待文档审阅及另行开发授权，尚未进入截图代码开发。

## 知识库

- [知识治理库](知识治理库/index.md)：文档归属、命名、状态和维护规则。
- [项目管理库](项目管理库/index.md)：项目目标、阶段状态、计划、验收和交接。
- [产品知识库](产品知识库/index.md)：产品定位、用户、能力范围、体验原则和 MVP 假设。
- [UI 与交互规范](产品知识库/UI与交互规范/index.md)：长期有效的布局、控件语义、状态反馈、动效和验收规则。
- [技术知识库](技术知识库/index.md)：技术边界、架构假设、接口形态和本地运行时约束。
- [调研与验证库](调研与验证库/index.md)：来源资料、竞品调研、验证计划、实验记录和待验证问题。
- [决策记录库](决策记录库/index.md)：重要决策的背景、选项、结论和复审条件。

## 当前优先阅读

1. [项目管理库](项目管理库/index.md)
2. [006 截图功能完善](项目管理库/006_截图功能完善/index.md)
3. [006 第一阶段 PRD](项目管理库/006_截图功能完善/step_1/PRD-截图采集与基础编辑.md)
4. [006 第一阶段 UI/交互原型](项目管理库/006_截图功能完善/step_1/UI-交互原型与状态说明.md)
5. [006 截图交互调研与设计语言审计](项目管理库/006_截图功能完善/step_1/截图交互调研与设计语言审计.md)
6. [架构升级项目](项目管理库/003_架构升级/index.md)
7. [架构升级方案 v0](项目管理库/003_架构升级/step_1/架构升级方案-v0.md)
8. [剪贴板持久化项目](项目管理库/002_剪贴板持久化/index.md)
9. [工具重命名项目](项目管理库/001_工具重命名/index.md)
10. [品牌重命名方案：旧称到积木工具 / blocks](项目管理库/001_工具重命名/品牌重命名方案-旧称到积木工具-2026-07-05.md)
11. [项目视图改造前归档](项目管理库/000_归档/2026-07-05_项目视图改造前/index.md)
12. [Blocks 正式 macOS App](../apps/Blocks/README.md)
13. [剪贴板历史：当前产品与实现逻辑](产品知识库/工具/文本/剪贴板历史-当前产品与实现逻辑.md)
14. [产品定位](产品知识库/产品定位.md)
15. [MVP 范围假设](产品知识库/MVP范围假设.md)
16. [技术边界与架构假设](技术知识库/技术边界与架构假设.md)
17. [正式 App Scaffold 架构 v0](技术知识库/正式AppScaffold架构-v0.md)
18. [AI / Agent / CLI / Hook 能力边界](技术知识库/AI-agent-CLI-Hook能力边界.md)
19. [AI Capability Provider Layer v0](技术知识库/AI-Capability-Provider-Layer-v0.md)
20. [Action Schema v0](技术知识库/Action-Schema-v0.md)
21. [Hook Manifest v0](技术知识库/Hook-Manifest-v0.md)
22. [Provider Secret Handling v0](技术知识库/Provider-Secret-Handling-v0.md)
22. [macOS 权限与分发风险清单](技术知识库/macOS权限与分发风险清单.md)
23. [分发与运行形态 v0](技术知识库/分发与运行形态-v0.md)
24. [Sandbox-first 与分发渠道](决策记录库/2026-07-01-sandbox-first与分发渠道.md)
25. [JSON Schema 校验策略](决策记录库/2026-07-02-JSON-Schema校验策略.md)
26. [正式 App Scaffold 架构](决策记录库/2026-07-02-正式AppScaffold架构.md)
27. [P2 技术验证记录](调研与验证库/2026-07-01-P2-技术验证记录.md)
28. [P2-K 批量技术验证记录](调研与验证库/2026-07-02-P2-K批量技术验证记录.md)
29. [Blocks Login Item Probe](../tools/spikes/blocks_login_item_probe/README.md)
30. [待验证问题](调研与验证库/待验证问题.md)
