# 004_剪贴板打磨 Step 2 UI/交互开发复审 v0

日期：2026-07-07
角色：UI/交互设计师
范围：Step 2 标签 / 收藏在面板、右键菜单、设置页中的体验实现
结论：`approve-with-changes`

## 1. 复审边界

本次只读复审覆盖 Step 2：

- 面板标签筛选、收藏优先、active 状态。
- 条目标签展示、右键菜单已添加 / 未添加状态、新建标签入口、收藏语义。
- Settings Clipboard 标签管理行、内置收藏不可改语义、颜色 / 排序 / 重命名 / 合并 / 删除反馈。
- 相关字符串、帮助文案和可访问性风险。

明确未覆盖：

- Step 3 面板 hover / toolbar / 选中反馈 / 密度专项。
- Step 4 隐私 App 管理。
- Step 5 详情编辑。
- 真实 App UI、真实剪贴板、provider、TCC、系统设置、Keychain 或任何系统动作。

本结论基于文档与静态源码；没有把未实测的视觉状态、VoiceOver 行为或真实右键菜单操作说成已通过。

## 2. 读取材料

- `docs/项目管理库/004_剪贴板打磨/step_2/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/项目负责人-开发派发-Step2-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/开发记录-Step2-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/项目负责人-Step2开发验收-v0.md`
- `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardTagStore.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift`
- `apps/Blocks/BlocksApp/App/AppModel.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
- `tools/verification/p13b_clipboard_tags_model_checks.py`
- `tools/verification/p8_clipboard_product_polish_checks.py`
- `tools/verification/p8i_settings_clipboard_system_checks.py`

## 3. UI/交互事实依据

### 3.1 面板标签筛选

- `ClipboardFloatingPanelView.filterStrip` 将 `clipboardStore.tagStore.tagsForFilter` 和 `displayFilterState` 传给 `ClipboardFilterClickGroup`，标签筛选由当前 `ClipboardTagStore` 驱动。
- `ClipboardFilterBarView` 在 tag group 中先显示 `All`，再遍历 tags；favorite 使用 `star.fill`，普通标签使用 `tag.fill`；active 状态通过 accent color、背景和 stroke 表达。
- `ClipboardStore.setTagFilter(_:)` 写入 `tagStore.selectedTagID` 并刷新搜索结果；repository reload 后如果选中 tag 不存在或过滤后为空，会清理选中 tag。

判断：Step 2 单标签筛选、favorite first 和 active 状态的静态实现与 PRD / 技术方案一致。未实测横向滚动、长标签名截断和 VoiceOver 读法。

### 3.2 条目标签展示与右键菜单

- `ClipboardRecordContextMenu` 已接入 `ClipboardTagMenu`。
- `ClipboardTagMenu` 优先显示 favorite；已添加状态用 `checkmark.circle.fill`，未添加 favorite 用 `star`，未添加普通标签用 `tag`。
- `New Tag...` 入口目前直接调用 `createTag("New Tag")`；设置页提供完整命名、重命名、冲突处理和删除 / 合并能力。
- `ClipboardTagChips` 在条目上显示最多 3 个标签 chip，并对每个 chip 提供 `.help(tag.displayName)`。

判断：右键菜单已能表达添加 / 移除状态和收藏语义；条目展示有最小可读性。`New Tag...` 固定默认名会在第二次创建或已有同名时暴露体验粗糙点，但由于 Settings 可完整补救，本轮不列为 must-fix，列为 P2 / should-fix。

### 3.3 Settings 标签管理

- `ClipboardTagManagementSection` 提供新建标签 TextField、创建按钮和 operation error detail。
- favorite row 显示内置文案，只展示 `Built-in`，不提供重命名、颜色、排序、合并、删除控件，符合 “favorite immutable”。
- 普通 tag row 提供重命名、颜色菜单、上移 / 下移、合并菜单、删除按钮，并通过 `.help(...)` 提供基础说明。
- String Catalog 已补充 Settings 标签管理的中 / 英 / 日三语言文案，包括 favorite detail、merge、delete、rename、move、new tag 等。

判断：Settings 的基础管理路径完整，信息密度符合既有 Settings row / trailing control 模式，没有引入 Step 3 式视觉重构。主要不足是反馈承载过于集中在新建 row 的 detail，删除 / 合并 / 重命名成功或失败后用户可能不确定具体哪一行发生了什么。

## 4. Must-Fix

本次静态 UI/交互复审未发现必须阻断 Step 2 进入复核收敛 / 最终验收准备的 P0/P1。

P0/P1 判断边界：

- 标签筛选、favorite first、右键添加 / 移除、Settings 管理入口均存在。
- 旧 pinboard / pinned UI 不再作为 active UI 语义来源，项目负责人验收记录中的 P13B / P8 / P8I / P9A / P9B / P11E 均已通过。
- 未做真实 UI 运行，因此不能把视觉和可访问性实测写为已通过；这属于验收证据风险，不是静态实现阻断。

## 5. Should-Fix / P2

1. 右键 `New Tag...` 固定创建 `New Tag`

建议定级：P2，可接受为 Step 2 残余，不应阻断本轮。

原因：入口能完成“创建并附加”的最小动作；同名、改名、删除等补救路径在 Settings 已存在。但它不符合用户对 `New Tag...` 的常规预期：带省略号的菜单项通常意味着会继续输入或打开命名流程。若已有 `New Tag`，第二次使用大概率只表现为失败或无明显结果。

建议后续口径：

- 短期：最终接受记录明确“右键 New Tag 是固定默认名最小入口，完整命名在 Settings”。
- 后续小修：将菜单文案改为 `Create "New Tag"`，或改成弹出轻量命名 popover / sheet。
- 若保留 `New Tag...` 文案，则建议补一个命名输入或冲突提示，否则省略号语义不稳定。

2. Settings 标签操作反馈需要更贴近动作来源

建议定级：P2。

当前 `operationError?.localizedMessage` 只在新建标签 row 的 detail 中显示。对重命名、合并、删除、排序等行内动作来说，错误出现在新建 row 位置，会让用户误以为是新建失败，或者忽略当前行的失败。

建议后续口径：

- 将失败反馈绑定到当前 tag row，或在 Settings Clipboard 顶部使用统一 inline status。
- 对删除 / 合并成功，至少提供一次性 status：如“已删除标签，条目保留”或“已合并到 {target}”。
- 删除文案建议明确“只删除标签，不删除剪贴板条目”。

3. `ClipboardTagOperationError.localizedMessage` 仍为 Swift 内中文硬编码

建议定级：P2。

String Catalog 已有 Settings 标签管理三语言文案，但 tag operation error 使用中文硬编码。若当前应用语言为英文或日文，冲突、空名、存储不可用等失败反馈会混入中文。

建议后续口径：

- 把 operation error message 接入 `Localizable.xcstrings`。
- 至少覆盖 duplicate name、empty name、reserved favorite、favorite immutable、invalid merge、repository unavailable。

4. 条目 tag chips 超过 3 个时没有数量提示

建议定级：P2。

当前 chips 只显示 `prefix(3)`，没有 `+N` 指示。对于多标签条目，用户可能误以为只有 3 个标签。

建议后续口径：

- 显示最多 2-3 个 chip 后补 `+N`。
- `+N` 的 help 可列出剩余低敏 tag 名；若担心宽度，至少提示“还有 N 个标签”。

5. 无障碍 label 需要低敏实物确认

建议定级：P2。

当前 icon-only 控件多通过 `.help(...)` 提供提示，但 `.help` 不能等同于 VoiceOver label 验收。Settings row 的 rename checkmark、paint palette、move up/down、merge、trash 等按钮需要确认 VoiceOver 是否读出动作、对象和状态。

建议后续口径：

- 为 icon-only 操作补明确 accessibilityLabel / accessibilityHint，尤其是“重命名 {tag}”“删除 {tag}”“将 {source} 合并到其他标签”。
- 过滤 chip 的 active 状态建议在可访问性上表达为 selected / active，而不只依赖颜色。

## 6. Residual Risk

- 未运行真实 App：右键菜单层级、按钮禁用态、Settings 行宽、popover/menu 对齐、滚动区域和焦点回收没有实物证据。
- 未触发真实剪贴板：无法确认真实条目数量、长文本、图片 OCR 条目与 tag chips 组合后的密度表现。
- 未做窄宽度截图：Settings row 中 TextField、颜色菜单、上下移动、合并、删除可能在窄窗口挤压。
- 未做 VoiceOver：目前只能确认部分 `.help` 和字符串存在，不能确认 VoiceOver 读法完整。
- 未做长标签名 / 三语言长句实物检查：`lineLimit(1)` 能避免溢出，但可能牺牲可读性；需截图确认。

## 7. 建议补充的 UI 证据

建议在 Step 2 最终接受前补充低敏证据；若项目负责人决定加速，也应把以下内容写为最终接受残余，而不是写成已验证：

- 面板筛选条截图：All、favorite、普通 tag，包含 active tag 状态。
- 条目 row / card 截图：favorite + 1 个普通 tag、3 个 tag、超过 3 个 tag。
- 右键菜单截图：未添加 tag、已添加 tag、favorite 已添加 / 未添加状态、`New Tag...`。
- Settings Clipboard 标签管理截图：favorite built-in row、普通 tag row、长标签名、窄宽度窗口。
- 错误反馈截图：重名、空名、保留 favorite 名称、repository unavailable 或等价低敏模拟。
- VoiceOver 或 accessibility inspector 记录：filter active 状态、icon-only 操作按钮、favorite immutable row。

## 8. 建议文案

可直接作为后续修订输入：

- 右键固定默认名保守口径：`Create "New Tag"`，避免 `...` 暗示会继续命名。
- 删除标签确认 / help：`Delete tag only; clipboard items remain.`
- 合并标签说明：`Move items from this tag into {target}, then remove this tag.`
- 重名错误：`Tag name already exists.`
- 保留名错误：`Favorite is built in and cannot be reused.`
- active filter 可访问性：`Active tag filter: {tagName}`。

## 9. 结论

`approve-with-changes`。

Step 2 标签 / 收藏核心体验的静态实现可以进入下一步复核收敛；未发现需要阻断的 must-fix。右键 `New Tag...` 固定默认名、Settings 行内反馈、operation error 本地化、tag chips 超量提示和可访问性 label 属于 P2 / should-fix。由于没有真实 UI 证据，不建议把 Step 2 UI 体验写成 full verified；最终接受前应补低敏截图或在接受记录中明确保留这些实物验收风险。
