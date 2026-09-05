# UI/交互设计师 - Step 4 技术方案复审 v0

日期：2026-07-07
项目：004_剪贴板打磨
阶段：Step 4 - 详情编辑与元数据组织
复审角色：UI/交互设计师
复审范围：只读复审 `App架构师-技术方案-v0.md`，不进入实现，不启动 Step 5/6。

## 1. 结论

结论：`approve-with-changes`

技术方案已经覆盖 Step 4 进入实现所需的核心体验边界：默认阅读态 + 显式 Edit、hover detail 不承载 dirty editor、bounded detail read model、metadata snapshot、detail edit/full value/save purpose 隔离、单一 Store/Repository 保存命令、固定 action bar、dirty-navigation sheet、2/4 行编辑区、metadata 两列/窄宽度单列、copy full value、P13D fail-closed gate、低敏 evidence 约束。

本轮未发现需要推翻方案的 P0/P1。建议在技术方案 v1 或开发派发中吸收下列 P2 级 UI 验收补充，避免开发完成后才用真实 UI 发现布局、文案或可访问性口径不一致。

## 2. 复审输入

- `AGENTS.md`
- `agents/UI-交互设计师.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-技术方案预审-v0.md`

## 3. P0 / P1 / P2

### P0

无。

### P1

无。

### P2-1：stable detail editor 的默认承载形态需要更具体

事实：技术方案明确 hover detail 只读、不承载 dirty editor，并把 stable editor / sheet / pane 放在 Batch D。但在承载形态上仍保留了 `sheet / pane / main detail area` 的选择空间。

风险：如果实现阶段把编辑器做成临时 popover 或随 hover 生命周期关闭的面板，用户会把编辑状态误认为预览状态，dirty draft、Cancel、Save、record switch 的预期也会不稳定。

建议回写口径：

- Step 4 默认采用“稳定详情编辑面”，可以是当前 detail panel 内的固定编辑区域或从 detail open 进入的稳定 sheet/pane。
- 禁止用 hover preview、hover detail 或会因鼠标离开自动关闭的 popover 承载 dirty editor。
- 编辑态必须有明确关闭/切换记录/切换筛选的 dirty-navigation 处理；不能静默丢草稿。
- 若开发必须在 sheet 与 pane 之间二选一，优先采用不改变 panel 主布局、底部 action bar 固定的 in-panel detail editor。

### P2-2：P13D 应把 keyboard / VoiceOver 低敏验收字段结构化

事实：PRD v1 对键盘和 VoiceOver 有明确验收；技术方案 Batch D 也要求 `keyboard / VoiceOver 低敏 evidence manifest`，但 P13D 输出字段示例主要围绕 bounded read、purpose、save、pasteboard、rich text、OCR、sanitizer。

风险：如果 P13D 只记录截图或静态布局，不记录键盘焦点与可访问性语义，最终仍会留下“PRD 写了但实现没有可复核证据”的残余风险。

建议回写口径：

- P13D evidence manifest 增加 `keyboard` 与 `accessibility` 分组。
- `keyboard` 至少记录：阅读态 Edit 可聚焦、Edit 后焦点进入编辑区或明确的首个编辑控件、Save/Cancel/Retry 可通过键盘到达、dirty sheet 默认焦点在安全动作、Esc/Cancel 语义一致。
- `accessibility` 至少记录：详情当前状态、字段 label/value、invalid URL 错误、saving/save failed/reindex failed、Save/Cancel/Retry 可用性、dirty sheet 三个动作及危险动作说明、metadata full value/copy affordance。
- 证据可以是低敏快照/manifest，不要求真实 VoiceOver 实测；但不得写成真实 VoiceOver 已通过。

### P2-3：fixed action bar 的布局稳定性应进入验收样例

事实：技术方案已有 fixed action bar、状态矩阵和 P13D，但尚未明确 action bar 在不同事务状态下的高度、按钮位置、错误文本承载是否保持稳定。

风险：invalid、saving、save-failed、record-unavailable 这类状态如果直接挤压编辑区或 metadata 区，会破坏“保存/取消稳定布局”的 Step 4 体验目标。

建议回写口径：

- P13D 增加 action bar 布局断言：`view`、`edit-clean`、`dirty`、`invalid`、`saving`、`save-failed`、`record-unavailable` 下 action bar 高度和主要按钮位置不跳动。
- field-level error 放在字段附近，但不得改变编辑区 2/4 行上限；transaction-level status 放在 action bar 保留区域。
- loading spinner、Retry、Save disabled、Cancel 可用状态需要在同一 footer/action bar 内表达。

### P2-4：dirty-navigation sheet 需要补齐失败回路和默认焦点

事实：技术方案覆盖 dirty-navigation sheet，角色复审问题也点名默认焦点。

风险：如果 Save and Continue 失败后直接关闭 sheet 或跳转，用户会以为内容已保存；如果默认焦点落在 Discard Changes，也会提高误丢草稿风险。

建议回写口径：

- 默认焦点放在 `Continue Editing` 或等价安全动作。
- `Discard Changes` 标为 destructive，并在文案中说明会放弃当前草稿。
- `Save and Continue` 失败时保留草稿、停留在当前记录，回到 `save-failed`，不执行导航。
- sheet 关闭、Esc、点击外部的默认行为应等价于继续编辑或取消导航，不应丢弃草稿。

