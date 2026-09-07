# Blocks for Mac（积木工具）

面向 macOS 的截图、剪贴板和翻译工具，使用 SwiftUI 与 AppKit。
项目自有代码采用 [MIT](LICENSE)，第三方材料遵守各自许可，见
[第三方声明](THIRD_PARTY_NOTICES.md)。不再计划上架 App Store。

## 安装与发行状态

首版目标为 Apple Silicon / macOS 14+。目前尚未发布可供普通用户下载的官方
签名、公证安装包，不要把源码构建产物当作正式发行版。

`LocalDevelopment`、统一安装/发布入口、内置 Helper 和 App 内更新代码已接入。
源码版已完成无开发证书构建、安装启动及原地重装验证；完整功能与官方发行仍在验收，
不会把未验证能力标为通过。源码构建需要完整 Xcode 26+，不需要 Apple 开发证书。

```sh
git clone https://github.com/winx402/blocks-mac.git
cd blocks-mac
./script/dev.sh run
```

环境检查使用 `./script/dev.sh doctor`，测试使用 `./script/dev.sh test`，
干净工作树的快进更新与重新运行使用 `./script/dev.sh update`。
源码版显示为 **Blocks Dev**，不替换正式版或复用正式版数据。

统一入口、身份隔离和迁移边界见 [源码安装与独立发布](docs/技术知识库/源码安装与独立发布.md)。

贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
请勿在公开 Issue 上传 API key、配对密钥、剪贴板内容或个人截图。

## 历史资料

以下项目说明保留自 2026-07-05 的早期阶段，不代表当前功能或发行状态；当前实现
应以代码、测试及最新验收记录为准。

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

- 早期 P8 说明仅保留为历史上下文，不代表当前发行状态。现行分发规则是：项目自有代码采用 MIT 开源；官方版本不计划上架 App Store，而以 Developer ID 签名、Hardened Runtime 和 notarization 的沙盒直发包发布。`LocalDevelopment` 不启用 App Sandbox，并以独立 runtime identity、数据目录和 Keychain namespace 与官方包隔离。尚未完成真实验证的安装、更新或功能不会标为可用。
- 除已进入决策记录库的事项外，架构与 MVP 内容均为 `proposed` 或 `待验证`。
- P2 第一轮技术验证与 P2-L 架构收敛已基本完成；P2-K 证明了截图边界、复杂剪贴板 fixture、helper recorder roundtrip、provider 设置确认和 Swift validator 候选的 spike 路径，但不等于正式 App、长期 recorder、多屏/权限撤销或真实 provider 调用已完成。
