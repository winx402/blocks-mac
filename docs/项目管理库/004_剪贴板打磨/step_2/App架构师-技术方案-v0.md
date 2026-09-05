# Step 2 App 架构师技术方案 v0

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-PRD-v1复核-v0.md`
范围：标签与收藏模型替换
状态：technical-plan-v0

## 1. 结论

Step 2 可以按“Tag / RecordTag 独立事实源 + Favorite built-in tag + 原子标签事务 + 标签字段搜索契约 + 旧 pinboard/pinned fail-closed 退出门禁”拆解进入技术方案复审。

当前代码中旧 pinboard / pinned 影响面较广：

- `AppDatabase` 当前建有 `clipboard_items.pinned`、`clipboard_pinboards`、`clipboard_pinned_metadata`。
- `ClipboardRepository` 当前暴露 `loadPinboards()`、`loadPinnedMetadata()`、`pin()`、`unpin()`、`move()`、`renamePinnedRecord()`、`clearUnpinned()` 等旧 API。
- `ClipboardStore` 当前持有 `pinboards`、`pinnedMetadata`、`togglePin()`、`move(...)`、`renamePinnedRecord(...)`、`setPinboardFilter(...)` 等旧事实。
- 面板、右键菜单、筛选条、设置页、状态文案和 verifier 中都还有 pinboard / pinned / 固定语义。

因此 Step 2 不能做成“UI 改名”。必须先建立新的 Tag / RecordTag 当前事实源，再替换 UI、Store、Repository 和 verifier 的事实来源。旧字段如短期因迁移成本保留，必须只作为 legacy storage，不参与当前 UI、筛选、收藏按钮、标签搜索字段或 ok 证据。

## 2. 非目标

本技术方案不覆盖：

- Step 1 明文展示、OCR 搜索底座和非标签搜索字段实现。
- Step 3 面板 hover 安全区、搜索框宽度、选中反馈、单 / 双击设置、卡片密度和全量布局打磨。
- Step 4 详情编辑、保存 / 取消、富文本编辑和 OCR 文本编辑。
- Step 5 隐私页真实 App 清单与 CLI 广义对象管理。
- 多标签 OR / AND 组合筛选。
- 批量删除标签、删除前二次确认、自动清理空标签。
- 旧 pinboard / pinned 数据迁移。

## 3. 总体架构

推荐分层：

```text
BlocksCore
- ClipboardTag
- ClipboardRecordTag
- ClipboardTagRepository / ClipboardRepository tag extension
- Normalized tag name generator
- Transactional tag operations

BlocksApp Features/Clipboard
- ClipboardTagStore or ClipboardStore tag sub-store
- Favorite tag bootstrap state
- Tag filter state
- Tag search invalidation contract

BlocksApp Views
- ClipboardFilterBarView consumes tags, not pinboards
- ClipboardRecordViews right-click menu edits tags, not pinboards
- ClipboardSettingsPane tag management section

tools/verification
- New Step 2 fail-closed verifier
- Existing P8/P9/P11 gates migrated away from pinboard/pinned ok evidence
```

推荐新增 `ClipboardTagStore`，由 `ClipboardStore` 持有并桥接 `objectWillChange`，保持 Step 4 系列 store 拆分方向。若开发阶段为了降低改动量暂不拆 store，也应在 `ClipboardStore` 内清晰分出 tag repository API 和 tag state，不允许 View 直接拼接 Tag / RecordTag 事实。

## 4. Tag / RecordTag 事实源

### 4.1 Core 模型

建议在 `BlocksCore` 定义：

```text
ClipboardTag:
- id: String
- displayName: String
- normalizedName: String
- colorToken: String
- sortOrder: Int
- builtInKind: ClipboardTagBuiltInKind
- createdAt: Date
- updatedAt: Date

ClipboardTagBuiltInKind:
- none
- favorite

