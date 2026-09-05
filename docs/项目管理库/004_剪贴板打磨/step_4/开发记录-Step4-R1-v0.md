# 004_剪贴板打磨 Step 4 R1 开发记录

日期：2026-07-07

结论：DONE_WITH_EVIDENCE

## 范围

本轮只处理 Step 4 详情编辑与元数据组织 R1 返工，不进入 Step 5 / Step 6。

改动文件：
- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift`
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`

未改范围：
- 未进入 Step 5 隐私页 App 清单 / CLI 广义对象。
- 未进入 Step 6 或后续功能。
- 未重做 Step 1 搜索/OCR、Step 2 标签事实源、Step 3 面板专项。
- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。

## P1 修复说明

### P1-1：P13D 假 PASS

`p13d_clipboard_detail_edit_checks.py` 已从 token presence / scenario name presence 改为动态 deterministic fixture：
- 使用临时 storage root 编译并执行 Swift fixture。
- 每个 scenario 返回结构化 evidence。
- 对 mutation count、content revision before/after、pasteboard read/write、full value read/copy、sanitizer、assertions 做非空和 fail-closed 检查。
- 保留 baseline/current evidence 区分，旧 story/archive 不参与 ok 判定。

P13D evidence schema 摘要：
- `scenario_id`
- `fixture_id`
- `category`
- `result`
- `evidence_type`
- `mutation_count`
- `content_revision_before`
- `content_revision_after`
- `pasteboard_read_attempts`
- `pasteboard_write_attempts`
- `full_value_read_attempts`
- `full_value_copy_attempts`
- `failure_reason`
- `sanitizer`
- `assertions`

P13D 覆盖的关键类别：
- plain text / empty save
- URL valid / invalid
- rich text representative fidelity / malformed RTF failure
- OCR user-edited guard
- fault injection rollback
- revision / stale conflict / cache invalidation
- pasteboard read/write zero
- full value explicit read / fake copy evidence
- dirty-navigation UI binding static evidence
- v3 -> v4 migration

### P1-2：OCR user-edited guard

修复点：
- `ClipboardRepository.updateOCRResult` 在 `ocrTextSource == .userEdited` 或 `ocrLockedContentRevision != nil` 时直接拒绝更新，不再把 source 改写成 `.ignoredLateVision`。
- `ClipboardVisionOCRQueue.retryOCR` 与 process path 同步检查 user-edited / locked OCR。
- `ignoredLateVisionCompletion(recordID:)` 改为确认已忽略但不改写 search document。

证据：
- P13D `detail_ocr_user_edited_retry_004` PASS：
  - late completion rejected
  - retry rejected
  - second completion rejected
  - OCR text preserved
  - source preserved as `userEdited`
  - locked revision preserved
- P13D `detail_ocr_late_completion_ignored_004` PASS：
  - late completion rejected
  - text/source preserved

### P1-3：Dirty-navigation 三动作阻断确认

修复点：
- `ClipboardDetailStore` 新增 `pendingNavigationAction`，覆盖 close、record switch、exit editing。
- `requestOpen(recordID:)` / `requestClose()` 统一进入 dirty guard。
- 新增 `saveAndContinue()`、`discardChangesAndContinue()`、`continueEditing()` 三动作。
- `ClipboardDetailEditorView` 接入 `.confirmationDialog`，提供 `Save and Continue` / `Discard Changes` / `Continue Editing`。
- overlay dismiss 改为调用 `clipboardStore.closeDetailEditor()`，不再直接 cancel。

证据：
- P13D `detail_dirty_navigation_004` PASS：
  - pending navigation action
  - request open/close guard
  - save/discard/continue actions
  - confirmation dialog
  - overlay close guard
  - record switch open guard

### P1-4：Metadata full value

修复点：
- Repository 新增 `readDetailMetadataFullValue(recordID:itemID:purpose:)`，只接受 `detailFullValueRead` purpose。
- Metadata item 保留 `fullValueAvailable`、`copyPurpose`、category。
- Detail Store 新增 `fullValueText(item:purpose:)`、`revealFullValue(item:)`、`fullValueFeedback`。
- Detail UI 按 `shortMetadataItems` / `longMetadataItems` 分类渲染，full value 通过显式按钮读取，带 feedback 与 accessibility hint。

说明：
- 本轮实现的是等价完整值路径：显式读取并展开 full value，不同步写系统剪贴板。
- P13D 的 full value copy 场景使用 fake copy attempt 证明完整值路径与真实 pasteboard write=0，不作为真实系统剪贴板写入。

证据：
- P13D `detail_full_value_read_004` PASS。
- P13D `detail_full_value_copy_fake_pasteboard_004` PASS：
  - explicit full value read
  - fake copy attempt
  - real pasteboard write zero
  - UI fullValueAvailable / copyPurpose / fullValueText / feedback / category layout / accessibility hint binding present

### P1-5：Rich text 编辑合同

修复点：
- `ClipboardRichTextFidelityService` 保持 `BlocksCore` Foundation-only，不引入 AppKit。
- 服务保留原 RTF 容器和控制字，只替换与原 plain text 段落匹配的可见文本。
- 如果段落数量不匹配、可见文本匹配失败、RTF 结构未闭合或代表格式 evidence 不通过，则返回失败，不保存。
- evidence 覆盖 link、paragraph、inline style、list representation、kind remains rich text、plain text derivation updated。

证据：
- P13D `detail_rtf_format_004` PASS：
  - hyperlink field preserved
  - paragraphs preserved
  - inline style preserved
  - list representation preserved
  - payload kind remains richText
  - payload plain text updated
- P13D `detail_rtf_fidelity_failure_004` PASS：
  - malformed RTF rejected
  - revision unchanged

## 验证结果

全部命令均在本地低敏 fixture / 临时 DB / 静态检查范围内执行。

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS |
| `git diff --check` | PASS |

`blocks --help` 低敏输出摘要：
- usage: `blocks list | blocks run blocks.screenshot.capture --dry-run [--mode region|window|fullscreen]`
- actions: `blocks.screenshot.capture`

## 低敏输出与安全声明

- 未读取或写入真实系统剪贴板正文。
- 未同步写系统剪贴板。
- 未触发真实 App、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 未输出真实剪贴板正文、OCR 原文、完整路径、真实 App 名、邮箱、凭据或图片字节内容。
- P13D sanitizer self-check 覆盖 workspace root、home path、邮箱、TCC raw requirement/csreq 样例低敏处理。

## 残余风险

P0：无。

P1：无已知残留。

P2：
- Rich text fidelity 当前证明范围是代表 fixture 和结构化保真 evidence，不等价于覆盖所有真实来源 RTF 变体；不匹配时会 fail closed，不静默降级保存。
- Metadata full value 当前采用显式 reveal / fake copy evidence，不做真实系统剪贴板 copy；如果产品后续坚持真实 copy，需要单独设计 user-triggered pasteboard adapter 与验证边界。
- Dirty-navigation 真实 UI 交互未通过自动化点击实物验证；本轮以 Swift 编译、静态 binding evidence 和 store path 约束证明，不触发真实 App。
