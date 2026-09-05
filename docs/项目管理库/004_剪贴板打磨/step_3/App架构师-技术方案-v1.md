# Step 3 App 架构师技术方案 v1

日期：2026-07-07
角色：App 架构师
对象：`产品经理-PRD-v1.md`、`项目负责人-技术方案复审收敛-v0.md`
范围：004_剪贴板打磨 Step 3 面板交互与布局打磨
状态：technical-plan-v1

## 1. 结论

Step 3 可以按本 v1 进入项目负责人复核。相对 v0，本版把角色复审收敛出的 P1 全部改写为可交给开发和 P13C 验收的契约：viewport evidence 按 panel position 与真实宽高记录，主激活统一进入 activation coordinator，focused / hover / interaction token 保持 view-local，P13C 使用低敏 manifest fail closed，并补齐事件日志、keyboard / VoiceOver、toolbar fallback、hover 参数、row/card 密度和回归矩阵。

本方案仍只覆盖 Step 3，不重新定义已接受的 Step 1 搜索 / OCR 底座，不修改 Step 2 标签与收藏事实源，不引入 Step 4 详情编辑，也不引入 Step 5 隐私页或 CLI 广义对象管理。

## 2. v1 必须遵守的边界

- 不修改 PRD 正文。
- 不触发真实 App、真实系统剪贴板、provider、Keychain、TCC、系统设置、Show in Finder、restart 或自动化。
- 不把 UI hover、focused、interaction token 写入 `AppState`、`ClipboardRepository`、数据库 schema 或新的持久化事实源。
- 不把 P13C 做成截图生成器、真实 UI 自动化器或真实剪贴板验证器；P13C 只读取仓库内相对路径 evidence manifest、低敏 fixture 和当前代码。
- 不用 Step 3 的 UI 打磨重写 Step 1 的 search document / OCR queue / preview 输出边界。
- 不用 Step 3 的筛选体验重写 Step 2 的 `Tag` / `RecordTag` / favorite built-in identity / 标签事务。

## 3. 当前代码事实与改动落点

v0 已抽样确认当前落点，本版沿用这些事实：

- `ClipboardFloatingPanelView.swift` 当前 header 包含 search、filter strip、spacer、paste activation、clear filters、settings、close；paste activation 当前是 `Menu`。
- `ClipboardFilterBarView.swift` 当前 expanded filter group 主要依赖 hover exit 触发收起，缺少短延迟、re-enter cancel 和 safe bridge。
- `ClipboardRecordViews.swift` 中 side list row 与 bottom tray card 当前有直接把 tap gesture 接到 paste 的路径，selected 与 paste 顺序在 double-click 模式下不稳定。
- `ClipboardPanelSettings.swift` 已有共享设置 key：`clipboard.panel.pasteActivationMode`。
- Step 3 的合理改动面应集中在 `apps/Blocks/BlocksApp/Views/` 下的面板交互 / 布局层、必要的 view-local coordinator / metrics helper，以及 `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`。

不建议在 Step 3 新增 repository、改 search document schema、改 tag store、改 payload access purpose、引入全局 `NSEvent` monitor，或把整块面板改写成 AppKit。

## 4. Viewport Evidence Matrix

P13C 的 viewport evidence 不使用单一抽象断点，必须按 `position` 记录 bottom / side 两套真实面板尺寸。若理论断点在当前面板 min width / min height 下无法复现，记录最接近的实际尺寸和原因，缺失 evidence 不能通过。

### 4.1 Bottom Panel

bottom panel 按实际宽度和高度 bucket 验收，不要求伪造当前面板无法达到的 360-459pt 证据。

推荐 width bucket：

| widthCategory | 口径 | 验收重点 |
| --- | --- | --- |
| `bottom_min_width` | 当前 bottom panel 可稳定复现的最小实际宽度；若代码 min width 为 720pt 左右，则记录实际值 | search 最小宽度、关键 trailing actions、paste activation fallback、clear filter 可达 |
| `bottom_regular_width` | 常规窗口宽度，介于最小宽度与宽屏之间 | search / filter / trailing actions 平衡，普通标签滚动或截断稳定 |
| `bottom_wide_width` | 大屏或接近全宽窗口 | filter group expanded 不遮挡关键动作，bottom tray card spacing 稳定 |

推荐 height bucket：

