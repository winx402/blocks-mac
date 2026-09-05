# Step 1B 开发记录 v0

日期：2026-07-07
角色：开发
结论：DONE_WITH_CONCERNS

## 1. 改动范围

本批次只实现 Step 1B：搜索状态与 Store/UI 接入。当前工作区已有 Step 1A 与协作文档未提交改动，本记录只覆盖 Step 1B 的实现与验证。

代码改动：

- `apps/Blocks/BlocksCore/ClipboardSearchDocument.swift`
  - 新增 `ClipboardSearchIndexActivity` 与 `ClipboardSearchResultSet`，承载 `idle/results/empty/emptyIndexing/partialIndexing/failed` 搜索状态及索引活动摘要。
- `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift`
  - 补齐 type synonym 与 time token：正文类型同义词、图片/链接/文件中英类型词、`YYYY-MM-DD`、UI 可见日期片段、`today/yesterday/今天/昨天`。
  - time token 保留完整归一化 term，避免 `YYYY-MM-DD` 被写入时拆分去重后不可检索。
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
  - `searchDocuments(query:limit:)` 返回 `ClipboardSearchResultSet`。
  - 新增本地 `searchIndexActivity()`，区分 pending index、pending/running OCR、failed OCR。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardSearchCoordinator.swift`
  - 新增搜索结果协调层，合并 repository result、现有 format/time/source/pinboard filter、repository availability 与索引状态。
  - 提供 panel 可用的低敏状态 presentation。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
  - 新增 `searchResult(query:limit:)`，非空查询走 repository search document / FTS projection 主路径。
  - `filteredRecords(query:)` 保留 facade，但改为读取 `searchResult.records`。
  - 查询结果路径继续加载 bounded preview snapshot，不批量读取完整 payload。
  - P1 返工后新增 `currentSearchResult` + `refreshSearchResult(query:limit:)` 显式刷新路径；View body 只读取当前结果，不在计算属性中触发 repository search 或 `@Published` 写入。
  - `previewSnapshots` 从 `@Published` 改为普通私有 cache，避免 preview cache 更新本身触发 SwiftUI 发布。
- `apps/Blocks/BlocksApp/Stores/ClipboardController.swift`
  - 移除旧的 visible string query filter 主路径，避免非空查询只在可见字符串上过滤。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
  - 面板查询结果改用 `ClipboardStore.searchResult`。
  - 接入确定无结果、索引中无结果、部分结果仍索引中、搜索路径失败的最小 UI 状态。
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
  - 新增搜索状态文案 key。
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
  - 新增 `ClipboardSearchCoordinator.swift` 到 Blocks app target。
- `tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`
  - 更新为 Step 1B 当前门禁，检查 SearchCoordinator、Store repository search path、UI state、localization、field tokens 与 target membership。
  - P1 返工后补充检查：Panel 不得直接调用 `clipboardStore.searchResult(query:)`；Store 必须使用 `currentSearchResult` / `refreshSearchResult` 显式刷新；search preview cache 不得是 `@Published`。
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
  - 补充正文、source、URL host/path、file name/extension、rich plain text、类型同义词、最小时间 token fixture。
  - 补充 `idle/results/empty/emptyIndexing/partialIndexing` search state fixture。

## 2. 未改范围

- 未实现 Step 1C Vision OCR queue、Apple Vision recognizer、OCR mock running-hold、retry UI。
- 未执行 Step 1D 设置页 hardening/redacted 文案清理和旧门禁迁移。
- 未推进 Step 2/3/4/5、标签/收藏、详情编辑、hover 布局、权限、provider、Keychain 或真实系统动作。
- 未触发真实 App、真实系统剪贴板、真实 OCR、TCC、provider、Keychain、系统设置、Show in Finder 或 restart。

## 3. 关键实现边界

- 非空查询主路径进入 repository `searchDocuments`，由 search document / FTS projection 提供结果；`ClipboardController.filteredRecords` 不再承担 query visible string filter。
- Panel body / computed property 路径只读取 `ClipboardStore.currentSearchResult`，不直接调用 repository search，不写 `repositoryUnavailable`，不写 preview cache。
- 搜索刷新只发生在显式生命周期/状态变化路径：`onAppear`、query change、records/search dependency change、filterState change、pinnedMetadata change。
- 现有 format/time/source/pinboard filter 在 `ClipboardSearchCoordinator.applyFilters` 中继续作用于 repository result 或默认列表，不另建事实源。
- `ClipboardSearchResultSet` 是 Store/UI 之间的搜索状态载体，`ClipboardStore.filteredRecords` 只是兼容 facade。
- 局部 pending index / OCR pending 只影响 `emptyIndexing` 或 `partialIndexing`，不会把已有结果覆盖成全局 failed。
- repository unavailable / query execution error 显示为搜索路径失败状态；未加入真实重试或诊断外发。
- 搜索状态 UI 仅展示低敏状态文案，不输出 query、matched snippet、完整 payload、完整 URL query、完整 file path、OCR 文本或图片数据。

## 4. 搜索 fixture

字段 fixture：

- content：text payload 可命中。
- source app：source bundle / app token 可命中。
- URL host/path：host/path token 可命中，不验证完整 query 输出。
- file name/extension：文件名与扩展名可命中，不输出完整 file path。
- rich plain text：rich text plain text 可命中。
- type synonym：`photo`、`图片` 等类型同义词可命中。
- time token：`YYYY-MM-DD`、`today`、`yesterday`、`今天`、`昨天` 可命中。

状态 fixture：

- `idle`：空 query 返回默认列表。
- `results`：命中且无 pending work。
- `empty`：无命中且无 pending work。
- `emptyIndexing`：无命中但存在 pending index。
- `partialIndexing`：有命中且存在 pending index。

## 5. P13A 变化

Step 1A 后 P13A：`ok=false`，6 个失败码。

Step 1B 实现后 P13A：`ok=false`，4 个失败码。`ok=false` 属预期，因为剩余项属于未派发的 Step 1C/1D。

本批次消除的 Step 1B 失败码：

- `visible_filter_search_path_active`
- `panel_uses_store_filtered_records_for_query`

剩余失败码归因：

- Step 1C：`ocr_recognizer_protocol_missing`、`apple_vision_implementation_missing`、`ocr_mock_missing`
- Step 1D：`settings_hardening_negative_tokens_active`

## 6. 验证结果

| 命令 | 结果 | 备注 |
|---|---:|---|
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | EXPECTED FAIL | `ok=false`，剩余 4 个失败码均为 Step 1C/1D；Step 1B 失败码已消除；P1 返工新增的 body/search publish 静态检查通过。输出低敏，sanitizer ok。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `schema_version=2`，验证 Step 1B search field fixtures 与 search state fixtures。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | Blocks app target 通过；存在既有 `FloatingPanelSupport.swift` main actor warning，不是本批次新增阻断。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI target 通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅执行 help，不触发真实剪贴板或系统动作。 |
| `git diff --check` | PASS | 本记录写入后复跑通过。 |

## 7. 低敏与安全声明

- 未读取真实系统剪贴板。
- 未触发真实 App、真实 OCR、TCC、provider、Keychain、系统设置、Show in Finder 或 restart。
- 验证只使用低敏 synthetic fixture。
- 验证输出不包含真实剪贴板正文、完整 URL query、完整 file path、图片 base64、完整 OCR 文本、secret 或 Authorization header。

## 8. 残余风险

- P0：无。
- P1：无。Step 1B 范围内两个 P13A 失败码已消除，P9A 与 build 已通过。
- P2：
  - P13A 仍为 `ok=false`，但剩余 4 个失败码归属 Step 1C/1D。
  - Panel 搜索状态已接入最小状态文案，但未做真实 App UI 自动化验收；按派发要求未触发真实 App。
  - 搜索刷新仍是同步 repository 查询；已移出 body 计算路径，后续如接入更高频实时搜索，可再评估 debounce 或异步查询边界。
