# Step 4 App 架构师技术方案 v0

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-PRD-v1复核-v0.md`、`项目负责人-技术方案派发-v0.md`
范围：004_剪贴板打磨 Step 4 详情编辑与元数据组织
状态：technical-plan-v0

## 1. 结论

Step 4 可以按“bounded detail read model + metadata snapshot + detail edit purpose + 单一 repository save command + P13D fail-closed gate”进入项目负责人预审和角色复审。

推荐默认技术路线：

- 默认详情展示只读 bounded read model，不为布局预读完整 payload。
- 点击 `Edit` 后才用 `detailEditRead` purpose 读取完整可编辑内容并生成 draft。
- 保存只通过一个 Store command 调用一个 Repository command，例如 `ClipboardDetailStore.save(command:) -> ClipboardRepository.saveDetailEdit(command:)`。
- 默认保存走同一 SQLite transaction，payload / summary / search document / FTS / updatedAt / detail read model 进入同一版本语义。
- `saved-index-pending` / `reindex-failed` 只作为技术上必须拆分索引更新时的异常路径；若开发可沿用当前 `upsertSearchDocument` 同事务路径，则本阶段不主动引入异步 reindex。
- 富文本编辑只在 RTF round-trip 和代表格式保真门禁通过时开放；否则进入项目负责人取舍，不在实现里静默降级。
- OCR 用户编辑文本需要新增 user-edited / override 来源标记；retry / late completion 不得覆盖用户文本。
- P13D 必须在开发前先建立 fail-closed baseline，再随实现转绿。

本方案只覆盖 Step 4。不得进入 Step 5 隐私页真实 App 清单 / CLI 广义对象管理，不做 Step 6 集成验收，不同步写回系统剪贴板，不编辑图片本体或文件本体。

## 2. 已接受事实源边界

### 2.1 Step 1

Step 1 已接受，当前事实源是：

- `ClipboardSearchDocument` / `ClipboardContentPreviewSnapshot` 是搜索与 bounded preview 的派生事实源。
- `clipboard_fts` 是 search document 的查询投影，不是独立事实源。
- 默认列表 / 搜索 / 设置输出不应退回旧 redacted-first 语义。
- P13A / P8 / P8I / P9A / P9B / P11E 已覆盖明文展示、搜索底座、OCR 状态、低敏输出和旧 hardening 边界。

Step 4 不重写搜索算法、OCR provider、Vision 队列基础能力或输出边界。

### 2.2 Step 2

Step 2 已接受，当前事实源是：

- `ClipboardTagRepository` / `ClipboardTagStore` 或等价边界提供标签与收藏事实。
- favorite 是内置标签，不再从旧 pinned / pinboard 推导当前 UI 事实。
- 标签 token 已进入 Step 1 search document。
- P13B / P9A / P9B / P8 等门禁覆盖旧 pinned/pinboard 退出、tag search 缺失文档重建和 Store / AppModel 边界。

Step 4 只展示标签 / 收藏元数据，不修改标签模型、右键标签关系或设置页标签管理。

### 2.3 Step 3

Step 3 已接受，当前事实源是：

- 面板 selected / focused / hover / active filter 的局部交互边界已由 P13C 覆盖。
- paste activation 已改为显性互斥控件。
- hover detail 仍应保持轻量、低敏和目的明确。
- Step 3 保留真实 UI / VoiceOver / 真实鼠标手感 P2 residual，不得在 Step 4 写成已实测事实。

Step 4 不继续重做 hover、toolbar、单击 / 双击和条目密度。

## 3. 当前代码事实

只读抽样确认如下事实，后续开发前仍应以最新工作区复核：

- `ClipboardRecorderItemKind` 已包含 `.text`、`.richText`、`.image`、`.url`、`.fileURL`、`.mixed`、`.unknown`。
- `ClipboardRecorderPayload` 当前字段为 `text`、`rtfDataBase64`、`pngDataBase64`、`urlString`。
- SQLite `clipboard_payloads` 表已有 `text`、`rtf_data`、`png_data`、`png_sidecar_path`、`url_string`。
- `ClipboardRepository.insert` 当前在 transaction 内插入 record、payload 和 search document。
- `ClipboardRepository+SearchDocuments.upsertSearchDocument` 会更新 `clipboard_search_documents`、`clipboard_items.search_text` / `updated_at` 和 FTS。
- `ClipboardSearchDocument` 已有 `contentText`、`richTextPlainText`、`urlTokens`、`fileTokens`、`tagTokens`、`ocrText`、`ocrState`、`payloadDerivationState`。
- 当前 `updateOCRResult` 是 Vision OCR pipeline 语义，只能表达 OCR result，不足以表达 user-edited OCR override。
- `ClipboardPayloadReadPurpose` 当前已有 `previewBuild`、`searchIndex`、`ocrInput`、`paste`、`copyPlainText`、`hoverDetail`、`translationPreview`；Step 4 需要新增详情编辑专属 purpose。
- `ClipboardAutoPasteCoordinator` 和 `AppModel.pasteClipboardRecord` 存在系统 `NSPasteboard.general` 写入路径；Step 4 保存必须不调用这些路径，并用 fake / spy / static scan 证明。
- 当前 `ClipboardFloatingDetailCard` 是 hover detail，读取 purpose 为 `.hoverDetail`，不应直接承载 dirty editing。

## 4. 推荐文件与职责

命名可由开发按现有目录微调，但职责边界应保持。

```text
apps/Blocks/BlocksCore/ClipboardDetailReadModel.swift
- ClipboardDetailReadModel
- ClipboardMetadataSnapshot
- ClipboardDetailEditability
- ClipboardDetailSaveStatus
- low-sensitive, bounded fields only

