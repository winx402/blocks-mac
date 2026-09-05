# Step 1B 项目负责人验收 v0

日期：2026-07-07
角色：项目负责人
对象：`开发记录-Step1B-v0.md`
结论：accepted

## 1. 验收结论

Step 1B 接受。

本批次完成了搜索状态与 Store / UI 接入，非空搜索主路径已接入 search document / repository search，不再以面板可见字符串过滤作为主体搜索路径。返工后的 P1 风险已消除：`ClipboardFloatingPanelView` 不再在 SwiftUI body / computed path 直接调用 repository search，改为读取 `ClipboardStore.currentSearchResult`；repository 查询和 preview snapshot 加载收敛到显式 `refreshSearchResult(query:limit:)` 调用；`previewSnapshots` 也不再是 `@Published`。

Step 1C 可以在 Step 1 内继续串行派发；Step 2 / Step 3 仍暂停。

## 2. 独立核验结果

项目负责人复跑命令：

| 命令 | 结果 | 结论 |
| --- | ---: | --- |
| `rg -n "currentSearchResult|refreshSearchResult|@Published private var previewSnapshots|private var previewSnapshots|searchResult\\(query:" apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift` | PASS | 面板读取 `currentSearchResult`，显式触发 `refreshSearchResult()`；Store preview cache 为普通私有缓存。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | EXPECTED FAIL | `ok=false`，仅剩 Step 1C / Step 1D 失败码；Step 1B 失败码已消除。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `schema_version=2`，FTS enabled，字段 fixture 与状态 fixture 通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | Blocks App 构建通过；仅见既有 `AppModel.swift` unused value warning。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI target 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅执行 help，未触发剪贴板业务动作。 |
| `git diff --check` | PASS | 无 whitespace error。 |

`P13A` 剩余失败码：

- Step 1C：`ocr_recognizer_protocol_missing`
- Step 1C：`apple_vision_implementation_missing`
- Step 1C：`ocr_mock_missing`
- Step 1D：`settings_hardening_negative_tokens_active`

`P9A` 已验证搜索字段 fixture：

- `content`
- `source_app`
- `url_host_path`
- `file_name_extension`
- `rich_plain_text`
- `type_synonym`
- `time_token`

`P9A` 已验证搜索状态 fixture：

- `idle`
- `results`
- `empty`
- `emptyIndexing`
- `partialIndexing`

## 3. 范围核对

已接受事实：

- 新增或接入 `ClipboardSearchResultSet` / `ClipboardSearchCoordinator`，Store 可表达搜索状态。
- `ClipboardStore.currentSearchResult` 成为面板搜索结果 read model。
- 非空查询通过 repository search / search document / FTS projection 获取结果。
- 面板搜索框接入 Store search result / state，清空查询回到默认列表。
- 搜索与现有 format / time / source / pinboard 过滤保持可用组合。
- 面板补充确定无结果、索引中无结果、部分结果仍索引中、搜索失败等最小状态表达。
- P13A 已覆盖 View body 不直接调用 `clipboardStore.searchResult(query:)` 和 `previewSnapshots` 不可为 `@Published` 的返工门禁。
- P9A 已覆盖正文、source、URL host/path、file name、rich plain text、类型同义词、最小时间 token 与搜索状态 fixture。

未接受为本批次完成的内容：

- Vision OCR recognizer、Apple Vision 实现、OCR mock、OCR queue 和 retry UI 尚未实现，这是 Step 1C 范围。
- 设置页 hardening / redacted 负向 token 清理和旧门禁迁移尚未完成，这是 Step 1D 范围。
- 标签/收藏、详情编辑、隐私页 App 清单、面板 hover 安全区、单/双击控件和卡片密度专项仍不属于 Step 1B。

## 4. 残余风险

P0：无。

P1：无。开发回传中的 P1 已通过返工和独立复核消除。

P2：

- 本批次未做真实 UI 自动化录屏验收；当前接受依据为静态复核、repository smoke、构建和低敏 CLI help。
- OCR 相关状态目前仍由 search document lifecycle / pending 字段承接，真实 Vision pipeline、失败重试和 OCR 文本进入索引需要 Step 1C 关闭。
- 设置页仍保留 hardening / redacted 负向 token，必须由 Step 1D 关闭。

## 5. 下一步

派发 Step 1C：系统 Vision OCR 队列、recognizer protocol、确定性 mock、OCR 状态与 retry 入口。

Step 1C 目标是消除 `P13A` 中三个 OCR 残余失败码，并让图片 OCR 文本能在低敏、确定性 fixture 下进入 search document / 搜索结果；不进入 Step 1D 设置页清理，也不进入 Step 2/3/4/5。
