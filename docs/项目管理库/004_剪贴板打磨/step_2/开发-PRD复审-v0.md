# Step 2 开发 PRD 复审 v0

状态：approve-with-changes
日期：2026-07-07
角色：开发
对象：`产品经理-PRD-v0.md`

## 1. 结论

Step 2 PRD 的方向可实现，且范围基本收敛在标签与收藏模型替换，没有把 Step 1 搜索/OCR、Step 3 面板布局、Step 4 详情编辑和 Step 5 隐私页扩进来。

开发结论为 `approve-with-changes`。进入开发前需要把若干“默认建议 / 技术方案阶段确认”的内容改成 PRD 明确契约，尤其是旧 pinboard / pinned schema 如何处置、单标签筛选是否定案、收藏标签是否允许被合并进入、标签状态如何同步到设置页 / 面板 / 右键菜单 / 搜索索引，以及旧门禁如何改写。

## 2. 可先做与必须等待 Step 1 的工作

### 2.1 可在 Step 1 修订期间先做

以下工作不依赖 Step 1 搜索底座最终形态，可以先做数据模型和方案拆解：

- 标签数据模型设计：`clipboard_tags`、`clipboard_record_tags` 或等价模型，字段至少包含名称、归一化名称、颜色、排序、内置标记、创建/更新时间。
- 收藏内置标签方案：使用稳定内部 ID，而不是依赖本地化显示名；五角星和默认第一属于 UI 呈现，不应成为数据库主键。
- Repository 事务接口拆解：创建、重命名、改色、排序、删除普通标签、合并、给记录添加/移除标签、批量读取记录标签关系。
- Store 状态形状：标签列表、按 recordID 分组的标签关系、当前标签筛选、标签管理操作结果和错误状态。
- 旧 pinboard / pinned 替换影响面清单：`AppDatabase`、`ClipboardRepository`、`ClipboardStore`、`ClipboardController`、`ClipboardFilterState`、`ClipboardFilterBarView`、`ClipboardRecordViews`、`ClipboardSettingsPane`、本地化和 P4/P7/P8/P9 验证脚本。
- 设置页和右键菜单的接口草图：可先定义操作闭包和状态来源，但不应在 PRD 未收敛前进入完整 UI 实现。

### 2.2 必须等待 Step 1 搜索底座

以下内容必须等 Step 1 搜索索引契约稳定后再最终接入或验收：

- 标签名称进入全局搜索索引的具体写入点、字段名、权重和排序。
- 标签重命名、删除、合并后的 reindex 策略。
- 标签命中与正文 / URL / 来源 App / 时间 / 类型 / OCR 命中的排序关系。
- 搜索验证门禁：Step 2 可先验证标签字段 provider 或 repository API，但不能在 Step 1 未接受前宣称全局搜索已完成。

## 3. 必须修改或补清

1. 需要把“单标签筛选”从“PRD 默认建议”改成明确阶段契约。
   开发建议 Step 2 只做单标签筛选；OR / AND 多选进入后续优化。否则 filter state、UI、验收矩阵和搜索联动都会扩大。

2. 需要明确旧 schema 的处置方式。
   用户确认不迁移旧数据，不等于实现可以忽略现有 `pinned`、`clipboard_pinboards`、`clipboard_pinned_metadata`。PRD 应明确是否允许 bump schema / 重建开发期数据库，还是保留旧字段但用户可见和业务路径不再读取。没有这条，开发容易在“删除旧逻辑”和“保持现有 DB 可打开”之间返工。

3. 需要明确收藏标签的合并规则。
   当前 PRD 默认建议允许普通标签合并到“收藏”，但这等于批量收藏，且本阶段不做删除前二次确认。开发建议 Step 2 禁止以“收藏”为合并目标；若项目负责人坚持允许，PRD 必须要求明确反馈文案和事务失败回滚。

4. 需要明确标签唯一性归一化。
   PRD 已写大小写不敏感和 trim，但还需要写清是否折叠连续空格、是否本地化比较、是否禁止控制字符，以及“收藏”是否按稳定内部 ID 保留、显示名是否可本地化。建议采用稳定 normalizedName：trim、折叠空白、大小写不敏感；内置收藏用固定 ID。