apps/Blocks/BlocksCore/ClipboardDetailEditCommand.swift
- ClipboardDetailEditCommand
- ClipboardDetailEditableKind
- ClipboardDetailEditDraft
- ClipboardDetailSaveResult
- ClipboardDetailSaveFailure
- URL validation result
- rich text fidelity result

apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift
- loadDetailReadModel(recordID:)
- readDetailEditablePayload(recordID:purpose:)
- saveDetailEdit(command:)
- repository transaction boundary
- detail metadata snapshot load helpers

apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift
- view/edit state
- draft state
- dirty/invalid/saving/save-failed/record-unavailable state
- calls repository detail APIs only
- emits mutation result for ClipboardStore refresh

apps/Blocks/BlocksApp/Features/Clipboard/ClipboardPayloadAccess.swift
- add detailEditRead / detailEditSave purpose names
- keep purpose-scoped cache boundaries

apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift
- stable detail editor / sheet / pane
- fixed bottom action bar
- 2-line default / 4-line max editor
- metadata snapshot rendering

tools/verification/p13d_clipboard_detail_edit_checks.py
- Step 4 fail-closed verifier
- static checks + fixture smoke + bounded JSON evidence checks
```

如果实现选择把 detail APIs 放入既有 `ClipboardStore` / `ClipboardRepository` 文件，P13D 仍必须证明：

- View 不直接写 repository 字段。
- 只有一个 Store-level save command。
- 只有一个 Repository-level save command。
- payload / summary / search document / FTS / updatedAt 不被分散写入。

## 5. 架构总览

```text
ClipboardDetailEditorView
  -> ClipboardDetailStore
      -> ClipboardRepository.loadDetailReadModel(recordID:)
      -> ClipboardRepository.readDetailEditablePayload(recordID:purpose:.detailEditRead)
      -> ClipboardRepository.saveDetailEdit(command:)
          -> validate editable kind
          -> validate URL / rich text / OCR override
          -> build updated payload or derived OCR fields
          -> build updated record summary / format summary if needed
          -> build updated search document
          -> write payload / item summary / search document / FTS / updatedAt in transaction
      -> ClipboardDetailSaveResult
  -> ClipboardStore refresh / apply mutation result
      -> previewSnapshots updated or reload
      -> active search result refreshed
      -> tag facts preserved
