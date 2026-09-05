# Step 2 代码审查复审 v0

状态：approve-with-changes
日期：2026-07-07
角色：代码审查
对象：`004_剪贴板打磨` Step 2 开发实现

## Findings

### P1 - tag search 重建 / 缺失文档路径会丢失已有标签 token

文件：

- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:336`
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:377`
- `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift:30`

`markSearchDocumentTagsDirty(recordIDs:)` 只在已存在 `ClipboardSearchDocument` 时更新 tag tokens；如果文档缺失，代码直接 `continue`。`rebuildSearchDocuments(limit:)` 用 `ClipboardSearchDocumentBuilder().build(record:payload:)` 重建文档，但没有从 `clipboard_record_tags` 读取已有标签；而 builder 的 `tags` 参数默认是空数组，`tagTokens` 只来自传入参数。

影响：

- 已有 `Tag / RecordTag` 关系在 DB 中仍然存在，但 search document 缺失或重建后，FTS/search_text 不会包含已有标签。
- 这会让当前 `tag_search.e2e_gate=pass` 口径过强：正常 create-and-attach 路径可以通过，但索引文档生命周期路径没有闭合。
- 后续 rename / merge / delete 虽能对已有文档更新 token，但对缺失文档路径仍不会重建或标记 pending。

建议：

- 在 repository 层提供统一的 search document 重建入口，重建时从 `clipboard_record_tags` / `clipboard_tags` 读取 tag tokens。
- `markSearchDocumentTagsDirty(recordIDs:)` 对缺失文档应创建带当前 tags 的文档，或显式标记 pending index，不能静默跳过后仍宣称 e2e gate pass。
- P9A 或 P13B 增加 fixture：已有记录带标签 -> 删除或缺失 search document -> rebuild -> 搜索标签名仍命中；同时覆盖 rename / merge / delete 的 tag search e2e。

### P2 - 单独标签筛选时，顶部“清除全部筛选”按钮不会出现

文件：

- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:41`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:269`

`displayFilterState` 会把 `tagStore.selectedTagID` 合入显示状态，但 header 中的清除按钮判断仍使用 `clipboardStore.filterState.hasActiveFilters`。`selectedTagID` 的当前事实源在 `ClipboardTagStore`，不在 `clipboardStore.filterState` 原值里，所以用户只选择标签筛选时，顶部 clear-all 按钮隐藏。

影响：

- 通过标签组里的 `All` 仍可回到全部，因此不是功能完全阻断。
- 但 Step 2 要求 active filter 有明确清除路径；当前全局清除入口对 tag-only filter 不一致，容易被误判为没有清除当前筛选。

建议：header 判断改用 `displayFilterState.hasActiveFilters` 或 `clipboardStore.hasActiveFilters`。

### P2 - App 层仍暴露旧 pinned count facade，P13B 未覆盖该退出项

文件：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift:79`
- `apps/Blocks/BlocksApp/Stores/ClipboardController.swift:4`
- `tools/verification/p13b_clipboard_tags_model_checks.py:263`

技术方案和开发派发都明确列出 `ClipboardController.pinnedCount` 必须退出 active path。当前 `ClipboardController.pinnedCount(in:)` 仍读取 `record.pinned`，`ClipboardStore.pinnedCount()` 仍向 App 层暴露该计算。静态检索未发现当前 UI 调用，所以这不是已发生的行为回流，但它仍是 active App 模块中的旧事实源入口。P13B 的 forbidden store tokens 没有覆盖 `pinnedCount`，因此门禁无法阻止这个残留。

建议：移除这两个 facade，或改为基于 favorite RecordTag 的 `favoriteCount`；同时把 `pinnedCount` 加入 P13B / P9B legacy active token 检查。

### P2 - Settings 标签操作反馈不满足创建外的操作契约

文件：

- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift:290`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift:367`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift:399`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift:410`

Settings 页只在“新建标签”行展示 `tagStore.operationError?.localizedMessage`。普通标签的 rename / recolor / move / merge / delete 按钮都丢弃返回值，没有就近错误提示、成功反馈或 delete / merge 影响说明。底层事务边界和失败不半更新基本成立，但 UI 反馈契约没有完全闭合。

影响：

- rename 重名、reserved name、merge invalid 等失败会改变全局 `operationError`，但错误显示在新建行 detail，用户不一定能关联到当前行操作。
- delete / merge 没有展示“从所有记录移除此标签”或“source 合并到 target”的最小结果说明。

建议：为 tag row 增加行内错误 / 成功反馈，delete / merge 使用 menu item 文案或 lightweight confirmation text 表达影响；至少把 `operationError` 显示到触发操作的 row。

## Open Questions / Residual Risk

- 右键菜单 `New Tag...`：当前 `ClipboardRecordViews.swift:195` 固定创建 `"New Tag"`。这不满足 PRD 中“新建失败在当前输入位置或当前操作语境展示错误”的完整交互，但在 Settings 页已有完整命名、重名和 reserved-name 管理的前提下，我判断它可以作为 Step 2 P2 残余接受，不是 must-fix。若项目负责人要求右键菜单本阶段完全闭合，应改为 popover/sheet 输入名称并保留失败输入。
- redacted / excluded 记录的标签搜索：`ClipboardSearchDocument.ftsProjectionText` 在 `payloadDerivationState == .redacted` 时返回空投影，因此即使 tag tokens 写入 search document，FTS 也不会命中该记录。PRD 未明确 redacted 记录是否应被标签名搜索命中；如果标签被视为用户显式元数据，应补充决策并加 fixture。
- 旧 `clipboard_pinboards` / `clipboard_pinned_metadata`、`ClipboardRecorderRecord.pinned`、repository 旧 pin/move/rename API 仍作为 legacy storage / baseline 残留。当前未发现 UI、Store 筛选、favorite button、search tag path 回流到这些事实源；但 P13B 应补上 `pinnedCount` 这类 App 层残留扫描。
- 本次只做静态源码复审，未触发真实 App、真实剪贴板、provider、TCC、Keychain、系统设置或真实 UI 自动化。项目负责人记录的构建和验证命令作为既有证据引用，未在本审查线程重新运行。

## 结论

`approve-with-changes`

主体实现方向符合 Step 2：`Tag / RecordTag` 独立事实源、favorite built-in、单标签筛选、Settings 管理、右键标签菜单、favorite 清理策略和旧 pinboard/pinned UI 退出都已落到当前工作区。旧 pinned / pinboard 没有发现行为回流到当前 UI / Store filter / favorite button / tag search 的主路径。

但 search document 重建 / 缺失文档路径会丢失已有标签 token，和当前 `tag_search.e2e_gate=pass` 口径不匹配。Step 2 最终接受前，应修复该路径或把 tag search e2e 降级为 residual risk，并补上对应 verifier。其余 P2 可以随 Step 2 残余接受或合并到下一轮 UI polish。