| heightCategory | 口径 | 验收重点 |
| --- | --- | --- |
| `bottom_compact_height` | 接近当前 bottom tray 最小高度 | row/card 状态不导致外部尺寸跳动，关键按钮仍可达 |
| `bottom_regular_height` | 常规 bottom panel 高度 | hover 展开、filter group、card density 稳定 |
| `bottom_tall_height` | 用户拉高或等价可复现高度 | expanded group、long tag、OCR 状态不破坏布局 |

### 4.2 Side Panel

side panel 按当前 side panel 实际宽度和高度验收，重点覆盖搜索框、筛选组、active filter、trailing actions 的可达性。

推荐 width bucket：

| widthCategory | 口径 | 验收重点 |
| --- | --- | --- |
| `side_min_width` | 当前 side panel 可稳定复现的最小实际宽度；若代码 min width 约 340pt，则记录实际值 | search 可聚焦、active filter 可清除、settings / close 可达 |
| `side_default_width` | 当前默认 side width；若默认约 390pt，则记录实际值 | filter strip 与 trailing actions 不互相遮挡 |
| `side_wide_width` | 用户拉宽或等价可复现宽度 | expanded filter group 与列表 hover/detail 不制造新遮挡 |

推荐 height bucket：

| heightCategory | 口径 | 验收重点 |
| --- | --- | --- |
| `side_compact_height` | 可复现的较矮 side panel | keyboard focus 不陷入 toolbar，列表首项可达 |
| `side_regular_height` | 常规 side panel 高度 | row density、OCR status、favorite/tag chips 稳定 |
| `side_tall_height` | 较高 side panel | 长列表滚动、hover/selected/focused 状态稳定 |

### 4.3 Manifest 字段

每条 viewport evidence 至少包含：

```json
{
  "evidenceID": "p13c-bottom-min-selected-001",
  "step": "004-step3",
  "position": "bottom",
  "widthCategory": "bottom_min_width",
  "heightCategory": "bottom_compact_height",
  "actualWidth": 720,
  "actualHeight": 156,
  "fixtureID": "clip-text-long-tags-001",
  "state": "selected_focused_hover_indexing",
  "artifactPath": "docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/bottom-min-selected.png",
  "closestActualReason": ""
}
```

`artifactPath` 必须为仓库相对路径，文件必须存在。`closestActualReason` 仅在理论断点无法复现时填写，例如当前 bottom panel 最小宽度高于某个旧断点。

## 5. Hover 安全桥

### 5.1 行为参数

首版默认参数：

- `collapseDelay`: 180ms。
- `safeBridgePadding`: 12pt。
- `safeRegionInflation`: 16pt。
- delay 可在实现阶段依据低敏 evidence 微调，但建议保持在 150-250ms。

验收以行为为准：

- 从 trigger 斜向进入 expanded content 不误收。
- 短暂移出 safe region 后 re-enter 会取消 pending collapse。
- 明显离开超过 delay 后可预测收起。
- Esc、失焦、点击选项或显式关闭立即收起。

### 5.2 实现策略

优先使用 SwiftUI overlay / geometry + delayed collapse：

- SwiftUI 持有 expanded group、pending collapse task 和 safe region geometry。
- overlay / safe bridge 必须 `allowsHitTesting(false)` 或等价 hit-test transparent。
- 不遮挡 search、settings、close、paste activation、clear filter 或标签按钮本身。

如果 SwiftUI 方案无法稳定满足 focus loss 或 pointer tracking，可用窄 `NSViewRepresentable`：

- AppKit bridge 只负责面板内 tracking 和 hit-test safe region 判断。
- 不保存筛选事实源，不读剪贴板，不读 repository，不处理标签数据。
- 不引入全局 `NSEvent` monitor。

### 5.3 状态所有权

hover runtime state 必须是 panel view-local 或局部 view model-local。不得进入：

- `AppState`
- `ClipboardStore`
- `ClipboardRepository`
- database schema
- UserDefaults / AppStorage
- 新的跨 feature 全局 coordinator

P13C 需要负向检查 focused / hover runtime state 不出现在 repository、storage、database、AppState 全局事实源中。

## 6. Toolbar / Filter / Paste Activation Fallback

### 6.1 空间优先级

toolbar 在所有 position / width bucket 下遵循固定优先级：

1. 右侧关键动作保持可达：settings、close、clear active filter。
2. paste activation 控件保持当前值可读、互斥关系可理解、可键盘操作。
3. search 保留最小可用宽度，允许 label / placeholder 截断但不能失去可聚焦入口。
4. active filter clear 与 show all / 全部路径优先于普通标签完整展示。
5. 普通标签可横向滚动、截断、折叠到更多入口或只在 expanded layer 中展示。

