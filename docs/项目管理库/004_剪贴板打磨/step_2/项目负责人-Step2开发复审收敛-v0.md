# 项目负责人 Step 2 开发复审收敛 v0

日期：2026-07-07
状态：rework-required
范围：004_剪贴板打磨 Step 2 标签与收藏模型替换

## 输入材料

- `开发记录-Step2-v0.md`
- `项目负责人-Step2开发验收-v0.md`
- `代码审查-Step2开发复审-v0.md`
- `测试-质量-Step2开发复审-v0.md`
- `UI-交互设计师-Step2开发复审-v0.md`

## 复审结论汇总

三方复审结果：

- 测试/质量：`approve`，未发现 P0/P1。
- UI/交互设计师：`approve-with-changes`，P0/P1=0，主要为 P2 体验与实物证据风险。
- 代码审查：`approve-with-changes`，发现 1 个 P1，要求 Step 2 最终接受前修复或明确降级。

项目负责人收敛判断：

- 不接受将 tag search 重建 / 缺失文档路径降级为 residual risk。
- Step 2 需要进入一次开发返工，修复 P1，并合并收口若干低风险 P2。
- Step 2 返工完成并重新验证前，不进入 Step 3。

## 必修返工项

### R1：修复 tag search 重建 / 缺失文档路径丢失标签 token

来源：代码审查 P1。

问题口径：

- 普通 tag mutation 会更新已有 search document。
- 但 search document 缺失或执行 rebuild 时，当前路径没有从 `clipboard_record_tags` / `clipboard_tags` 重新灌入已有标签。
- 这会让已有 RecordTag 关系仍在 DB 中，但标签名搜索不再命中对应记录。

返工要求：

- repository 层重建 search document 时，必须读取当前记录关联标签并写入 `tagTokens` / search projection。
- `markSearchDocumentTagsDirty(recordIDs:)` 对缺失 search document 不得静默跳过；应创建 / 重建含当前 tags 的 search document，或显式进入可恢复 pending index 状态。
- tag rename / merge / delete / add / remove 后，标签搜索索引必须保持一致。
- P9A 或 P13B 增加缺失 / 重建路径 fixture：已有记录带标签 -> 删除或缺失 search document -> rebuild -> 搜索标签名仍命中。
- 当前 `tag_search.e2e_gate=pass` 只有在上述路径闭合后才可保留。

### R2：修复 tag-only filter 下全局清除筛选入口不出现

来源：代码审查 P2。

返工要求：

- 浮窗顶部“清除全部筛选”按钮的可见判断必须包含 `tagStore.selectedTagID`。
- 用户只选择标签筛选时，也应能看到并使用全局 clear-all 入口。
- clear-all 后应同时清除普通 filter 和 tag filter。
- 优先使用已经合成 tag 状态的 `displayFilterState` 或等价单一展示状态，避免 header 与 filter strip 对 active 状态判断不一致。

### R3：收口旧 pinned count App 层残留和门禁

来源：代码审查 P2。

返工要求：

- `ClipboardController.pinnedCount` / `ClipboardStore.pinnedCount()` 不应继续作为 active App 层旧事实源入口。
- 选择之一：
  - 移除这两个 facade；或
  - 改为明确基于 favorite RecordTag 的 `favoriteCount`。
- P13B / P9B 增加 `pinnedCount` 等旧 active path 负向检查，避免后续回流。

## 建议一并收口项

以下为 P2，不单独阻断 Step 2，但本轮返工可在低风险前提下合并处理：

- 将 `ClipboardTagOperationError.localizedMessage` 从 Swift 内中文硬编码迁入 String Catalog，至少覆盖 duplicate name、empty name、reserved favorite、favorite immutable、invalid merge、repository unavailable。
- 条目 tag chips 超过 3 个时增加 `+N` 提示，避免用户误以为只有 3 个标签。
- 右键固定默认名如果暂不做命名输入，至少将 `New Tag...` 文案改为不暗示继续输入的口径，例如 `Create "New Tag"`；完整右键命名输入仍可保留为 P2 residual。
- Settings 标签操作反馈可以保持当前最小实现，但最终接受记录必须说明 rename / merge / delete 行内反馈仍是 P2 体验残余；如果实现成本低，可把错误提示移动到触发操作附近。

## 本轮不要求处理

- 不要求触发真实 App、真实剪贴板、provider、TCC、Keychain、系统设置或真实 UI 自动化。
- 不要求实现右键菜单完整命名 popover / sheet，除非开发判断成本很低且不扩大风险。
- 不要求删除所有 legacy pinboard / pinned storage；只要求 active App/UI/filter/search/verifier 事实源不回流。
- 不进入 Step 3 hover / toolbar / 面板布局专项。

## 返工后验收要求

开发完成后必须更新开发记录，并至少提供以下证据：

- P13B 通过，并输出 tag search 重建 / 缺失文档路径 gate。
- P9A 通过，且包含 repository smoke 对 tag search rebuild path 的真实行为验证。
- P9B 通过，且旧 `pinnedCount` active path 被覆盖。
- P8 / P8I 通过，确保 Step 2 UI surface 未回退。
- P11E 与 P13A 回归通过，确保 Step 1 输出边界和搜索/OCR底座未被破坏。
- Blocks App build、BlocksCLI build、CLI help、`git diff --check` 通过。

开发完成后，项目负责人将先独立复跑门禁，再决定是否二次送代码审查 / 测试 / UI 复核。