```

关键原则：

- `ClipboardDetailStore` 可以持有 draft 和 UI 状态，但不是 payload / OCR / search document 的事实源。
- `ClipboardStore` 继续负责列表、搜索结果、preview snapshot、tagStore 桥接；不直接拼 detail edit payload。
- `AppModel` 只做 facade / status / coordinator，不接收 detail payload、OCR 文本或保存事务事实。
- Repository 是 Step 4 编辑后的唯一持久化事实源。

## 6. Bounded Detail Read Model

### 6.1 默认读取

打开详情时默认读取 bounded model，不读取完整 payload：

```text
ClipboardDetailReadModel
- recordID
- revision
- kind
- title
- boundedBody
- badge
- editability
- saveStatus
- ocrState
- ocrTextSource
- metadata: ClipboardMetadataSnapshot
- actions
```

`boundedBody` 来自 `ClipboardContentPreviewSnapshot` 或等价 bounded projection。不得为显示默认详情一次性读取完整正文、完整 URL、完整 file path、完整 RTF body、完整 OCR 原文或图片 base64。

### 6.2 Metadata Snapshot

```text
ClipboardMetadataSnapshot
- recordID
- kindTitle
- sourceDisplayNameBounded
- sourceBundleIdentifierBounded
- createdAt
- contentUpdatedAt
- itemCount
- textLength
- byteCount
- fileCount
- urlCount
- tagNamesBounded
- isFavorite
- restorable
- excluded
- snapshotSkipped
- ocrState
- ocrTextSource
- signatureSHA256_12
- boundedURLHostOrSummary
- boundedFileDisplayName
- longValueAvailability
```

`longValueAvailability` 只告诉 UI 某项有完整值可通过显式动作读取，不包含完整值。

短项两列、长项单行、窄宽度单列都基于 snapshot 完成。完整值路径通过显式动作触发：

- copy full URL
- copy full file path / file URL
- expand full bounded text
- edit content

这些动作必须使用明确 purpose 和 sanitizer，不把完整值写入 verifier 输出。

## 7. Purpose 边界

在 `ClipboardPayloadReadPurpose` 或等价 purpose 枚举中新增：

```text
detailEditRead
detailFullValueRead
detailEditSave
```

推荐语义：

- `detailEditRead`：用户点击 Edit 后读取完整可编辑内容生成 draft。
- `detailFullValueRead`：用户显式复制 / 展开完整元数据值，如完整 URL 或 file URL。只读，不进入保存。
- `detailEditSave`：保存 mutation 内部读取旧 payload 或构建新 payload 的目的标识。若实现不把 save 放进 read-purpose enum，可用同名 mutation purpose，但 P13D 必须能识别。

禁止复用：

- `.hoverDetail`
- `.paste`
- `.copyPlainText`
- `.translationPreview`
- `.ocrInput`
- `.searchIndex`

Step 4 不改写 `paste` 和 `copyPlainText` 的既有语义。

缓存规则：

- `detailEditRead` 可使用 purpose-scoped cache，但保存成功、取消、切换记录、record missing、repository reload 后必须失效。
- `detailEditSave` 不复用旧 cached payload 作为唯一事实，应在 repository transaction 内重新读取当前记录 / payload / revision。
- fixture / in-memory 兼容路径也必须使用 purpose-keyed cache，不能退回 recordID-only cache。

## 8. Store / Repository Save Command

### 8.1 Store Command

推荐 Store API：

```text
ClipboardDetailStore
- load(recordID:)
- beginEditing()
- updateDraft(...)
- validateDraft()
- save()
- cancel()
- handleDirtyNavigation(...)
```

`save()` 只调用一个 repository command：

```text
ClipboardRepository.saveDetailEdit(command: ClipboardDetailEditCommand) throws -> ClipboardDetailSaveResult
```

`ClipboardDetailStore` 不直接写：

- `clipboard_payloads`
- `clipboard_items.summary`
- `clipboard_items.search_text`
- `clipboard_search_documents`
- `clipboard_fts`
- OCR state

### 8.2 Repository Command

```text
ClipboardDetailEditCommand
- recordID
- expectedRevision
- editableKind: plainText / url / richText / imageOCRText
- draftText
- originalDraftHash
- purpose: detailEditSave
- now
```

```text
ClipboardDetailSaveResult
- recordID
- newRevision
- contentUpdatedAt
- updatedPreview: ClipboardContentPreviewSnapshot
- updatedDetailReadModel: ClipboardDetailReadModel
- searchIndexState: completed / savedIndexPending / reindexFailed
- changedFields
```

```text
ClipboardDetailSaveFailure
- recordNotFound
- payloadMissing
- notEditable
- invalidURL
- richTextFidelityFailed
- ocrStateNotEditable
- userEditedOCRConflict
- revisionConflict
- transactionFailed
- reindexFailed
```

`expectedRevision` 使用当前 search document revision 或等价记录版本。保存时 repository 重新读取当前 record / payload / search document；不信任 View 传入的完整旧 payload。

## 9. 保存事务与异步 Reindex

### 9.1 默认同步事务

默认必须选择同步事务：

```text
database.transaction {
  load current record + payload + search document
  validate expectedRevision and editability
  build updated payload or derived OCR update
  build updated record summary / format summary if required
  build updated search document with current tag tokens preserved
  write payload / OCR source metadata
  update clipboard_items summary / updated_at / search_text
  upsert clipboard_search_documents
  replace clipboard_fts
}
```

该路径可以复用现有 `upsertSearchDocument`，但必须确保它在同一 transaction 内执行。

保存成功后：

- detail read model 来自 repository 返回结果或保存后重新读取。
- `ClipboardStore` 刷新 preview snapshots 和当前搜索结果。
- 系统 pasteboard 不写入。

### 9.2 异步 Reindex 例外

只有在开发证明 FTS / search document 不能可靠放入同一事务时，才启用异步 reindex 分支。

触发：

- payload / record content 已提交，但 search document / FTS 构建明确进入 pending 队列。

状态：

- `saved-index-pending`：内容已保存，索引待更新。
- `reindex-failed`：内容已保存，索引更新失败，有恢复路径。

恢复：

- `ClipboardRepository.rebuildSearchDocuments(limit:)` 或 Step 4 专属 reindex command。
- UI 显示待更新 / 失败状态，不宣称搜索已更新。
- P13D 必须覆盖 pending / failed 证据。

本方案推荐不要把异步 reindex 作为默认路径；当前 `ClipboardSearchDocumentBuilder` 和 `upsertSearchDocument` 已支持同事务内构建和写入。

## 10. 类型编辑方案

### 10.1 Plain Text

保存输入：

- `editableKind = plainText`
- `draftText` 允许多行，按 UI 2/4 行展示，但 payload 保存完整内容。

保存逻辑：

- 新 payload：`kind = .text`，`text = normalizedDraftForStorage`。
- `rtfDataBase64`、`pngDataBase64`、`urlString` 置空。
- record kind 保持 `.text`。
- summary / preview 由 `ClipboardSearchDocumentBuilder` 生成 bounded text。
- search document `contentText` 更新。
- `createdAt`、source App、tags、favorite 保留。

失败：

- payload missing 可视为可创建 payload，但 record missing / revision conflict 失败。
- 空文本是否允许由 PRD 未禁止；技术方案建议允许空字符串但必须有可见 summary，如 `Empty text` 或等价低敏文案。若产品不接受，应在角色复审收敛。

### 10.2 URL

保存输入：

- `editableKind = url`
- `draftText` 是用户输入 URL string。

校验：

- trim leading/trailing whitespace。
- reject empty。
- reject control characters。
- `URLComponents(string:)` 可解析。
- scheme 必须存在。
- 默认成功 scheme：`http`、`https`、`mailto`。
- `http` / `https` 必须有 host。
- `mailto` 必须有非空 path。
- `file` 默认 reject，按 file URL 不可编辑处理。
- custom scheme 默认 reject；若支持，必须由项目负责人接受 allowlist / denylist，并补 fixture。
- 不自动补 `https://`。
- 不发网络请求，不打开 App，不打开 Finder。