expanded filter layer 不得覆盖 paste activation、settings、close、clear filter。若空间冲突，收缩普通标签区域，不收缩关键动作。

### 6.2 Paste Activation 控件

面板顶部 paste activation 不再使用 `Menu` / 下拉。默认推荐 compact segmented control，设置页如提供同项也使用同一 key：

```text
clipboard.panel.pasteActivationMode
```

fallback 条件：

- 窄窗口导致 segmented 当前值不可读。
- 本地化文本导致互斥关系不清。
- 控件挤压 search / clear / settings / close。
- VoiceOver 无法读出完整动作语义与当前值。

fallback 形态：

- radio group，或
- 明确互斥的按钮组。

不得退回 `Menu`。视觉短标签可接受，但 accessibility label 必须包含完整动作语义、当前值和互斥关系。

## 7. Activation Coordinator 契约

### 7.1 最小 API

row/card 的主激活不得继续把 `TapGesture(...).onEnded` 直接接到 `onPaste()`。必须进入一个局部 activation handler。命名可调整，但语义至少等价于：

```swift
func onPrimaryActivation(
    recordID: ClipboardRecord.ID,
    source: ClipboardPanelActivationSource,
    trigger: ClipboardPanelActivationTrigger
)
```

推荐枚举：

```swift
enum ClipboardPanelActivationSource {
    case sideRow
    case bottomCard
}

enum ClipboardPanelActivationTrigger {
    case singleClick
    case doubleClick
    case keyboard
}
```

### 7.2 固定处理顺序

handler 内的顺序必须固定：

1. `selectRecord(recordID)`
2. `focusRecord(recordID)`
3. 记录低敏 interaction event
4. 再触发 paste / detail / OCR retry / copy 等耗时或异步动作

double-click 模式：

- first click：只 select / focus / 记录低敏事件。
- double-click：再次 select / focus / 记录低敏事件，然后 paste。

single-click 模式：

- single click：select / focus / 记录低敏事件，然后 paste。

detail open、OCR retry、copy 等路径也必须先经过 select / focus / event，再发起实际动作。

### 7.3 手势替换点

必须替换以下直接路径：

- side list row 主体点击。
- bottom tray card 主体点击。
- 键盘主激活入口。
- OCR retry 可见按钮入口。
- detail open 入口。

允许 context menu 保留自己的菜单展示逻辑，但菜单动作进入 paste/detail/copy 前也要保证 selected / focused 已写入或事件中可证明动作不依赖旧 focused 状态。

### 7.4 Stale Completion Guard

快速点击 A 后 B 的异步完成必须有 interaction token / latest record guard：

- token 属于 panel view-local 或局部 view model-local。
- 每次 primary activation 生成新的 monotonic token。
- async completion 只能在 token 仍为 latest 且 recordID 仍匹配时更新 focused / selected 相关 UI 状态。
- 旧 completion 不得把最终 selected / focused 回写为 A。

## 8. Selected / Focused / Interaction Token 所有权

Step 3 不新增 focused 的全局事实源。

允许保留现有 selected facade 或现有 `floatingSelectedRecordID` 兼容路径，但新增的 focused 与 interaction token 必须保持局部：

| 状态 | 所有权 | 是否可持久化 | 说明 |
| --- | --- | --- | --- |
| selected record | 可沿用现有 selected facade / store 兼容路径 | 不在 Step 3 改变 | 仅用于保持既有面板选择行为 |
| focused record | panel view-local / panel view model-local | 否 | 仅表示当前键盘与交互焦点 |
| hover expanded group | filter view-local | 否 | 不进入 AppState / repository |
| interaction token | panel view-local / panel view model-local | 否 | 仅防 stale async completion |
| interaction event log | 低敏 fixture/evidence 文件 | 否 | 只服务 P13C，不包含 payload/OCR/真实路径 |

低敏 event recorder 只能记录 synthetic id、fixture id、事件名、relative timestamp、boolean/count。禁止记录 payload、preview body、OCR text、真实文件路径、真实 App 名、邮箱、secret、Authorization header 或验证码。

## 9. Row / Card Density 与点击目标

side list row 与 bottom tray card 使用各自 metrics，不强行复用一套尺寸。

必须保持外部尺寸稳定的状态：