ClipboardRecordTag:
- recordID: String
- tagID: String
- createdAt: Date
```

最低不变量：

- `ClipboardTag.id` 是稳定主键，不使用 `displayName` 关联记录。
- `normalizedName` 全局唯一。
- `builtInKind = favorite` 全局最多一条。
- `RecordTag(recordID, tagID)` 唯一。
- RecordTag 的 recordID 必须指向现有 clipboard record。
- 删除 record 时级联删除 RecordTag。
- 删除普通 tag 时级联删除 RecordTag。
- favorite tag 不可删除。

### 4.2 数据库 schema 建议

建议新增迁移版本，例如 V2：

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

旧表和字段：

- `clipboard_pinboards`、`clipboard_pinned_metadata`、`clipboard_items.pinned` 可以短期保留为 legacy storage，避免大范围破坏，但 Step 2 当前事实源不得读取它们。
- 不做旧数据迁移，不从旧 pinned 生成 favorite RecordTag。
- 不从旧 pinboard 生成 ordinary tags。

## 5. NormalizedName 稳定算法

### 5.1 推荐算法

建议实现一个独立纯函数，例如 `ClipboardTagNameNormalizer.normalizedName(_:)`：

```text
1. Unicode normalize to NFC or NFKC.
2. Trim leading/trailing whitespace and newlines.
3. Replace internal whitespace runs with a single ASCII space.
4. Reject empty result.
5. Reject control characters after normalization.
6. Case-fold using stable locale-independent folding.
7. Return normalized key.
```

建议使用 locale-independent 行为，例如 Swift `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))` 或等价实现。是否做 diacriticInsensitive 可由开发评估，但必须在技术方案 / 开发记录固定；不要跟随系统语言动态变化。

### 5.2 Favorite 名称占用

favorite 的 normalizedName 建议固定为：

```text
favorite
```

`displayName` 可以本地化显示为“收藏”，但普通标签不能通过 `Favorite`、` favorite `、`收藏` 或本地化别名占用 favorite 语义。为避免中文显示名与英文内置 key 混乱，建议在 built-in tag 上单独存：

```text
builtInKind = favorite
normalizedName = favorite
displayName = 收藏
```

普通标签创建 / 重命名时：

- 若 normalizedName == `favorite`，拒绝。
- 若 displayName 经内置别名表匹配到收藏，例如 `收藏`、`favorite`，拒绝。

内置别名表不需要复杂多语言，首版至少覆盖当前 UI 语言中的 `收藏` 和 `favorite`。

### 5.3 错误类型

建议 Core 层错误类型：

```text
ClipboardTagError.emptyName
ClipboardTagError.invalidName
ClipboardTagError.duplicateName
ClipboardTagError.builtInNameReserved
ClipboardTagError.favoriteImmutable
ClipboardTagError.tagNotFound
ClipboardTagError.recordNotFound
ClipboardTagError.invalidMergeTarget
ClipboardTagError.transactionFailed
```

UI 根据错误展示明确反馈；日志只记录错误 code 和低敏 id。

## 6. Favorite Bootstrap 与不可变更保护

### 6.1 Bootstrap 时机

推荐在以下位置确保 favorite 存在：

- repository migration V2 完成后 seed。
- `ClipboardTagRepository.loadTags()` 前进行 lightweight ensure。
- fixture/reset 初始化时 ensure。

bootstrap 应满足幂等：

- 如果没有 `builtInKind = favorite`，创建一条。
- 如果存在一条 favorite，校正 displayName/colorToken/sort invariant。
- 如果异常存在多条 favorite，保留稳定一条并使 verifier fail；不静默吞掉数据损坏，除非开发方案定义修复策略。

### 6.2 Favorite 不变量

favorite tag：

- `builtInKind = favorite`。
- `sortOrder` 不参与普通排序；UI 永远第一。
- colorToken 固定，例如 `favorite` 或 `star`。
- displayName 由 L10n / built-in display provider 提供，普通 rename API 不可修改。
- delete API 不可删除。
- updateColor API 不可改色。
- reorder API 不接受 favorite。
- merge source / target 中，source 不能为 favorite，target 也不能为 favorite，符合 PRD “普通标签禁止合并到收藏”。

## 7. Repository / Store API

### 7.1 Repository API 建议

建议新增 `ClipboardTagRepository` 或作为 `ClipboardRepository` extension：

```text
loadTags() -> [ClipboardTag]
loadRecordTags(recordIDs: [String]) -> [String: [ClipboardTag]]
createTag(displayName: String, colorToken: String?) throws -> ClipboardTag
renameTag(tagID: String, displayName: String) throws -> ClipboardTag
updateTagColor(tagID: String, colorToken: String) throws -> ClipboardTag
reorderTags(tagIDsInDisplayOrder: [String]) throws -> [ClipboardTag]
deleteTag(tagID: String) throws
mergeTag(sourceTagID: String, targetTagID: String) throws
addTag(recordID: String, tagID: String) throws
removeTag(recordID: String, tagID: String) throws
toggleFavorite(recordID: String) throws -> Bool
```

所有 mutation API 必须在 repository transaction 内维护 Tag / RecordTag、search invalidation 事件和 updatedAt。

### 7.2 Store 边界

推荐 `ClipboardTagStore: ObservableObject`：

```text
@Published private(set) var tags: [ClipboardTag]
@Published private(set) var recordTags: [String: [ClipboardTag]]
@Published var selectedTagID: String?

