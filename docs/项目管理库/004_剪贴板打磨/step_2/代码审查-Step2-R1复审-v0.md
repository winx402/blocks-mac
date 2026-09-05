# Step 2 R1 代码审查定向复审 v0

状态：approve
日期：2026-07-07
角色：代码审查
对象：`004_剪贴板打磨` Step 2 R1 返工实现

## 1. 结论

`approve`

本次只做 R1 定向复审，没有重新做 Step 2 全量复审，也没有进入 Step 3。复审范围限定为上一轮 P1、R2、R3，以及开发顺手收口的 P2 是否引入新的 P0/P1/P2 风险。

结论：上一轮 P1 已关闭；本轮未发现新的 P0/P1/P2 findings。Step 2 是否最终接受仍由项目负责人结合测试/质量、UI/交互等复审结果决定。

## 2. P0 / P1 / P2 Findings

### P0

无。

### P1

无。

### P2

无新增 P2 finding。

说明：上一轮已记录的“右键菜单固定默认名 `New Tag`”在 R1 中已改为菜单文案 `Create "New Tag"`，但交互仍是固定默认名创建；在 Settings 页已有完整命名 / 冲突处理路径的前提下，我仍判断它不是 Step 2 R1 must-fix。真实 UI 体验未在本线程触发。

## 3. 上一轮 P1 关闭判断

上一轮 P1：tag search 重建 / 缺失 search document 路径会丢失已有标签 token。

判断：已关闭。

关键依据：

- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:336`：`markSearchDocumentTagsDirty(recordIDs:)` 在 search document 缺失时不再静默 `continue`，而是加载 record 后调用统一 `searchDocument(record:)` 重建。
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:381`：`rebuildSearchDocuments(limit:)` 对缺失文档也走同一 `searchDocument(record:)` helper。
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:474`：`tagSearchTokens(recordID:)` 从 `clipboard_record_tags` join `clipboard_tags` 读取 `display_name` 和 `normalized_name`。
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:501`：`searchDocument(record:)` 读取 payload 和当前 tag tokens，并将 tags 传给 `ClipboardSearchDocumentBuilder().build(...)`。
- `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift:30`：builder 接受 `tags` 参数，并在 `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift:45` 生成 `tagTokens`。
- `tools/verification/p9a_clipboard_repository_storage_smoke.py:317` 到 `tools/verification/p9a_clipboard_repository_storage_smoke.py:329`：新增 fixture 覆盖删除 search document 后，通过 `markSearchDocumentTagsDirty` 和 `rebuildSearchDocuments` 恢复 tagTokens 与 tag search 命中。
- `tools/verification/p13b_clipboard_tags_model_checks.py:360` 到 `tools/verification/p13b_clipboard_tags_model_checks.py:363`：P13B 将 `tag_search_missing_document_repair` / `tag_search_rebuild_path` 纳入 e2e gate。

## 4. R2 / R3 复核

R2：tag-only filter 下全局 clear-all 已闭合。

- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:41`：`displayFilterState` 把 `clipboardStore.tagStore.selectedTagID` 合入显示状态。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:269`：header clear-all 展示条件已改用 `displayFilterState.hasActiveFilters`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift:426`：`clearFilters()` 同时清 `filterState` 和 `tagStore.selectedTagID`。
- `apps/Blocks/BlocksApp/Support/ClipboardFilters.swift:238`：`ClipboardFilterState.hasActiveFilters` 包含 `selectedTagID`。
- `tools/verification/p8_clipboard_product_polish_checks.py:72`：P8 静态门禁覆盖该契约。

R3：active App 层旧 `pinnedCount` facade 已退出，并被 P13B / P9B 覆盖。

- `apps/Blocks/BlocksApp/Stores/ClipboardController.swift:4`：当前 `ClipboardController` 只保留 restorable / excluded / active filter / source options / ingest helper，未再暴露 `pinnedCount`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift:79`：`ClipboardStore` 保留 `restorableCount()`、`excludedCount()` 等当前 facade，未再暴露 `pinnedCount()`。
- `tools/verification/p13b_clipboard_tags_model_checks.py:263` 和 `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py:187`：`pinnedCount` 已进入 active store / app model 负向扫描。
- 针对性 `rg` 命中显示 `pinnedCount` 仅剩 core recorder baseline 结构和 verifier 负向 token，未命中 active App 层。

