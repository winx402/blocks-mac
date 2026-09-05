# 004_剪贴板打磨 Step 4 UI/交互 PRD 复审 v0

日期：2026-07-07
角色：UI/交互设计师
范围：只读复审 Step 4 PRD v0：详情编辑与元数据组织。不进入技术方案、开发、Step 5 或 Step 6。

## 1. 结论

结论：`approve-with-changes`

PRD v0 的范围控制清楚，覆盖了 plain text、URL、富文本文本内容、图片 OCR 文本、显式保存/取消、dirty/saving/failed/read-only/OCR 状态、编辑区 2 行默认/4 行上限、元数据短项两列/长项单行和低敏 fixture。未发现需要阻断角色复审或退回重写的 P0/P1。

建议在 PRD v1 或复审收敛中吸收 UI 口径，主要是把“可接受多种形态”收敛成首版推荐：详情默认阅读态，点击 Edit 进入编辑；底部固定操作区常驻；状态反馈按固定位置承载；窄宽度下元数据降级为单列；可访问性和低敏实物验收写得更可测。

## 2. 已读取输入

- `AGENTS.md`
- `agents/UI-交互设计师.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-PRD派发-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-PRD预审-v0.md`

未运行真实 App、真实剪贴板、TCC、provider、Keychain、系统设置、自动化或 UI 截图。本复审是文档级只读判断。

## 3. 总体判断

### 做得足够好的部分

- 阶段边界明确：没有把 Step 5 隐私页 App 清单、CLI 广义对象管理或 Step 6 集成验收提前塞进 Step 4。
- 保存模型方向正确：显式保存 + 取消、dirty-navigation、保存失败草稿保留、系统剪贴板不更新，符合用户可控预期。
- 富文本和 OCR 没有过度承诺：富文本格式保留列为产品目标和架构待确认项，OCR 文本编辑不改图片 payload 本体。
- 布局目标清楚：编辑区 2 行默认、4 行上限、内部滚动；元数据短项两列、长项单行。
- 低敏 fixture 覆盖面较全，能支撑后续 P13D 或等价门禁。

### 需要收敛的部分

PRD v0 目前在一些 UI 入口和布局形态上给了多个可选项，这适合 v0 讨论，但进入技术方案前建议收敛为默认方案，避免开发和测试各自解释。

## 4. Findings

### P0

无。

### P1

无。

### P2

#### P2-1 编辑入口需要从“任选”收敛为首版推荐

PRD 允许“直接可编辑”或“点击编辑按钮进入编辑态”。从当前产品语境看，剪贴板详情页的首要任务仍是阅读、确认、复制和查看元数据，编辑属于高影响操作。建议首版采用：

- 默认进入 read-only / view mode。
- 可编辑类型在固定操作区展示 `Edit`。
- 点击 `Edit` 后进入 edit-clean，编辑区获得可编辑样式但不强制抢焦点。
- 不可编辑类型同一位置显示只读原因或相关动作，如 OCR retry。

推荐理由：

- 避免打开详情时误触造成 dirty。
- 与“显式保存 + 取消”的安全感一致。
- 对图片 OCR、富文本、URL 校验等复杂类型更容易解释状态。

可写入 PRD v1 的口径：

```text
首版默认采用显式 Edit 入口。详情打开时优先阅读态；可编辑类型显示 Edit，点击后进入 edit-clean。仅在进入 edit-clean 后允许输入。直接可编辑文本区不作为 Step 4 首版默认方案，除非技术方案证明不会造成误 dirty、焦点抢占和状态解释成本。
```

#### P2-2 保存 / 取消稳定布局建议指定固定底部操作区

PRD 已要求保存 / 取消操作区布局稳定，但没有给推荐形态。建议 PRD v1 明确首版采用详情面板内固定 footer / action bar，而不是在编辑区附近插入按钮。

推荐规则：

- 操作区高度常驻，read-only、edit-clean、dirty、saving、failed 都占同一布局位。
- read-only：显示 `Edit` 或只读原因。
- edit-clean：显示 `Cancel` + disabled `Save`，并可显示 `No changes` 或弱状态。
- dirty：显示 `Cancel` + enabled `Save` + `Unsaved changes`。
- saving：`Save` 变 loading，防重复提交；编辑区是否锁定交给技术方案，但视觉不能跳动。
- failed：同一操作区显示失败文案、`Retry Save` / `Save` 和 `Cancel`。

可写入 PRD v1 的口径：