loadTagState(recordIDs:)
createTagAndAttach(displayName:, recordID:)
toggleTag(recordID:, tagID:)
toggleFavorite(recordID:)
renameTag(...)
updateColor(...)
reorder(...)
deleteTag(...)
mergeTag(...)
```

`ClipboardStore` 可持有 `ClipboardTagStore`，或暴露 facade 给 View。关键是：

- View 不直接访问 SQLite / repository。
- View 不直接读旧 pinned / pinboard 决定 favorite。
- `selectedTagID` 替代 `filterState.pinboardID`。
- `activeFilterCount` 计算基于 selected tag，不再基于 pinboardID。

### 7.3 AppModel facade

`AppModel` 可继续提供轻量 coordinator/status banner facade，例如：

- `toggleClipboardFavorite(recordID:)`
- `addClipboardTag(recordID:tagID:)`
- `createClipboardTagAndAttach(recordID:displayName:)`
- `deleteClipboardTag(tagID:)`

但 `AppModel` 不应成为 tag facts 源，也不应重新保存 tag arrays。

## 8. 操作事务边界

### 8.1 创建

Transaction：

1. normalize name。
2. validate non-empty / no control / not reserved / unique。
3. insert tag with next normal sortOrder。
4. if created from context menu, insert RecordTag(recordID, tagID) in same transaction。
5. emit search invalidation for recordID if attached。

失败：不创建 tag、不改变 record relation。

### 8.2 添加 / 移除标签

添加：

- ensure record exists。
- ensure tag exists。
- insert or ignore RecordTag(recordID, tagID)。
- emit record tag-search invalidation。

移除：

- delete RecordTag(recordID, tagID)。
- favorite 可移除关系，但不可删除 tag entity。
- emit record tag-search invalidation。

重复添加应 idempotent，不报错或返回 alreadyExists 状态；但 DB 仍靠 unique(recordID, tagID) 防重复。

### 8.3 重命名

Transaction：

1. reject favorite。
2. normalize new name。
3. reject duplicate / reserved。
4. update displayName / normalizedName / updatedAt。
5. find affected recordIDs。
6. emit search invalidation for affected records。

失败：旧名称、右键菜单、筛选、设置页、record tags 保持原样。

### 8.4 改色

Transaction：

1. reject favorite。
2. validate colorToken in controlled palette。
3. update tag color / updatedAt。

改色不影响搜索 index，但 UI 需要刷新所有相关展示。

### 8.5 排序

Transaction：

1. reject favorite in ordinary reorder list。
2. validate set equals all ordinary tags or accepted subset strategy。
3. update ordinary sortOrder。
4. leave favorite outside ordinary ordering。

推荐 ordinary tags sortOrder 使用 spaced integers，例如 1000、2000，便于插入；是否压缩由技术方案决定，UI 只要求稳定。

### 8.6 删除普通标签

Transaction：

1. reject favorite。
2. load affected recordIDs。
3. delete RecordTag rows for tagID。
4. delete Tag row。
5. if selectedTagID == deleted tag, clear selectedTagID at Store/UI level。
6. emit search invalidation for affected recordIDs。

失败：Tag 和 RecordTag 保持原状态。

### 8.7 合并普通标签

Transaction：

1. reject source == target。
2. reject source favorite。
3. reject target favorite。
4. load affected recordIDs for source。
5. insert or ignore RecordTag(recordID, targetTagID) for affected records。
6. delete RecordTag(sourceTagID)。
7. delete source Tag。
8. keep target displayName/color/sortOrder unchanged。
9. if selectedTagID == source, Store/UI switches to target after success。
10. emit search invalidation for affected recordIDs。

失败：不允许部分记录已转移、部分未转移。SQLite transaction 必须覆盖全部 steps。

## 9. Step 1 Search Document 接入

Step 2 只交付标签字段 contract，不实现非标签搜索底座。

### 9.1 Contract

建议定义：

```text
ClipboardTagSearchProjection
- recordID
- tagIDs
- tagDisplayNames
- tagNormalizedNames
- updatedAt
```

或在 Step 1 `ClipboardSearchDocument` 扩展：

```text
tagTokens: [String]
tagRevision: String
```

Step 2 mutation 成功后必须调用等价接口：

```text
markSearchDocumentTagsDirty(recordIDs:)
```

如果 Step 1 search document 已实现：

- 立即重建 affected records 的 tagTokens。

如果 Step 1 search document 未实现：

- 记录 contract hook 或 no-op adapter，并在开发记录中标记“端到端标签搜索待 Step 1 集成”。

### 9.2 Gate 拆分

字段契约 Gate：

- create / rename / delete / merge / add / remove 都能产出 affected recordIDs。
- 标签搜索 projection 可由 repository 查询。
- fixture 正文不包含标签名，避免伪命中。

端到端搜索 Gate：

- 搜索标签名命中拥有标签的记录。
- 重命名后旧名不命中、新名命中。
- 合并后源名不命中、目标名命中。
- 删除后标签名不命中。

端到端 Gate 依赖 Step 1 search document 实现；不能在 Step 2 单独伪装完成。

## 10. 旧 Pinboard / Pinned 退出方案

### 10.1 必退当前事实源

Step 2 完成后，以下不应作为当前事实源：

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
- verifier 中旧 pinboard / pinned checks as ok evidence

如果上述符号因开发拆分短期存在，必须满足：

- active UI 不调用。
- current verifier 不以它们作为 pass 条件。
- 开发记录列为 legacy residual。

### 10.2 DB legacy 处理

不要求 Step 2 立即删除旧 DB 字段和表。建议：

- 新 schema 增加 `clipboard_tags` / `clipboard_record_tags`。
- 旧 `clipboard_items.pinned`、`clipboard_pinboards`、`clipboard_pinned_metadata` 保留但停止写入当前动作。
- `ClipboardRepositoryPrunePolicy.preservePinned` 需要重新定义或退出用户可见设置。PRD Step 2 没有要求存储策略重设，但“收藏”替代固定后，保留 pinned policy 会造成语义冲突。建议 Step 2 技术方案把它列为必须处理的兼容点：
  - 若保留“保护收藏项不被清理”，则 rename 为 preserveFavorite 并基于 favorite RecordTag。
  - 若不在 Step 2 改 policy，则 UI 不应继续显示 preservePinned 文案，开发记录标明该行为待后续策略收口。

推荐在 Step 2 内最小完成 preserveFavorite 语义替换，因为设置页当前有 `settings.clipboardPolicyPreservePinned` 和 `clearUnpinned`，否则用户会看到旧 pinned 概念。

## 11. UI 接入边界

### 11.1 FilterBar

替换 pinboard filter group 为 tag filter group：

- `all`。
- favorite first。
- ordinary tags sorted。
- selectedTagID。
- clear selection path。

不做多标签 OR / AND。

### 11.2 RecordViews 右键菜单

替换：

- pin/unpin -> favorite toggle。
- move to pinboard -> tag menu。
- rename pinned -> 不属于 Step 2。

右键菜单 tag section：

- favorite first，checked if attached。
- ordinary tags sorted，checked if attached。
- new tag entry。
- duplicate/empty error feedback via Store/AppModel status。

### 11.3 SettingsPane

替换 pinboards section 为 tags management section：

- favorite row first, immutable actions hidden/disabled。
- ordinary tag rows with color, name, reorder, rename, merge, delete。
- new tag action。
- delete/merge feedback。

Step 2 不做全量设置页视觉重设计；只要求信息结构不粗糙、不跳动、可访问。

## 12. Fail-Closed Verifier

建议新增：

- `tools/verification/p13b_clipboard_tags_model_checks.py`

最低断言：

1. Current PRD v1 与技术方案存在，且旧 PRD v0 不作为 ok evidence。
2. `ClipboardTag` / `ClipboardRecordTag` 或等价模型存在。
3. schema 或 repository contract 包含 tagID、displayName、normalizedName、colorToken、sortOrder、builtInKind。
4. record-tag unique(recordID, tagID) 或等价去重约束存在。
5. favorite built-in identity exists，且 delete/rename/reorder/recolor/merge source/merge target 路径拒绝 favorite。
6. normalizer 有 trim、whitespace fold、case fold、empty/control rejection。
7. create/rename/delete/merge/add/remove 通过 repository/store API，不由 View 直接改事实。
8. delete/merge 使用 transaction 或等价一致性边界。
9. tag mutation 暴露 search invalidation / reindex contract。
10. active UI 不再引用 pinboard / pinned / fixed 作为标签、收藏、筛选、右键菜单事实源。
11. `ClipboardFilterState.pinboardID` 不作为当前筛选事实源。
12. fixture/reset 可构造 tag + record-tag。
13. output JSON 不泄露真实剪贴板正文、完整路径或用户数据。

需要更新旧 verifier：

- `p9a_clipboard_repository_storage_smoke.py`：新增 tag repository smoke，并移除 pinboard/pinned smoke 作为当前 ok。
- `p9b_clipboard_appstate_repository_integration_checks.py`：从 pinboard/pinned contract 转为 tag/favorite contract。
- `p8_clipboard_product_polish_checks.py` / `p8i_settings_clipboard_system_checks.py`：不再要求 pinboards UI；改查 tags section、favorite row、tag filter。
- `p7d_clipboard_panel_resize_hover_checks.py` 中如仍检查 `togglePinboardFilter`，需要迁移为 tag filter 或降级到 Step 3。
- `p11e_clipboard_hardening_checks.py` 若仍检查 pinned displayName，只能作为 baseline/output-boundary，不作为 Step 2 tag ok。

## 13. 开发子批次建议

### Step 2A：Core schema 与 TagRepository

范围：

- 新增 tag / record-tag schema。
- normalizer。
- favorite bootstrap。
- repository CRUD / relation API。
- repository smoke fixture。

验收：

- 创建、重名、favorite bootstrap、record-tag unique、add/remove、delete、merge transaction smoke。
- 不迁移旧 pinboard/pinned。

### Step 2B：Store / AppModel facade

范围：

- 新增 `ClipboardTagStore` 或 ClipboardStore tag sub-store。
- selectedTagID。
- favorite toggle。
- create/rename/color/reorder/delete/merge/add/remove facades。
- objectWillChange bridge。

验收：

- Store 不把 AppModel 作为事实源。
- View 只调用 Store/AppModel facade，不直接写 repository。
- status feedback 有错误 code 映射。

### Step 2C：UI 替换

范围：

- FilterBar pinboard -> tag filter。
- RecordViews pin/move menu -> favorite/tag context menu。
- SettingsPane pinboards -> tags management。
- Localizable active token 更新。

验收：

- 用户可见 pinboard/pinned/fixed 独立模型退出。
- favorite first and immutable。
- 单标签筛选清除路径。
- 右键菜单 add/remove/new tag。

### Step 2D：Search contract 与 verifier 迁移

范围：

- tag search projection / invalidation hook。
- Step 1 search document adapter if available；否则 no-op + residual risk record。
- 新 `p13b` verifier。
- 迁移 P8/P9/P11 pinboard/pinned checks。

验收：

- 字段契约 Gate PASS。
- 若 Step 1 search document 已落地，端到端 tag search Gate PASS；否则明确残余风险，纳入 Step 6。

## 14. 风险

### P1 风险

1. 双事实源风险：旧 pinned 和新 favorite 同时存在。缓解：UI/Store/verifier 只认 Tag / RecordTag；旧字段不作为 ok 证据。
2. DB migration 风险：新增 tag 表后旧 repository smoke 仍期待 pinboard。缓解：同步迁移 P9A/P9B，并明确旧 checks baseline。
3. favorite bootstrap 重复风险：reload/fixture/reset 产生多个 favorite。缓解：unique builtInKind + fail-closed verifier。
4. search dependency 风险：Step 1 search document 未完成时，Step 2 tag search 伪装通过。缓解：字段契约 Gate 与端到端 Gate 分离。
5. transaction 风险：merge/delete 部分提交导致 UI 不一致。缓解：SQLite transaction + repository smoke。

### P2 风险

1. 归一化细节可能影响用户对重名的预期。缓解：开发记录固定算法，测试覆盖 Work/work/空白/控制字符。
2. 标签多时右键菜单可用性下降。缓解：Step 2 保证状态正确，搜索/分页可后续优化。
3. preservePinned policy 与 favorite 语义替换可能触及设置页文案。缓解：推荐 Step 2 改成 preserveFavorite 或隐藏旧文案，避免旧概念泄漏。
4. 颜色 token 与暗色模式可访问性需要 UI 细化。缓解：只允许受控 colorToken，UI/测试复审色板。

## 15. 需要开发 / 测试复审的问题

开发需要重点复审：

1. Tag schema 是否作为 AppDatabase V2 合适，是否需要 migration helper。
2. Normalizer 算法是否可在 Core 中稳定实现。
3. `ClipboardTagRepository` 独立类还是 `ClipboardRepository` extension 更适合当前模块边界。
4. `ClipboardTagStore` 是否单独文件/feature store，如何与 `ClipboardStore` objectWillChange bridge。
5. preservePinned -> preserveFavorite 是否纳入 Step 2 实现；如果不纳入，如何隐藏旧 UI 并记录残余。
6. Step 1 search document adapter 当前状态，Step 2D 是否只能交付 no-op contract。

测试/质量需要重点复审：

1. Tag repository smoke fixture：create/duplicate/rename/delete/merge/add/remove/favorite immutable。
2. UI fixture：favorite first、single tag filter、right-click add/remove/new、settings CRUD。
3. Legacy exit scan：pinboard/pinned/fixed active UI token 与 code path。
4. Search Gate 拆分：字段契约与端到端搜索分别如何标记 PASS / residual risk。
5. Error feedback：duplicate/empty/control/favorite immutable/delete failed/merge failed。

## 16. 建议参与技术方案复审角色

进入开发前建议复审角色：

- 项目负责人：确认方案没有扩大 Step 2 范围，并接受 search Gate 拆分。
- 开发：确认 schema、repository/store、UI 替换和 verifier 拆分可落地。
- 测试/质量：确认事务、legacy exit 和 search Gate 验收可执行。
- UI/交互设计师：确认 settings tag management、right-click menu、favorite immutable 表达可用。
- App 架构师：在开发方案细化后复核是否仍保持 Tag / RecordTag 独立事实源。

安全合规顾问通常不必阻塞 Step 2，除非实现中引入日志输出、CLI 标签管理或批量外发路径。

## 17. 建议开发前通过条件

开发派发前建议项目负责人确认：

- 本技术方案经开发和测试/质量复审，无 P0/P1 未闭合。
- 是否把 preservePinned 语义替换为 preserveFavorite 已决定。
- Step 2A-2D 子批次顺序被接受。
- `p13b_clipboard_tags_model_checks.py` 最低断言集合被接受。
- 标签端到端搜索是否依赖 Step 1 search document 的状态被明确记录。
