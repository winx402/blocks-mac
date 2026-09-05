# 测试/质量开发复审：Step 2 标签与收藏模型替换

日期：2026-07-07
角色：测试/质量
复审对象：当前工作区 Step 2 实现、`开发记录-Step2-v0.md`、`项目负责人-Step2开发验收-v0.md`

## 结论

`approve`

本次复审没有发现需要阻塞 Step 2 最终接受的 P0/P1。基于项目负责人独立运行记录、开发记录、PRD v1、技术方案 v1，以及对 P13B / P8 / P8I / P9A / P9B / P11E 和相关代码路径的静态抽查，当前 verification matrix 基本足以支撑 Step 2 acceptance gate。

右键菜单 `New Tag...` 固定默认名 `New Tag` 不建议作为本阶段 must-fix。它是 P2 residual risk：功能上已有最小“新建并附加当前记录”入口，完整命名、改色、排序、合并、删除在 Settings 管理区闭合；但右键原地命名和重复 `New Tag` 场景的体验后续应补强。

未做真实 App UI、真实剪贴板、provider、TCC 或系统设置触发，不构成本阶段阻塞。Step 2 的主要验收对象是 Tag / RecordTag 数据模型、Store/UI 当前事实源、静态 UI surface、repository smoke、构建和低敏输出；真实 UI 操作可作为 P2 残余证据补充。

## 复审范围与证据

已读文档：

- `step_2/产品经理-PRD-v1.md`
- `step_2/App架构师-技术方案-v1.md`
- `step_2/项目负责人-开发派发-Step2-v0.md`
- `step_2/开发记录-Step2-v0.md`
- `step_2/项目负责人-Step2开发验收-v0.md`

静态抽查：

