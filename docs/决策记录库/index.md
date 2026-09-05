# 决策记录库

状态：active
最后审阅：2026-07-02

本知识库维护重要决策的背景、选项、结论、后果和复审条件。

## 当前决策

- [2026-07-01-开源产品依赖边界](2026-07-01-开源产品依赖边界.md)：V1 不依赖现有开源整包产品完成核心主路径；相关项目仅作为产品功能、交互深度和边界设计参考。
- [2026-07-01-sandbox-first与分发渠道](2026-07-01-sandbox-first与分发渠道.md)：正式 App 按 sandbox-first 设计；前期开发保留 Direct Download 和 App Store 双出口，不接真实支付或自建服务器。
- [2026-07-02-JSON-Schema校验策略](2026-07-02-JSON-Schema校验策略.md)：P2 不引入第三方 validator；正式工程第一方 action 用 Swift typed validation，外部输入和 hook manifest 必须走完整或等价严格校验。
- [2026-07-02-正式AppScaffold架构](2026-07-02-正式AppScaffold架构.md)：P3 前正式工程形态暂定为 `SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core`。

## 仍待决策

三类通用工具深度、MVP 范围、最终分发渠道、商业目标人群、agent 调用协议、具体 validator 依赖、真实 provider 调用和 Alpha 分发链路仍处于 proposed / 待验证状态。

## 写入规则

- 一条决策记录只记录一个重要选择。
- 文件名使用 `YYYY-MM-DD-决策主题.md`。
- 决策记录应包含背景、选项、结论、后果、复审条件和相关链接。