保存逻辑：

- record kind 保持 `.url`。
- payload `urlString = trimmedInput`。
- payload `text = trimmedInput`，确保 paste / copy / preview 同源。
- summary / URL tokens / search document 由 builder 或 URL-specific helper 生成。
- invalid URL 不进入 repository mutation；如果服务端式校验在 repository 才发现，返回 `invalidURL`，draft 保留。

### 10.3 Rich Text

当前格式事实：

- rich text payload 使用 `ClipboardRecorderPayload.rtfDataBase64` 保存 RTF data，并通常同时有 `text` 纯文本。
- pasteboard 捕获路径从 `NSPasteboard.PasteboardType.rtf` 读取 data。

推荐保真策略：

1. `detailEditRead` 解码 `rtfDataBase64` 为 `NSAttributedString`。
2. 提取 plain string 作为 draft。
3. 保存时使用 `ClipboardRichTextFidelityService` 或等价 helper 进行 RTF round-trip：
   - 若 draft 与原文只做文本替换，尽量保留 document attributes。
   - 代表格式检查链接、段落 / 换行、基础 inline style、列表代表项。
   - 重新生成 RTF data，并提取同步 plain text。
4. 若 round-trip 或代表格式检查失败，返回 `richTextFidelityFailed`，不写 payload。

首版不做完整富文本工具栏，不提供字体 / 颜色 / 表格编辑。

降级 gate：

- 富文本无法通过最低保真 fixture 时，不能静默转 plain text。
- 可选降级只有三类：暂缓富文本编辑、只读 + 可复制纯文本、只编辑派生纯文本。
- 任一降级必须有当前项目负责人接受记录，P13D 才可转绿。

### 10.4 Image OCR Text

当前事实：

- OCR 文本位于 `ClipboardSearchDocument.ocrText`。
- `updateOCRResult` 使用 OCR pipeline revision 更新 `ocrText` 和 `ocrState`。
- 当前模型没有 user-edited 来源字段。

需要新增模型：

```text
ClipboardOCRTextSource
- none
- vision
- userEdited
- ignoredLateVision
```

推荐 schema migration v4 或等价：

```text
clipboard_search_documents.ocr_text_source TEXT NOT NULL DEFAULT 'vision'
clipboard_search_documents.ocr_user_edited_at REAL
clipboard_search_documents.ocr_locked_revision TEXT
```

如果不改 schema，也必须有等价持久化位置；仅 View-local 标记不接受。

编辑条件：

- record kind == `.image`
- search document `ocrState == .succeeded`
- `ocrText` 非空
- `ocrTextSource != userEdited` 或允许继续编辑已 user-edited 文本

