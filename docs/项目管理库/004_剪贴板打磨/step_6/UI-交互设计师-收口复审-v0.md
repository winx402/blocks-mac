# UI/交互设计师收口复审 - Step 6 覆盖回扫

日期：2026-07-07
角色：UI/交互设计师
对象：`004_剪贴板打磨` Step 6 收口覆盖回扫

结论：`approve`

P0：0
P1：0
P2：保留，见第 6 节。

## 1. 复审边界

本轮只做 Step 6 收口覆盖回扫的 UI/交互复审，不修改业务代码，不重新打开 Step 1-5 已接受范围，不触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。

已读输入：

- `docs/项目管理库/004_剪贴板打磨/step_6/项目负责人-收口派发-Step6-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_6/产品经理-收口覆盖回扫-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_6/项目负责人-收口预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_1/项目负责人-Step1验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/项目负责人-Step2最终验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_2/UI-交互设计师-Step2-R1复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-Step3最终验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/UI-交互设计师-Step3-R1复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4最终验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/UI-交互设计师-Step4-R3复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5最终验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5-R2验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-Step5-R3验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/代码审查-Step5-R3复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/UI-交互设计师-技术方案复审-v0.md`

## 2. 总体判断

产品经理的 Step 6 收口覆盖回扫可以接受。其关键优点是：

- 没有把 Step 1-5 的 P2 residual 写成已实测通过。
- 没有把真实 UI、真实 VoiceOver、真实剪贴板、真实系统枚举或真实系统动作误写成已覆盖。
- 对原始需求 R1-R13、澄清需求 C1-C17、流程需求 P1-P5 的覆盖判断基本符合各阶段最终验收。
- 对体验类、真实环境证据类、可访问性类和系统边界类 residual 的分类方向正确。

本轮 UI/交互侧未发现 P0/P1 级体验遗漏，也未发现 hover、selected/focused、单/双击显性控件、标签/收藏、详情编辑或隐私 App row 存在被错误降级的 P1。

## 3. 体验类 residual 分类复核

### 3.1 Step 2 标签 / 收藏

判断：分类准确，P2 合理。

Step 2 已关闭 tag-only filter clear-all、`+N` chips、`Create "New Tag"` 语义和错误本地化问题。剩余的 Settings 标签行内反馈不贴近触发来源、右键快速创建仍固定默认名、真实 UI / VoiceOver / 窄宽度证据缺口，确实属于体验打磨或证据缺口，不构成 P1。

理由：

- 用户仍能通过 Settings 完整改名、冲突处理和标签管理完成任务。
- `Create "New Tag"` 已不再暗示会继续输入名称。
- 收藏作为内置标签的五角星、默认第一、不可删除 / 改名 / 改色 / 排序语义已在 Step 2 终验中接受。

### 3.2 Step 3 hover、selected/focused、单/双击显性控件

判断：分类准确，P2 合理。

Step 3 R1 已关闭 paste activation icon-only / 可访问性语义 P1。hover safe bridge 12 / 16 参数、180ms delay、`.allowsHitTesting(false)` 和 selected/focused 先写后动作的静态合同已接受。真实鼠标斜向穿越、brief leave、obvious leave、真实单击 / 双击事件顺序和真实 VoiceOver 未覆盖，属于真实 UI 手感与实物证据缺口。

这不是 P1 的原因：

- 低敏门禁和源码路径已证明设计意图被编码为稳定合同。
- 未实测项不会直接说明功能不可用，只说明发布前体验置信度不足。
- 产品经理文档没有声称这些路径已现场通过。

### 3.3 Step 4 详情编辑与元数据

判断：分类准确，P2 合理。

Step 4 R1-R3 已关闭 dirty navigation、保存 / 取消、metadata full value、关闭面板后继续 paste / translation 等 P1。`Continue Editing`、`Save and Continue`、`Discard Changes` 的语义在 UI 复审和 P13D 证据中成立。真实 App 点击 / 键盘路径、真实系统剪贴板读写、真实 paste command、真实 VoiceOver 未覆盖，保留为 P2 合理。

需要保留的口径：

- 不得把 dirty guard 三动作写成真实点击路径已通过。
- 不得把 pasteboard write / paste command 写成真实系统端到端已通过。
- 后续新增“关闭面板后继续动作”的调用方，仍必须使用 guarded continuation，并扩展 P13D。

### 3.4 Step 5 隐私 App row

判断：分类基本准确，P2 合理。

Step 5 早期曾有代码审查 P1，包括旧 exclusion migration、CLI typed subject、P13E 假 PASS、真实 App icon provider；最终验收显示 R2/R3 已关闭这些 P1。当前剩余的真实 `/Applications` 三目录实物扫描、真实 icon 截图、hidden / unreadable / damaged app 真实枚举、真实用户数据库 migration、真实 VoiceOver / accessibility inspector，属于真实环境或辅助技术证据缺口。

这不是 P1 的原因：

- Step 5 最终验收和 R2/R3 链路已明确 P0/P1 清零。
- P13E、P13A-D、P11E、P8/P8I、P9A/P9B 与构建/CLI help 提供了低敏功能合同证据。
- 当前 Step 6 边界明确禁止真实系统枚举和真实系统状态变更。

