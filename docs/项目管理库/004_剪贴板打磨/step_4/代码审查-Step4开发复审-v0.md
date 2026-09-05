# 代码审查 - Step 4 开发复审 v0

日期：2026-07-07

角色：代码审查

结论：`rework-required`

建议项目负责人：暂不接受 Step 4 开发实现。当前 schema v4、detail purpose、Repository 保存主路径和 Step 5/6 边界方向基本正确，但存在会破坏 Step 4 核心合同的 P1 问题：P13D 不是 fail-closed 证据门禁、OCR user-edited 保护在一次 late completion 后失效、dirty-navigation 未按 PRD 实现。建议先返工 P1，再重新跑 P13D 和回归矩阵。

## P0 Findings

无。

## P1 Findings

### P1-1：P13D 当前是假 PASS，不满足 Step 4 硬门禁的 fail-closed 证据要求

证据：

- `tools/verification/p13d_clipboard_detail_edit_checks.py:452`-`453` 用 `scenario in scenario_source` 判断场景是否存在，等价于检查字符串是否出现在 verifier / 源码中。
- `tools/verification/p13d_clipboard_detail_edit_checks.py:516`-`529` 为每个 scenario 输出 `mutation_count = None`、`content_revision_before = None`、`content_revision_after = None`、`full_value_read_attempts = None`、`full_value_copy_attempts = None`，但只要字符串存在且无其他静态 failure 就 `result = pass`。
- 本轮运行 `python3 tools/verification/p13d_clipboard_detail_edit_checks.py`：`ok True`、`status pass`、`scenario_count 29`，同时 `null_mutation_count 29`、`null_revision_count 29`。`purpose_matrix.negative_reuse_count` 输出 `paste: 1`、`searchIndex: 4`，仍然 PASS。
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md:407`-`430` 要求 P13D 是 fail-closed verifier，且“仅输出已检查不能作为通过证据”。
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md:648`-`666`、`:740`-`:752` 要求每个关键场景输出真实 mutation count、content revision before/after、pasteboard attempts、full value attempts，并且负向 purpose 复用计数为 0。

影响：

- P13D 无法证明 payload / summary / search document / FTS / updatedAt / contentUpdatedAt 的原子更新，也无法证明 rollback、dirty navigation、OCR late completion、rich text fidelity 和 pasteboard no-write。
- 该门禁已经漏掉本复审发现的 P1-2、P1-3；因此项目负责人已跑通过的 P13D 不能作为 Step 4 接受证据。

可执行修复建议：

- 将 P13D 改为低敏临时 DB / fixture runner，而不是字符串扫描。保存成功类场景必须断言 `mutation_count = 1`、content revision 递增、payload / summary / search document / FTS / detail read model 一致。
- invalid / conflict / rollback 类场景必须断言 `mutation_count = 0`，并证明 payload、summary、search document、FTS、contentRevision、updatedAt/contentUpdatedAt 未部分提交。
- OCR user-edited retry / late completion 必须执行真实状态序列。
- purpose matrix 中 `.hoverDetail`、`.paste`、`.copyPlainText`、`.translationPreview`、`.ocrInput`、`.searchIndex`、provider 相关复用计数非 0 时应 fail。
- pasteboard read/write attempts 应来自 fake pasteboard / adapter spy 或等价可执行证据，不应只靠 `NSPasteboard` 字符串缺失推断。

### P1-2：OCR user-edited 文本在第一次 late completion 被拒后，后续 retry / completion 仍可能覆盖用户编辑文本

证据：