5. 需要补充状态同步契约。
   标签重命名、改色、排序、删除、合并后，设置页列表、面板条目标签、筛选组选项、右键菜单勾选状态、当前筛选状态和搜索索引必须同步。PRD 应写明：如果当前筛选标签被删除或合并，filter 应清空或切到目标标签，不能留下无效 ID。

6. 需要把旧固定 / pinboard 用户可见入口的负向清单写清楚。
   包括旧固定按钮文案、pin 图标语义、`Pinned Groups` 设置区、`Move to Pinboard` 右键菜单、pinboard 筛选组、pinned stats、clear unpinned / preserve pinned 等策略文案是否保留、替换或删除。这里不是纯文案问题，会影响保留策略和清理操作语义。

7. 需要要求新增 Step 2 专属 verification gate。
   建议新增 P13A 或同类脚本，fail closed 检查：新 tag 文件 target membership、旧 pinboard / pinned 用户可见入口移除、收藏标签不是第二套状态、多标签关系、唯一性、合并事务、设置页 / 面板 / 右键菜单 / filter 使用同一事实源。旧 P4/P7/P8/P9 中依赖 pinned/pinboard 的脚本必须迁移或降级为 baseline。

## 4. 建议可吸收到 PRD v1 的推荐口径

以下内容可以直接作为产品经理修订 PRD 或后续技术方案输入。

### 4.1 阶段范围推荐写法

建议 PRD v1 明确写成：

- Step 2 交付“标签事实源 + 收藏内置标签 + 单标签筛选 + 设置页基础管理 + 右键添加/移除/新建 + 旧 pinboard 用户可见入口移除”。
- Step 2 不交付多标签 OR / AND 组合筛选，不交付标签搜索排序权重调优，不承诺 Step 1 搜索底座未 accepted 前的全局搜索完成。
- 标签名称搜索在 Step 2 中交付“索引字段与更新 hook”，最终搜索结果排序和 OCR / 正文混排等验收归 Step 1 搜索底座合流后执行。

### 4.2 数据模型推荐口径

建议 PRD v1 指定以下产品可见约束，技术方案再落具体字段：

- 标签有稳定 ID、显示名、归一化名、颜色、排序、内置标记。
- “收藏”使用稳定内置 ID，例如 `tag.favorite`；显示名可本地化，但普通标签不得占用收藏的归一化显示名。
- 普通标签唯一性使用同一 normalizer：trim、折叠连续空白、大小写不敏感；空名和控制字符无效。
- 一条记录可以关联多个标签，同一 record/tag 组合唯一。
- 删除普通标签会删除所有 record-tag 关联；收藏标签不可删除。

### 4.3 旧逻辑替换推荐口径

建议 PRD v1 增加旧入口负向清单：

- 用户界面不再出现 `pinboard`、`Pinned Groups`、`Move to Pinboard`、`pinned summaries`、`clear unpinned` 等独立旧概念。
- 旧固定按钮替换为收藏按钮，图标语义变成五角星；点击只添加或移除收藏标签。
- 旧 pinboard 筛选组替换为标签筛选组；收藏作为标签组第一项。
- 旧 pinboard / pinned 数据不迁移；如技术方案为保持开发数据库可打开而保留兼容字段，这些字段不得作为 Step 2 用户可见事实源。

### 4.4 合并与删除推荐口径

建议 PRD v1 采用保守规则：

- Step 2 允许普通标签合并到普通标签。
- Step 2 禁止任何标签合并到“收藏”，避免一次操作造成批量收藏；后续如用户需要再单独设计。
- 目标标签保留名称、颜色和排序；被合并标签的关联转移到目标标签；重复关联去重；被合并标签删除。
- 删除普通标签不要求二次确认，但必须有即时、明确、低干扰反馈；删除失败不得改变标签关系。

### 4.5 状态同步推荐口径

建议 PRD v1 明确这些同步规则：