- hover
- selected
- focused
- OCR pending / OCR failed / OCR retry visible
- indexing
- excluded
- skipped
- favorite
- long tag / multiple tags
- long source / URL / file name

验收约束：

- 状态变化不得改变 row/card 外部宽高，不得导致列表或 tray 抖动。
- row 主体点击区域和 context menu target 不得低于当前基线。
- 如使用数值底线，主要点击高度不低于约 44pt。
- OCR retry、显式按钮、resize handle、favorite toggle 等小目标在密度调整后仍可达。
- before / after evidence 必须使用同一 fixture、同一 viewport / panel position、同一 locale 或明确记录 locale 差异。

推荐将 metrics 抽成局部 helper，例如 `ClipboardRecordDensityMetrics`，但不强制文件名。关键是 row/card 的外部 frame、status slot、tag chip area、action area 有稳定约束。

## 10. P13C Evidence Manifest

### 10.1 输入边界

P13C 只读取：

- 当前工作区代码。
- 仓库相对路径的 Step 3 evidence manifest。
- manifest 引用的仓库相对路径截图、录屏、事件日志、keyboard checklist、VoiceOver checklist。
- 低敏 fixture 元数据。

P13C 不得：

- 启动真实 App。
- 读取真实剪贴板。
- 生成截图或录屏。
- 调用 provider。
- 访问 Keychain。
- 触发 TCC / 系统权限。
- 打开系统设置。
- 执行 UI 自动化。

### 10.2 Manifest 顶层结构

推荐 manifest：

```json
{
  "schemaVersion": 1,
  "project": "004_剪贴板打磨",
  "step": "step_3",
  "generatedFrom": "manual-or-fixture-evidence",
  "buildOrCommit": "working-tree-or-commit-id",
  "artifactsRoot": "docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c",
  "viewportEvidence": [],
  "interactionEvents": [],
  "keyboardChecklists": [],
  "voiceOverChecklists": [],
  "sanitizer": {
    "forbidAbsolutePaths": true,
    "forbidPayloadBody": true,
    "forbidOCRRawText": true,
    "forbidImageBase64": true
  }
}
```

不得用 `screenshots: 8`、`recordings: 3` 这类计数替代逐条 artifact。每个 artifact 必须绑定 viewport category、panel position、state、fixture id 和文件路径。

### 10.3 Fail-Closed 条件

任一情况出现时 P13C 必须失败：

- manifest 缺失。
- manifest 不属于当前 Step 3。
- artifact path 是绝对路径。
- artifact 文件不存在。
- 使用旧 step 文档或旧验收记录作为 ok evidence。
- viewport evidence 缺 `position`、`widthCategory`、`actualWidth`、`actualHeight`、`fixtureID` 或 `state`。
- 缺 event log、keyboard checklist 或 VoiceOver checklist。
- evidence 中出现真实 home path、真实文件路径、邮箱、secret、Authorization header、验证码、二维码、payload 正文、OCR 原文或图片 base64。
- row/card 代码仍存在主激活直接 paste。
- focused / hover runtime state 出现在 repository、database、AppState 全局事实源或持久化层。
- paste activation 仍使用 `Menu` / 下拉作为主控件。

### 10.4 输出摘要

P13C 输出 JSON 建议包含：

```json
{
  "gate": "P13C",
  "status": "pass",
  "checked": {
    "viewportEvidence": 9,
    "interactionScenarios": 5,
    "keyboardChecklists": 3,
    "voiceOverChecklists": 3,
    "staticGestureChecks": true,
    "stateOwnershipNegativeChecks": true,
    "sanitizerChecks": true
  },
  "failures": []
}
```

失败时列出 fail code、artifact path 和缺失字段，不输出敏感原文。

## 11. Selected / Focused 事件日志

### 11.1 必备场景

P13C 至少读取以下 scenario：

- `single_click_paste`
- `double_click_paste`
- `detail_open`
- `ocr_retry`
- `rapid_click_stale_completion`

允许开发使用等价命名，但必须在 manifest 中映射到上述语义。

### 11.2 单条事件结构

```json
{
  "scenario": "single_click_paste",
  "recordFixtureID": "clip-text-001",
  "recordSyntheticID": "fixture-record-a",
  "seq": 1,
  "t": 0,
  "event": "selected",
  "source": "sideRow"
}
```

字段要求：