保存逻辑：

- 不读取 / 不写图片 payload。
- 更新 `ocrText`。
- 设置 `ocrTextSource = userEdited`。
- 更新 summary / search document / FTS / updatedAt / detail read model。

retry / late completion：

- `ClipboardVisionOCRQueue.retryOCR` 在发起前检查 `ocrTextSource`。
- user-edited 时：默认禁用 retry，或要求 UI 明确确认覆盖。
- late completion 到达时：repository `updateOCRResult` 如果发现 `ocrTextSource == userEdited`，必须拒绝覆盖并返回 skipped / ignored 状态。
- P13D 覆盖 `detail_ocr_user_edited_retry_004`。

## 11. Record Missing / Payload Missing / Conflict

### 11.1 record missing

触发：

- 编辑期间记录被删除、裁剪、清空或 policy prune。

状态：

- `record-unavailable`。
- 草稿保留在 UI 内存中。
- 不写入其他记录。
- 可关闭 / 返回列表；如 UI 提供复制草稿，必须是低敏可控路径，不进入验收输出。

### 11.2 payload missing

plain text / URL / rich text：

- 如果 record 可编辑但 payload 缺失，默认返回 `payloadMissing`，不创建新 payload，避免把旧 skipped / redacted / unavailable 记录误写为用户内容。
- 如果后续产品想允许“从空 payload 恢复文本”，需另行项目负责人接受。

OCR text：

- 不依赖图片 payload 保存用户 OCR 文本；依赖 search document 存在。

### 11.3 save conflict

触发：

- `expectedRevision` 不匹配。
- 同一 record 外部更新。
- OCR late completion / tag rebuild 改动影响 search document revision。

处理：

- 返回 `revisionConflict`。
- UI 进入 save-failed / conflict state。
- 草稿保留。
- 用户可 reload latest 或取消；不要自动 merge。

## 12. UI 数据与状态输入

### 12.1 Stable Detail Editor

Step 4 不把 hover detail 改成默认编辑器。推荐新增稳定 detail editor：

- floating panel 内 sheet / popover-like pane / detail pane 均可。
- 由 `detailOpen` 或显式 Edit 入口打开。
- hover detail 保持只读，可提供进入 stable editor 的显式入口。

### 12.2 Detail Editor State

```text
view
readOnly
editClean
dirty
invalid
saving
saveSuccess
savedIndexPending
reindexFailed
saveFailed
recordUnavailable
dirtyNavigation
```

这些状态由 `ClipboardDetailStore` 提供给 View。View 不自行推断 repository 保存成功。

### 12.3 编辑区布局输入

View 需要从 read model / store 获得：

- `editableKind`
- `draftText`
- `validationError`
- `saveStatus`
- `linePolicy`: min 2 lines, max 4 lines, scroll after max
- `fontPolicy`: independent from list item font size

编辑区高度规则是 UI 层实现，但 P13D 应读取低敏 layout evidence。

### 12.4 Metadata 布局输入

`ClipboardMetadataSnapshot` 需要为每项提供：

```text
MetadataItem
- id
- title
- boundedValue
- fullValueAvailable
- category: short / long / conditionalShort
- copyPurpose: none / detailFullValueRead
- accessibilityLabel
```

常规宽度两列、窄宽度单列由 View 根据 `category` 和 viewport evidence 决定。长值不挤压 editor。

## 13. 系统 Pasteboard 不写入证据

Step 4 保存不得调用：

- `ClipboardAutoPasteCoordinator.paste`
- `ClipboardAutoPasteCoordinator.writePayload`
- `AppModel.pasteClipboardRecord`
- `NSPasteboard.general.clearContents`
- `NSPasteboard.general.setString`
- `NSPasteboard.general.setData`
- `NSPasteboard.writeObjects`

证据组合：

1. static scan：P13D 检查 Step 4 detail save 文件不包含 `NSPasteboard.general`、`clearContents`、`setString`、`setData`、`writeObjects`。
2. fake pasteboard / adapter spy：如果为了测试保存路径注入 pasteboard adapter，则保存测试中 `writeAttempts == 0`。
3. fixture smoke：四类保存结果 JSON 输出 `pasteboard_write_attempts=0`。

不得读取或写入真实系统剪贴板。

## 14. P13D Verifier 设计