```text
详情页保留固定底部操作区，所有编辑状态共用同一高度和位置。按钮启用、loading、错误文案变化不得导致正文编辑区和元数据区重新布局。
```

#### P2-3 状态反馈需要补最小文案层级

PRD 的状态矩阵完整，但状态反馈位置和文案层级还可以更具体。建议补充：

- dirty：短状态文案在固定操作区，避免占用编辑正文。
- invalid URL：inline error 靠近 URL 编辑区，同时操作区 Save disabled 或显示保存失败。
- saving：按钮内 spinner + `Saving...`，避免全屏遮罩。
- save-success：轻量状态，不应抢焦点；可短暂显示 `Saved`。
- save-failed：错误文案必须靠近操作区或编辑区，不使用易消失 toast 作为唯一反馈。
- read-only：必须说清原因，例如 `File content cannot be edited here`、`OCR is still running`、`OCR failed, retry first`。
- OCR done empty：显示 `No text recognized`，不要让用户误以为内容丢失。

可写入 PRD v1 的口径：

```text
状态反馈分三层：字段级错误靠近字段；编辑事务状态固定在操作区；全局短反馈只作为补充，不能作为失败、dirty 或 read-only 的唯一反馈。
```

#### P2-4 dirty-navigation 推荐使用确认 sheet，避免静默切换

PRD 已要求保存、放弃、继续编辑三路径。建议明确首版 UI 形态：

- dirty 状态切换条目、关闭详情、关闭面板时弹出确认 sheet / dialog。
- 默认焦点放在 `Continue Editing` 或最安全动作；危险动作 `Discard` 明确命名。
- `Save and Continue` 进入 saving，成功后执行原动作；失败则停留当前记录并显示失败。

可写入 PRD v1 的口径：

```text
dirty-navigation 使用阻断式确认 sheet，动作固定为 Save and Continue / Discard Changes / Continue Editing。不得用 toast、状态条或隐式自动保存替代。
```

#### P2-5 编辑区 2 行 / 4 行需要补可测尺寸口径

PRD 已写 2 行默认、4 行上限。建议补充验收可测口径：

- “行”按详情编辑字体和 line height 计算，不随列表字体设置变化。
- read-only、edit-clean、dirty、saving、failed 状态下编辑区外框高度稳定。
- 错误文案不把编辑区挤到低于 2 行。
- 超过 4 行后只编辑区内部滚动，详情整体滚动不被文本区吞掉。
- URL、长英文单词、日文长句需要验证换行 / 横向滚动策略。

可写入 PRD v1 的口径：

```text
编辑区最小可见高度为 2 行，最大可见高度为 4 行；状态文案和操作按钮不改变该高度。超过 4 行时编辑区内部滚动，详情页整体滚动仍可用。
```

#### P2-6 元数据两列 / 长项布局需要补降级阈值和操作规则

PRD 已定义短项两列、长项单行，但窄宽度降级还可更明确。建议：

- 默认宽度：短项两列，长项单行。
- 窄宽度：全部元数据降级为单列，避免两列互相挤压。
- 长项值默认单行截断或两行内换行，提供 copy 完整值按钮。
- tooltip 可作为桌面补充，但不能是唯一完整语义路径；VoiceOver label 要包含完整语义或明确 “copy full value”。
- file URL 和真实路径相关证据必须低敏化，不把真实 home path 写进截图或日志。

可写入 PRD v1 的口径：

```text
元数据布局按宽度降级：常规宽度短项两列、长项单行；窄宽度全部单列。每个长项至少提供 copy full value 或等价完整值路径，视觉截断时 accessibility label 保留完整语义或说明可复制。
```

#### P2-7 OCR 用户编辑后与 retry 的冲突策略需要 UI 文案占位

PRD 已把冲突策略列为架构待确认项。UI 侧建议在 PRD 保留用户可见占位：

- 用户编辑后的 OCR 文本应显示 `Edited OCR text` 或等价状态。
- 如果用户点击 OCR retry，需明确是否覆盖用户编辑内容；在策略未定前，不应允许静默覆盖。
- 推荐首版：用户编辑 OCR 文本后，retry 需要二次确认；确认文案说明会替换或保留用户编辑版本。

可写入 PRD v1 的口径：

```text
用户保存过 OCR 文本后，详情页显示 Edited OCR text。后续 OCR retry 不得静默覆盖用户编辑内容；若技术方案允许重试覆盖，必须先确认。
```