- `apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift:385`-`394`：`updateOCRResult` 遇到 `.userEdited` 时，会调用 `document.replacingOCR(... source: .ignoredLateVision ...)` 并 upsert，然后返回 `false`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift:42`-`44` 和 `:74`-`:76`：retry / process 的保护条件只检查 `document.ocrTextSource != .userEdited`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift:45`-`54`：retry 在保护通过后会先把 OCR 状态写回 pending。
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md:189`-`199` 要求 user-edited OCR 文本不得被 retry 或 late completion 静默覆盖。

可复现的代码路径：

1. 用户保存 OCR 文本后，search document source 为 `.userEdited`。
2. Vision late completion 调用 `updateOCRResult`，代码保留文本但把 source 改成 `.ignoredLateVision`。
3. 后续 retry / process 只拦 `.userEdited`，因此 `.ignoredLateVision` 会继续进入 `updateOCRResult`。
4. pending / running / succeeded 更新可以把 OCR source 改回 `.none` / `.vision`，并用 Vision 结果替换用户编辑文本。

影响：

- 违反 Step 4 的 OCR source boundary。用户已经编辑并保存的 OCR 文本不能被后台 late completion 或 retry 静默覆盖。
- 当前 P13D 只检查 token，未覆盖这个状态序列。

可执行修复建议：

- 不要把持久 source 从 `.userEdited` 改成 `.ignoredLateVision`；可以把 ignored late completion 作为独立低敏事件 / transient evidence 记录。
- 如果必须持久化 `.ignoredLateVision`，则 retry / process / updateOCRResult 必须把 `.ignoredLateVision` 视为同等 locked source，并且 pending/running/succeeded 均不得清空或替换 OCR 文本。
- P13D 增加真实序列：save user-edited OCR -> late completion -> retry -> completion，断言 OCR 文本、source、locked revision 均未被覆盖。

### P1-3：Dirty-navigation 未实现阻断式三动作确认；切换记录会静默丢弃 dirty draft

证据：

- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md:107`-`119` 要求 dirty 状态下切换条目、关闭详情、关闭面板或离开编辑上下文时出现阻断式确认 sheet，动作固定为 `Save and Continue`、`Discard Changes`、`Continue Editing`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:47`-`79`：`open(recordID:)` 直接调用 `load(recordID:)`，并重置 `dirtyNavigation`、`draftText`、`originalDraftText`。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift:208`-`214`：`openDetailEditor` / `closeDetailEditor` 只是透传到 detail store。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:766`-`767`：`.editDetail` action 直接 `clipboardStore.openDetailEditor(recordID:)`，未经过 dirty guard。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:140`-`148`：`cancel()` 在 dirty 时只设置 `dirtyNavigation = true` 和 message。
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift:119`-`132`：编辑态 action bar 只有 Cancel/Discard 和 Save，没有 `Save and Continue`、`Discard Changes`、`Continue Editing` 三动作 sheet；本轮 `rg "Save and Continue|Continue Editing|Discard Changes" apps/Blocks` 无命中。

影响：

- dirty draft 切换记录时可被 `load(recordID:)` 静默清空。
- close / overlay dismiss / panel action 没有保存成功后继续原动作的 continuation，也没有保存失败不导航的路径。
- UI 上的 `Discard` 文案不是 PRD 所要求的 destructive sheet action，且无法代表 `Continue Editing` 默认安全动作。

可执行修复建议：

- 在 `ClipboardDetailStore` 引入 pending navigation action / continuation，并让 `open(recordID:)`、`close()`、overlay dismiss、切换记录、切换筛选、关闭面板等离开编辑上下文的入口统一走 dirty guard。
- 使用阻断式 sheet 或等价 modal，动作固定为 `Save and Continue`、`Discard Changes`、`Continue Editing`；默认焦点在 `Continue Editing`。
- `Save and Continue` 保存成功后执行原动作；保存失败保留草稿并停留当前记录；`Discard Changes` 执行原动作；Esc / sheet close / 点击外部等价继续编辑。
- P13D 必须执行 dirty-record-switch / dirty-close / save-failed-continue 场景。

### P1-4：Rich text fidelity gate 不是实际保真 round-trip，当前证据不足以支持“可编辑 rich text”合同

证据：

- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift:45`-`52` 用 `"{\\rtf1\\ansi ...}"` 重新包裹 draft 文本生成新 RTF，而不是在原 RTF 上保留代表性格式。
- `apps/Blocks/BlocksCore/ClipboardRichTextFidelityService.swift:68`-`93` 只用 token heuristic 判断 link、paragraph、inline style、list 是否保留。
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift:125`-`143` 对 `.richText` 暴露保存路径，并依赖上述 helper 决定是否写入。
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md:421` 要求 rich text 不静默丢格式；若降级为只读、暂缓或派生纯文本编辑，必须有项目负责人接受记录。

影响：

- 对含链接、inline style、列表的代表性 rich text，当前实现大概率返回 fidelity failed，导致用户看到可编辑入口但保存失败。
- 对未被 heuristic 覆盖的真实 RTF 属性，存在静默丢失风险。
- P13D 未执行 representative fixture，也没有输出 rich text round-trip 的实际格式比较证据。

可执行修复建议：

