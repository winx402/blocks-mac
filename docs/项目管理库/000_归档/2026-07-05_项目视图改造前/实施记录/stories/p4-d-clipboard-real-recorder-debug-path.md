---
id: P4-D
title: 剪贴板真实 Recorder Debug Path
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - P4-D 先做完
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P4-D 剪贴板真实 Recorder Debug Path

## Scope

本轮把正式工程里的 `JDToolLoginItemHelper` 从低敏 fixture store 扩展到受控真实 pasteboard watch debug path。它只在显式 CLI 参数下运行，默认不注册 Login Item、不长期常驻、不接 provider、不执行 hook、不把真实剪贴板原文写入仓库或日志。

已实现：

- `JDToolCore` 增加 recorder watch / inspect report，以及 `appendRecords`、`inspect`、`reset` store API。
- `JDToolCore` 增加 `debugDirectory()`：优先探测未来 App Group 共享容器；本地无可写 App Group 时回退到当前进程 sandbox Application Support。
- `JDToolLoginItemHelper` 新增 `--recorder-watch`、`--recorder-inspect`、`--recorder-reset`。
- `--recorder-watch --write-fixture-sample` 会短暂覆盖当前剪贴板，写入固定低敏样本，再保存 redacted 元数据记录。
- `--exclude-frontmost` 命中时只记录 `excluded=true`、`snapshot_skipped=true`，不读取 pasteboard items 和 types。
- App Clipboard 面板增加 “Import Debug Store” 入口，导入 `p4d-watch` redacted store；当前用于受控 debug，不声明已完成长期 helper 与主 App 共享 store。
- 新增三语 String Catalog 文案，覆盖导入按钮、debug 提示和导入成功/失败状态。
- 新增 `tools/verification/p4d_clipboard_real_recorder_debug_checks.py`，验证 helper watch/inspect/reset、workspace 不落 store、原文不出现在 JSON 输出、App 面板不直接访问 `NSPasteboard`。

## Acceptance Notes

- Given helper 以 `--recorder-watch --write-fixture-sample --store-name p4d-watch --reset` 启动，Then 它会记录至少一条真实 pasteboard change 的 redacted 元数据。
- Given helper 输出 watch / inspect JSON，Then 记录中不包含低敏 fixture 原文、base64、完整文件路径、provider 输出或 secret。
- Given helper 以 `--exclude-frontmost` 启动，Then 记录必须显示 `excluded=true` 和 `snapshot_skipped=true`，且不输出 pasteboard type 列表。
- Given App Clipboard 面板点击 Import Debug Store，Then App 只尝试读取 redacted store，并把结果导入当前内存态列表或显示本地化失败状态。
- Given 本地使用 ad hoc signing，Then 不要求 Developer ID、notarization 或 provisioning profile。

## Privacy And Safety

- 本轮会短暂覆盖当前剪贴板，写入固定低敏测试文本；不保存用户原剪贴板用于恢复。
- 真实用户事件在 P4-D 中始终 `fixture_owned=false`、`restorable=false`。
- helper 只保存 format summary、长度、短哈希、source app candidate 和摘要；不保存原文、RTF 内容、图片 base64、URL 原值或真实文件路径。
- `apps/JDTool/RuntimeClipboardRecorder/` 继续作为 ignored workspace 防护路径，但 P4-D 默认不写 workspace。
- App Group 共享容器只作为 future-ready 探测路径保留；由于本地 `Sign to Run Locally` 无 provisioning profile，本轮不启用 App Group entitlement。

## Not Covered Yet

- 长期 Login Item 注册、后台常驻、功耗评估和用户设置中的启停控制。
- helper 与主 App 的正式共享容器；App Group entitlement 需要在开发签名 / provisioning 决策后复测。
- 真实剪贴板内容的本地可恢复保存、格式恢复写回、分组、过期清理 UI、复杂第三方样本和隐私排除设置页。
- Agent / CLI 读取完整剪贴板内容；完整内容仍必须走 `preview` 确认路径。

## Verification

已执行并通过：

- `python3 tools/verification/p4d_clipboard_real_recorder_debug_checks.py --timeout 180`

P4-D 后续全链路回归见本轮提交记录。