- `seq` 单调递增。
- `t` 是相对时间，不是系统绝对时间。
- record id 必须是 synthetic id 或 fixture id。
- `event` 只能是低敏事件名。

### 11.3 判定规则

通过条件：

- 每个 paste / detail / OCR retry 请求前，同一 record 已出现 `selected` 与 `focused`。
- double-click 模式 first click 只有 select / focus，不直接 paste。
- rapid A -> B 场景最终 selected / focused 为 B。
- A 的旧 async completion 不得在 B 后重新写回 A。

失败条件：

- 只有截图，没有事件。
- `pasteRequested` 早于 `selected` 或 `focused`。
- detail / OCR retry 早于 selected / focused。
- 事件中包含 payload、OCR raw text、真实路径、真实 App 名或用户敏感内容。

## 12. Keyboard / VoiceOver Evidence

### 12.1 Checklist 顶层字段

每份 keyboard / VoiceOver checklist 至少包含：

```json
{
  "evidence_id": "p13c-keyboard-side-min-001",
  "date": "2026-07-07",
  "tester": "role-or-thread-name",
  "build_or_commit": "working-tree-or-commit-id",
  "locale": "zh-Hans",
  "viewport_category": "side_min_width",
  "actual_width": 340,
  "actual_height": 720,
  "panel_position": "side",
  "fixture_ids": ["clip-text-001", "clip-image-ocr-001"],
  "artifact_paths": [
    "docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/keyboard-side-min.json"
  ],
  "checks": []
}
```

缺 `tester`、`date`、`build_or_commit`、`locale`、viewport、position、fixture id、逐项 pass/fail 或低敏附件路径时，P13C 不得通过。

### 12.2 Keyboard Checks

至少覆盖：

- search 可获得焦点。
- filter group 可展开 / 收起。
- 全部 / show all 可达。
- 收藏可达。
- 普通标签可达或通过更多入口可达。
- active filter clear 可达。
- record list 可聚焦，selected 与 focused 状态可区分。
- paste activation toggle 可达，互斥关系清楚。
- settings / close 可达。
- OCR retry 在可见时可达。
- detail open 可达。
- 不存在 focus trap。

每项结构：

```json
{
  "id": "keyboard-search-focus",
  "action": "Tab to search field",
  "expected": "Search field receives focus",
  "actual": "Search field receives focus",
  "pass": true,
  "failure_detail": ""
}
```

### 12.3 VoiceOver Checks

至少覆盖：

- search label 可读。
- active filter / all state 可读。
- filter group expanded / collapsed state 可读。
- selected / focused 语义可读。
- favorite 语义可读。
- OCR status 可读，但不读 OCR 原文。
- paste activation mutual exclusion 可读。
- long tag accessibility label 包含完整语义。
- settings / close / clear filter label 可读。

每项必须有 pass/fail；失败项可作为开发修复依据，但不得写入 payload / OCR / 真实路径。

## 13. Toolbar / Filter / Paste Activation Evidence

P13C 的 viewport evidence 需要覆盖以下状态组合：

- no filter / all。
- favorite filter active。
- ordinary tag active。
- long tag label。
- expanded filter group。
- paste activation single-click mode。
- paste activation double-click mode。
- clear filter visible。
- settings / close visible。

最低可用窗口下，允许普通标签减少首屏展示数量，但不允许：

- 丢失 all / show all。
- 丢失 favorite。
- 丢失 active clear。
- expanded layer 遮挡 paste activation / settings / close / clear。
- paste activation 回退到 Menu。
- search 完全不可聚焦。

## 14. P13C Verifier 断言

