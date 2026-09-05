# 正式 App Scaffold 架构

状态：active
决策日期：2026-07-02
来源级别：architecture decision

## 背景

P2-K 已把第一轮技术验证批量跑通：截图 boundary suite、复杂剪贴板 fixture、helper recorder roundtrip、provider 设置确认 smoke、Codex 低敏 provider、Swift JSON Schema validator 候选和批量 runner 均已有证据。

但 P2-K 仍是 spike。下一步如果直接进入完整 App 实现，主 App、helper、CLI、provider、hook runtime 和 action core 很容易各自形成边界，导致确认绕过、后台能力过宽、schema 解释不一致或后续分发路线被过早锁死。

当前核验结论：

- Apple App Sandbox 仍是正式 App 的当前安全边界。
- SMAppService 是 macOS 13+ Login Item/helper 的主要候选 API。
- ScreenCaptureKit 继续作为截图捕获主候选。
- JSON Schema Draft 2020-12 和 JSON Schema Test Suite 继续作为接口校验基准。
- `swift-json-schema` `0.13.1` 已完成候选 spike，但尚未成为正式依赖。

## 选项

1. 先创建完整 App 工程，把截图、剪贴板、翻译都铺开。
2. 继续追加 P2 spike，暂不收敛正式工程边界。
3. 先固定正式 App scaffold 的最小运行架构，再进入 P3 scaffold / 截图纵切。

## 结论

选择选项 3。

P3 前正式工程形态暂定为：

```text
SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core
```

约束如下：

- 主 App 负责 UI、权限引导、设置、确认卡片、Keychain、审计展示。
- helper 优先承载剪贴板 recorder、后台心跳和轻量事件采集；默认不执行外部 CLI provider 或 hook。
- CLI 使用 `blocks` 前缀和统一 JSON envelope，后续与 App 共享 action core。
- 外部 provider 和 hook 必须走确认、预览、审计；hook enabled 前仍是高风险路径。
- JSON Schema 文件继续是接口事实源；第一方 action 用 Swift typed validation，外部输入和 hook manifest 预留完整 validator adapter。

本决策不创建正式 App 工程，不接真实支付，不调用真实 API，不启用任意 hook 脚本，不实现完整三工具 UI。

## 后果

- P3 可以从最小 scaffold 或截图纵切计划启动，但必须继承本决策的进程边界和确认规则。
- `tools/spikes/` 只作为验证证据，不能直接被视为正式模块。
- provider 设置页、Keychain account、base URL、模型名、外发 preview 和审计日志进入正式产品化设计范围。
- helper 的默认边界被收窄：采集和上报 redacted event，而不是执行任意自动化。
- `swift-json-schema` 仍是候选；正式采用前需要 wrapper、跨文件 `$ref`、错误映射、许可证和替换方案决策。
- Direct Download 与 App Store 仍保留双出口；Alpha 前再准备 Developer ID、Hardened Runtime、notarization、更新路径和审核边界复核。

## 复审条件

出现以下情况时复审本决策：

- P3 scaffold 发现 SwiftUI + AppKit 混合无法满足菜单栏、overlay 或快捷键体验。
- sandbox helper 无法支撑长期剪贴板 recorder、全局热键或需要的后台状态。
- 外部 CLI provider 或 hook runtime 必须进入 helper 或独立 XPC/service 才能满足安全边界。
- App Store 审核、TCC 权限、Developer ID/notarization 或用户信任成本迫使分发路线收敛。
- 真实 API provider、OCR 或本地模型接入需要改变 provider adapter 和审计模型。

## 相关链接

- [正式 App Scaffold 架构 v0](../技术知识库/正式AppScaffold架构-v0.md)
- [P2-L App Scaffold Architecture Spine](../项目管理库/000_归档/2026-07-05_项目视图改造前/规划产物/architecture/p2-l-app-scaffold-architecture/ARCHITECTURE-SPINE.md)
- [Sandbox-first 与分发渠道](2026-07-01-sandbox-first与分发渠道.md)
- [JSON Schema 校验策略](2026-07-02-JSON-Schema校验策略.md)
- [分发与运行形态 v0](../技术知识库/分发与运行形态-v0.md)
- [AI / Agent / CLI / Hook 能力边界](../技术知识库/AI-agent-CLI-Hook能力边界.md)
- Apple App Sandbox: <https://developer.apple.com/documentation/security/app-sandbox>
- Apple SMAppService: <https://developer.apple.com/documentation/servicemanagement/smappservice>
- Apple ScreenCaptureKit: <https://developer.apple.com/documentation/screencapturekit/>
- JSON Schema Draft 2020-12: <https://json-schema.org/draft/2020-12>
- JSON Schema Test Suite: <https://github.com/json-schema-org/JSON-Schema-Test-Suite>
- `swift-json-schema`: <https://github.com/ajevans99/swift-json-schema>