### P2-5：metadata copy full value 需要明确可见反馈

事实：技术方案明确 metadata snapshot 不含完整值，完整 URL/path/OCR/full value 只能通过 `detailFullValueRead` 显式读取，且 tooltip 不应作为唯一路径。

风险：用户看到被截断的路径、URL 或 OCR 摘要时，如果 copy full value 的反馈不清楚，会误以为复制的是截断值，或者误以为详情页默认已经读取了完整敏感内容。

建议回写口径：

- 长 metadata 行展示 bounded value + 显式 copy full value 控件。
- copy full value 应有 `copying`、`copied`、`copy failed` 的低调反馈；失败时说明未复制完整值。
- VoiceOver label 应区分“显示的是摘要/截断值”和“复制完整值”。
- P13D evidence 必须证明默认 metadata JSON 不含完整 URL、完整 file path、OCR 原文或 RTF body。

### P2-6：空文本保存的用户语义需提前定口径

事实：技术方案建议 plain text 空文本可接受，并用明显 empty summary 表达；PRD v1 未把空文本保存作为重点。

风险：如果空文本保存后列表、详情、搜索索引没有一致文案，用户可能误以为记录损坏或内容丢失。

建议回写口径：

- 若允许保存空文本，阅读态显示 `Empty text` / 本地化等价文案，metadata 保留类型、创建时间、更新时间、标签等上下文。
- 搜索索引对空文本的行为要明确：不匹配正文搜索，但仍可通过标签/收藏/来源筛选找到。
- 若不接受空文本保存，应作为 field-level validation，而不是保存后再失败。

### P2-7：窄宽度、多语言、长值 evidence 应覆盖具体组合

事实：PRD v1 已要求中文/英文/日文长文案、长 URL、长 file path、窄宽度、metadata 单列降级。技术方案把 metadata layout 与 P13D evidence 纳入 Batch D。

风险：如果 evidence 只覆盖默认英文短值，无法证明 2/4 行编辑区、fixed action bar 和 metadata 两列/单列在真实长文本下不重叠、不跳动。

建议回写口径：

- P13D 最少包含：长 URL、长 file path、中文长句、英文长词/长句、日文长句、长 tag/source 名称。
- 常规宽度验证短项两列、长项单行；窄宽度验证所有 metadata 单列且 action bar 不横向挤压。
- 编辑区验证默认 2 行、最多 4 行、超出后内部滚动，不推动 footer/action bar。

## 4. 已满足的关键体验契约

- 默认阅读态 + 显式 Edit：技术方案与 PRD 一致，没有把详情打开直接变成编辑态。
- hover 安全边界：hover detail 被限定为只读入口，不承载 dirty editor。
- 字段/事务反馈层级：field-level validation 与 transaction-level save/reindex 状态分层是正确方向。
- 保存语义：单一 Store/Repository save command、默认同事务更新 payload/summary/search/FTS/updatedAt，避免 UI 层散写。
- rich text：不接受静默纯文本降级，必须有 fidelity gate 或项目负责人接受记录。
- OCR：user-edited 来源持久化，retry/late completion 不得静默覆盖用户编辑。
- 隐私边界：默认 bounded read model + metadata snapshot，完整值必须显式 purpose 读取。
- 系统剪贴板边界：保存不写系统 pasteboard，使用 fake/spy/static scan 和 fixture 证明。

## 5. 可吸收到技术方案 v1 / 开发派发的推荐口径

1. “Step 4 的编辑器是稳定详情编辑面，不是 hover 预览的一种状态。hover detail 只能提供只读信息或进入详情编辑的显式入口。”
2. “action bar 为固定 footer 区域；按钮、spinner、transaction error、Retry 在该区域内变化，不挤压编辑区和 metadata。”
3. “dirty-navigation 的默认安全动作是继续编辑；丢弃草稿为 destructive；Save and Continue 失败不得导航。”
4. “metadata 默认只展示 bounded snapshot；完整值读取与复制必须通过显式控件、显式 purpose 和可见反馈。”
5. “P13D 只提供低敏 keyboard / accessibility evidence，不声称真实 VoiceOver 已通过；真实 UI/VoiceOver 仍作为后续专项或最终验收残余。”

## 6. 残余风险

- 本轮未运行真实 App、真实剪贴板、TCC、provider、Keychain、系统设置或真实 VoiceOver；真实 UI/VoiceOver 仍是 P2 residual，不能在 Step 4 技术方案阶段宣称已通过。
- Rich text fidelity 与 OCR user-edited schema 是实现复杂度最高的两块。技术方案的 fail-closed 方向正确，但最终是否可接受取决于 P13D fixture 与项目负责人对 rich text 降级的取舍记录。
- Step 4 不应借机重做 Step 3 面板布局专项，也不应提前进入 Step 5/6。技术方案当前边界清楚，开发派发时需要继续保持。

## 7. 建议下一步

允许进入技术方案收敛或开发准备，但建议项目负责人把第 3 节 P2 建议中与 P13D manifest、stable editor carrier、fixed action bar、dirty-navigation sheet 相关的口径写入技术方案 v1 或开发派发，避免实现验收时出现解释空间。