脚本路径：

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
```

最低职责矩阵：

| 类别 | 断言 |
| --- | --- |
| static gesture | row/card 主激活不再直接 `TapGesture(...).onEnded { onPaste() }` 或等价 paste 直连 |
| activation coordinator | 存在局部 primary activation handler 或等价封装，事件证明 selected/focused 早于 paste/detail/OCR retry |
| state ownership | focused / hover / interaction token 不进入 AppState / repository / database / persistence |
| paste activation | 主控件不是 Menu/dropdown，fallback 不是 Menu/dropdown |
| hover | 存在 delayed collapse、re-enter cancel、safe bridge / safe region 机制或 evidence 证明等价行为 |
| viewport manifest | 每条 viewport evidence 绑定 position、widthCategory、actualWidth、actualHeight、fixtureID、state、相对路径 |
| artifact existence | manifest 引用文件存在，且属于当前 Step 3 |
| event log | 覆盖五类 scenario，seq 单调，relative time，synthetic id |
| keyboard checklist | 必备字段与逐项 pass/fail 完整 |
| VoiceOver checklist | 必备字段与逐项 pass/fail 完整 |
| sanitizer | 无真实路径、home path、邮箱、secret、Authorization、验证码、二维码、payload body、OCR raw text、image base64 |
| fail closed | 缺任一必备 evidence 或检查项即失败 |

P13C 不重新断言 Step 1 搜索/OCR 算法正确性，也不重新断言 Step 2 标签事务正确性；这些由 P13A / P13B 回归承担。

## 15. 回归矩阵

Step 3 实现完成后，最终验收至少串行运行：

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
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

矩阵职责：

- P13C：Step 3 专属 interaction / layout / evidence gate。
- P13A：防止 Step 1 明文搜索、OCR、bounded preview 与低敏输出回归。
- P13B：防止 Step 2 标签与收藏模型、旧 pinned 退出、Search Gate 回归。
- P8 / P8I：防止产品 polish 与 Settings 系统项回归。
- P9A / P9B：防止 repository / AppState integration 回归。
- P11E：防止 clipboard payload hardening 与低敏 read model 边界回归。
- Blocks / BlocksCLI build：防止 App 与 CLI target membership / compile 回归。
- `blocks --help`：防止 CLI 基础入口回归。
- `git diff --check`：防止格式与尾随空白问题。

## 16. 开发拆分建议

顶层 Step 严格串行；Step 3 内可按两个较大批次推进，避免过度拆碎。

### Batch A：P13C baseline + hover / toolbar / paste activation

交付：

- 新增 P13C verifier skeleton 与 fail-closed manifest parser。
- 建立 Step 3 evidence manifest schema 和低敏 fixture 路径。
- 实现 hover delayed collapse / re-enter cancel / safe bridge。
- 改造 paste activation，从 Menu 改为显性互斥控件，并接入 fallback。
- 明确 toolbar 空间优先级与 bottom / side viewport evidence。

验收重点：

- P13C 能在 evidence 缺失时失败。
- hover 不引入全局事件 monitor。
- paste activation 不再是 Menu。
- viewport manifest 字段完整。

### Batch B：activation coordinator + focused/selected + density/accessibility evidence

交付：

- 替换 row/card 直接 paste 手势，接入 primary activation handler。
- selected / focused 先写，并加入 interaction token / latest guard。
- row/card metrics 稳定外部尺寸和点击目标。
- 补齐 selected/focused event log。
- 补齐 keyboard / VoiceOver checklist。
- 串行跑完整回归矩阵。

验收重点：

- 事件证明 selected/focused 早于 paste/detail/OCR retry。
- rapid A -> B 场景旧 completion 不覆盖 B。
- focused / hover / token 不进入全局事实源。
- row/card before-after evidence 同 fixture / 同 viewport / 同 position。

## 17. 风险与复审关注点

P1 风险应在开发前按本方案关闭：

- P13C 如果只检查文件数量或只看截图数量，会放过实际交互顺序错误；必须读取结构化 manifest 和 event log。
- row/card 如果只在视觉上选中而不先写 focused，会继续出现 paste/detail/OCR retry 先于焦点状态的问题。
- hover safe bridge 如果不是 hit-test transparent，会制造新的 toolbar 遮挡或点击失效。
- paste activation 如果用 Menu 变体伪装，会继续违背 PRD 的显性互斥控件要求。

P2 残余风险可在实现复审中二次打磨：

- hover delay / padding / inflation 数值可能需要根据截图或录屏微调。
- 多语言长文案可能触发 paste activation radio/button fallback。
- VoiceOver 文案可能需要 UI/交互二次复审。
- row/card 点击目标的数值底线需要以当前实现基线为准，约 44pt 是建议下限，不替代实测。

## 18. 项目负责人 v1 复核建议

本 v1 已吸收项目负责人收敛文档第 4 节的 must-change，可以进入项目负责人 v1 复核。

建议项目负责人复核时重点看三点：

- 是否接受 P13C 作为 Step 3 的唯一新增专属 gate，并以 fail-closed manifest 作为证据中心。
- 是否接受 focused / hover / interaction token 只做 view-local 状态，不新增全局事实源。
- 是否接受 Step 3 内开发按 Batch A / Batch B 合并推进，最终以完整回归矩阵进入实现验收。