- 若 Step 4 要保留 rich text 编辑，应实现真实 RTF / attributed string round-trip，并用 representative fixtures 证明链接、段落、inline style、列表至少不被静默丢失。
- 若暂不做完整保真，应把 rich text 降级为只读或明确派生纯文本编辑，并取得项目负责人接受记录。
- P13D 对 rich text 场景必须执行 fixture，不应只检查 `ClipboardRichTextFidelityService` token。

## P2 Findings

### P2-1：metadata full value / copy full value 路径已在 Store/Core 存在，但未接到 UI

证据：

- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md:332`-`340` 要求长项至少提供 `copy full value` 或等价完整值路径。
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift:213`-`230` 已有 `fullValueText(purpose: .detailFullValueRead)`。
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift:150`-`165` 的 `metadataGrid` 只显示 `item.boundedValue`，未使用 `fullValueAvailable`、`copyPurpose` 或 `fullValueText()`。
- 本轮 `rg "fullValueText\\(" apps/Blocks` 仅命中 Store 定义，未发现 UI 调用。

影响：

- 用户在长 URL / file path / OCR 原文 / rich text body 等长值场景无法通过明确动作读取或复制完整值。
- P13D 的 `detail_full_value_read/copy` 场景当前也是假 PASS，无法证明该路径可用。

建议：

- 在 metadata 长项提供明确的展开 / copy full value 控件和低敏反馈。
- 如果实现真实系统剪贴板写入，则必须使用独立 `detailCopyFullValue` purpose、fake pasteboard verifier 和低敏 sanitizer；如果只做展开查看，也要在 PRD/验收证据中说明等价路径。

## 正向证据

- 未看到 Step 5 / Step 6 范围进入当前实现：本轮复审重点文件集中于 Step 4 detail edit / metadata / OCR / P13D。
- schema v4 migration 方向正确：`apps/Blocks/BlocksCore/AppDatabase.swift:260`-`320` 添加 `content_revision`、`content_updated_at`、search document content/OCR source 字段，并只对已有 succeeded + non-empty OCR 文本回填 `vision`。
- Repository 保存主路径收敛在单个事务中：`apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift:55`-`205` 在 `database.connection.transaction` 内检查 revision / purpose / editability，更新 payload/summary/search document/read model。
- URL validation 未发现网络、Finder、System Settings 或系统动作：静态抽查只看到 URL 字符串规范化和 scheme/host 校验。
- AppState / AppModel / ClipboardController 未被扩大为 detail fact source 的主要事实源；detail draft/read/save 集中在 `ClipboardDetailStore` 和 Repository。

## 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13d_clipboard_detail_edit_checks.py | python3 -c '...extract summary...'
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
git diff --check
rg -n "fullValueText\\(" apps/Blocks
rg -n "Save and Continue|Continue Editing|Discard Changes" apps/Blocks
rg -n "detailCopyFullValue|copyPurpose|fullValueAvailable" apps/Blocks/BlocksApp apps/Blocks/BlocksCore
```

命令结果摘要：

- P13A / P13B / P13C / P9A / P9B / P8 / P8I / P11E / `git diff --check` 均通过。
- P13D 返回 PASS，但本复审判定为 P1 false PASS：29 个 scenarios 的 mutation / revision / full value evidence 全部为 null，负向 purpose count 非 0 仍通过。
- 未重复运行 `xcodebuild` 和 CLI help；原因是静态 P1 已足够构成返工，且项目负责人已有独立 build / CLI help PASS 证据。

## 未覆盖风险

- 未触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作，符合本次只读边界。
- 未做真实 UI 自动化，因此 action bar 高度、编辑区 2/4 行内部滚动、metadata 响应式布局和 VoiceOver 仍需由 UI/测试角色或后续低敏自动化覆盖。
- 未验证真实 pasteboard copy full value；若后续接入系统剪贴板写入，必须增加 fake pasteboard / adapter spy 和低敏输出证明。
- 未做复杂 RTF corpus 兼容性测试；当前 rich text finding 来自代码路径和门禁证据不足。

## 总结

当前实现不建议接受。必须先修复 P13D fail-closed 证据门禁、OCR user-edited retry / late completion 保护、dirty-navigation 三动作阻断流程；rich text 编辑能力需要在“真实保真实现”或“降级只读/派生编辑并取得接受记录”之间收敛。P1 清零后再重跑 P13D 和既有回归矩阵。
