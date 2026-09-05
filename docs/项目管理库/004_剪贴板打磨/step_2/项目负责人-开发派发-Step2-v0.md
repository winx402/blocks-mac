# Step 2 开发派发 v0

状态：assigned
日期：2026-07-07
角色：项目负责人
对象：开发
目标：实现 004_剪贴板打磨 Step 2 标签与收藏模型替换

## 1. 背景

Step 1 已验收接受。Step 2 PRD v1 和 App 架构师技术方案 v1 已由项目负责人接受，现在进入开发实现。

用户最新推进口径：

- 顶层 step 严格串行，Step 2 开发和验收完成前不进入 Step 3。
- 单个 step 内开发批次可以更大，不必拆得过细。

本次派发按一个较大开发批次处理 Step 2，但开发过程和验证输出必须保持分层，便于项目负责人验收和必要返工。

## 2. 输入文档

- `step_2/产品经理-PRD-v1.md`
- `step_2/项目负责人-PRD-v1复核-v0.md`
- `step_2/App架构师-技术方案-v1.md`
- `step_2/项目负责人-技术方案-v1复核-v0.md`
- `step_2/项目负责人-技术方案复审收敛-v0.md`
- `step_2/UI-交互设计师-技术方案复审-v0.md`
- `step_2/测试-质量-技术方案复审-v0.md`
- `step_2/开发-技术方案复审-v0.md`

## 3. 实现范围

只实现 Step 2：标签与收藏模型替换。

必须覆盖：

1. `Tag / RecordTag` 独立事实源。
2. favorite built-in tag，固定第一，五角星语义，不可删除、重命名、改色、排序、合并。
3. 一个记录可拥有多个标签。
4. 标签名称 normalizedName 唯一，普通标签不能使用 `favorite` / `收藏` reserved aliases。
5. 标签支持颜色、排序、重命名、删除、合并。
6. 设置页标签管理。
7. 面板标签筛选，首版为单标签筛选。
8. 条目右键菜单添加/移除/新建标签，新建成功后附加到当前记录。
9. 收藏按钮或收藏动作改为添加/移除 favorite tag。
10. 旧 pinboard / pinned 当前事实源退出，不迁移旧数据，不兼容旧固定项逻辑。
11. 标签字段进入 Step 1 search document 的 contract / invalidation / reindex；如果 Step 1 search document 已可用，端到端标签搜索必须闭合，不能只停留在 contract。
12. P13B fail-closed verifier 和旧 P8/P9/P11 等门禁迁移。

## 4. 明确不做

- 不重做 Step 1 明文展示、搜索底座、OCR pipeline。
- 不做多标签 OR / AND 组合筛选。
- 不做批量删除标签、删除前二次确认、自动清理空标签。
- 不做 Step 3 hover 安全区、toolbar 空间、选中反馈、条目密度专项。
- 不做 Step 4 详情编辑。
- 不做 Step 5 隐私页 App 清单或 CLI 广义对象管理。
- 不触发真实用户剪贴板、真实 provider、Keychain、TCC、系统设置或自动化动作作为开发默认验证。

## 5. 实现要求

### 5.1 Core model / repository / store

- 增加 AppDatabase V2 migration 或等价版本迁移。
- 新增 `clipboard_tags`、`clipboard_record_tags` 或等价表。
- `clipboard_record_tags` 必须保证 `recordID + tagID` 唯一。
- favorite seed 幂等；reload / restart / fixture reset 后不能重复。
- 旧 pinned / pinboard 数据不迁移到 tag 模型。
- 旧 pinned / pinboard 如短期保留，只能是 legacy storage 或 deprecated adapter。
- 实现 `ClipboardTagNameNormalizer` 或等价 normalizer，固定 NFKC、trim、Unicode whitespace fold、control rejection、locale-independent case fold、reserved aliases。
- 推荐实现 `ClipboardTagRepository` + `ClipboardTagStore`；如采用等价命名，必须在开发记录说明单事实源如何满足技术方案 v1。
- `ClipboardStore` 只桥接 tag store，不复制 tag facts 或双写。
- `AppModel` 只做 facade / status / coordinator，不保存 tag facts。
- View 不直接访问 repository。

### 5.2 Mutation and transaction

标签 mutation 必须返回等价 `ClipboardTagMutationResult`：

- changed tag IDs。
- affected record IDs。
- removed tag IDs。
- selected tag transition：none / clear / switchTo。
- search invalidation 状态。

最低行为：

