# 决策记录库

状态：active
最后审阅：2026-07-02

本知识库维护重要决策的背景、选项、结论、后果和复审条件。

## 当前决策

- [2026-07-01-开源产品依赖边界](2026-07-01-开源产品依赖边界.md)：V1 不依赖现有开源整包产品完成核心主路径；相关项目仅作为产品功能、交互深度和边界设计参考。
- [2026-07-01-sandbox-first与分发渠道](2026-07-01-sandbox-first与分发渠道.md)：2026-07 的双出口决策已被当前规则取代；官方发行固定为 MIT 开源、Developer ID 沙盒直发、Hardened Runtime 与 notarization，不计划 App Store；LocalDevelopment 保持非沙盒隔离。
- [2026-07-02-JSON-Schema校验策略](2026-07-02-JSON-Schema校验策略.md)：P2 不引入第三方 validator；正式工程第一方 action 用 Swift typed validation，外部输入和 hook manifest 必须走完整或等价严格校验。
- [2026-07-02-正式AppScaffold架构](2026-07-02-正式AppScaffold架构.md)：2026-07 的 scaffold 历史记录；其中“sandbox-first”仅适用于当时设想的正式 App，不覆盖现行 LocalDevelopment 非沙盒隔离规则或已确定的 Developer ID 直发渠道。

## 仍待决策

三类通用工具深度、MVP 范围、商业目标人群、agent 调用协议、具体 validator 依赖、真实 provider 调用和官方直发链路的验收仍处于 proposed / 待验证状态；发行渠道本身已确定，不再以 App Store 作为候选出口。

## 写入规则

- 一条决策记录只记录一个重要选择。
- 文件名使用 `YYYY-MM-DD-决策主题.md`。
- 决策记录应包含背景、选项、结论、后果、复审条件和相关链接。
