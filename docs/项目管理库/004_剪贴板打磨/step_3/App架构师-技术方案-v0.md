# Step 3 App 架构师技术方案 v0

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-技术方案派发-v0.md`
范围：面板交互与布局打磨
状态：technical-plan-v0

## 1. 结论

Step 3 可以按“hover 安全桥 + toolbar 空间约束 + selected/focused 先写 + 显性 paste activation 控件 + row/card 稳定密度 + P13C 低敏证据门禁”进入角色复审。

本阶段只承载 Step 1 / Step 2 已接受的状态，不重新定义底层事实源：

- 不修改 Step 1 搜索字段、OCR 队列、OCR lifecycle、输出边界。
- 不修改 Step 2 标签事实源、RecordTag 关系、收藏 built-in identity、标签事务。
- 不实现 Step 4 详情编辑。
- 不实现 Step 5 隐私页真实 App 清单或 CLI 广义对象管理。
- 不触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

## 2. 当前代码落点

只读抽样确认的当前落点：

- `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift`
  - `ClipboardFilterClickGroup` 当前 expanded 后通过 `onHover(false)` 调用 `onExpandedHoverExit()`，没有 delayed collapse / re-enter cancel / safe bridge。
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
  - `header` 由 search bar、filter strip、spacer、paste activation menu、clear filters、settings、close 组成。
  - `pasteActivationModeControl` 当前是 `Menu`。
  - `filterStrip` 是横向 `ScrollView`，bottom 位置有 `frame(maxWidth: 620)`。
  - selected state 使用 `selectedRecordID`，`selectRecord(_:)` 同步写 `clipboardStore.floatingSelectedRecordID`。
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
  - `ClipboardFloatingRecordRow` 与 `ClipboardFloatingRecordCard` 分别承载 side list / bottom tray。
  - row/card 当前使用 `highPriorityGesture(TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() })`，double click 模式普通 tap 才调用 `onSelect()`。
  - OCR、excluded、favorite、tag chips 在 row/card 内可见。
- `apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift`
  - 已有 key：`ClipboardPanelSettings.Keys.pasteActivationMode = "clipboard.panel.pasteActivationMode"`。
  - 已有 bottom tray card 尺寸常量。

这些代码事实说明 Step 3 的改动应集中在面板 UI/interaction 层，不需要触碰 repository、OCR provider、tag repository 或 payload 访问边界。

## 3. 推荐模块边界

命名可由开发按现有目录微调，但职责边界应保持：

```text
apps/Blocks/BlocksApp/Views/ClipboardFilterHoverBridge.swift
- SwiftUI/AppKit narrow hover bridge
- hit-test safe region geometry
- delayed collapse scheduler
- re-enter cancellation
- Escape / focus loss / option click close callbacks

apps/Blocks/BlocksApp/Views/ClipboardPanelToolbarLayout.swift
- toolbar metrics
- viewport category
- search min width / filter max width / trailing action fixed width
- layout decision helpers

apps/Blocks/BlocksApp/Views/ClipboardPasteActivationModeControl.swift
- explicit mutually exclusive control
- segmented compact mode / radio fallback
- shared AppStorage key binding

apps/Blocks/BlocksApp/Views/ClipboardRecordSelectionCoordinator.swift
- selected/focused state write ordering
- low-sensitive interaction event recorder hook
- stale async completion guard

apps/Blocks/BlocksApp/Views/ClipboardRecordDensityMetrics.swift
- side list row metrics
- bottom tray card metrics
- fixed status slot sizes

tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
- Step 3 fail-closed gate
- static checks + evidence manifest checks
```

不建议在 Step 3 做的事：

- 新增 repository。
- 修改 search document / OCR queue。
- 修改 tag store 事实源。
- 引入全局 NSEvent monitor。
- 将整块面板改写成 AppKit。

## 4. Hover 安全桥

### 4.1 平台边界

纯 SwiftUI `onHover(false)` 对“触发区到展开内容区之间的窄缝”和快速斜向移动不够稳定。推荐使用最小 AppKit interop：

- `NSViewRepresentable` 仅负责 pointer tracking / hit-test safe region。
- SwiftUI 仍拥有 expanded group state。
- AppKit bridge 不保存筛选事实源，不读剪贴板，不处理标签数据。
- 不使用全局 event monitor；只在面板内 bridge view 范围内追踪。

如果开发能用 SwiftUI overlay + geometry + delayed collapse 等价实现，也可接受；P13C 检查行为和证据，不强制具体类型名。

### 4.2 首版行为参数

推荐首版参数：

```text
safeBridgePadding: 12 pt
safeRegionInflation: 16 pt
collapseDelay: 180 ms
collapseAnimation: easeOut 160-220 ms
```

参数可以在开发记录中微调，但不得破坏 PRD pass/fail：

- trigger -> expanded content 斜向移动不收起。
- brief leave 后 re-enter 取消收起。
- obvious leave 超过 delay 后收起。
- action close 立即收起。

### 4.3 状态机

```text
collapsed
  -> expanded(group)
  -> collapsePending(group, deadline)
  -> expanded(group) when pointer re-enters trigger/content/safe bridge
  -> collapsed when deadline expires outside safe region
  -> collapsed immediately on option click / group switch / Esc / panel close / window resign key
