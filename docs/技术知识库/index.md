# 技术知识库

状态：active
最后审阅：2026-07-06

本知识库维护架构假设、接口形态、本地运行时、权限和分发约束。除已进入决策记录库的 sandbox-first、开源产品依赖边界和 JSON Schema 校验策略外，当前技术内容仍为 proposed。

当前架构升级状态：正式 App 工程已进入 Step 5 cleanup。`AppModel` 是组合根；截图、权限、快捷键、设置、Provider/Translation 和 Clipboard facts 由 feature store 承担；旧 `AppState` facade、`SettingsView` wrapper、Login Item helper target、P4 recorder debug UI 和长期兼容分支已移除。future helper/App Group、CLI clipboard payload、真实用户内容恢复、真实 OCR/provider 图片外发和分发打包仍需另开 PRD。

## 当前文档

- [组合根与剪贴板持久化职责](组合根与剪贴板持久化职责.md)：当前实现说明，覆盖 Store 绑定、独立取色和采集持久化的源码归属。
- [滚动截图捕获协调器职责](滚动截图捕获协调器职责.md)：当前实现说明，其状态以文档中的实现标记为准。
- [技术边界与架构假设](技术边界与架构假设.md)
- [正式 App Scaffold 架构 v0](正式AppScaffold架构-v0.md)
- [AI / Agent / CLI / Hook 能力边界](AI-agent-CLI-Hook能力边界.md)
- [AI Capability Provider Layer v0](AI-Capability-Provider-Layer-v0.md)
- [Action Schema v0](Action-Schema-v0.md)
- [Hook Manifest v0](Hook-Manifest-v0.md)
- [Provider Secret Handling v0](Provider-Secret-Handling-v0.md)
- [macOS 权限与分发风险清单](macOS权限与分发风险清单.md)
- [分发与运行形态 v0](分发与运行形态-v0.md)
- [剪贴板持久化存储方案 v0](../项目管理库/002_剪贴板持久化/剪贴板持久化存储方案-v0.md)：已迁入项目管理库，由剪贴板持久化项目承接后续实现与验收。
