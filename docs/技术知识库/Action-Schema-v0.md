# Action Schema v0

状态：proposed
最后审阅：2026-07-02
来源级别：spike design

本文定义 P2 技术验证用的最小 action schema。P2-A 后，可验证 JSON 文件已经成为接口事实源；本文只解释接口意图和使用边界，不再作为唯一事实源。

接口包入口：[actions.catalog.json](action-schemas/actions.catalog.json)

## 目标

- 让 UI、CLI、agent 和未来 hook 调用同一组 action。
- 用统一 JSON envelope 表达成功、失败、警告、确认需求和审计 ID。
- 先覆盖截图、剪贴板、翻译三个 V1 工具的最小链路。
- 避免 agent 通过 CLI 绕过用户确认和隐私边界。
- P2-B 起 action namespace 统一使用 `blocks.*`，不保留短名兼容。

## 非目标

- 不定义最终数据库 schema。
- 不定义最终 Swift / AppKit / SwiftUI 类型。
- 不承诺所有 provider 都能按此 schema 无头调用。
- 不在 smoke test 中读取真实屏幕、真实剪贴板或外部模型。

## Envelope

所有 action 输出必须是 JSON object：

```json
{
  "ok": true,
  "action": "blocks.translate.text",
  "result": {},
  "warnings": [],
  "audit_id": "act_..."
}
```

失败或需要确认时仍返回同一 envelope：

```json
{
  "ok": false,
  "action": "blocks.clipboard.search",
  "result": {},
  "warnings": [],
  "audit_id": "act_...",
  "requires_confirmation": {
    "level": "preview",
    "reason": "Full clipboard content requires explicit user authorization.",
    "preview": {
      "query": "token",
      "limit": 10
    }
  },
  "error": {
    "code": "requires_confirmation",
    "message": "Confirmation required."
  }
}
```

## 通用字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `ok` | boolean | 是 | action 是否完成。 |
| `action` | string | 是 | action 名称。 |
| `result` | object | 是 | 成功时的结构化结果；失败时为空对象。 |
| `warnings` | array | 是 | 非阻断提示。 |
| `audit_id` | string | 是 | 本次调用审计 ID。 |
| `requires_confirmation` | object | 否 | 需要用户确认时返回。 |
| `error` | object | 否 | 失败代码和面向开发者的错误信息。 |

## JSON Schema 文件

| 类型 | 路径 |
| --- | --- |
| catalog | [actions.catalog.json](action-schemas/actions.catalog.json) |
| envelope | [envelope.schema.json](action-schemas/shared/envelope.schema.json) |
| error | [error.schema.json](action-schemas/shared/error.schema.json) |
| confirmation | [confirmation.schema.json](action-schemas/shared/confirmation.schema.json) |
| screenshot input/output | [input](action-schemas/actions/blocks.screenshot.capture.input.schema.json) / [output](action-schemas/actions/blocks.screenshot.capture.output.schema.json) |
| clipboard input/output | [input](action-schemas/actions/blocks.clipboard.search.input.schema.json) / [output](action-schemas/actions/blocks.clipboard.search.output.schema.json) |
| translate input/output | [input](action-schemas/actions/blocks.translate.text.input.schema.json) / [output](action-schemas/actions/blocks.translate.text.output.schema.json) |
| hook manifest | [hook-manifest.schema.json](action-schemas/hooks/hook-manifest.schema.json) |

所有 schema 均使用 JSON Schema Draft 2020-12：<https://json-schema.org/draft/2020-12>。

## P2-H 校验策略

决策记录：[JSON Schema 校验策略](../决策记录库/2026-07-02-JSON-Schema校验策略.md)。

当前规则：

- `docs/技术知识库/action-schemas/` 和 `actions.catalog.json` 继续作为接口事实源。
- `tools/spikes/p2_action_smoke.py` 只用于 P2 smoke test；它当前覆盖 `$ref` 到本地文件、基础类型、`enum`、`required`、`additionalProperties`、`minLength`、`minimum`、`maximum`、`pattern` 和 `items` 等本项目已用子集，不是完整 Draft 2020-12 validator。
- P2 阶段不新增第三方 JSON Schema validator 依赖。
- 正式 App 的第一方 action 输入输出优先使用 Swift typed model / `Codable` / 显式业务校验；需要额外处理未知字段、跨字段确认规则和脱敏预览规则。
- agent 外部输入、CLI 外部输入、hook manifest 在进入 enabled 或执行路径前，必须通过完整 JSON Schema validator，或通过等价严格校验并以本项目 fixtures 和 JSON Schema Test Suite 基础用例证明。
- P2-K 已用隔离包验证 `ajevans99/swift-json-schema` `0.13.1` 候选：基础关键字、local `$ref`、项目 action output fixtures 和 hook manifest fixtures 通过。
- 当前没有任何第三方 validator 被本项目正式采用；统一 envelope 的跨文件 `$ref` 完整验证仍待正式方案处理。

## P2-L 正式 runtime 边界