```

事件规则：

- `enterTrigger(group)`：展开 group，取消同 group pending collapse。
- `enterContent(group)`：保持展开，取消 pending collapse。
- `leaveSafeRegion(group)`：启动 180ms delayed collapse。
- `reenterSafeRegion(group)`：取消 delayed collapse。
- `obviousLeave(group)`：进入 delayed collapse；不需要复杂三角 corridor。
- `selectOption(group)`：立即 collapse。
- `switchGroup(old,new)`：old 立即 collapse，new 展开。
- `escapeOrFocusLoss`：立即 collapse。

### 4.4 Hit-test 与点击穿透

安全桥应只扩大 hover/tracking 区域，不应捕获无关点击：

- bridge overlay 默认 hit-test transparent。
- 只有实际 filter controls/options 接收点击。
- search bar、settings、close、paste activation control 仍可点击。
- 如果 expanded layer 与右侧固定操作重叠，属于 layout fail，不应靠 hit-test 穿透掩盖。

P13C 应检查当前实现不再只通过 `onHover(false)` 即时收起。

## 5. Toolbar 空间优先级

### 5.1 固定优先级

顶部工具区优先级：

1. 右侧关键操作可见、可点、可键盘聚焦。
2. 搜索框保留最小可读宽度。
3. 筛选组在剩余空间展开，必要时内部滚动/截断/更多入口。

右侧关键操作：

- paste activation 显性控件。
- clear filters / show all，当存在 active filter。
- settings。
- close。
- 现有固定在右侧的其他面板操作，如后续代码中存在，纳入同一 trailing action group。

### 5.2 推荐布局结构

推荐拆出 `ClipboardPanelToolbarLayout`：

```text
HStack
- Search region: min width by viewport category
- Filter region: max width by viewport category, horizontal scroll inside
- Spacer min 0/8
- Trailing action group: fixed width or fixed intrinsic width
```

filter expanded content 不应通过无限宽 overlay 推挤 trailing group。filter region 内部可横向滚动、截断或展示更多入口。

### 5.3 窗口矩阵与首版尺寸

推荐首版 viewport 分类：

| 类别 | 面板宽度 | search min | filter max | trailing action |
| --- | --- | --- | --- | --- |
| 宽 | `>= 760pt` | `260pt` | `520pt` | 固定 intrinsic，不被覆盖 |
| 常规 | `600-759pt` | `220pt` | `360pt` | 固定 intrinsic，不被覆盖 |
| 窄 | `460-599pt` | `170pt` | `240pt` | 固定 icon/action 可达 |
| 最小可用 | `360-459pt` | `132pt` | `160pt` 或更多入口 | close/settings/activation 可达 |

如果当前面板最小宽度高于 360pt，开发记录应以实际 min width 覆盖，但仍需四类矩阵。

### 5.4 Pass / fail

Pass：

- filter expanded 时不遮挡 settings / close / paste activation。
- 长查询在搜索框内部处理，不撑破 toolbar。
- active filter clear 在 active 状态下可达。
- bottom panel 与 side panel 均通过矩阵。

Fail：

- filter overlay 覆盖右侧关键操作。
- search 被压到无法辨识当前 query。
- 窄窗口横向撑破面板。
- 展开/收起导致 header 元素大幅跳动。

## 6. Paste Activation 显性控件

### 6.1 面板顶部必须替换 Menu

Step 3 至少替换 `ClipboardFloatingPanelView.pasteActivationModeControl` 当前 `Menu`。不得继续使用下拉 / `Menu` 作为 active 单击 / 双击切换入口。

推荐新增 `ClipboardPasteActivationModeControl`：

```text
@Binding var mode: ClipboardPasteActivationMode
let style: compactSegmented / radioGroup
```

默认：

- 面板顶部使用 compact segmented control。
- label 可短显示 `单击` / `双击`。
- accessibility label 使用完整语义：`单击粘贴` / `双击粘贴`。

当多语言文案过长：

- 不回退下拉。
- 可使用 radio group、按钮组、短视觉标签 + 完整 accessibility label。

### 6.2 持久化 key

面板顶部和设置页如同时提供同一设置，必须共享：

```text
ClipboardPanelSettings.Keys.pasteActivationMode
"clipboard.panel.pasteActivationMode"
```

设置页不是 Step 3 必须新增项；但如果新增，必须和面板顶部绑定同 key，不得出现两个不同状态源。

### 6.3 键盘与 VoiceOver

最低要求：

- Tab 可到达控件。
- Space / Enter 或方向键可切换。
- VoiceOver 读出当前值、选项和互斥关系。
- 当前值常显，不需要打开菜单才能知道。

## 7. Selected / Focused 状态先写

### 7.1 状态层级

- `selectedRecordID`：持久选择状态，优先级高于 hover。
- `focusedRecordID` 或等价焦点状态：键盘焦点，可与 selected 并存。
- `hoveredRecordID`：鼠标临时状态，不覆盖 selected。
- `active filter`：toolbar 状态，不与 record selected 共用语义。

建议新增或明确 `focusedRecordID`，避免只用 selected 表示键盘焦点。

### 7.2 事件顺序

点击或键盘激活 record 时：

```text
pointerDown/tap(recordID)
-> selectRecord(recordID)
-> focusRecord(recordID)
-> start action: paste / detail / OCR retry / copy / hover detail / async request
```

single-click paste：

- on activation 先 `selectRecord` / `focusRecord`。
- 再发起 paste request。
- 如果面板随 paste 关闭，低敏 event log 仍需证明 selection 先写。

double-click paste：

- first click 选择 / 聚焦。
- double click 选择 / 聚焦后发起 paste request。

快速连续点击：

- 使用 monotonically increasing interaction token 或 latest selected ID guard。
- 旧 detail / paste / OCR completion 不得回写覆盖最新 selected。

### 7.3 推荐代码调整方向

当前 row/card 的 `highPriorityGesture(TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() })` 有状态后写风险。推荐把 row/card 行为收敛到一个 activation coordinator：

```text
ClipboardRecordActivationCoordinator
- handlePrimaryClick(recordID, mode)
- handleDoubleClick(recordID)
- handleKeyboardSelect(recordID)
- emit low-sensitive events when enabled
```

实际实现可用 SwiftUI gestures，但必须能证明：

- paste/detail/OCR retry 前已写 selected/focused。
- async completion 不覆盖最新 selected。

### 7.4 低敏事件证据

推荐事件 schema：

```json
{
  "suite": "p13c_clipboard_panel_interaction_layout_checks",
  "events": [
    {"t": 0, "event": "pointerDown", "record": "clip_text_alpha"},
    {"t": 4, "event": "selected", "record": "clip_text_alpha"},
    {"t": 7, "event": "focused", "record": "clip_text_alpha"},
    {"t": 12, "event": "pasteRequested", "record": "clip_text_alpha"}
  ]
}
```

禁止输出 payload、preview body、OCR text、真实路径、真实 bundle 内容。

## 8. Row / Card 密度与尺寸稳定

### 8.1 Side list row

推荐新增 `ClipboardSideListRowMetrics` 或等价 constants：

```text
rowMinHeight: 72 pt
rowHorizontalPadding: 10 pt
rowVerticalPadding: 8 pt
thumbnailSize: 34 pt
titleLineLimit: 1
bodyLineLimit: 2
metadataSlotMinHeight: 18 pt
statusSlotMinWidth: 96 pt
cornerRadius: 10 pt
```

目标：

- 核心内容区域比当前基线更大。
- 点击主体、缩略图和 row contentShape 稳定。
- context menu target 不因 padding 收窄难点。
- OCR / indexing / excluded / skipped 放入固定 metadata/status slot，不改变 row 高度。

### 8.2 Bottom tray card

沿用 `ClipboardBottomTrayLayout`，补齐稳定槽位：

```text
cardWidth: existing user setting, clamped
cardHeight: fixed by tray height, not by content state
headerSlotHeight: 18-22 pt
bodySlot: flexible but lineLimit fixed by cardHeight
metadataSlotHeight: 20 pt
statusSlotMinWidth: 96 pt
thumbnail/image state: bounded slot, no dynamic height
```

目标：

- hover / selected / focused 只改变 tint/border/focus overlay，不改变 card frame。
- OCR failed / retry 不增加 card height。
- indexing / skipped / excluded 使用固定 slot。
- 横向滚动卡片间距稳定。

### 8.3 状态不跳动规则

以下状态不得改变 row/card 外部尺寸：

- hover
- selected
- focused
- OCR pending / running / done / failed / retry
- search indexing / partial indexing
- excluded
- skipped
- favorite
- long tag / many tags

允许变化：

- 文本在固定 lineLimit 内截断。
- 状态文本在固定 slot 内截断或 icon+tooltip。
- VoiceOver/accessibility label 保留完整语义。

## 9. Fixture 与证据

### 9.1 内容 fixture

沿用 PRD 最低集合：

- `txt_alpha_004`
- `url_step3_long_004`
- `rtf_plain_004`
- `file_url_report_004`
- `image_ocr_pending_004`
- `image_ocr_running_004`
- `image_ocr_done_004`
- `image_ocr_failed_004`

压力 fixture：

- `long_text_004`
- `long_url_004`
- `long_file_name_004`
- `long_source_app_004`
- `long_tag_004`
- `many_tags_004`
- `zh_long_004`
- `en_long_004`
- `ja_long_004`
- `search_indexing_004`

这些 fixture 只承载布局和状态，不重新验证 search/OCR/tag 底层算法。

### 9.2 截图 / 录屏矩阵

最低证据：

- Toolbar：宽、常规、窄、最小可用 4 组截图。
- Hover：至少 2 段录屏或事件证据，覆盖斜向移动、短暂移出、明显离开。
- Click feedback：至少 1 段录屏或低敏事件证据，证明 selected/focused 先写。
- Density：side list row 前后对照、bottom tray card 前后对照。
- Keyboard：1 组路径记录。
- VoiceOver：1 组检查记录。

截图/录屏可以由实现验收阶段生成；本技术方案阶段不运行 App。

### 9.3 低敏输出

证据不得包含：

- 真实剪贴板正文。
- 真实 home path。
- 真实文件路径。
- 邮箱。
- secret。
- Authorization header。
- 二维码。
- 验证码。
- OCR 原文。

允许：

- fixture id。
- synthetic record id。
- viewport category。
- state name。
- boolean。
- relative timestamp。
- relative screenshot path。

## 10. 键盘与 VoiceOver

### 10.1 键盘路径

Pass：

- Tab 可到达搜索框、筛选组、清除筛选 / 显示全部、条目列表、paste activation 控件、设置、关闭。
- 筛选组可用 Space / Enter 展开。
- 展开后可到达 `全部`、收藏、普通标签。
- Enter / Space 可选择标签。
- Esc 可关闭展开层。
- 条目列表可用键盘移动 focused / selected。
- paste activation 控件可键盘切换。
- OCR retry 可见时可键盘聚焦和触发。

Fail：

- focus trap 在筛选展开层。
- 无法清除筛选或回到全部。
- focus ring 与 selected / hover / active filter 混淆。
- 可见操作不可键盘聚焦。

### 10.2 VoiceOver

Pass：

- 搜索框读出 label 和 query。
- 筛选组读出 active 标签或 `全部`。
- 展开 / 收起状态、选中标签、清除筛选动作可理解。
- 条目读出 selected / focused、主要内容摘要、标签名、来源 App、时间、OCR 状态。
- favorite 五角星有文本语义。
- paste activation 控件读出当前值、选项和互斥关系。
- 长标签视觉截断时 accessibility label 保留完整标签名。

Fail：

- 颜色、图标或 hover 背景是唯一信息来源。
- selected 和 focused 无语义差异。
- OCR 状态、active filter、favorite 只能视觉猜测。

## 11. P13C 门禁

### 11.1 脚本

新增或等价：

- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`