- create-and-attach、add、remove 返回当前 recordID。
- rename 返回所有关联该 tag 的 recordIDs。
- delete 返回删除前关联 recordIDs。
- merge 返回 source / target 去重 affected recordIDs。
- updateColor / reorder 不触发 search invalidation，但刷新 tag list。
- delete / merge 失败不得半更新。
- 删除 active tag 后 selectedTagID 清空。
- 合并 active source 后 selectedTagID 切换到 target。

### 5.3 UI and settings

- FilterBar 改为 tag filter，favorite first，普通标签按 sortOrder。
- 保留 All / 全部路径。
- 单标签筛选，不展示多标签 OR / AND。
- 条目右键菜单 favorite first；checked 表示已添加，点击移除；unchecked 表示未添加，点击添加。
- 右键新建标签成功后立即附加当前记录。
- 右键新建失败不清空输入，不改变 record-tag 关系，并提供可见错误反馈。
- Settings tag row 至少包含颜色 swatch、名称、状态/内置标识、排序控件、操作入口。
- favorite row 固定第一，不暴露可执行 delete / rename / recolor / reorder / merge。
- 删除普通标签文案表达“从所有记录移除此标签”。
- 合并 UI 展示 source、target 和结果；合并 active source 后切到 target。
- 长标签名、窄宽度、VoiceOver label、键盘排序路径需有最低实现或明确残余风险。

### 5.4 Legacy exit

Step 2 完成后 active path 不得继续依赖：

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

如果清理策略仍有“保留收藏项”能力，必须改为 `preserveFavorite` / `clearUnfavorited` 或等价 favorite 语义，并基于 favorite RecordTag 判断。

### 5.5 Search Gate

- mutation 成功后必须输出 affected recordIDs / projection / invalidation hook。
- 如果 Step 1 search document 可用，重建 affected records 的 tag tokens。
- 标签端到端搜索必须避免正文命中伪装成标签命中，fixture 正文不能包含标签名。
- 验收输出必须区分：
  - `tag_search_contract_gate`
  - `tag_search_e2e_gate`

## 6. P13B 与门禁

新增或更新：

- `tools/verification/p13b_clipboard_tags_model_checks.py`

最低输出要求：

- JSON 输出。
- `ok`
- `failures`
- `baseline_reference`
- `current_evidence`
- `legacy_exit`
- `tag_search`
- `sanitizer`

P13B 必须能证明：

- schema / repository / normalizer / favorite bootstrap。
- Store / AppModel facade / selectedTagID。
- UI active token、right-click、filter、settings。
- Search Gate。
- Legacy scan 分层：active UI clear、active store/repository/filter clear、verifier ok evidence clear、legacy storage baseline only。
- 低敏输出：不输出真实剪贴板正文、完整路径、用户内容、完整 URL query。

旧门禁迁移：

- `p9a_clipboard_repository_storage_smoke.py` 增加 tags/favorite repository smoke。
- `p9b_clipboard_appstate_repository_integration_checks.py` 改查 tag store / selectedTagID / tag facade。
- `p8_clipboard_product_polish_checks.py` 改查 favorite row、tag filter、right-click tag menu。
- `p8i_settings_clipboard_system_checks.py` 改查 tag management、favorite immutable、legacy wording exit。
- `p7d_clipboard_panel_resize_hover_checks.py` 如覆盖 filter bar，则迁移为 tag filter；否则降级为 Step 3 baseline。
- `p11e_clipboard_hardening_checks.py` 只能作为 output-boundary / baseline，不作为 Step 2 tag ok。

## 7. 开发记录

请写入：

- `step_2/开发记录-Step2-v0.md`

开发记录必须包含：

- 实现摘要。
- P13B baseline red 记录；如果开发批次内直接从 red 到 green，也要记录 red 的失败原因和 green 的修复证据。
- 技术方案 v1 覆盖清单。
- 明确哪些旧 pinned / pinboard 只作为 legacy storage 保留。
- Search Gate 结果。
- 低敏 fixture 说明。
- 验证命令和结果。
- 残余风险，不得把未验证项写成已完成。

## 8. 最低验证命令

开发完成前至少运行：

```bash
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

如 `p7d_clipboard_panel_resize_hover_checks.py` 覆盖当前 filter bar，则也要运行；如果降级为 Step 3 baseline，开发记录必须说明。

## 9. 完成回报

完成后回复：

- `DONE_WITH_EVIDENCE` 或 `DONE_WITH_CONCERNS`
- 开发记录路径
- 主要改动文件
- 验证命令和结果
- 残余风险

如果无法完成，回复：

- `BLOCKED`
- 阻塞原因
- 已完成部分
- 需要项目负责人补充的具体输入