脚本：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
```

### 14.1 输入

P13D 只读取：

- 当前代码。
- 当前 Step 4 PRD / 技术方案 / 开发记录。
- 低敏 fixture repository 或 fixture JSON。
- bounded JSON evidence。
- 低敏截图 / snapshot manifest，如 UI 验收有提供。

P13D 不启动真实 App，不读写真实剪贴板，不触发 TCC / provider / Keychain / 系统设置 / Finder / restart。

### 14.2 最低断言

P13D 必须 fail closed 覆盖：

- 当前事实源引用 `产品经理-PRD-v1.md` 和当前技术方案；旧 story/archive 只能作为 baseline reference。
- 可编辑 / 不可编辑类型 fixture 完整。
- 默认 detail / metadata snapshot 不读取不必要完整 payload。
- `detailEditRead` / `detailEditSave` purpose 存在，且不复用 hover / paste / copy / translation / provider purpose。
- 保存路径可追踪到单一 Store command 和单一 Repository command。
- View 不直接写 payload、summary、search document、FTS 或 OCR 状态。
- plain text 保存后 payload、summary、search document、FTS、updatedAt、detail read model 一致。
- URL valid save 不访问网络、不改 kind；invalid URL 不产生 mutation。
- rich text 不静默丢格式；降级需当前项目负责人接受记录。
- image OCR text edit 不修改图片 payload，不输出 OCR 原文，不被 retry / late completion 静默覆盖。
- 保存失败保留草稿，不产生用户可见部分提交。
- cancel / dirty-navigation discard 不提交 mutation。
- 系统剪贴板未被保存动作更新，输出 `pasteboard_write_attempts=0`。
- 编辑区 2 行默认、4 行上限、超过内部滚动，不受列表字号设置影响。
- 元数据短项两列、长项单行、窄宽度单列，长值不挤压 editor。
- 低敏输出无真实剪贴板、真实 home path、真实文件路径、OCR 原文、URL 全文、图片/base64、邮箱、secret、Authorization header、二维码、验证码。

### 14.3 输出 Schema

```json
{
  "gate": "P13D",
  "ok": true,
  "source": {
    "prd": "docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md",
    "technical_plan": "docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v0.md",
    "development_record": "docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md"
  },
  "editable_fixtures": {
    "plain_text": true,
    "url": true,
    "rich_text": true,
    "image_ocr_text": true
  },
  "bounded_read_model": {
    "default_detail_avoids_full_payload": true,
    "metadata_snapshot_bounded": true
  },
  "purpose_boundary": {
    "detail_edit_read": true,
    "detail_edit_save": true,
    "forbidden_purpose_reuse_count": 0
  },
  "save_command": {
    "single_store_command": true,
    "single_repository_command": true,
    "view_direct_repository_writes": 0
  },
  "pasteboard": {
    "write_attempts": 0,
    "static_forbidden_calls": 0
  },
  "rich_text": {
    "fidelity_passed": true,
    "degradation_acceptance_record_present": false
  },
  "ocr": {
    "user_edited_retry_overwrite": false,
    "late_completion_overwrite": false
  },
  "sanitizer": {
    "ok": true,
    "forbidden_token_count": 0
  },
  "failures": []
}
```

P13D 可以拆为 static scan + fixture smoke + evidence manifest，但最终命令必须一键 fail closed。

## 15. 与既有门禁关系

最终验收至少运行：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

职责：

- P13D：Step 4 detail edit / metadata / save transaction 专属 gate。
- P13A：防止搜索/OCR/bounded preview 和低敏输出回归。
- P13B：防止标签/收藏事实源和 tag search 回归。
- P13C：防止面板交互、selected/focused、hover/paste activation 回归。
- P8 / P8I：防止产品 polish 和 Settings 系统项回归。
- P9A / P9B：防止 repository storage 与 AppState / Store integration 回归。
- P11E：防止 clipboard payload purpose / low-sensitive read model 边界回归。

## 16. 开发拆分建议

同一顶层 Step 内可以合并开发批次，但建议保留以下审查边界。

### Batch A：P13D baseline + read model / purpose

交付：

- 新增 P13D fail-closed baseline。
- 新增 / 调整 detail read model、metadata snapshot、purpose enum。
- 实现 bounded detail read path。
- 明确 hover detail 只读，不承载 dirty editor。

验收：

- P13D 在缺 evidence 时失败。
- 默认 detail / metadata 不读取完整 payload。
- purpose 边界可静态检查。

### Batch B：Repository save command + plain text / URL

交付：

- 新增单一 repository save command。
- 新增 detail store save command。
- plain text 保存。
- URL 校验、标准化和保存。
- 保存事务、失败回滚、pasteboard spy/static scan。

验收：

- plain text / URL fixture 通过。
- invalid URL 不产生 mutation。
- pasteboard writes 为 0。
- P13A / P9A / P9B 不回归。

### Batch C：Rich text / OCR text

交付：

- Rich text fidelity service / gate。
- OCR user-edited source 持久化。
- retry / late completion 冲突处理。
- rich text 降级接受记录检查。

验收：

- `detail_rtf_format_004`。
- `detail_rich_text_degrade_blocked_004`。
- `detail_ocr_user_edited_retry_004`。
- P13A OCR 状态不回归。

### Batch D：Stable detail editor UI + metadata layout + full regression

交付：

- Stable detail editor / sheet / pane。
- fixed action bar。
- dirty-navigation sheet。
- 2/4 行编辑区。
- metadata two-column / narrow single-column / copy full value。
- keyboard / VoiceOver 低敏 evidence manifest。

验收：

- P13D 完整通过。
- P13A / P13B / P13C / P8 / P8I / P9A / P9B / P11E / builds / CLI help / diff 全部通过。

## 17. 风险与项目负责人取舍点

### 17.1 富文本保真

风险：RTF round-trip 对复杂格式不可完全保证。

默认取舍：只有最低代表 fixture 通过时才开放富文本编辑。若不能通过，建议项目负责人在 Step 4 内接受“富文本暂缓编辑 / 只读 + 可复制纯文本”，不要把富文本静默纯文本化。

### 17.2 OCR user-edited schema

风险：当前 search document 没有 `ocrTextSource` 字段。

建议：Step 4 migration 明确新增持久化来源标记；不接受 View-local 标记。

### 17.3 事务范围

风险：`storePayload` 当前为 `ClipboardRepository.swift` 内 private helper，新 extension 可能无法直接复用。

建议：开发要么把 detail save command 放在可访问 `storePayload` 的同一文件附近，要么抽出 internal `replacePayload` helper；不要复制一套 payload 写入逻辑。

### 17.4 updatedAt 暴露

风险：数据库有 `clipboard_items.updated_at`，但当前 `ClipboardRecorderRecord` 模型未暴露 updatedAt。

建议：Step 4 detail read model 从 search document / repository 查询提供 `contentUpdatedAt`，不必为了列表模型强行扩散 `updatedAt`。如开发选择给 record 模型加字段，必须回归 P9A / P9B。

### 17.5 真实 UI / VoiceOver

风险：Step 3 仍有真实 UI / VoiceOver P2 residual。

建议：Step 4 技术方案和 P13D 只要求低敏 evidence；不得写成真实 VoiceOver 已实测。真实 UI / VoiceOver 仍留给 Step 6 或专项验收。

## 18. 需要角色复审的问题

### UI / 交互设计师

- Stable detail editor 应采用 sheet、pane 还是 main detail area；是否满足默认阅读态 + Edit。
- fixed action bar 在 view / edit-clean / dirty / invalid / saving / failed 下文案和焦点是否清楚。
- dirty-navigation sheet 默认焦点是否放在最安全动作。
- metadata 窄宽度单列、长值 copy full value、VoiceOver label 是否可接受。

### 开发

- `saveDetailEdit(command:)` 放在何处才能复用 payload 写入和 search document upsert，不复制逻辑。
- Rich text fidelity service 是否能通过最低代表 fixture；若不能，如何生成降级接受记录输入。
- OCR user-edited schema migration 与 `updateOCRResult` guard 如何落地。
- P13D static scan 和 fixture smoke 的最小可行实现。

### 测试 / 质量

- P13D 是否覆盖所有 PRD P1：富文本、事务、pasteboard、OCR、URL、bounded read model。
- 保存失败 / reindex failed / record missing / conflict 的低敏 fixture 是否能稳定复跑。
- sanitizer 是否能防 URL 全文、OCR 原文、真实路径、图片/base64 输出。

### 代码审查

- View 是否绕过 Store / Repository command。
- AppState / AppModel 是否被扩大为 detail edit 事实源。
- 新 schema / migration 是否保持旧数据可打开。
- purpose boundary 是否避免复用 hover / paste / copy / translation。

## 19. PRD v1 第 20 节逐条回答

1. 富文本 payload 当前格式，以及链接、段落 / 换行、inline style、列表代表项的保留能力。
   - 当前格式是 `ClipboardRecorderPayload.rtfDataBase64`，来自 pasteboard RTF data，并伴随 `text` 纯文本。方案要求用 `NSAttributedString` RTF decode / encode 做 round-trip。链接、段落 / 换行、基础 inline style、列表代表项必须由 `detail_rtf_format_004` 验证；未通过则富文本编辑不开放。

2. 富文本无法保真时采用降级、暂缓还是只读，并提供项目负责人接受记录。
   - 默认不是自动降级。无法保真时 repository 返回 `richTextFidelityFailed`，P13D 失败。只有项目负责人明确接受“暂缓富文本编辑 / 只读 + 可复制纯文本 / 只编辑派生纯文本”之一，并有当前 Step 4 接受记录，P13D 才允许对应降级路径转绿。

3. 单一 detail edit save command 的 Store / Repository 边界。
   - Store 层只有 `ClipboardDetailStore.save()` 或等价单一入口；Repository 层只有 `ClipboardRepository.saveDetailEdit(command:)` 或等价单一入口。View 不直接写 payload、summary、search document、FTS 或 OCR 状态。

4. payload、summary、search document、FTS、updatedAt、detail read model 的事务或异步 reindex 方案。
   - 默认同一 repository transaction 内提交 payload / summary / search document / FTS / updatedAt。detail read model 由保存结果返回或保存后同事务读取。异步 reindex 仅为例外，必须进入 `saved-index-pending` / `reindex-failed`。

5. `saved-index-pending` / `reindex-failed` 的触发、恢复和验收方式。
   - 仅当内容已保存但索引未同步完成时触发 `saved-index-pending`；索引重建失败触发 `reindex-failed`。恢复通过 reindex command / rebuildSearchDocuments 或等价路径。P13D 用 `detail_save_atomic_failure_004` 覆盖 pending / failed，不允许静默吞掉索引失败。

6. 系统 pasteboard 写入路径如何通过 fake pasteboard / spy / static scan 证明未调用。
   - P13D 组合 static scan、fake pasteboard / adapter spy、fixture JSON。保存路径不得引用 `NSPasteboard.general`、`clearContents`、`setString`、`setData`、`writeObjects`，四类保存 evidence 输出 `pasteboard_write_attempts=0`。

7. URL 校验和标准化规则，包括 absolute URL、scheme 保留、custom scheme 默认阻断或 allowlist。
   - trim 后本地解析，不发网络请求。必须 absolute URL 且保留 scheme。默认允许 `http`、`https`、`mailto`；`file` reject；custom scheme 默认 reject。若支持 custom scheme，必须有项目负责人接受的 allowlist / denylist 和 fixture。

8. OCR user-edited / override / locked source 标记位置，以及 retry / late completion 冲突处理。
   - 标记必须持久化，推荐 `clipboard_search_documents.ocr_text_source` / `ocr_user_edited_at` / `ocr_locked_revision` 或等价 schema。retry 前检查 user-edited；默认禁用或要求确认覆盖。late completion 发现 user-edited 时拒绝覆盖并记录低敏 ignored 状态。

9. bounded detail read model 与 metadata snapshot 包含哪些字段，哪些完整值必须显式读取。
   - `ClipboardDetailReadModel` 包含 recordID、revision、kind、bounded title/body、editability、saveStatus、OCR state/source、metadata snapshot。metadata snapshot 包含 bounded source、created/content updated time、count、tag summary、favorite、flags、bounded URL/file summary。完整正文、完整 URL、完整 file path、OCR 原文、RTF body 都必须通过显式 `detailEditRead` 或 `detailFullValueRead` 读取。

10. detail edit read / save purpose 命名和与 hover / paste / copy / translation purpose 的隔离。
    - 新增 `detailEditRead`、`detailFullValueRead`、`detailEditSave` 或等价命名。P13D 检查 Step 4 detail edit 不复用 `.hoverDetail`、`.paste`、`.copyPlainText`、`.translationPreview`、`.ocrInput`、`.searchIndex`。

11. record missing、payload missing、save conflict、外部更新同一记录时的用户可见错误状态。
    - record missing / prune -> `record-unavailable`，草稿保留，不写其他记录。payload missing -> `payloadMissing` / save failed，除 OCR text 外不自动创建 payload。revision mismatch / external update -> `revisionConflict`，草稿保留，用户选择 reload 或取消，不自动 merge。

12. P13D 的具体脚本 / verifier 组合和 bounded JSON evidence 字段。
    - 脚本为 `tools/verification/p13d_clipboard_detail_edit_checks.py`。组合 static scan、fixture repository smoke、fake pasteboard / spy、bounded JSON evidence、sanitizer。输出包含 source、editable_fixtures、bounded_read_model、purpose_boundary、save_command、pasteboard、rich_text、ocr、sanitizer、failures 等字段，详见第 14 节。

## 20. 技术方案自检

- Step 4 范围未扩大到 Step 5 / Step 6。
- 未把真实 UI / VoiceOver / 真实剪贴板写成已实测。
- 已明确 bounded detail read model 和 metadata snapshot。
- 已明确 purpose 隔离。
- 已明确单一 Store / Repository save command。
- 已覆盖 plain text、URL、rich text、OCR text 四类编辑。
- 已定义保存事务、异步 reindex 例外和失败状态。
- 已定义 pasteboard 不写入证据。
- 已定义 rich text fidelity gate 和 OCR user-edited conflict。
- 已定义 P13D fail-closed verifier 与回归矩阵。
