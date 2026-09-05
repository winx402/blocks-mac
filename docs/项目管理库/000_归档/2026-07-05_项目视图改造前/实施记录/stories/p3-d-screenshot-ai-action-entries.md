# P3-D Screenshot AI Action Entries

状态：done
最后审阅：2026-07-02
来源级别：implementation story

## Story

As a 奇点工具 user,
I want screenshot results to expose OCR, Translate, and Summarize entry points,
so that future AI workflows are visible without silently uploading the screenshot image.

## Scope

- 新增 `ScreenshotAIAction`，覆盖 OCR / Translate / Summarize。
- 截图结果浮层新增 AI actions 区块和 preview card。
- Preview card 展示 mode、尺寸、source、action detail 和 route-only 状态。
- 所有 AI action 当前只返回 preview；不上传图片、不调用 OCR、不调用 LLM/provider。
- 新增三语文案覆盖 action 名称、preview 状态和图片未上传提示。

## Non-goals

- 不执行真实 OCR。
- 不调用翻译 runtime、LLM provider、CLI provider 或 OCR provider。
- 不上传截图图片、OCR 图片或截图内容。
- 不新增持久截图历史、标注、拖拽导出或多屏复测。

## Acceptance Criteria

- Given 截图结果浮层打开，When 用户点击 OCR / Translate / Summarize，Then UI 展示对应 preview card。
- Given preview card 展示，Then 它必须说明 provider call 未执行且 image 未上传。
- Given 用户继续 Copy / Save As / Retake，Then 原有截图结果操作仍可用。
- Given 新增 UI 文案，Then `zh-Hans`、`en`、`ja` 都有 String Catalog 覆盖。

## Verification

- `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py --timeout 180`
- `python3 tools/verification/p3c_screenshot_checks.py --timeout 180`

## Notes

- P3-D 只补入口和安全状态，不改变 provider runtime。后续 OCR provider、截图翻译和总结需要单独 story。