## 5. 顺手收口 P2 复核

未发现这些 P2 收口引入新的 P0/P1/P2 风险：

- String Catalog：`ClipboardTagOperationError.localizedMessage` 已改为 `L10n.string(...)`，相关 key 存在于 `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`。
- `+N` chips：`apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift:208` 起的 `ClipboardTagChips` 只展示前三个 tag，溢出时显示 `+\(overflowCount)`，并使用 `clipboard.tags.moreTags` 作为 help 文案。
- `Create "New Tag"`：`apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift:197` 起使用 `clipboard.tags.createDefault`；`rg` 未发现旧 `New Tag...` 菜单文案。

## 6. 实际查看的关键文件

- `AGENTS.md`
- `agents/代码审查.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/项目负责人-Step2开发复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/开发记录-Step2-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/项目负责人-Step2-R1验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/代码审查-Step2开发复审-v0.md`
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
- `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository.swift`
- `apps/Blocks/BlocksCore/ClipboardTag.swift`
- `apps/Blocks/BlocksCore/ClipboardTagRepository.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardTagStore.swift`
- `apps/Blocks/BlocksApp/Support/ClipboardFilters.swift`
- `apps/Blocks/BlocksApp/Stores/ClipboardController.swift`
- `apps/Blocks/BlocksApp/App/AppModel.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardSearchCoordinator.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
- `tools/verification/p8_clipboard_product_polish_checks.py`
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
- `tools/verification/p13b_clipboard_tags_model_checks.py`

## 7. 实际运行的只读验证命令

通过：

```bash
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
jq empty apps/Blocks/BlocksApp/Resources/Localizable.xcstrings
rg -n "pinnedCount|New Tag\\.\\.\\.|Create \"New Tag\"|displayFilterState\\.hasActiveFilters|tag_search_missing_document_repair|tag_search_rebuild_path|clipboard\\.tags\\.error\\.|clipboard\\.tags\\.createDefault|clipboard\\.tags\\.moreTags" apps/Blocks tools/verification
rg -n "pinnedCount" apps/Blocks/BlocksApp apps/Blocks/BlocksCore tools/verification/p13b_clipboard_tags_model_checks.py tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
rg -n "markSearchDocumentTagsDirty|rebuildSearchDocuments|tagSearchTokens|searchDocument\\(record:" apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift tools/verification/p9a_clipboard_repository_storage_smoke.py tools/verification/p13b_clipboard_tags_model_checks.py
```

补充说明：

- `python3 tools/verification/p13b_clipboard_tags_model_checks.py` 输出 `ok=true`，`tag_search.e2e_gate=pass`，`legacy_exit.active_store_paths_clear=true`。
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` 输出 `ok=true`。
- `python3 tools/verification/p8_clipboard_product_polish_checks.py` 输出 `ok=true`，其中 `step2_clear_all_includes_tag_filter=true`。
- `jq empty apps/Blocks/BlocksApp/Resources/Localizable.xcstrings` 退出码 0，确认 catalog JSON 可解析。
- 曾尝试 `plutil -lint apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`，该环境返回 `Unexpected character { at line 1`，未作为项目失败依据；已用 `jq empty` 做替代语法校验。

未运行：

- 未运行 `tools/verification/p9a_clipboard_repository_storage_smoke.py`，因为它会编译 / 运行 Swift smoke 并使用临时 DB fixture，不属于本线程的最小只读复审动作。本次仅阅读其新增 fixture 源码，并引用项目负责人已独立运行通过的验收记录。
- 未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

## 8. Residual Risk

- 真实 macOS UI、真实剪贴板、provider、Keychain、TCC 和系统设置未在本代码审查线程触发；这些仍需要由测试/质量或项目负责人按阶段边界决定是否补验。
- 右键菜单仍是固定默认名创建 `New Tag`，完整命名输入交互未在 R1 实现；我判断为可随 Step 2 接受的 P2 残余，不是本轮阻断。
- core 层 legacy pinboard / pinned baseline 类型仍存在；本轮只确认它们未回流到 active App 层 `pinnedCount` facade，也确认 P13B / P9B 已覆盖 active path 负向扫描。