- `tools/verification/p13b_clipboard_tags_model_checks.py`
- `tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
- `tools/verification/p8_clipboard_product_polish_checks.py`
- `tools/verification/p8i_settings_clipboard_system_checks.py`
- `tools/verification/p11e_clipboard_hardening_checks.py`
- 相关 Swift 代码路径中的 `ClipboardTag`、`ClipboardTagRepository`、`ClipboardTagStore`、`ClipboardStore`、`ClipboardSearchCoordinator`、`ClipboardFilterBarView`、`ClipboardRecordViews`、`ClipboardSettingsPane`。

本次未独立复跑 xcodebuild 或 verification 命令；命令结果引用项目负责人独立验收记录。复审重点是判断矩阵和门禁是否足以支撑质量结论，以及是否存在明显假 PASS。

## Must-Fix

无。

未发现以下阻断：

- 未发现 Tag / RecordTag 被旧 pinboard / pinned 改名替代的证据。
- 未发现 favorite 仍由旧 `pinned` 作为当前事实源的证据。
- 未发现 Step 2 当前门禁继续以旧 pinboard/pinned 作为 ok evidence 的证据。
- 未发现标签搜索端到端 gate 被伪装成未闭合但通过；开发记录和项目负责人验收均记录 P13B / P9A 为 `tag_search.contract_gate=pass`、`tag_search.e2e_gate=pass`。
- 未发现真实剪贴板、provider、TCC、系统设置或 Keychain 被本阶段默认验证触发的证据。

## Should-Fix

1. 右键 `New Tag...` 后续建议改为原地命名或弹出轻量输入。
   当前固定创建 `New Tag` 可作为 Step 2 最小入口接受，但体验上容易遇到第二次创建重名、用户创建后还要去 Settings 改名的问题。建议后续 UI/交互或 Step 3/收口阶段补强为原地输入、popover 或菜单内命名。

2. P13B 的 `verifier_ok_evidence_clear` 可再收紧。
   当前 P13B 已分层检查 active UI/store path、legacy storage baseline、旧 verifier 迁移；但 `verifier_ok_evidence_clear` 的布尔输出本身偏概括。建议后续增强为逐脚本字段，例如 `p8_current_tag_ok`、`p8i_current_tag_ok`、`p9a_tag_smoke_ok`、`p9b_tag_store_ok`、`p11e_output_boundary_only`，降低未来维护时假 PASS 风险。

3. 补一份低敏 UI 截图或 accessibility 摘要会更完整。
   当前静态门禁和 smoke 足以覆盖 Step 2 acceptance；但 Settings tag row、right-click menu、favorite first、single tag filter 的真实渲染仍未由截图/录屏证明。该项建议补证，不阻塞。

4. 旧 legacy storage 仍在代码中保留，后续 Step 6 可回扫是否删除或继续标 baseline。
   当前门禁确认 legacy storage 不参与 active UI/store/filter/policy ok；但旧 `ClipboardPinboard`、旧 repository pin/move/metadata API 仍存在。Step 2 可接受，最终收口应再次确认无用户可见泄漏。

## Verification Matrix 判断

当前矩阵覆盖足够：

- P13B 覆盖 schema、model、normalizer、mutation result、repository API、favorite immutability、tag store、selectedTagID、UI surface、legacy exit、search contract、target membership 和 low-sensitive sanitizer。
- P9A 用 Swift repository smoke 覆盖 schema v3、search document、tag/favorite、record-tag、tag search、clearUnfavorited、preserveFavorite policy、body excludes tag name 等。
- P9B 覆盖 AppModel / ClipboardStore / ClipboardTagStore / search coordinator 集成，并检查旧 active pinned/pinboard fact 退出。
- P8 覆盖产品 surface：single tag filter、record tag menu、favorite surface、tag store bridge、旧 pinboard UI 退出。
- P8I 覆盖 Settings tag management、favorite immutable、preserve favorite、旧 pinboard settings 退出。
- P11E 已转为 Step 1 output-boundary + Step 2 tag/favorite UI/store guard，不再作为旧 redacted/pinned acceptance。
- P13A 回归覆盖 Step 1 明文展示、搜索/OCR、设置页清理，降低 Step 2 改动破坏 Step 1 的风险。
- App / CLI build、`blocks --help`、`git diff --check` 均由项目负责人独立跑过并记录通过。

## Fixture 覆盖判断

已覆盖或有足够证据：

- normalizedName：P13B 检查 NFKC、whitespace fold、case fold、empty/control/reserved rejection；P9A smoke 有相关 fixture 证据。
- 收藏内置：P13B + P9A 覆盖 unique favorite、`tag.favorite`、favorite immutable 和 reload/reset 不重复。
- add/remove/create/delete/rename/merge/reorder：P13B 检查 API/transaction/selected transition；P9A 覆盖 repository smoke；Settings/P8I 覆盖 UI 管理入口。
- Settings 管理：P8I 检查 `ClipboardTagManagementSection`、preserve favorite、merge/delete/move 等。
- 右键菜单：P8/P13B 检查 `ClipboardTagMenu`、favorite、checked add/remove、新建入口。
- 单标签筛选：P8/P9B/P13B 检查 selectedTagID + RecordTag 当前事实源。
- 标签搜索契约与端到端：P13B 输出 e2e pass 源自 P9A；P9A 通过 body excludes tag name 避免正文伪命中。
- 旧逻辑退出：P13B legacy_exit、P8/P8I/P9B 均覆盖 active UI/store/verifier ok evidence；旧 DB/storage 只作为 baseline。

证据较弱但不阻塞：

- 真实右键菜单交互没有运行时 UI 录屏。
- Settings 标签管理没有真实 UI 截图。
- VoiceOver/键盘路径不是 Step 2 当前阻断，更多属于 UI/交互复核或后续 Step 3/收口证据。

## P13B / P8 / P8I / P9A / P9B / P11E 假 PASS 风险

总体判断：未发现明显假 PASS，当前组合门禁可接受。

原因：

- P13B 不是只看文档，它读取当前 Swift 文件、Xcode project 和旧 verifier 文件，且缺文件/缺 target membership/旧 active token 会失败。
- P9A 是 Swift repository smoke，能覆盖真实 DB schema、repository 行为、tag search、clearUnfavorited / preserveFavorite，而不是纯字符串检查。
- P9B 检查 AppModel/Store/SearchCoordinator 当前事实源，对旧 `togglePin`、`setPinboardFilter`、`pinnedMetadata` 等 active path 有负向断言。
- P8/P8I 分别覆盖面板/右键和 Settings 当前 UI token，旧 pinboard UI / settings 退出作为阻断。
- P11E 已明确定位为 output boundary / tag surface guard，未继续把旧 Step 4D redacted-first 当作 Step 2 通过条件。

剩余假 PASS 风险主要来自静态检查天生无法证明真实 UI 可点击、菜单展开和可访问性朗读。这个风险是 P2，不构成本阶段阻塞。

## New Tag 判断

右键菜单 `New Tag...` 固定默认名 `New Tag`：可接受为 P2 residual risk，不要求本阶段返工。

理由：

- PRD 要求右键菜单有新建标签并附加当前记录入口；当前实现满足最小路径。
- 完整标签命名、改色、排序、合并、删除已由 Settings 管理区覆盖。
- P8 明确检查了 `createTag("New Tag")`，说明门禁没有漏掉该行为。
- 若第二次创建 `New Tag` 遇到重名，应由现有 duplicate/error feedback 兜底；不是数据一致性风险。

建议：

- 后续改为原地输入或 popover 命名，避免用户创建多个泛名标签或频繁回 Settings 重命名。
- 如果 UI/交互复核认为右键原地命名是核心体验，则可升级为 should-fix；从测试/质量验收角度不建议升为 must-fix。

## 真实 UI / 真实剪贴板未覆盖判断

不阻塞 Step 2。

理由：

- Step 2 当前 acceptance gate 重点是数据模型、事实源迁移、UI surface 静态合同、repository smoke、search contract、legacy exit 和构建。
- 真实剪贴板、TCC、provider、系统设置不属于 Step 2 验收范围，触发反而会扩大风险。
- 真实 UI 自动化可补充右键菜单、Settings row、filter 的可点击证据，但不应作为当前数据/门禁通过的前置条件。

建议补证：

- 非阻断补一组低敏截图或 accessibility tree 摘要：favorite first、单标签筛选、右键 tag menu、Settings tag management。
- 若最终接受前想提高 UI 置信度，可由 UI/交互复核侧补手工低敏证据。

## Residual Risk

- P2：右键 `New Tag...` 固定默认名，体验不完整，后续建议原地命名。
- P2：旧 pinboard/pinned legacy storage 和部分 deprecated API 仍在代码中，当前可接受为 baseline；Step 6 应回扫。
- P2：未做真实 UI 点击 / VoiceOver / 键盘路径验证。
- P2：P13B 部分 legacy verifier ok evidence 字段可进一步细化，当前组合门禁已足够但后续维护可增强。
- P2：既有 `FloatingPanelSupport.swift` main-actor warning 非 Step 2 引入，保留为已知构建 warning。

## 建议补跑或补证据项

非阻断建议：

1. 若项目负责人需要测试/质量独立命令证据，可让我后续串行复跑：
   - `python3 tools/verification/p13b_clipboard_tags_model_checks.py`
   - `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`
   - `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
   - `python3 tools/verification/p8_clipboard_product_polish_checks.py`
   - `python3 tools/verification/p8i_settings_clipboard_system_checks.py`
   - `python3 tools/verification/p11e_clipboard_hardening_checks.py`
   - `git diff --check`
2. 补低敏 UI 截图或 accessibility tree：filter favorite first、right-click tag menu、Settings tag management。
3. 在最终接受记录中明确：真实 UI/VoiceOver/键盘路径未覆盖，不阻塞 Step 2，但进入 Step 3/Step 6 继续追踪。
