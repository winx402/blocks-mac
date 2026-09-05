# Step 2 App 架构师技术方案 v1

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-技术方案复审收敛-v0.md`、`项目负责人-技术方案v1修订派发-v0.md`
范围：标签与收藏模型替换
状态：technical-plan-v1

## 1. 结论

Step 2 v1 继续采用 v0 主线，但把进入开发前必须固定的模型、事务、UI 合同和 verifier 门禁写成硬契约：

- `Tag / RecordTag` 是独立当前事实源，不是旧 pinboard / pinned 改名。
- `Favorite` 是唯一 built-in tag，收藏关系来自 RecordTag，不来自旧 pinned 字段。
- `ClipboardTagRepository` + `ClipboardTagStore` 是推荐边界；`ClipboardStore` 只桥接，`AppModel` 只做 facade / status / coordinator。
- 标签 mutation 必须返回 `ClipboardTagMutationResult` 或等价结果，search invalidation 只消费 affected record IDs。
- `preservePinned` / `clearUnpinned` 的 active UI、policy 行为、Store facade、verifier ok evidence 必须在 Step 2 内退出或改为 favorite 语义。
- P13B 是 Step 2 fail-closed gate，按 baseline red -> 分层转绿 -> final gate 的方式推进。

本方案只处理 Step 2：标签与收藏模型替换。不重做 Step 1 搜索/OCR，不提前做 Step 3/4/5，不写实现代码，不修改 PRD。

## 2. v1 相对 v0 的收敛点

v1 相对 v0 固定以下项目负责人收敛点：

1. 数据模型明确为 `AppDatabase` V2 migration，新增 `clipboard_tags` / `clipboard_record_tags`，seed 唯一 favorite，不迁移旧 pinned / pinboard。
2. normalizer 固定为 NFKC + trim + Unicode whitespace fold + control rejection + locale-independent case fold + favorite reserved aliases。
3. 单事实源固定为推荐 `ClipboardTagRepository` + `ClipboardTagStore`，并明确 `ClipboardStore` / `AppModel` / View 的边界。
4. 定义 mutation result，包括 changed tag IDs、affected record IDs、removed tag IDs、selected tag transition。
5. favorite immutable 和 bootstrap/reload/reset 不重复写为底层和 UI 双重要求。
6. `preservePinned` / `clearUnpinned` 不再后置，Step 2 内替换为 `preserveFavorite` / `clearUnfavorited` 或等价 favorite 语义。
7. UI 合同补齐 Settings row、右键菜单、删除/合并说明、active filter 状态迁移、长标签/窄宽度/可访问性。
8. P13B 红绿顺序、legacy scan 分层、旧 P8/P9/P11 迁移口径、Search Gate 输出固定。
9. fixture 和低敏证据矩阵固定。
10. 开发拆分从 2A/2B/2C/2D 小批次改为较大开发批次，同时保留验证分层。

## 3. 非目标

不属于 Step 2：

- Step 1 明文展示、OCR 搜索底座和非标签搜索字段实现。
- 多标签 OR / AND 组合筛选。
- 批量删除标签、删除前二次确认、自动清理空标签。
- Step 3 筛选 hover、安全区域、toolbar 空间、选中反馈、条目密度专项。
- Step 4 详情编辑。
- Step 5 隐私页真实 App 清单或 CLI 广义对象管理。
- 旧 pinboard / pinned 数据迁移、提示迁移或兼容当前产品语义。

## 4. 数据模型与迁移

### 4.1 AppDatabase V2

Step 2 使用 `AppDatabase` V2 或项目等价 schema version：

- v1 -> v2 migration 创建 `clipboard_tags` 和 `clipboard_record_tags`。
- 同一 migration 或 migration 后 ensure seed 唯一 favorite built-in tag。
- 打开旧开发库时保留旧 pinboard/pinned 表和字段，但不迁移数据到新 tag 模型。
- 旧 `clipboard_items.pinned`、`clipboard_pinboards`、`clipboard_pinned_metadata` 只能作为 legacy storage。
- active repository、Store、View、Settings、filter、right-click、verifier ok evidence 不得再以旧 pinned / pinboard 为当前事实源。

### 4.2 Schema 建议

```sql
CREATE TABLE clipboard_tags (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    normalized_name TEXT NOT NULL UNIQUE,
    color_token TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    built_in_kind TEXT NOT NULL DEFAULT 'none',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE UNIQUE INDEX idx_clipboard_tags_builtin_favorite
ON clipboard_tags(built_in_kind)
WHERE built_in_kind = 'favorite';

CREATE INDEX idx_clipboard_tags_sort
ON clipboard_tags(sort_order, display_name);

CREATE TABLE clipboard_record_tags (
    record_id TEXT NOT NULL,
    tag_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY(record_id, tag_id),
    FOREIGN KEY(record_id) REFERENCES clipboard_items(id) ON DELETE CASCADE,
    FOREIGN KEY(tag_id) REFERENCES clipboard_tags(id) ON DELETE CASCADE
);

CREATE INDEX idx_clipboard_record_tags_tag
ON clipboard_record_tags(tag_id, record_id);
```

如果当前 SQLite connection 没有持续启用 foreign keys，repository 必须提供等价 cleanup：

- 删除 record 时删除对应 `clipboard_record_tags`。
- 删除普通 tag 时删除对应 `clipboard_record_tags`。
- repository smoke 需要证明 cleanup 真实发生，而不是只依赖 schema 文案。

### 4.3 Core 模型

```text
ClipboardTag
- id: String
- displayName: String
- normalizedName: String
- colorToken: String
- sortOrder: Int
- builtInKind: ClipboardTagBuiltInKind
- createdAt: Date
- updatedAt: Date

ClipboardTagBuiltInKind
- none
- favorite

ClipboardRecordTag
- recordID: String
- tagID: String
- createdAt: Date
```

不变量：

- `ClipboardTag.id` 是稳定主键。
- `normalizedName` 全局唯一。
- `builtInKind = favorite` 全局最多一条。
- `recordID + tagID` 唯一。
- favorite tag 不可删除。
- favorite 关系来自 `ClipboardRecordTag`。
- 旧 pinned 字段不参与 favorite 状态判断。

## 5. Normalizer 固定算法

`ClipboardTagNameNormalizer.normalizedName(_:)` 固定为：

1. Unicode normalize to NFKC。
2. Trim leading/trailing whitespace and newlines。
3. Replace internal Unicode whitespace runs with a single ASCII space。
4. Reject empty result。
5. Reject any control character after normalization。
6. Locale-independent case folding，不跟随系统语言。
7. Return normalized key。

建议 reserved alias 检查走同一 normalizer，再比对 reserved set。

Reserved aliases 最低包含：

- `favorite`
- `收藏`
- 上述值的 trim / case / width 变体。

favorite built-in tag 固定：

```text
builtInKind = favorite
normalizedName = favorite
displayName = 收藏
```

普通标签创建 / 重命名时：

- normalizedName == `favorite` -> reject。
- normalizedName 或 normalized alias 匹配 `收藏` -> reject。
- 空名、控制字符、重复 normalizedName -> reject。

最低 fixture：

- `Work` / ` work ` / `WORK` 视为重复。
- 连续 Unicode 空白折叠。
- 全角英文经 NFKC 后按同一规则比较。
- 空名失败。
- 控制字符失败。
- `favorite`、` Favorite `、`收藏`、全角/空白变体失败。

## 6. Repository / Store 单事实源

### 6.1 ClipboardTagRepository

推荐独立 `ClipboardTagRepository`，共享 `AppDatabase` connection / transaction helper：

```text
loadTags() -> [ClipboardTag]
loadRecordTags(recordIDs:) -> [String: [ClipboardTag]]
createTag(displayName:colorToken:) -> ClipboardTagMutationResult
createTagAndAttach(displayName:colorToken:recordID:) -> ClipboardTagMutationResult
renameTag(tagID:displayName:) -> ClipboardTagMutationResult
updateTagColor(tagID:colorToken:) -> ClipboardTagMutationResult
reorderTags(tagIDsInDisplayOrder:) -> ClipboardTagMutationResult
deleteTag(tagID:) -> ClipboardTagMutationResult
mergeTag(sourceTagID:targetTagID:) -> ClipboardTagMutationResult
addTag(recordID:tagID:) -> ClipboardTagMutationResult
removeTag(recordID:tagID:) -> ClipboardTagMutationResult
toggleFavorite(recordID:) -> ClipboardTagMutationResult
ensureFavoriteTag() -> ClipboardTag
```

如果实现选择 `ClipboardRepository` extension，P13B 必须证明等价单事实源：

- View 不直接写 DB。
- Store 不拼旧 pinboard/pinned 事实。
- tag operations 仍统一返回 mutation result。
- old pinned/pinboard APIs 不作为 current ok evidence。

### 6.2 ClipboardTagStore

`ClipboardTagStore` 是以下事实唯一来源：

- `tags`
- `recordTags`
- `selectedTagID`
- tag operation state
- tag operation error

`ClipboardStore` 继续负责 records、payload read、preview/search/list 状态；可持有并桥接 `ClipboardTagStore.objectWillChange`，但不得复制 tag arrays、record-tags 或 selected tag。`AppModel` 只提供 facade、status banner 和跨 store 协调，不保存 tag facts。

View 只能通过 `ClipboardTagStore` / `ClipboardStore` / `AppModel` facade 操作标签，不直接访问 repository，也不读取旧 pinned / pinboard 事实源。

### 6.3 Filter State

`ClipboardController.filteredRecords` 必须从旧 `pinboardID` 迁移到：

```text
selectedTagID + RecordTag
```

要求：

- `selectedTagID == nil` 表示全部。
- favorite filter 也是 selected favorite tag ID。
- active filter count 基于 selected tag，不基于 pinboard。
- `ClipboardFilterState.pinboardID` 不再是当前筛选事实源。

## 7. Mutation Result 与事务边界

### 7.1 Mutation result

每个标签 mutation 返回等价结构：

```text
ClipboardTagMutationResult
- changedTagIDs: [String]
- affectedRecordIDs: [String]
- removedTagIDs: [String]
- selectedTagTransition: ClipboardTagSelectionTransition
- searchInvalidation: ClipboardTagSearchInvalidation

ClipboardTagSelectionTransition
- none
- clear
- switchTo(tagID)
```

`searchInvalidation` 只消费 `affectedRecordIDs`。View / Store 不得二次猜测旧状态。

### 7.2 操作与结果

| 操作 | 事务要求 | affectedRecordIDs | selectedTagTransition |
| --- | --- | --- | --- |
| create | normalize/validate/insert tag | [] | none |
| create-and-attach | create + insert RecordTag 同一事务 | 当前 recordID | none |
| add | ensure record/tag + insert or ignore RecordTag | 当前 recordID | none |
| remove | delete RecordTag | 当前 recordID | none |
| rename | reject favorite + validate + update tag | 所有关联该 tag 的 recordIDs | none |
| updateColor | reject favorite + update color | [] | none |
| reorder | reject favorite in ordinary order + update sortOrder | [] | none |
| delete | reject favorite + capture affected + delete relations + delete tag | 删除前关联 recordIDs | clear if selected deleted tag |
| merge | reject favorite/source==target + transfer/de-dupe + delete source | source/target 去重 affected recordIDs | switchTo target if selected source |
| toggleFavorite | add/remove favorite RecordTag | 当前 recordID | none |

删除 / 合并失败不得半更新。成功后 Store 按 `selectedTagTransition` 更新：

- 删除当前筛选 tag -> 清空 selectedTagID。
- 合并当前筛选 source -> selectedTagID 切换为 target。
- 删除 / 合并非当前筛选 tag -> 不改变 selected tag。

### 7.3 Search invalidation

mutation 成功后：

- create 不附加 record 时不触发 record search invalidation。
- create-and-attach、add、remove、rename、delete、merge、toggleFavorite 触发 affected recordIDs。
- updateColor / reorder 不触发 search invalidation，但刷新 tag list。
- invalidation 可在 DB transaction 内写 dirty marker，或 transaction 成功后调用 adapter。

如果 DB transaction 成功但 invalidation adapter 失败：

- mutation result 必须报告 `searchInvalidation` 的失败 category。
- P13B / 开发记录不得宣称 tag search contract 完全闭合。
- UI tag facts 仍以 DB transaction 结果为准。

## 8. Favorite Built-In 保护

favorite 是 built-in identity：

- 固定第一。
- 不参与普通排序。
- colorToken 固定，例如 `favorite` 或 `star`。
- displayName 由 built-in display provider / L10n 提供。
- delete / rename / updateColor / reorder 都拒绝。
- merge source / target 都拒绝 favorite。
- 普通标签不能合并到 favorite。
- favorite 不能作为 source 被合并删除。
- favorite bootstrap / load / reload / restart / fixture reset 后不重复。
- favorite button 和右键 favorite 读写 favorite RecordTag，不读写 `clipboard_items.pinned`。

bootstrap 时机：

- V2 migration seed。
- `ClipboardTagRepository.loadTags()` 前 lightweight ensure。
- fixture/reset 初始化。

异常存在多个 favorite 时，P13B fail closed。除非开发方案定义明确修复策略，不应静默吞掉数据损坏。

## 9. Preserve / Clear 策略收敛

Step 2 内 active UI、Store 当前事实源、repository policy 当前行为、verifier ok evidence 不得继续依赖：

- `preservePinned`
- `clearUnpinned`
- pinned / unpinned 用户可见语义。

如果保留“清理时保留收藏项”能力：

- 用户可见命名改为 `preserveFavorite` 或等价收藏语义。
- 清理动作命名改为 `clearUnfavorited` 或等价收藏语义。
- repository policy 基于 favorite RecordTag 判断。
- P13B / P9A smoke 证明旧 pinned 字段不参与保留/清理行为。

旧 `preservePinned` / `clearUnpinned` 名称如因兼容暂存，只能作为 deprecated adapter 或 legacy storage：

- 不出现在 active UI 文案。
- 不作为 Store/AppModel current facade。
- 不作为 verifier ok evidence。
- 不作为开发记录通过项。

## 10. Search Gate

Step 2 只交付标签字段 contract，不重做 Step 1 search document。

### 10.1 Contract

推荐 projection：

```text
ClipboardTagSearchProjection
- recordID
- tagIDs
- tagDisplayNames
- tagNormalizedNames
- updatedAt
```

或扩展 Step 1 `ClipboardSearchDocument`：

```text
tagTokens: [String]
tagRevision: String
```

mutation 成功后通过 affected recordIDs 调用：

```text
markSearchDocumentTagsDirty(recordIDs:)
```

若 Step 1 search document 可用，重建 affected records 的 tag tokens；若不可用，使用 no-op adapter + residual record。

### 10.2 Gate 输出

P13B 或验收记录必须区分：

```json
{
  "tag_search": {
    "contract_gate": "pass",
    "e2e_gate": "blocked_by_step1",
    "affected_record_ids_emitted": true,
    "projection_available": true,
    "fixtures_body_excludes_tag_name": true,
    "residual_risk": "Step 1 search document not yet implemented; end-to-end tag search remains integration gate."
  }
}
```

允许值：

- `tag_search_contract_gate=pass`
- `tag_search_e2e_gate=blocked_by_step1`
- `tag_search_e2e_gate=residual_risk`
- `tag_search_e2e_gate=pass`

只有 Step 1 search document 可用，且搜索框真实命中标签名时，`e2e_gate` 才能为 `pass`。

端到端 Gate 通过时必须覆盖：

- 搜索 `Work` 命中拥有 Work 标签的记录。
- `Work -> Review` 后旧名不命中，新名命中。
- `Draft -> Work` 合并后源名不命中，目标名命中。
- 删除 `Work` 后不再因标签字段命中。
- fixture 正文不包含标签名，避免正文命中伪装为标签命中。

## 11. UI 合同

### 11.1 FilterBar

单标签筛选：

- `全部` / All 可达。
- favorite first。
- 普通标签按 Settings 排序。
- active filter 与 hover / focus / 普通状态可区分。
- 清除筛选路径始终可达。
- 删除 active tag 后 selectedTagID 清空，回到全部。
- 合并 active source 后 selectedTagID 切换为 target。

不展示多标签 OR / AND。

### 11.2 右键菜单

右键 tag section 是当前记录关系编辑入口：

- favorite first。
- checked 表示当前记录已添加该标签，点击移除。
- unchecked 表示当前记录未添加该标签，点击添加。
- `New Tag...` 或等价入口固定在标签菜单中。
- 新建成功后立即附加到当前记录。
- 新建失败时错误贴近输入语境或同屏可见。
- 新建失败不清空输入，不改变 record-tag 关系。
- 如果平台菜单关闭，必须通过同屏 status 显示失败原因，并允许用户重新进入。

最低错误反馈：

- duplicate：`标签名称已存在`
- empty：`标签名称不能为空`
- control character：低敏错误 code + 可理解文案
- reserved favorite name：`“收藏”是内置标签名称`

### 11.3 Settings tag management

Settings tag row 固定结构：

- 颜色 swatch。
- 名称。
- 状态 / 内置标识。
- 排序控件。
- 操作入口。

favorite row：

- 固定第一。
- 显示五角星和内置状态。
- 不暴露可执行 delete / rename / recolor / reorder / merge。
- 若禁用控件，tooltip / accessibility label 说明原因。
- 若隐藏动作，row 内仍需说明 favorite 是内置标签。

普通标签：

- 可改名、改色、排序、合并、删除。
- 新建默认进入普通标签末尾。
- 删除文案必须表达“从所有记录移除此标签”。
- 合并 UI 展示 source、target 和结果。

排序控件：

- 首版建议上下移动按钮或操作菜单中的“上移 / 下移”。
- 若采用拖拽，必须提供键盘可用替代路径。

### 11.4 删除 / 合并文案与状态

删除普通标签：

- 文案使用“删除标签并从所有记录移除”或等价说明。
- 成功反馈说明标签已移除。
- 失败反馈说明未做更改。

合并普通标签：

- UI 展示“将 {源标签} 合并到 {目标标签}，相关记录将改为使用 {目标标签}，{源标签} 将被删除”或等价说明。
- 成功后，如 active filter 是 source，切换到 target 并提示。
- 失败后 source / target / record-tag 全部保持原状态。

### 11.5 布局与可访问性

最低验收：

- 长标签名单行截断或等价处理，不覆盖操作区。
- 完整名称通过 tooltip / accessibility label 可读。
- 颜色 swatch 只辅助识别，标签名始终显示。
- favorite colorToken 固定，不进入普通色板。
- 窄宽度下可把 rename / merge / delete 折叠进操作菜单，但新建、favorite 状态、active filter、清除筛选仍可达。
- VoiceOver 能读出标签名、是否收藏/内置、排序位置和可用操作。
- 键盘用户可完成普通标签排序和打开操作入口。

## 12. 旧 Pinboard / Pinned 退出

### 12.1 必退 active path

Step 2 完成后，以下不得作为当前事实源：

- `ClipboardStore.pinboards`
- `ClipboardStore.pinnedMetadata`
- `ClipboardStore.togglePin`
- `ClipboardStore.move(recordID:toPinboard:)`
- `ClipboardStore.renamePinnedRecord`
- `ClipboardStore.setPinboardFilter`
- `ClipboardController.pinnedCount`
- `ClipboardFilterState.pinboardID`
- `ClipboardFilterBarView` pinboard group
- `ClipboardRecordViews` pin/unpin / move-to-pinboard menu
- `ClipboardSettingsPane` pinboards section
- `AppModel` pin/move/rename pinned facades
- `preservePinned` / `clearUnpinned` active behavior
- verifier 中旧 pinboard / pinned checks as ok evidence

### 12.2 Legacy storage

允许短期存在：

- 旧 DB 字段/表。
- 历史归档文档。
- 旧 verifier baseline reference。

但必须标记为 `legacy_storage` 或 `baseline_reference`，不参与 current ok。

### 12.3 Legacy scan 分层

P13B 输出至少包含：

```json
{
  "legacy_exit": {
    "active_ui_tokens_clear": true,
    "active_store_paths_clear": true,
    "filter_state_no_pinboard_fact": true,
    "right_click_no_move_to_pinboard": true,
    "settings_no_pinboard_section": true,
    "policy_no_pinned_fact": true,
    "verifier_ok_evidence_clear": true,
    "legacy_storage_baseline_only": true
  }
}
```

Fail 条件：

- active UI 中存在 `Move to Pinboard`、`Pinned Groups`、`clear unpinned`、`固定` 独立模型。
- current Store / AppModel facade 仍用 `togglePin`、`setPinboardFilter`、`renamePinnedRecord`、`pinnedMetadata` 决定 favorite/filter/search。
- policy 仍基于 `clipboard_items.pinned` 保护或清理当前记录。
- P8/P9/P11 仍把 pinboard/pinned smoke 当成 `ok` 证据。
- `ClipboardFilterState.pinboardID` 仍是当前筛选事实源。

## 13. P13B Fail-Closed Verifier

新增：

- `tools/verification/p13b_clipboard_tags_model_checks.py`

### 13.1 红绿顺序

- Step 2A 前：P13B 可因缺少 Tag schema / active legacy path 失败。
- Step 2A 后：schema / repository / normalizer / favorite bootstrap 相关断言转绿。
- Step 2B 后：Store / AppModel facade / selectedTagID 相关断言转绿。
- Step 2C 后：UI active token、right-click、filter、settings 相关断言转绿。
- Step 2D / final gate 后：search contract 和旧 P8/P9/P11 当前事实源迁移转绿或明确 residual。

开发批次可以合并，但 P13B 输出仍应能按上述层次定位红绿状态。

### 13.2 最低断言

P13B 最低断言：

1. Current PRD v1、技术方案 v1 存在；旧 PRD/v0 不作为 ok evidence。
2. `ClipboardTag` / `ClipboardRecordTag` 或等价模型存在。
3. V2 schema / migration 包含 tagID、displayName、normalizedName、colorToken、sortOrder、builtInKind。
4. `normalizedName` unique，favorite built-in unique，recordID+tagID unique。
5. foreign key cascade 或等价 cleanup 存在且 smoke 可证明。
6. normalizer 固定 NFKC、trim、Unicode whitespace fold、case fold、empty/control/reserved rejection。
7. favorite bootstrap idempotent，reload/reset/restart 不重复。
8. favorite delete/rename/recolor/reorder/merge source/merge target 均拒绝。
9. RecordTag 是多标签和 favorite 关系来源，不读取 pinned。
10. tag operations 通过 repository/store API，不由 View 直接改事实。
11. mutation result 暴露 changed tags、affected records、removed tags、selected tag transition。
12. delete/merge 使用 transaction 或等价一致性边界。
13. selectedTagID delete active -> clear；merge active source -> switch target。
14. search contract gate 输出 affected recordIDs / projection / invalidation。
15. `ClipboardTagStore` 或等价 store 是 tag facts source；`ClipboardStore` 不复制 facts；`AppModel` 不保存 facts。
16. `ClipboardController.filteredRecords` 不以 pinboardID 为 current filter fact。
17. active UI 使用 tag source：filter/right-click/settings/favorite button。
18. Settings favorite row immutable UI 合同存在。
19. right-click checked/unchecked/add/remove/new/error 合同存在。
20. `preservePinned` / `clearUnpinned` active UI/policy/facade/ok evidence 退出或改为 favorite 语义。
21. legacy scan 分层输出。
22. low-sensitive output 不泄露真实剪贴板正文、完整路径、用户内容。

### 13.3 旧门禁迁移

| 脚本 | Step 2 定位 | 必改方向 |
| --- | --- | --- |
| `p9a_clipboard_repository_storage_smoke.py` | Repository smoke | 增加 tags/favorite repository smoke；旧 pinboard smoke 只 baseline reference |
| `p9b_clipboard_appstate_repository_integration_checks.py` | AppModel/Store integration | 改查 ClipboardTagStore/selectedTagID/tag facade，不再以 `togglePin` / `renamePinnedRecord` 为 ok |
| `p8_clipboard_product_polish_checks.py` | 产品展示门禁 | 改查 favorite row、tag filter、right-click tag menu |
| `p8i_settings_clipboard_system_checks.py` | Settings 门禁 | 改查 tag management、favorite immutable、legacy wording exit |
| `p7d_clipboard_panel_resize_hover_checks.py` | 若覆盖 filter bar | 迁移为 tag filter；否则降级 Step 3 baseline |
| `p11e_clipboard_hardening_checks.py` | output boundary / baseline | 旧 pinned displayName 不作为 Step 2 tag acceptance |

任何旧 story/archive/project docs 只能进入 `baseline_reference`，不得进入 `ok` 判定。

## 14. Fixture 与低敏证据

### 14.1 Repository smoke

| 场景 | 操作 | Pass | Fail |
| --- | --- | --- | --- |
| favorite bootstrap | ensure/load/reset/reload | 始终唯一 favorite，第一位 | 0 个或多个 favorite |
| create | 新建 `Work` | tag 存在，normalizedName 稳定，sortOrder 普通末尾 | 空 tag、无 normalizedName、排序不稳定 |
| duplicate | `work` / ` Work ` / `WORK` | 均拒绝，原状态不变 | 创建重复普通标签 |
| invalid name | 空名 / 控制字符 / `收藏` / `favorite` | 拒绝并输出 error code | 创建成功或占用 favorite |
| add/remove | A 添加 `Work`、`Draft`，重复添加 `Work`，移除 `Draft` | 去重，A 保留 `Work` | 重复关系、误删其他标签 |
| rename | `Draft -> Review` | 展示/筛选/右键/search contract 同步 | 旧名和新名混用或半更新 |
| delete | 删除 `Draft` | tag 消失、关系移除、record 保留 | 关系残留或 record 被删 |
| merge | `Draft -> Work` | 关系转移、重复去重、source 删除、target 属性保留 | 部分迁移、target 属性被覆盖 |
| favorite immutable | delete/rename/recolor/reorder/merge favorite | 全部拒绝 | 任一路径改动 favorite |
| persistence | reload/restart 后读取 | 标签、关系、颜色、排序、favorite 保持 | 状态丢失或 favorite 重复 |

### 14.2 UI fixture

| 场景 | Pass | Fail |
| --- | --- | --- |
| filter favorite first | `全部` 可达，favorite 第一，普通标签按排序，active 明确 | favorite 不在第一，或仍显示 pinboard group |
| single tag filter | 选择 `Work` 只显示有 Work 的记录，clear 回全部 | 暗示多选 OR/AND 或结果不确定 |
| right-click add/remove | 已添加/未添加可区分，点击可添加/移除 | 无状态列表或关系不同步 |
| right-click new | 新建 `Review` 后立即附加当前记录 | 创建成功但未附加，或失败半更新 |
| settings CRUD | 普通标签可新建、改名、改色、排序、合并、删除 | 入口不可达或状态不同步 |
| favorite immutable UI | favorite 行禁用/隐藏 delete/rename/recolor/reorder/merge，并说明原因 | UI 可触发 favorite 变更 |
| long label/narrow | 长标签不遮挡主操作，名称仍可识别或可访问 | 操作按钮被覆盖、label 溢出不可用 |

### 14.3 错误反馈

必须可复跑：

- duplicate
- empty
- control character
- reserved favorite name
- favorite immutable
- delete failed
- merge failed
- create from context menu failed

失败证据只输出 fixture id、error code、布尔断言和低敏字段。

### 14.4 低敏输出

Verifier、smoke、开发记录、验收记录不得输出：

- 真实剪贴板正文。
- 完整文件路径。
- 真实用户路径。
- 完整 URL query。
- 用户内容。

默认输出允许：

- fixture id。
- short record id/hash。
- boolean。
- count。
- error code/category。
- relative path。

## 15. 开发批次建议

用户最新要求是顶层 step 串行推进；单个 step 内开发批次可以适当合并。建议按较大批次组织，同时保留 P13B 分层输出。

### Batch 1：Core model / repository / store 基础

合并原 2A + 2B 的主要内容：

- P13B baseline red。
- AppDatabase V2 migration。
- `ClipboardTag` / `ClipboardRecordTag` / normalizer。
- favorite bootstrap。
- `ClipboardTagRepository`。
- `ClipboardTagMutationResult`。
- `ClipboardTagStore`。
- `ClipboardStore` objectWillChange bridge。
- AppModel thin facade。
- selectedTagID 替代 pinboardID 的 Store/filter 事实。

验收：

- repository smoke 大部分转绿。
- favorite immutable 转绿。
- normalizer fixture 转绿。
- Store/AppModel 单事实源转绿。

### Batch 2：UI replacement / legacy exit / favorite policy

合并原 2C 和旧 pinned 退出：

- FilterBar tag filter。
- right-click favorite/tag/new。
- Settings tag management。
- favorite row immutable UI。
- `preserveFavorite` / `clearUnfavorited` 或等价替换。
- active UI legacy wording exit。
- old Store/AppModel/repository pinned facade 退出 active path。

验收：

- UI fixture 转绿。
- legacy scan active UI/store/policy/verifier ok 转绿。
- P8/P8I/P9B 当前事实源迁移。

### Batch 3：Search contract / final verifier migration

收口：

- tag search projection / invalidation hook。
- Step 1 search document adapter；不可用时 no-op + residual。
- P13B final gate。
- P9A/P9B/P8/P8I/P7D/P11E 迁移。
- 最终 build / CLI / diff check。

验收：

- `tag_search_contract_gate=pass`。
- `tag_search_e2e_gate=pass` 或明确 `blocked_by_step1` / residual。
- 旧 evidence 只 baseline reference。

## 16. 最低最终验收矩阵

实现完成后建议串行运行并记录：

```bash
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
```

如相关脚本仍覆盖 filter bar：

```bash
python3 tools/verification/p7d_clipboard_panel_resize_hover_checks.py
```

若保留 P11E：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
```

但 P11E 只能作为 output-boundary / baseline，不作为 Step 2 tag ok。

最终还应运行：

```bash
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

技术方案和自动化 verifier 不触发真实剪贴板内容、真实用户路径、provider、Keychain、TCC、系统设置、Show in Finder 或 restart。

## 17. 风险

### P1

1. 双事实源风险：旧 pinned/pinboard 与新 favorite/tag 并存。缓解：P13B legacy scan 分层，active path 必须清空。
2. normalizer 变更风险：normalizedName 进入唯一约束后再改算法成本高。缓解：v1 固定 NFKC 算法和 fixture。
3. favorite 重复风险：migration、reload、fixture reset 多次 seed。缓解：unique index + idempotent ensure + P13B。
4. mutation 半更新风险：delete/merge 未返回 affected IDs 或 selected transition。缓解：transaction + mutation result。
5. preservePinned 泄漏风险：清理策略继续保护旧 pinned。缓解：Step 2 内改为 favorite 语义或 active UI/policy 退出。
6. tag search 伪闭合风险：Step 1 search document 不可用时冒充 e2e pass。缓解：Search Gate 三态输出。

### P2

1. 标签数量多时右键菜单可用性下降。Step 2 保证状态正确，搜索/分页后续优化。
2. 长标签名、色板、窄宽度需要低敏截图或 accessibility tree 复核。
3. 旧 DB 字段短期保留会让静态 token 扫描持续出现旧词。P13B 必须区分 legacy storage 与 active path。
4. 真实 macOS 菜单场景难以完全自动化。验收记录应区分静态/fixture/UI 手工证据。

## 18. 需要复审的问题

开发复审：

1. V2 migration 文件位置和 SQLite foreign key/cascade 真实启用方式。
2. `ClipboardTagRepository` 与 `AppDatabase` transaction helper 共享方式。
3. `ClipboardTagStore` 与 `ClipboardStore` objectWillChange bridge。
4. `preserveFavorite` / `clearUnfavorited` 与当前 prune/clear API 对接。
5. Search invalidation adapter 在 Step 1 search document 可用/不可用两种状态下的实现。

测试/质量复审：

1. Repository smoke fixture 是否覆盖全部 mutation result。
2. UI fixture 是否能低敏复跑。
3. P13B legacy scan false positive / false negative 边界。
4. Search Gate 输出是否满足 PASS/residual。
5. 旧 P8/P9/P11 迁移后的 current ok evidence。

UI/交互复审：

1. Settings row 固定结构和 favorite immutable 原因表达。
2. 右键新建失败反馈落点。
3. 删除/合并文案与 active filter 迁移反馈。
4. 长标签名、排序控件、窄宽度、VoiceOver / 键盘路径。

## 19. 开发前通过条件

项目负责人派发开发前建议确认：

- 本 v1 已吸收收敛文档和 v1 修订派发的必须项。
- Step 2 不扩大到 Step 1/3/4/5。
- `preservePinned` / `clearUnpinned` 已确定为 Step 2 内退出或 favorite 语义替换。
- P13B red/green 分层和 legacy scan 分层被接受。
- Search Gate 三态输出被接受。
- 后续开发按较大批次推进，但 P13B 仍能定位每层红绿状态。

当前仍需项目负责人额外取舍的问题：无。