#### P2-8 可访问性验收建议补 keyboard order 和 announcement

PRD 已提到可访问性，但建议补成可验收清单：

- 进入详情后，焦点不自动跳进编辑区；点击 Edit 后焦点进入编辑区或保持在明确位置。
- Tab 顺序：编辑入口 / 编辑区 / metadata copy buttons / Save / Cancel / retry。
- dirty、saving、failed、read-only、invalid URL、OCR 状态需要可被 VoiceOver 读出。
- 保存失败应以 alert/status role 或等价方式可感知，不能只改变颜色。
- 取消 / 放弃更改动作需要明确 label，避免 VoiceOver 用户误操作。

可写入 PRD v1 的口径：

```text
Step 4 验收至少包含 1 组键盘路径和 1 组 VoiceOver 检查：Edit、编辑区、Save、Cancel、错误反馈、dirty-navigation sheet、metadata copy、OCR 状态均可聚焦或可读。
```

## 5. 可吸收建议汇总

建议 PRD v1 吸收以下默认口径：

1. 编辑入口：默认阅读态 + 显式 `Edit`，不默认直接编辑。
2. 操作区：固定底部 action bar，read-only/edit-clean/dirty/saving/failed 共用稳定布局位。
3. dirty-navigation：使用确认 sheet，三动作固定为保存并继续 / 放弃更改 / 继续编辑。
4. 状态反馈：字段级错误靠近字段，事务状态固定在操作区，全局 toast 只做补充。
5. URL 校验：非法 URL 不静默保存；推荐保存前或保存时阻止，并保留草稿。
6. OCR：pending/running/failed 不可编辑；done 有文本可编辑；用户编辑后显示 edited 标记，retry 不静默覆盖。
7. 编辑区：2 行默认、4 行上限按详情字体计算；状态变化不改变高度。
8. 元数据：常规两列/长项单行，窄宽度单列；长项有 copy full value 或等价完整值路径。
9. 可访问性：补 keyboard order、VoiceOver announcement 和错误状态可感知验收。
10. 低敏证据：长 URL、file URL、来源 App、标签、多语言和保存失败 fixture 均不得含真实剪贴板正文或真实路径。

## 6. 建议低敏验收样例

建议后续技术方案或测试/质量把以下样例变成 P13D 或等价门禁输入：

- `detail_text_alpha_004`：打开详情为 read-only，点击 Edit 进入 edit-clean，修改后 dirty，保存成功后摘要 / 搜索 / 更新时间更新。
- `detail_text_long_004`：编辑区 2 行默认、4 行上限、内部滚动；状态切换不改变编辑区高度。
- `detail_url_invalid_004`：非法 URL 显示 inline error，Save disabled 或保存失败后保留草稿。
- `detail_save_failure_004`：保存失败保留草稿，错误不遮挡正文，可重试 / 取消。
- `detail_dirty_navigation_004`：dirty 下切换记录弹出三动作确认 sheet。
- `detail_rtf_format_004`：若不能保留格式，必须有项目负责人取舍记录；不得静默纯文本化。
- `detail_image_ocr_done_004`：编辑 OCR 文本后显示 edited 状态，搜索命中新 OCR 文本。
- `detail_image_ocr_failed_004`：失败状态下展示 retry，不展示普通编辑入口。
- `detail_metadata_long_004`：长 URL / 长文件名 / 长来源 App / 长标签在常规和窄宽度不重叠，完整值可复制。
- `detail_a11y_004`：键盘和 VoiceOver 覆盖 Edit、Save、Cancel、失败、dirty-navigation 和 metadata copy。

## 7. 残余风险

- 本轮是 PRD 只读复审，没有真实 UI、截图、VoiceOver、真实剪贴板或系统级行为证据。
- 富文本格式保留、保存事务原子性、OCR retry 与用户编辑冲突属于架构/技术方案关键风险；UI 侧不将其判为 PRD P1，但进入开发前必须被技术方案明确。
- 如果 PRD v1 不收敛编辑入口和固定操作区形态，后续技术方案仍能推进，但开发与验收解释成本会增加。

## 8. 是否建议进入下一步

建议：可以进入角色复审收敛和 PRD v1 修订；UI/交互侧不要求 `rework-required`。

进入技术方案前，建议项目负责人要求产品经理至少吸收：显式 Edit、固定底部操作区、dirty-navigation sheet、状态反馈层级、窄宽度元数据降级和可访问性验收清单。
