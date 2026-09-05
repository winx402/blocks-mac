# Step 2 项目负责人最终验收 v0

状态：accepted-with-p2-residuals
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 2 标签与收藏模型替换

## 1. 结论

Step 2 最终接受，可以进入 Step 3。

接受口径是 `accepted-with-p2-residuals`：

- P0：无。
- P1：无。
- 上一轮代码审查提出的 tag search 重建 / 缺失 search document 路径 P1 已在 R1 中关闭。
- 剩余问题均为 P2 residual，不阻断 Step 2 接受，但必须在后续阶段或最终集成验收中保留记录。

本验收不代表 Step 3/4/5 已启动或完成；按用户要求，顶层 Step 串行推进，Step 2 完成后才能恢复 Step 3。

## 2. 输入材料

- `产品经理-PRD-v1.md`
- `App架构师-技术方案-v1.md`
- `项目负责人-开发派发-Step2-v0.md`
- `开发记录-Step2-v0.md`
- `项目负责人-Step2开发验收-v0.md`
- `代码审查-Step2开发复审-v0.md`
- `测试-质量-Step2开发复审-v0.md`
- `UI-交互设计师-Step2开发复审-v0.md`
- `项目负责人-Step2开发复审收敛-v0.md`
- `开发记录-Step2-R1-v0.md`
- `项目负责人-Step2-R1验收-v0.md`
- `代码审查-Step2-R1复审-v0.md`
- `测试-质量-Step2-R1复审-v0.md`
- `UI-交互设计师-Step2-R1复审-v0.md`

## 3. 范围确认

本阶段已覆盖：

- Tag / RecordTag 独立事实源。
- 一个条目可关联多个标签。
- 标签不可重名，采用归一化唯一性约束。
- 标签颜色、排序、重命名、删除、合并。
- Settings 标签管理入口。
- 面板标签筛选。
- 条目右键添加 / 移除 / 快速创建标签。
- `收藏` 作为内置标签，五角星、默认第一、不可删除、不可重命名、不可改色、不可排序、不可被普通标签合并。
- 点击收藏走收藏标签语义，不再走旧 pinned 事实源。
- 旧 pinboard / pinned 不作为 active App UI / Store / filter / search / verifier ok 事实源。
- 标签字段进入 Step 1 搜索底座，并覆盖缺失 search document / rebuild 路径。

明确未覆盖：

- Step 3 面板 hover、toolbar、选中反馈、搜索框宽度、卡片密度专项。
- Step 4 详情编辑。
- Step 5 隐私页真实 App 清单和 CLI 广义对象管理。
- 真实 App UI 自动化、真实系统剪贴板、provider、Keychain、TCC、系统设置或自动化动作。

## 4. 复审收敛

### 4.1 代码审查

结论：`approve`。

关键判断：

- 上一轮 P1 已关闭。
- R1 中 `markSearchDocumentTagsDirty(recordIDs:)` 和 `rebuildSearchDocuments(limit:)` 均能在 search document 缺失 / 重建时回填当前标签 token。
- R2 tag-only filter clear-all 闭合。
- R3 active App 层旧 `pinnedCount` facade 退出，并被 P13B / P9B 覆盖。
- R1 顺手收口的 String Catalog、`+N` chips、`Create "New Tag"` 未引入新增 P0/P1/P2。

### 4.2 测试/质量

结论：`approve`。

关键判断：

- P13B / P9A 足以证明 tag search 缺失文档与 rebuild 路径闭合。
- P9B 覆盖旧 `pinnedCount` active path 退出。
- P8 覆盖 tag-only filter clear-all。
- P8I / P11E / P13A / P9C 保留必要回归边界。
- Blocks App build、BlocksCLI build、CLI help、`git diff --check` 足以支撑 Step 2 R1 进入最终收敛。

### 4.3 UI/交互

结论：`approve-with-changes`，P0/P1=0。

关键判断：

- tag-only clear-all、`+N` chips、`Create "New Tag"` 和错误本地化均可接受。
- Settings 行内反馈、真实 UI / VoiceOver 证据缺口仍为 P2 residual。
- 固定默认名快速创建仍不是完整右键命名体验，但不阻断 Step 2。

## 5. 验证证据

项目负责人在 R1 验收中独立执行并通过：

```bash
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

定向复审补充验证：

- 代码审查运行 P13B / P9B / P8、`jq empty`、针对性 `rg` 检索。
- 测试/质量独立复跑 P13B / P9A / P9B / P8 / P8I / P11E / P13A / P9C、Blocks App build、BlocksCLI build、CLI help、`git diff --check`。
- UI/交互运行 P8 / P13B / `git diff --check`。

## 6. 残余风险

P2 residual：

- Settings 标签管理的失败 / 成功反馈仍不够贴近触发操作来源。
- 右键菜单新建标签仍是固定默认名 `New Tag` 的快速创建入口，完整命名输入未在 Step 2 实现。
- 真实 macOS UI、窄宽度、长标签、右键菜单、VoiceOver / accessibility inspector 证据未覆盖。
- 真实系统剪贴板未触发；本阶段证据来自 repository smoke、静态门禁、构建和低敏 CLI help。
- `FloatingPanelSupport.swift` 既有 main-actor warning 仍存在，本轮构建通过，不作为 Step 2 阻塞。

这些残余不影响 Step 2 当前接受，但不得在后续文档中写成已实测通过。

## 7. 下一步

- 更新阶段状态为 Step 2 accepted。
- 恢复 Step 3，先回看已有 PRD v0 和角色复审材料，按串行流程完成 Step 3 PRD 收敛后再进入技术方案 / 开发。
- Step 6 最终集成验收时，必须回扫 Step 2 的 P2 residual，决定补低敏 UI / VoiceOver 证据还是明确保留为发布前待办。