## 4. 是否需要 Step 6 补低敏截图 / 录屏 / 可访问性证据

判断：不建议作为 Step 6 P1 hard gate，但建议作为发布前待办或项目负责人可选的 Step 6 低敏补证据包。

原因：

- 当前 Step 6 任务边界禁止真实 App、真实剪贴板、真实系统枚举和真实系统动作；强行补真实证据会违反本轮边界。
- 现有文档没有把未实测 UI / VoiceOver 写成已通过，因此不存在必须返工的事实错误。
- 但用户原始诉求中包含明显的体感问题，例如 hover 容错、选中反馈延迟、搜索/筛选空间、单/双击显性选择、条目密度、详情编辑可理解性、隐私 App row 信息密度。这些最终对用户是否“感觉完成”很关键，发布前不应完全跳过。

建议口径：

- Step 6 最终接受可以不因这些 P2 阻塞，但最终接受记录必须明确：真实 UI、VoiceOver、窄宽度、长文本和真实手感未完成实测。
- 若项目负责人希望 004 对外声明“体验已整体完成”，应在发布前至少补一组低敏 UI 证据；否则只能声明“功能与低敏门禁已收口，真实体验证据保留发布前待办”。

## 5. 建议发布前体验待办

以下是 UI/交互建议保留的发布前待办，不要求在当前只读复审中执行。

1. 面板 hover 与筛选组手感
   - 低敏录屏覆盖 trigger 到 expanded content 的斜向穿越、brief leave、obvious leave。
   - 验证安全区不拦截搜索框、settings、close、paste activation、clear filter。

2. selected / focused / 单击 / 双击
   - 低敏录屏或 UI evidence 覆盖 first click select/focus、double click paste、selected/focused/hover/active filter 层级。
   - 不能使用真实用户剪贴板内容。

3. 标签 / 收藏
   - 截图覆盖 `+N` chips、长标签、收藏星标、tag-only filter clear-all、右键 `Create "New Tag"`、Settings tag row 错误反馈。
   - Accessibility inspector 或 VoiceOver 低敏记录覆盖 icon-only 操作的 label / hint。

4. 详情编辑
   - 低敏路径覆盖 dirty guard 三动作：`Save and Continue`、`Discard Changes`、`Continue Editing`。
   - 覆盖关闭面板、paste、translation panel、settings 前 close 的 guard 语义。
   - 覆盖编辑区 2 行默认 / 4 行上限、长文本滚动、metadata full value / copy。

5. 隐私 App row
   - 使用 synthetic 或公开低敏 App fixture，覆盖真实 icon / fallback 同尺寸、duplicate bundle confirmation、unsupported reason、failed retry/cancel、partial/loading/no result。
   - 覆盖长 App 名、长 bundle id、长 path summary、窄宽度、三语言长句。

6. VoiceOver / 键盘
   - 覆盖 paste activation、tag menu、detail editor / dirty dialog、privacy app row / policy menu / issue popover。
   - 最低记录 label、value、hint、焦点返回和 Esc 关闭路径。

## 6. Findings

### P0

无。

### P1

无。

本轮未发现体验类 P1 被误降级。产品经理收口文档的 `coverage-ready-for-review` 可以接受。

### P2

1. 真实 UI 手感证据仍不足。
   - 覆盖 hover、selected/focused、单/双击、toolbar 空间、条目密度、长文本和窄宽度。

2. 真实 VoiceOver / accessibility inspector 证据仍不足。
   - 覆盖标签、paste activation、详情编辑、隐私 App row 和 policy control。

3. Step 5 隐私页真实系统清单 / icon 实物证据仍不足。
   - 当前可接受为系统边界下 residual；发布前建议使用低敏公开 App 或 synthetic fixture 截图补证。

4. Step 2 Settings 标签反馈仍是体验优化残余。
   - 不构成 P1，但发布前如有时间，建议优先改善操作反馈与触发行的关联。

5. Step 4 真实继续动作路径仍未实测。
   - 当前 P13D 和静态合同足够接受，但真实点击 / 键盘 / 焦点顺序建议发布前补证。

## 7. 建议项目负责人收敛口径

- 可以接受产品经理 Step 6 覆盖回扫输入，进入后续角色复审收敛。
- 不建议在 004 Step 6 内新增功能返工。
- 如果不补低敏 UI / VoiceOver 证据，最终接受记录应明确这些仍是发布前待办，不应写成已实测完成。
- 若要补证据，应限定为低敏截图 / 录屏 / accessibility inspector 记录，不触发真实剪贴板、真实系统枚举、TCC、provider、Keychain、System Settings、Finder、App launch 或真实系统状态变更。

## 8. 最终结论

`approve`。

Step 6 收口覆盖回扫从 UI/交互角度可接受。P0/P1 为 0；体验类 residual 的分类和口径准确。真实 UI、VoiceOver、窄宽度、长文本和真实手感证据不应被写成已通过，但可以作为发布前待办或项目负责人决定的低敏补证据包，不阻塞当前 Step 6 角色收口复审。
