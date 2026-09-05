# 004_剪贴板打磨 Step 4 开发记录 v0

## 结论

状态：`implemented-with-evidence`。

本轮只实现 Step 4：详情编辑与元数据组织。未进入 Step 5 隐私页真实 App 清单、Step 6 集成验收，也未重做 Step 1 搜索/OCR、Step 2 标签事实源或 Step 3 面板专项交互。

## 改动范围

核心数据与仓储：

- `apps/Blocks/BlocksCore/AppDatabase.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
- `apps/Blocks/BlocksCore/ClipboardSearchDocument.swift`
- `apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailReadModel.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailEditCommand.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailURLValidator.swift`
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift`

App 层与 UI：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPayloadAccess.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`

工程与验证：

- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md`

## 关键实现

- 新增 schema v4 migration：`clipboard_items.content_revision`、`clipboard_items.content_updated_at`，以及 `clipboard_search_documents.content_revision`、`ocr_text_source`、`ocr_user_edited_at`、`ocr_locked_content_revision`。OCR source 默认 `none`，仅对已有成功且非空 OCR 文本条件回填 `vision`。
- 新增 bounded detail read model 和 metadata snapshot，详情阅读态不读取完整 payload；编辑态通过显式 purpose 读取。
- 新增显式 purpose：`detailEditRead`、`detailFullValueRead`、`detailEditSave`、`detailCopyFullValue`。Step 4 save/read 路径没有复用 paste、hover、translation、provider purpose。
- 新增单一 repository save command：`saveDetailEdit(command:)`。plain text、URL、rich text、OCR user-edited text 都走同一 transaction，同步更新 payload / summary / content revision / search document / FTS。
- URL 编辑只允许本地验证通过的 `http`、`https`、`mailto`；空值、相对路径、缺 scheme、控制字符、`file`、custom scheme 均阻断。
- Rich text fidelity 使用保守 gate。当前实现不会静默降级：最低可保真场景通过；遇到链接、列表、段落或 inline style 无法证明保真时返回 `richTextFidelityFailed`，由 UI 显示保存失败。
- OCR user-edited 保存写入 `userEdited` source 和 locked revision；OCR 队列 retry / late completion 遇到 user-edited source 时不覆盖用户编辑文本。
- `ClipboardDetailStore` 只持有 draft/edit/save UI 状态，不持有 AppModel/AppState/ClipboardController；持久事实源仍在 repository。
- 面板通过 context menu 打开 detail editor；row/card 主激活和 hover detail 保持 Step 3 行为，不把 detail edit 混入 paste activation。

## P13D Baseline Red

在实现前先运行：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
```

结果：`FAIL`，符合 baseline red 预期。低敏失败摘要包括：缺少 Step 4 当前实现文件、缺少 target membership、schema v4 contract、detail model contract、purpose matrix、repository save command、detail UI state、rich text fidelity、URL validation、OCR user-edited source 和 per-scenario evidence。

该 baseline 不读取真实剪贴板、不启动真实 App、不输出真实 payload。

## 验证结果

实现后验证矩阵：

| 命令 | 结果 | 摘要 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | `PASS` | Step 4 专属 gate 转绿；target membership、purpose matrix、state ownership、call graph、pasteboard read/write=0、sanitizer 均通过。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | `PASS` | Step 1 搜索/OCR 回归通过。 |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | `PASS` | Step 2 tag/favorite 回归通过。 |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | `PASS` | Step 3 面板交互/布局回归通过。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | `PASS` | Clipboard product polish 当前事实源门禁通过。 |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | `PASS` | Settings clipboard/system 当前事实源门禁通过。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | `PASS` | 已迁移 schema smoke 到 user_version 4；temp DB 路径低敏输出。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | `PASS` | 修复 Core 层 `import AppKit` 回归后通过。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | `PASS` | Clipboard hardening 回归通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | `PASS` | Blocks Debug 构建通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | `PASS` | BlocksCLI Debug 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | `PASS` | CLI help 输出 action/usage，不含敏感数据。 |
| `git diff --check` | `PASS` | 无 whitespace error。 |

修复过程中的中间失败：

- `p9a_clipboard_repository_storage_smoke.py` 初次失败原因是 smoke 仍要求 schema user_version 3；已按 Step 4 schema v4 迁移更新为当前事实源。
- `p9b_clipboard_appstate_repository_integration_checks.py` 初次失败原因是 `ClipboardRichTextFidelityService.swift` 在 Core 层引用 AppKit；已改为 Foundation-only 保守 fidelity service。

## P13D 证据摘要

- `target_membership.step4_files`: 全部 Step 4 新文件已进入 `Blocks` app/core target。
- `purpose_matrix.positive`: `detailEditRead`、`detailFullValueRead`、`detailEditSave`、`detailCopyFullValue` 均存在。
- `call_graph.save_path_forbidden_token_count`: `0`。
- `call_graph.pasteboard_read_attempts`: `0`。
- `call_graph.pasteboard_write_attempts`: `0`。
- `call_graph.async_reindex_enabled`: `false`。Step 4 保存使用同步 repository transaction，不启用异步 reindex。
- `state_ownership`: AppModel / ClipboardController 不成为 detail fact source；repository 是持久事实源；DetailStore 仅持有 draft UI 状态。
- `baseline_reference.old_story_or_archive_used_for_ok`: `false`。
- `sanitizer.ok`: `true`。

## Rich Text Fidelity

当前 rich text fidelity 策略是保守通过：能够证明最低 RTF payload 仍保持 rich text kind、plain text 派生一致、基础段落表示不被破坏时才保存；无法证明链接、列表、段落或 inline style 保真时返回 `richTextFidelityFailed`。这满足“不静默降级”的边界，但不是完整富文本编辑器。

## OCR User-Edited / Retry / Late Completion

- OCR user-edited 保存只更新 search document 中的 OCR 文本事实，不编辑图片本体或文件本体。
- 保存后 source 为 `userEdited`，并记录 locked content revision。
- OCR queue retry / late completion 发现 user-edited source 时跳过覆盖，避免 Vision 结果覆盖用户编辑文本。

## 安全与隐私声明

本轮没有触发真实 App、真实剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。验证使用静态门禁、低敏 fixture、temp database 和 spy/call-graph 证据；输出没有包含真实剪贴板正文、OCR 原文、完整路径、URL 全文、图片/base64、邮箱、secret、Authorization header、二维码或验证码。

## 未覆盖项与残余风险

- 未做真实 UI 自动化和真实系统剪贴板读写验证，这是派发边界要求；P13D 以静态 call graph、fixture scenario 和 spy 证据证明 Step 4 save path pasteboard read/write=0。
- Full value copy 只保留显式 purpose 与低敏证据边界；本轮不实现同步写系统剪贴板，也不触发真实 pasteboard。
- Rich text fidelity 是保守实现，不是完整富文本编辑器。复杂样式或链接列表无法证明保真时会阻断保存并提示失败。
- Detail editor 文案和 context menu 文案本轮以现有 UI 方式接入，未做完整多语言 polish；如产品要求更高文案覆盖，可作为后续 UI/本地化收口。
