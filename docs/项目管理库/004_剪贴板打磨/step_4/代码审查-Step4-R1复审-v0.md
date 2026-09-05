# 代码审查 - Step 4 R1 定向复审 v0

日期：2026-07-07

角色：代码审查

结论：`approve-with-changes`

建议项目负责人：R1 相对上一轮已实质关闭 P0/P1，可进入最终接受判断；但建议把本文列出的 P2 residual 明确纳入 Step 4 最终验收记录或 Step 6 回扫，不要写成真实 UI / 真实剪贴板 / 全量 rich text corpus 已验收。

## P0 / P1 结论

P0：无。

P1：未发现新的 P1。上一轮代码审查提出的五类阻塞项，本轮按定向复审范围判断均已关闭：

1. P13D 不再是 token / 文件存在假 PASS。
2. OCR user-edited guard 已覆盖 late completion / retry / second completion。
3. Dirty-navigation 已补三动作确认和 record switch / close guard。
4. Metadata full value 路径已从 Store/Core 接到 UI，且未在 Step 4 detail 路径写真实 pasteboard。
5. Rich text 保存已从“重建极简 RTF”改为代表格式保真 + fail-closed。

## P1 关闭证据

### 1. P13D 已转为 fail-closed dynamic fixture

证据：

- `tools/verification/p13d_clipboard_detail_edit_checks.py:116`-`797` 内嵌 Swift fixture，实际使用 BlocksCore 源码构造临时 repository / DB 场景。
- `tools/verification/p13d_clipboard_detail_edit_checks.py:880`-`966` 通过 `swiftc` 编译 fixture 并执行，编译失败、执行失败、JSON 解析失败均写入 failure。
- `tools/verification/p13d_clipboard_detail_edit_checks.py:969`-`990` 对每个 scenario 强制检查 result、mutation count、revision、pasteboard attempts、full value attempts、sanitizer、assertions 非空且全 true。
- `tools/verification/p13d_clipboard_detail_edit_checks.py:1406`-`1428` 缺 scenario 或 scenario evidence 失败会 fail closed。
- 本轮运行 P13D：`ok True`、`failure_count 0`、`scenario_count 29`、`null_mutation_count 0`、`null_revision_count 0`、`purpose_matrix.negative_reuse_count` 全 0，`current_evidence.development_record` 指向 `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`。

判断：上一轮“P13D false PASS”P1 已关闭。保留 P2：dirty navigation / full value UI 仍有一部分是静态 binding evidence，不等价于真实 App 点击验收。

### 2. OCR user-edited guard 已关闭覆盖漏洞

证据：

- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:385`-`388`：`updateOCRResult` 遇到 `.userEdited` 或 `ocrLockedContentRevision != nil` 时直接返回 `false`，不再把 source 改写为 `.ignoredLateVision`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift:42`-`44`、`:75`-`:77`：retry / process path 同时检查 `.userEdited` 和 locked revision。
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift:164`-`180`：保存图片 OCR 文本时写入 `.userEdited`、`ocrUserEditedAt`、`ocrLockedContentRevision`。
- P13D `detail_ocr_user_edited_retry_004` 输出：late completion rejected、retry rejected、second completion rejected、text/source/locked revision preserved 均为 true。

判断：上一轮 OCR P1 已关闭。

### 3. Dirty-navigation 三动作和 record switch guard 已接入

证据：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:4`-`8` 定义 pending navigation action：close / open / exitEditing。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:57`-`67`、`:331`-`:340`：open/close 统一经过 `requestNavigation`，dirty 时挂起 pending action 并进入 `.dirtyNavigation`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:178`-`203`：`continueEditing`、`discardChangesAndContinue`、`saveAndContinue` 三动作语义独立；保存失败不执行 pending action。
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift:25`-`43`：UI 接入 `confirmationDialog`，含 `Save and Continue`、`Discard Changes`、`Continue Editing`。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:766`-`767` 的 record switch 入口继续调用 `openDetailEditor`，而 `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift:208`-`213` 已透传到 detail store guard；overlay dismiss 改为 `closeDetailEditor()`，见 `ClipboardFloatingPanelView.swift:880`-`887`。

判断：上一轮 dirty-navigation P1 已关闭。

### 4. Metadata full value 已接入 UI，且未写真实 pasteboard

证据：

- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift:55`-`72` 新增 `readDetailMetadataFullValue(recordID:itemID:purpose:)`，只接受 `detailFullValueRead`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:262`-`289`：`fullValueText(item:)` 和 `revealFullValue(item:)` 从 UI 显式动作读取完整值并给出 feedback。
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift:170`-`207`：metadata 按 short / long 分类渲染，并在 `fullValueAvailable` 时提供 `Show full value` 控件。
- 静态搜索 Step 4 detail 路径未发现 `NSPasteboard` / `setString` / `writeObjects` / `clearContents`；P13D `detail_full_value_copy_fake_pasteboard_004` 输出 `full_value_read_attempts=1`、`full_value_copy_attempts=1`、`pasteboard_write_attempts=0`。

判断：上一轮“full value 未接 UI”P1 已关闭。保留 P2：当前用户可见实现是 reveal / show full value 等价路径，不是真实 copy full value；如果产品后续坚持真实复制，需要单独接 user-triggered pasteboard adapter 与 fake pasteboard 验证。

### 5. Rich text fidelity 已从静默降级风险改为代表 fixture + fail-closed

证据：

- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift:37`-`53`：要求 richText kind、RTF body、结构有效、原始 plain text 存在，否则失败。
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift:76`-`99`：按原始 plain text 行数和可见文本替换原 RTF，无法匹配则失败。
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift:62`-`73`、`:177`-`:214`：保存前检查 link、paragraph、inline style、list、kind、plain text derivation。
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift:144`-`158`：Repository 保存 rich text 时仍强制通过 fidelity service，否则抛 `richTextFidelityFailed`。
- P13D `detail_rtf_format_004` 输出 link / paragraphs / inline style / list / kind / plain text derivation 全 true；`detail_rtf_fidelity_failure_004` 输出 malformed RTF rejected、revision unchanged。

判断：上一轮 rich text P1 已关闭。保留 P2：当前证明范围仍是代表 fixture，不覆盖所有真实来源 RTF 变体；不匹配时会 fail closed。

## P2 Residual

1. Metadata full value 的用户可见路径是 `Show full value`，不是实际 copy。PRD 允许“copy full value 或等价完整值路径”，所以不作为 P1；但 R1 验收和 P13D 中的 “copy” 口径建议写清楚为 fake copy / reveal-only，不要让最终验收误以为已经实现真实系统剪贴板复制。
2. Dirty-navigation 和 metadata full value 的 UI 证据主要来自 SwiftUI binding / static evidence，未触发真实 App 点击、键盘焦点、VoiceOver 或窄宽度截图。该残余符合本次只读边界，应留给 Step 6 或后续低敏 UI 验收。
3. Rich text fidelity 仍是代表性实现：重复文本、复杂嵌套 RTF、非 UTF-8 RTF、字体/颜色/表格等不在 Step 4 代表 fixture 范围内。当前策略是 fail closed，不静默降级，产品体验风险仍需保留。
4. `Blocks` build 仍有既有 `FloatingPanelSupport.swift` main actor isolation warnings；不属于 Step 4 R1 新 P1，但建议后续统一收口。

## 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13d_clipboard_detail_edit_checks.py | python3 -c '...extract summary...'
python3 tools/verification/p13d_clipboard_detail_edit_checks.py | python3 -c '...extract key scenarios...'
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
git diff --check
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
```

结果摘要：

- P13D / P13A / P13B / P13C / P8 / P8I / P9A / P9B / P11E / `git diff --check`：PASS。
- `Blocks` build：PASS；有既有 `FloatingPanelSupport.swift` actor-isolation warnings。
- `BlocksCLI` build：PASS。
- `blocks --help`：PASS，低敏输出仅包含 usage 和 `blocks.screenshot.capture` action。

## 未覆盖风险

- 未触发真实 App、真实系统剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。
- 未做真实 UI / VoiceOver / 窄宽度自动化验证。
- 未验证真实系统剪贴板 copy full value，因为当前实现是 reveal-only 等价路径。

## 最终建议

建议项目负责人将 Step 4 R1 标记为 P0/P1 清零，并以 `approve-with-changes` 接受上述 P2 residual。若项目负责人要求 Step 4 内必须提供真实 copy full value，而非 reveal 等价路径，则需要追加小范围 R2；否则不建议阻塞 Step 4 最终验收。