P13C 可组合静态检查、fixture manifest、低敏事件日志、截图/录屏 manifest。仅靠文字说明不能 pass。

### 11.2 输入

P13C 输入：

- Step 3 PRD v1。
- Step 3 App 架构技术方案 v0。
- 开发记录。
- 当前 Swift 文件。
- fixture manifest。
- evidence manifest，例如 screenshots/recordings/event logs 的相对路径和低敏 metadata。

不读取真实剪贴板，不调用 provider，不触发 Keychain/TCC/系统设置。

### 11.3 最低断言

P13C 最低断言：

1. 当前证据引用 Step 3 PRD v1、技术方案 v0 和当前开发记录；旧草稿只 baseline reference。
2. `ClipboardFilterClickGroup` 或等价 filter UI 不再以即时 `onHover(false)` 作为唯一收起路径。
3. 存在安全桥 / expanded hit-test safe region / delayed collapse / re-enter cancellation / obvious leave collapse 或等价实现。
4. option click、group switch、Esc、panel close、window focus loss 立即收起。
5. filter expanded layer 不覆盖 trailing actions。
6. 面板顶部 paste activation 切换不再使用 `Menu` / 下拉。
7. 如 Settings 提供同一设置，使用 `clipboard.panel.pasteActivationMode`。
8. selected/focused 写入先于 paste/detail/OCR retry/async action 的低敏事件证据存在。
9. 快速连续点击旧 async completion 不覆盖最新 selected。
10. toolbar 有 search min width、filter max width、fixed trailing actions 或等价布局约束。
11. 宽/常规/窄/最小可用 viewport evidence 存在。
12. side list row 与 bottom tray card 分别有 metrics / fixed slots / before-after evidence。
13. hover/selected/focused/OCR/indexing/excluded/skipped 不改变 row/card 外部尺寸。
14. keyboard checklist evidence 存在。
15. VoiceOver checklist evidence 存在。
16. evidence sanitizer 检查无真实剪贴板正文、真实路径、邮箱、secret、Authorization、二维码、验证码、OCR 原文。
17. P13C 不修改或重新定义 Step 1 search/OCR 底层算法。
18. P13C 不修改或重新定义 Step 2 tag fact source。

