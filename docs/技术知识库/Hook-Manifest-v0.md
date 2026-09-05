# Hook Manifest v0

状态：proposed
最后审阅：2026-07-01
来源级别：spike design

本文定义 P2-A 的 hook manifest 边界。schema 文件是可验证事实源：[hook-manifest.schema.json](action-schemas/hooks/hook-manifest.schema.json)。本文只解释接口意图和安全约束。

## 目标

- 让 agent 可以生成 hook 草案，但不能静默启用。
- 让 hook 与 action schema 使用同一套确认等级和审计边界。
- 先支持声明式 manifest，不开放任意脚本执行。

## 状态

| status | 说明 |
| --- | --- |
| `draft` | 草稿。agent 生成的 hook 默认必须处于该状态。 |
| `enabled` | 已启用。启用前必须经过用户确认。 |
| `disabled` | 已禁用。保留配置但不触发。 |

## 触发点

首轮只覆盖当前 P2 文档已定义的 hook 点：

- `after_screenshot_captured`
- `after_ocr_completed`
- `before_clipboard_item_saved`
- `before_clipboard_item_pasted`
- `before_translation_requested`
- `after_ai_action_completed`

## 确认等级

Hook 使用 [Action Schema v0](Action-Schema-v0.md) 的三级确认：

| level | 用途 |
| --- | --- |
| `preview` | 只预览或建议，不修改用户内容。 |
| `external_transfer` | 可能外发到 provider、API 或本地 CLI agent。 |
| `destructive_or_hook` | hook 启用、阻断、修改、删除、自动外发等高风险行为。 |

规则：

- agent 创建的 hook 必须先是 `draft`。
- `enabled` hook 必须使用 `destructive_or_hook` 确认。
- `block`、`modify`、`external_transfer` 效果必须使用 `destructive_or_hook` 确认。
- V1 不执行任意脚本；`runtime` 仅允许 `declarative`。

## 示例

- [敏感剪贴板保存前拦截](action-schemas/examples/hook-sensitive-clipboard-review.json)：`before_clipboard_item_saved`，默认草稿，启用需要 `destructive_or_hook`。
- [截图后 OCR 建议](action-schemas/examples/hook-screenshot-ocr-suggestion.json)：`after_screenshot_captured`，只建议 UI action，不执行脚本。

## 校验命令

```bash
python3 tools/spikes/p2_action_smoke.py validate-hook --json docs/技术知识库/action-schemas/examples/hook-sensitive-clipboard-review.json
python3 tools/spikes/p2_action_smoke.py validate-hook --json docs/技术知识库/action-schemas/examples/hook-screenshot-ocr-suggestion.json
```

## 非目标

- 不实现完整 hook runtime。
- 不执行 shell、AppleScript、JavaScript 或第三方插件代码。
- 不允许 agent 静默启用 hook。
- 不把 hook 当作绕过 UI 确认的自动化入口。
