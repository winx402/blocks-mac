# Action 调用

状态：proposed
最后审阅：2026-07-01
来源级别：authoritative definition

## 模块定位

为 UI、快捷菜单、CLI 和 agent 调用提供统一动作定义。

## V1 功能

- 每个基础工具有 action 名称。
- action 定义输入、输出、错误、权限和 AI 调用要求。
- action schema/catalog 作为 UI、CLI、agent、hook 的共同接口事实源，见 [Action Schema v0](../../../技术知识库/Action-Schema-v0.md)。
- CLI JSON 输入输出。
- 记录调用来源和结果。
- 对敏感操作设置确认边界。
- 支持 provider 抽象：本地 CLI、API、本地模型均通过统一 AI provider layer 接入。
- 支持 hook 草案定义，但 V1 不默认开放任意脚本执行。

## 做到什么程度

- 同一个能力不应在 UI 和 CLI 各实现一套不兼容逻辑。
- agent 调用结果必须结构化。
- `requires_confirmation` 必须区分 `preview`、`external_transfer`、`destructive_or_hook`。
- 失败原因必须可读。

## AI 结合点

- AI 相关 action 必须声明是否调用模型、输入内容范围、输出结构和用户确认要求。
- 本地 CLI provider 和 API provider 都必须有超时、错误和审计记录。

## 首版不做

- 完整插件市场。
- 第三方 action 扩展系统。
- Agent 静默启用 hook。
