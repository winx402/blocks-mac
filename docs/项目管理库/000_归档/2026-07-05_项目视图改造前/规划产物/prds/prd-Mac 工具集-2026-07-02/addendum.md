# V1 PRD Addendum

状态：supporting
最后审阅：2026-07-02
来源级别：PRD support notes

本文保存 V1 PRD 的支撑背景和被主文档压缩的技术上下文。它不是需求主文档；需求以 [prd.md](prd.md) 为准。

## 输入来源

- [V1 产品规格](../../../../V1产品规格.md)：定义截图、剪贴板、翻译三类工具的 Jobs、必做、暂缓、不做和验收场景。
- [V1 交互规格草案](../../../../../产品知识库/交互整合/V1交互规格草案.md)：定义菜单栏、截图浮层、剪贴板面板、翻译面板和设置页的交互骨架。
- [正式 App Scaffold 架构 v0](../../../../../技术知识库/正式AppScaffold架构-v0.md)：定义 P3 前 Main App、Helper、CLI、Provider、Hook、Action Core、Store 和 Schema 的职责边界。
- [Action Schema v0](../../../../../技术知识库/Action-Schema-v0.md)：定义 `jdtool.*` action、统一 envelope、confirmation levels 和 CLI smoke 边界。
- [P2 技术验证记录](../../../../../调研与验证库/2026-07-01-P2-技术验证记录.md) 与 [P2-K 批量技术验证记录](../../../../../调研与验证库/2026-07-02-P2-K批量技术验证记录.md)：保存截图、剪贴板、Keychain、helper、provider smoke 和 validator 候选的第一轮验证证据。

## P2 / P2-L 对 PRD 的约束

- 正式 App 按 sandbox-first 设计，Direct Download 和 App Store 双出口暂不锁死。
- P3 前工程形态暂定为 `SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core`。
- Helper 首轮优先承载剪贴板 recorder、后台心跳和轻量事件采集；默认不执行外部 CLI provider、hook 或自动粘贴。
- API secret 默认进入 Keychain；CLI provider 使用自身登录态，工具不读取或保存 CLI token。
- JSON Schema 文件是接口事实源；`swift-json-schema` `0.13.1` 只是候选 spike，不是正式采用依赖。
- App UI 本地化是 V1 横向约束，首批语言为 `zh-Hans`、`en`、`ja`；它不扩大翻译工具本身的语言覆盖。CLI/action JSON 字段、action 名称和 `error.code` 保持未本地化。
- macOS 26 Liquid Glass 是视觉渐进增强，不提高 macOS 14 最低部署版本；旧系统使用原生 material / `NSVisualEffectView` 回退。

## P2-Q Targeted Correction 记录

- 翻译默认快捷键关闭为 V1 默认未设置，由设置页引导用户录入、禁用或恢复默认。
- 剪贴板保存策略关闭为：非排除 App 的支持类型默认本地可恢复保存；agent 默认只读取 redacted summary，完整内容读取必须 `preview` 确认。
- Provider 默认策略关闭为 BYOK/API 配置和本地 CLI；V1 不提供内置云额度、账号、订阅或 license server。
- MCP server、App Intents / Shortcuts 不进入 V1，作为 V1.1+ 候选。
- Direct Download / App Store 继续双出口不锁死；该分发决策不阻塞 P3-A 本地 scaffold。

## 已验证但不能过度解释的内容

- ScreenCaptureKit display、rect、window 和 boundary suite 已在当前机器通过，但当前机器只有一个 display，多屏和跨屏未覆盖。
- AppKit 临时 overlay 选区、取消、超时、过小选区已验证，但不是最终截图 UI。
- NSPasteboard 低敏 fixture 的 text、RTF、PNG、URL、file URL、HTML、multi、transient、file-list 已通过 roundtrip，但不代表第三方复杂 App 样本已覆盖。
- Keychain dummy secret 生命周期已验证，但真实 API provider 未调用。
- SMAppService 最小 helper 已验证注册、心跳、注销、低敏 recorder roundtrip，但长期功耗、崩溃恢复和用户撤销仍未覆盖。
- P3-A scaffold 已验证 String Catalog 可构建出 `zh-Hans`、`en`、`ja` 资源，当前语言设置先保存偏好并提示重启生效；运行时无重启切换不是本轮目标。
- P3-A scaffold 已引入统一 `GlassPanel` wrapper；其 macOS 26+ Liquid Glass 路径依赖当前 Xcode/macOS SDK，旧系统回退可构建但仍需在 macOS 14-25 真机环境做视觉复测。

## PRD 主文档有意不写入的技术细节

- 正式 Swift package/module 目录结构。
- Xcode target、entitlement、code signing、notarization 配置。
- SQLite/CoreData 的具体 schema。
- `swift-json-schema` adapter 的具体 API。
- Provider prompt、模型 JSON schema 或函数调用协议。
- Hook runtime sandbox 或脚本执行机制。

这些内容进入后续 Architecture、UX Spec、P3-A scaffold plan 或 epics/stories。

## 后续建议

1. 以 P2-L 架构和 P2-Q correction 为约束，制定 P3-A 最小正式 App scaffold 或截图纵切计划。
2. P3-A 计划必须固定 target、entitlement、helper 嵌入方式、local signing、action core smoke 和测试命令。
3. 推荐隐私排除 App 列表、Alpha 分发路线、多屏/权限撤销/第三方复杂剪贴板样本继续作为后续复测或设置页细化项。
