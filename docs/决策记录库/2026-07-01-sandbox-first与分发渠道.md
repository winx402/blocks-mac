# Sandbox-first 与分发渠道

状态：active
决策日期：2026-07-01
来源级别：user-confirmed decision

## 背景

「积木 AI 工具箱」V1 计划覆盖截图、剪贴板历史和翻译。这些能力会接触屏幕内容、剪贴板内容、选中文本、文件、Keychain、外部 CLI provider 和未来 hook runtime，属于高敏感本地能力。

用户已明确偏好：走 sandbox-first，这样安全一点；正式 App 尽量完整；直接下载还是 App Store 不应阻断前期开发。

当前核验结论：

- Apple App Sandbox 通过 entitlement 限制 App 对系统资源和用户数据的访问，用于降低 App 被攻破后的影响面。
- Developer ID 与 notarization 是 Mac App Store 外分发的主要信任路径。
- SMAppService 是 macOS 13+ 注册和控制 Login Item、LaunchAgent、LaunchDaemon helper 的主要候选 API。
- Apple 自动续订订阅属于 App Store Connect / StoreKit 路线；直接下载版不应把 Apple 订阅写成正式收费默认方案。
- StoreKit Testing 可在 Xcode 本地模拟 IAP，不等于本轮要接真实支付。

## 选项

1. 直接下载优先，放松 sandbox 约束，最大化系统集成自由度。
2. App Store 优先，严格按审核和 IAP 体系倒推首版能力。
3. sandbox-first，前期本地开发保留直接下载和 App Store 双出口。

## 结论

选择选项 3。

正式 App 从一开始按 sandbox-first 设计；分发渠道暂不锁死，保留两条出口：

- Direct Download：Developer ID + Hardened Runtime + notarization，后续可选 Sparkle/静态更新和自有 license。
- App Store：更严格 sandbox、StoreKit/IAP、审核和可能的功能裁剪。

前期本地开发使用 Xcode/local signing，不要求 Developer ID，不购买云服务器，不实现账号、真实订阅、license server 或真实支付。

## 后果

- P3 前所有正式 App 设计都必须列出 sandbox entitlement、TCC 权限、用户确认和失败提示。
- 外部 CLI provider 和 hook runtime 不得被设计成主 App 无提示任意执行；后续必须经过 helper、显式确认、审计和可撤销路径设计。
- 截图、剪贴板、文件访问、Keychain、Login Item、AI 外发和自动粘贴都必须按 sandbox-first 风险模型设计。
- 直接下载和 App Store 暂不影响大多数早期 UI、action core、本地数据库、Keychain 和工具流程开发。
- Developer ID、Hardened Runtime、notarization 在 Alpha 外部分发前准备；现在不把证书、profile、支付配置或 secret 写入仓库。
- Apple 订阅只作为 App Store 路线候选；直接下载路线后续若商业化，应另行设计 license/支付/授权方案。

## 复审条件

出现以下情况时复审本决策：

- App Store 审核或 sandbox 限制阻断外部 CLI、hook、剪贴板后台 recorder 或 Accessibility 主路径。
- 直接下载路线的签名、notarization、自动更新或用户信任成本超过预期。
- 商业化路线确认必须使用 App Store 订阅或必须使用自有支付/license server。
- 正式工程进入 Alpha 外部分发前，需要确认 Developer ID、notarization、更新和 crash/log 策略。

## 相关链接

- [分发与运行形态 v0](../技术知识库/分发与运行形态-v0.md)
- [macOS 权限与分发风险清单](../技术知识库/macOS权限与分发风险清单.md)
- [技术边界与架构假设](../技术知识库/技术边界与架构假设.md)
- Apple App Sandbox: <https://developer.apple.com/documentation/security/app-sandbox>
- Apple Developer ID: <https://developer.apple.com/developer-id/>
- Apple SMAppService: <https://developer.apple.com/documentation/servicemanagement/smappservice>
- Apple App Store subscriptions: <https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/>
- Apple StoreKit testing: <https://developer.apple.com/videos/play/wwdc2023/10142/>