### 11.4 输出 schema

```json
{
  "ok": true,
  "suite": "p13c_clipboard_panel_interaction_layout_checks",
  "checks": {
    "hover_safe_bridge": true,
    "hover_delayed_collapse": true,
    "paste_activation_menu_removed": true,
    "selected_before_actions": true,
    "toolbar_viewport_matrix": true,
    "row_card_stable_dimensions": true,
    "keyboard_voiceover_evidence": true,
    "low_sensitive_output": true
  },
  "viewport_matrix": {
    "wide": true,
    "regular": true,
    "narrow": true,
    "minimum": true
  },
  "evidence": {
    "screenshots": 8,
    "recordings": 3,
    "event_logs": 1
  },
  "baseline_reference": [],
  "failures": []
}
```

输出只包含 counts、booleans、fixture id、relative paths 和 category；不输出真实内容。

## 12. 回归关系

### 12.1 Step 1 P13A

Step 3 不修改 search document、OCR queue、OCR lifecycle、payload output boundary。实现后应至少运行或引用 Step 1 当前 accepted gate：

- P13A 保持通过。
- OCR pending/running/done/failed/retry 只作为布局承载状态。
- Step 3 的 OCR retry UI 不改变 retry 事务或 OCR 输入边界。

### 12.2 Step 2 P13B

Step 3 不修改 tag facts、RecordTag、favorite built-in、tag repository/store。实现后应至少运行或引用 Step 2 当前 accepted gate：

- P13B 保持通过。
- Step 3 只调整 filter UI 的 hover/布局/active/clear 表达。
- 不引入多标签 OR / AND。
- 不改变 favorite first、single tag filter、tag source。

### 12.3 P8 / P8I

- P8 可吸收 Step 3 panel polish checks：toolbar、density、selected feedback、visible controls。
- P8I 如涉及 settings paste activation control，应检查同 key；若 Step 3 不新增 settings control，P8I 不应阻断。