- 正式 scaffold 中 UI、helper、CLI、agent 和 hook 都必须通过 shared action core 进入工具能力。
- Main App 负责用户可见 confirmation；CLI / agent 需要确认时必须返回同一 envelope 的 `requires_confirmation`，或交给主 App 触发确认路径。
- Helper 可以产生 redacted event 并调用允许的本地 action，但默认不执行 provider 外发或 hook。
- action schema 文件仍是接口事实源；Swift typed model 是第一方 runtime 的实现约束，不替代 schema 作为跨端契约。

## Confirmation levels

`requires_confirmation` 必须包含 `level`、`reason`、`preview`。`preview` 只能放摘要、数量、来源、provider、条目 ID 等脱敏信息，不放完整敏感内容。

| level | 用途 |
| --- | --- |
| `preview` | 读取完整剪贴板、真实截图、本地敏感内容预览。 |
| `external_transfer` | 外部 provider、API 或 CLI 可能接收用户内容。 |
| `destructive_or_hook` | hook 生效、阻断、修改、删除、自动外发等高风险行为。 |

## Action：`blocks.screenshot.capture`

用途：触发截图并返回截图结果引用。

输入草案：

```json
{
  "mode": "region",
  "dry_run": true,
  "send_to_ai": false
}
```

约束：

- `mode` 支持 `region`、`window`、`fullscreen`。
- P2 smoke test 只允许 `dry_run: true`。
- 真实截图、截图后外发给 AI、保存文件都必须进入权限与确认流程。

结果草案：

```json
{
  "capture_id": "cap_...",
  "mode": "region",
  "image_available": true
}
```

## Action：`blocks.clipboard.search`

用途：查询剪贴板历史。

输入草案：

```json
{
  "query": "hello",
  "limit": 10,
  "include_content": false
}
```

约束：

- 默认只返回摘要、类型、时间和 ID。
- `include_content: true` 必须要求确认或满足已配置授权策略。
- agent 默认不能读取完整剪贴板历史。

结果草案：

```json
{
  "items": [
    {
      "id": "clip_...",
      "kind": "text",
      "created_at": "2026-07-01T00:00:00Z",
      "summary": "content redacted"
    }
  ],
  "truncated": false
}
```

## Action：`blocks.translate.text`

用途：翻译手动文本、选中文本、剪贴板文本或截图 OCR 文本。

输入草案：

```json
{
  "text": "hello",
  "source_language": "auto",
  "target_language": "zh",
  "provider": "mock",
  "source": "manual"
}
```

约束：

- `source` 支持 `manual`、`selection`、`clipboard`、`screenshot`。
- `provider: mock` 只用于 P2 smoke test。
- 非 mock provider、剪贴板来源、截图来源都必须先展示预览并确认。

结果草案：

```json
{
  "source_language": "auto",
  "target_language": "zh",
  "text": "译文"
}
```

## 错误代码草案

| code | 说明 |
| --- | --- |
| `unknown_action` | action 不存在。 |
| `invalid_input` | 输入缺失或类型不符合 schema。 |
| `requires_confirmation` | 操作需要用户确认。 |
| `permission_denied` | 系统权限或用户授权不足。 |
| `provider_unavailable` | provider 不存在或不可调用。 |
| `provider_timeout` | provider 超时。 |
| `provider_invalid_output` | provider 未返回可解析结构。 |

## CLI 命令草案

```bash
blocks action list
blocks action schema blocks.translate.text
blocks action run blocks.translate.text --json '{"text":"hello","target_language":"zh"}'
```

P2 spike 使用本仓库脚本模拟：

```bash
python3 tools/spikes/p2_action_smoke.py list
python3 tools/spikes/p2_action_smoke.py schema blocks.translate.text
python3 tools/spikes/p2_action_smoke.py run blocks.translate.text --json '{"text":"hello","target_language":"zh"}'
python3 tools/spikes/p2_action_smoke.py smoke
```

## P2-A / P2-B 校验命令

```bash
python3 tools/spikes/p2_action_smoke.py validate-schemas
python3 tools/spikes/p2_action_smoke.py list
python3 tools/spikes/p2_action_smoke.py schema blocks.translate.text --kind input
python3 tools/spikes/p2_action_smoke.py run blocks.translate.text --json '{"text":"hello","target_language":"zh"}'
python3 tools/spikes/p2_action_smoke.py smoke
python3 tools/spikes/p2_action_smoke.py validate-hook --json docs/技术知识库/action-schemas/examples/hook-sensitive-clipboard-review.json
```

## P2 验收

- 三个 action 均能输出同一 envelope。
- 敏感输入能返回 `requires_confirmation`，而不是静默执行。
- CLI 输出可被 agent 直接解析为 JSON。
- action schema 能被 UI、CLI、hook manifest 共同引用。

## 待验证

- 具体 Swift JSON Schema validator 或代码生成工具是否采用，需在 P3 scaffold 的 validator adapter 设计中单独决策。
- audit log 是否由 action core 生成，还是由更底层 runtime 生成。
- provider 的结构化输出应使用模型 JSON schema、函数调用，还是后处理解析。
