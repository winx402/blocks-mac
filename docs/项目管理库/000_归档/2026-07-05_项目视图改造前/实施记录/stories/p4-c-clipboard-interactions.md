---
id: P4-C
title: 剪贴板历史本地交互完善
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - 继续完善粘贴板部分
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P4-C 剪贴板历史本地交互完善

## Scope

本轮在 P4-B 的剪贴板历史最小面板上补齐本地摘要交互：固定/取消固定、隐藏摘要、重置低敏 fixture、状态统计和对应三语 UI 文案。仍不读取真实剪贴板、不启动长期 helper、不保存真实用户剪贴板内容。

已实现：

- `ClipboardRecorderRecord.replacing(...)`：在 `JDToolCore` 中为不可变 redacted record 提供局部替换 helper。
- `AppState` 增加本地内存态操作：`toggleClipboardPin`、`removeClipboardSummary`、`resetClipboardFixtures`。
- `ClipboardHistoryView` 增加统计 badge：固定、可恢复、排除数量。
- 每条剪贴板摘要增加固定/取消固定、翻译预览和隐藏摘要图标按钮。
- 空状态和工具栏都可重置低敏 fixture。
- 新增三语 String Catalog 文案，覆盖新增按钮、统计和状态反馈。
- 新增 `tools/verification/p4c_clipboard_interactions_checks.py`，验证构建、P4-B 回归、本地化覆盖、交互入口和隐私边界。

## Acceptance Notes

- Given 剪贴板历史面板加载 fixture，When 用户点击 pin 图标，Then 该 redacted 摘要在内存态切换固定状态，并显示本地化状态反馈。
- Given 用户点击隐藏摘要，Then 该条 redacted 摘要从当前列表移除，不删除真实剪贴板内容，也不触碰系统剪贴板。
- Given 用户点击重置 fixture，Then 当前 debug 会话重新加载低敏 fixture 摘要。
- Given 用户搜索或切换暂停状态，Then P4-B 既有行为保持可用。
- Given 用户点击翻译图标，Then 仍进入 P5-A 的 confirmation preview，不调用 provider。

## Privacy And Safety

- P4-C 不导入或调用 `NSPasteboard`。
- 所有操作只作用于 `ClipboardRecorderFixture.records()` 生成的 redacted 内存记录。
- 隐藏摘要不是删除真实剪贴板，也不是修改系统剪贴板。
- 固定/取消固定当前仅是内存态行为；正式持久策略仍需在长期 recorder 和 store 接入后实现。
- Agent / CLI 默认仍只能取得摘要；完整内容读取必须走 `preview` 确认。

## Not Covered Yet

- 真实剪贴板 recorder 常驻、真实格式恢复写回、真实排除 App 设置和长期 retention 持久化。
- 分组、详情预览、自动粘贴、AI 处理、复杂第三方剪贴板样本和长期 helper 功耗。
- 用户真实剪贴板内容的本地可恢复保存路径；此能力必须在后续受控 store 设计和确认路径落地后再实现。

## Verification

已执行并通过：

- `python3 tools/verification/p4c_clipboard_interactions_checks.py --timeout 180`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`