- 当前筛选标签被删除时，筛选状态清空。
- 当前筛选标签被合并时，筛选状态切到目标标签。
- 标签重命名和改色后，设置页、筛选组选项、右键菜单、条目标签展示同步更新。
- 右键菜单新建标签失败时，不创建标签、不添加关联，并展示重名或空名错误。
- 合并、删除、重命名、改色、排序均应是 repository 层事务或具备失败回滚语义。

## 5. 建议实现边界

建议后续开发方案按以下边界拆：

1. Core schema / repository boundary
   新增 tag 表和 record-tag 关联表，seed 收藏标签，实现标签 CRUD、assign/remove、rename、reorder、merge/delete 事务，提供低敏 fixture smoke。

2. Feature store / read model boundary
   在 `ClipboardStore` 或独立 `ClipboardTagStore` 中形成唯一事实源：标签列表、record-tag 关系、当前标签筛选、操作错误。开发方案需要明确是否拆独立 store；若不拆，也要保证 pinboard 旧字段不再是事实源。

3. Panel boundary
   替换收藏按钮、标签筛选组、条目标签展示和右键菜单。右键菜单的新建标签应走同一 store/repository API，不直接写 UI 局部状态。

4. Settings boundary
   将标签管理拆成独立组件或 pane 内子组件，避免把颜色、排序、重命名、合并、删除全部堆回 `ClipboardSettingsPane`。

5. Search integration boundary
   暂时只暴露标签搜索字段 provider / reindex hook；等 Step 1 搜索底座 accepted 后再接入最终全局索引和排序验收。

6. Verification boundary
   新增 Step 2 专属 gate；旧 P4/P7/P8/P9 只保留与当前事实源一致的检查，不再用旧 pinboard/pinned 作为通过条件。

## 6. 实现复杂度与影响面

- 数据层影响大于 UI 改名。当前数据库和 repository 已有 `pinned`、`clipboard_pinboards`、`clipboard_pinned_metadata`、`pin(recordID:)`、`move(recordID:toPinboard:)`、`renamePinnedRecord`、`clearUnpinned` 等路径；标签模型需要新表和新事务 API，不能只改 UI 名称。
- Store / Controller 需要同步替换：当前 `ClipboardStore` 暴露 `pinboards`、`pinnedMetadata`、`togglePin`、`setPinboardFilter`，`ClipboardController.filteredRecords` 也按 pinboard 过滤。Step 2 应替换为 tag store/read model，而不是继续复用 pinboard 字段。
- 面板影响点包括筛选条、卡片/行收藏状态、右键菜单和选中后的操作反馈。右键菜单新增标签会比现有 pinboard move 更复杂，需要错误反馈和创建失败不改变关系。
- 设置页影响点包括旧 pinboard 区块替换为标签管理区。颜色、排序、重命名、合并、删除如果全部进入 Step 2，建议拆成小组件，否则 `ClipboardSettingsPane` 会重新变成大文件。
- 搜索索引是跨阶段依赖。Step 2 可以准备标签字段和 reindex hook，但全局搜索通过应等 Step 1 搜索底座 accepted 后再验收。

## 7. 可后续优化

- 多标签 OR / AND 筛选。
- 标签删除前确认、撤销、批量删除、自动清理空标签。
- 允许合并到“收藏”以及更强的批量反馈。
- 标签颜色高级自定义、图标自定义、拖拽排序动效。
- 标签右键菜单搜索 / 自动补全和键盘快捷操作。
- 标签搜索排序权重调优。

## 8. 开发建议的拆分

建议 Step 2 开发至少拆两段：

1. 数据模型与旧逻辑替换基础：schema / repository / store / 单标签 filter / 收藏标签 / 旧 pinboard 用户可见入口移除 / P13A 红绿门禁。
2. UI 管理面与交互完善：设置页管理、右键菜单新建 / 添加 / 移除、合并、颜色和排序、搜索字段接入 Step 1 后的底座。

如果 Step 1 搜索底座还未 accepted，第一段可以完成并验收“标签字段 ready”，第二段中的全局搜索接入应标为待 Step 1 合并后的 integration gate。
