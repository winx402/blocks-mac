# 2026-07-02 JSON Schema 校验策略

状态：accepted
最后审阅：2026-07-02
来源级别：technical decision

## 背景

P2-A 已把 action schema 从 Markdown 草案升级为 `docs/技术知识库/action-schemas/` 下的 JSON Schema / catalog 接口包。当前 `tools/spikes/p2_action_smoke.py` 会读取这些 schema，并验证 action、envelope、hook 示例。

但该 Python smoke harness 只实现当前 schema 用到的 JSON Schema 子集，不是完整 Draft 2020-12 validator。正式 App、CLI、agent 和 hook 不能长期各自解释 schema，否则会产生确认绕过、hook 启用边界不一致和错误处理分叉。

当前核验结论：

- JSON Schema Draft 2020-12 是当前 schema 声明使用的规范版本，包含 `$dynamicRef`、`prefixItems`、`unevaluatedItems`、format vocabulary 等 P2 子集尚未使用的能力。来源：<https://json-schema.org/draft/2020-12>
- JSON Schema Test Suite 是语言无关的 validator 行为测试集，并覆盖 draft-2020-12。来源：<https://github.com/json-schema-org/JSON-Schema-Test-Suite>
- `ajevans99/swift-json-schema` 当前自述提供 Swift 侧 JSON Schema 2020-12 validator 和 schema builder 能力，但本项目尚未接入或实测。来源：<https://github.com/ajevans99/swift-json-schema>
- `kylef/JSONSchema.swift` 当前自述声明支持多个 draft，但 2019-09 和 2020-12 支持不完整，且不支持 remote referencing；不适合作为未复测前的默认选择。来源：<https://github.com/kylef/JSONSchema.swift>
- Apple Foundation 的 `JSONDecoder` / `JSONSerialization` 可用于 JSON 解码或 Foundation object 转换，但它们不是 JSON Schema validator。来源：<https://developer.apple.com/documentation/foundation/jsondecoder>、<https://developer.apple.com/documentation/foundation/jsonserialization>

## 选项

1. 继续只使用轻量子集校验器。
2. 现在就在 P2 spike runtime 中引入完整第三方 Swift validator。
3. JSON Schema 继续作为接口事实源；P2 保留轻量 smoke；正式工程用 Swift typed validation 处理第一方 action，并为外部输入和 hook manifest 保留完整 validator 插槽。

## 决策

采用选项 3。

- P2 阶段不新增第三方 validator 依赖，`p2_action_smoke.py` 继续只作为 spike smoke harness。
- JSON Schema 文件和 `actions.catalog.json` 继续作为 UI、CLI、agent、hook 的接口事实源。
- 正式 App 的第一方 action 输入输出优先落成 Swift typed model / `Codable` / 显式业务校验；不能假设 `Codable` 自动覆盖 `additionalProperties`、跨字段确认规则或 hook 安全策略。
- agent 外部输入、CLI 外部输入、hook manifest 在进入 enabled 或执行路径前，必须通过完整 JSON Schema validator，或通过等价严格校验并有测试证明覆盖当前 schema 关键字。
- 任何候选 Swift validator 在进入正式工程前必须做独立 spike，至少跑通本项目 schema fixtures，并对照 JSON Schema Test Suite 的 Draft 2020-12 基础用例。

## 后果

- 避免在 P2 过早引入依赖，同时不给正式 runtime 留下“只靠 smoke 子集校验”的隐患。
- 后续正式 App scaffold 需要预留 `SchemaValidationService` 或等价边界，避免把 validator 逻辑散落在 UI、CLI、agent adapter 和 hook runtime 中。
- schema 演进在 validator spike 前不得随意使用 P2 子集之外的复杂 Draft 2020-12 关键字，例如 `$dynamicRef`、`unevaluatedProperties`、复杂 `prefixItems` 或 format assertion。
- hook runtime、agent 外部调用和 provider 配置 UI 不能在完整校验路径缺失时宣称已可正式落地。

## 后续实测

P2-K 已新增隔离 Swift Package `tools/spikes/blocks_schema_validator_probe/`，固定候选依赖 `ajevans99/swift-json-schema` `0.13.1`。

已通过：

- Draft 2020-12 基础用例：`type`、`required`、`additionalProperties`、`enum`、`const`、`minimum`。
- local `$ref` 用例。
- 本项目 action output fixtures。
- hook manifest fixtures。

仍未改变的边界：

- `swift-json-schema` 仍是候选，不是正式采用依赖。
- 统一 envelope 的跨文件 `$ref`、错误本地化和正式 runtime 封装仍需在 App scaffold 前决策。

## 复审条件

- 正式 App 工程 scaffold 启动 action core 实现前。
- hook manifest 从草稿文档进入可启用 runtime 前。
- CLI / MCP / App Intents 开始接受第三方或 agent 生成的外部 JSON 输入前。
- schema 需要使用当前轻量校验器未覆盖的 Draft 2020-12 关键字前。
- 准备引入任何 Swift JSON Schema validator 或代码生成工具前。

## 相关链接

- [Action Schema v0](../技术知识库/Action-Schema-v0.md)
- [Hook Manifest v0](../技术知识库/Hook-Manifest-v0.md)
- [P2 技术验证记录](../调研与验证库/2026-07-01-P2-技术验证记录.md)
- [P2-K 批量技术验证记录](../调研与验证库/2026-07-02-P2-K批量技术验证记录.md)
