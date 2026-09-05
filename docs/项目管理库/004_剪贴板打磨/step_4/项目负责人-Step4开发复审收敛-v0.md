# Step 4 项目负责人开发复审收敛 v0

状态：rework-required
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 4 开发实现复审

## 1. 结论

结论：`rework-required`。

Step 4 开发实现不能进入最终接受，必须进行 R1 返工。

理由：五个角色复审均不建议接受；代码审查、App 架构师、UI/交互设计师、测试/质量、安全合规顾问均给出 `rework-required`。当前问题不是 P2 体验残余，而是 Step 4 核心合同和专属门禁存在 P1。

## 2. 复审输入

- `step_4/代码审查-Step4开发复审-v0.md`：`rework-required`
- `step_4/App架构师-Step4开发复审-v0.md`：`rework-required`
- `step_4/UI-交互设计师-Step4开发复审-v0.md`：`rework-required`
- `step_4/测试-质量-Step4开发复审-v0.md`：`rework-required`
- `step_4/安全合规顾问-Step4开发复审-v0.md`：`rework-required`
- `step_4/项目负责人-Step4开发验收-v0.md`
- `step_4/开发记录-Step4-v0.md`
- `step_4/产品经理-PRD-v1.md`
- `step_4/App架构师-技术方案-v1.md`

## 3. 必须返工的 P1

### P1-1：P13D 当前是假 PASS，不满足 Step 4 fail-closed 证据门禁

角色共识：

- 代码审查、App 架构、测试/质量、安全合规均指出 P13D 当前主要是字符串 / token / 文件存在检查。
- P13D 输出中 29 个 scenario 的 `mutation_count`、`content_revision_before`、`content_revision_after`、`full_value_read_attempts`、`full_value_copy_attempts` 均为 `null` 仍可 PASS。
- `purpose_matrix.negative_reuse_count.paste=1`、`searchIndex=4` 仍未导致 fail。

返工要求：

- P13D 必须从静态 scenario 名称检查改为可执行的低敏 deterministic fixture / fault injection gate。
- 每个 scenario 必须输出非空、可判定 evidence：fixture id、mutation count、content revision before/after、failure reason 或 pass evidence。
- 成功保存类必须证明 payload / summary / search document / FTS / updatedAt / contentUpdatedAt / detail read model 一致，且 content revision 前进。
- invalid / conflict / rollback / record missing / payload missing / search document fail / FTS fail 类必须证明 mutation count 为 0 或明确无部分提交。
- full value read/copy 必须区分 `detailFullValueRead`、`detailCopyFullValue`、fake pasteboard / spy、save path pasteboard read/write。
- purpose negative count 必须 fail closed；若有误报，先缩窄到 detail edit/full value/save call graph，再让非 0 fail。
- P13D 必须覆盖下面 P1-2 到 P1-5 的关键路径，不能只让实现文件出现对应字符串。

### P1-2：OCR user-edited guard 在 late completion 后失效

事实：

- `updateOCRResult` 遇到 `.userEdited` 时会把 source 写成 `.ignoredLateVision` 并返回 false。
- 后续 `retryOCR` / `process` 只检查 `document.ocrTextSource != .userEdited`。
- 因此 `userEdited save -> late completion ignored -> retry/second completion` 后，用户编辑 OCR 文本仍可能被 Vision 结果覆盖。

返工要求：

- late completion 不得解除 user-edited protection。
- 推荐保留持久 source 为 `.userEdited`；ignored late completion 可作为低敏事件、transient evidence 或独立字段，不要覆盖 protected source。
- 如果必须持久化 `.ignoredLateVision`，则 retry / process / updateOCRResult 必须将其视为同等 locked source，并同时检查 `ocrLockedContentRevision`。
- P13D 必须增加真实序列 fixture：user-edited save -> late completion -> retry / second completion -> 断言 OCR text、source、locked revision、contentRevision、mutation count 不被错误覆盖。

### P1-3：Dirty-navigation 未实现阻断式三动作确认，切换记录可能静默丢弃 draft

事实：

- PRD 要求 dirty 状态离开编辑上下文时出现 `Save and Continue` / `Discard Changes` / `Continue Editing` 三动作阻断确认。
- 当前 `cancel()` 只设置 dirtyNavigation 状态；View 只是把按钮文案改成 `Discard` / `Save`，没有真正三动作 sheet。
- `discardDirtyNavigation()` 存在但未被 View 调用。
- `open(recordID:)` 直接 `load(recordID:)`，切换另一条记录时可能重置 dirty draft。

返工要求：