### 12.4 P9A / P9B

- P9A repository storage smoke 不应因 Step 3 UI 改动变化。
- P9B AppState/Repository integration 应保持 selected/filter facade 不回退到旧事实源。
- 如 Step 3 新增 view-local focused state，不应进入 AppState/Repository 层。

### 12.5 P11E

P11E 仍只作为 output boundary / clipboard hardening baseline。Step 3 低敏事件、截图/录屏 manifest 不得输出 payload、完整路径、OCR 原文或 secret。

## 13. 开发拆分建议

同一 Step 内可适当合并，但建议保留三个开发批次，便于证据收口。

### Batch 1：Hover + Toolbar + Paste Activation

范围：

- `ClipboardFilterHoverBridge` / delayed collapse。
- toolbar layout metrics。
- trailing action group。
- paste activation segmented/radio control。
- P13C baseline red + 第一层 green。

验收：

- hover pass/fail 证据。
- toolbar viewport matrix 初版。
- `Menu` 退出 active 切换。

### Batch 2：Selection / Focus / Density

范围：

- selected/focused state ordering。
- interaction event recorder。
- stale async guard。
- side list row metrics。
- bottom tray card metrics。
- status fixed slots。

验收：

- selected/focused 先写事件证据。
- row/card before-after evidence。
- 状态不跳动。

### Batch 3：Evidence / Accessibility / Regression Gates

范围：

- fixture manifest。
- screenshot/recording manifest。
- keyboard checklist。
- VoiceOver checklist。
- P13C final gate。
- P13A/P13B/P8/P8I/P9/P11E 回归矩阵。

验收：

- P13C PASS。
- 回归 gate 通过或明确 residual。
- `git diff --check`。

## 14. 风险

### P1

1. Hover bridge 过度捕获点击，导致 search/right actions 不可用。缓解：hit-test transparent safe bridge，P13C 检查 right action 可点。
2. selected/focused 仍晚于 paste/detail。缓解：central activation coordinator + event log。
3. toolbar 在窄窗口重叠。缓解：fixed trailing actions + search/filter min/max + viewport matrix。
4. row/card 状态引发尺寸跳动。缓解：固定 slots + external frame 不随状态变化。
5. paste activation panel/settings 双状态源。缓解：同 key `clipboard.panel.pasteActivationMode`。

### P2

1. hover delay 参数需要运行时微调。首版 180ms，可在开发记录调整。
2. 多语言长文案和 VoiceOver 可能需要 UI 复审微调。
3. 截图/录屏证据可能受机器字体/窗口尺寸影响。缓解：记录 viewport category 和 fixture id，不依赖像素完美。
4. 真实 UI/VoiceOver 手工证据仍需实现验收阶段补充；技术方案阶段不运行 App。

## 15. 需要角色复审的问题

UI/交互复审：

- hover delay 180ms、safe padding 12pt、safe inflation 16pt 是否适合作为首版。
- paste activation 顶部控件使用 compact segmented 是否满足中文/英文/日文。
- row/card metrics 是否能兼顾密度和点击目标。

开发复审：

- hover bridge 采用 `NSViewRepresentable` 还是 SwiftUI overlay 等价实现。
- activation coordinator 如何与现有 row/card gestures 最小改动结合。
- toolbar metrics 是否适配当前 bottom/side panel min sizes。
- P13C 如何读取截图/录屏 manifest，而不是直接启动真实 App。

测试/质量复审：

- P13C 静态 + 低敏证据组合是否足够 fail closed。
- viewport matrix 的具体断点是否可稳定复跑。
- selected/focused 事件日志是否足以证明状态先写。
- keyboard / VoiceOver 证据是否需要手工记录模板。

## 16. 开发前通过条件

项目负责人派发开发前建议确认：

- Step 3 不扩大到 Step 1/2/4/5。
- hover 首版参数和可调范围被接受。
- toolbar viewport matrix 和 trailing action 清单被接受。
- paste activation 顶部 `Menu` 必须退出，且同 key 边界被接受。
- P13C 最低断言和低敏证据 schema 被接受。
- 后续实现验收允许使用 fixture screenshot/recording/event log，不要求真实剪贴板证据。