- 在 `ClipboardDetailStore` 或等价协调层实现 pending navigation action / continuation，所有离开编辑上下文入口统一走 dirty guard。
- 覆盖至少：关闭详情、点击 overlay、切换另一条记录、关闭面板或其他会丢弃当前 editor 的动作。
- 三个动作语义必须独立：
  - `Continue Editing`：关闭确认，保留 draft，焦点回到编辑器或安全位置。
  - `Discard Changes`：destructive，丢弃 draft 并执行原 pending action。
  - `Save and Continue`：保存成功后执行原 pending action；保存失败保留草稿并停留当前记录。
- 默认焦点应放在安全动作；Esc / 关闭确认应等价于继续编辑。
- P13D 或新增低敏 UI/static verifier 必须证明三动作绑定不是复用 `cancel()` 文案。

### P1-4：Metadata full value read/copy 与布局合同没有接到 UI

事实：

- Core / Store 已有 `fullValueAvailable`、`copyPurpose`、`fullValueText()`。
- `ClipboardDetailEditorView.metadataGrid` 只展示 bounded value，未使用 `fullValueAvailable`、`copyPurpose` 或 `fullValueText()`。
- UI 未提供 copy full value / expand full value 控件、反馈和 accessibility hint。
- metadata grid 未按 category 明确实现短项两列、长项单行、窄宽度单列降级。

返工要求：

- 对 `fullValueAvailable == true` 的 metadata item 提供显式完整值动作：copy full value、expand full value 或等价路径。
- full value read/copy 必须走显式 purpose；copy 自动化证据使用 fake pasteboard / spy，不写真实系统剪贴板。
- 提供 `copying`、`copied`、`copy failed` 或等价状态反馈。
- accessibility label/hint 必须区分 bounded value 和完整值动作。
- metadata layout 按 category 渲染：short 常规两列，long 整行，conditionalShort 在空间不足或内容过长时降级；窄宽度全部单列。
- P13D 或 UI static verifier 必须证明 View 层实际调用完整值路径，而不是只在 Store/Core 定义方法。

### P1-5：Rich text 编辑合同不闭合

事实：

- PRD 要求富文本文本内容可编辑，同时不能静默丢格式；如无法可靠保真，必须回到项目负责人做范围取舍。
- 当前实现把 rich text 暴露为可编辑，但 `ClipboardRichTextFidelityService` 更像保守失败 gate；对 link / inline style / list 等代表格式大概率保存失败。
- P13D 没有真实 representative fixture 证明 `detail_rtf_format_004` 的 link / paragraph / inline style / list 等实际通过或明确失败路径。

返工要求：

- 开发不得自行把“富文本可编辑”降级成隐式失败体验。
- 需要二选一：
  - 实现代表格式的真实保真编辑，并用 P13D fixture 证明 rich text kind、plain text derivation、link、paragraph、inline style、list 等不被静默丢失；
  - 如果无法实现，则停止并反馈项目负责人，由项目负责人决定是否调整为只读、派生纯文本编辑或暂缓，不得直接作为 R1 完成。
- 保存失败可以作为复杂格式保护策略，但不能让“可编辑入口 + 大量代表格式保存失败”成为默认体验。

## 4. P2 与后续收口

以下不作为 R1 阻塞，但必须保留到后续验收记录：

- 真实 App UI、真实系统剪贴板、真实 VoiceOver、真实跨 App 富文本交互未覆盖。
- Step 4 新增文案仍有本地化 polish 风险。
- 保存中 / 保存失败状态的视觉反馈可进一步打磨。
- Detail editor 固定宽度、长文本、多语言和窄宽度仍需低敏截图或 Step 6 回扫。
- 既有构建 warning 不阻塞本轮，但后续可统一收口。

## 5. 项目负责人取舍

- 不接受将上述 P1 降级为 residual risk。
- 不进入 Step 5。
- 不要求 PRD 或技术方案重写；当前 PRD v1 / 技术方案 v1 合同足够，问题在实现和验证证据。
- 开发可以在一个 R1 批次内修复，不必过度拆分；但 P13D 必须作为 R1 的首要 gate 转绿，且不能继续假 PASS。

## 6. R1 验证要求

R1 完成后至少运行：

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

开发记录需写入：

- `step_4/开发记录-Step4-R1-v0.md`
- 每个 P1 的修复说明和证据。
- P13D 新 evidence schema 摘要。
- OCR user-edited sequence 证据。
- Dirty-navigation 三动作和切换记录 guard 证据。
- Metadata full value UI 证据。
- Rich text 代表格式保真证据，或明确阻塞并等待项目负责人取舍。
