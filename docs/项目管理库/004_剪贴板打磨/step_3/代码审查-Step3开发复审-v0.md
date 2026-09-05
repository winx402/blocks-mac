# Step 3 代码审查开发复审 v0

状态：rework-required
日期：2026-07-07
角色：代码审查
对象：`004_剪贴板打磨` Step 3 开发实现

## 1. 结论

`rework-required`

本次只读复审覆盖 Step 3 面板交互与布局打磨实现，没有进入 Step 4，也没有触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

当前实现主体方向基本符合 Step 3：paste activation 已退出顶部 `Menu`，row/card 主激活进入面板级 handler，`focusedRecordID` / `latestInteractionToken` / filter hover task 保持在 `ClipboardFloatingPanelView` view-local；P13A / P13B / P8 / P9B / P11E 回归命令通过。

但存在一个 P1：P13C 宣称 `detail_open` 已通过，而当前代码没有 detail action 进入 activation handler；实际 hover detail 仍绕过 handler，在 detail card `.onAppear` 直接读取 `.hoverDetail` payload。因此“detail 前 selected / focused / interaction token 先写”的 Step 3 契约没有被当前实现或 P13C 证明，P13C 对该项属于假 PASS。

## 2. Findings

### P1 - `detail_open` 只有 manifest 自述，实际 detail/hover detail 路径绕过 activation handler

文件：

- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:22`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift:706`
- `apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift:558`
- `apps/Blocks/BlocksApp/Views/ClipboardHoverDetailLayer.swift:617`
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py:57`
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py:238`
- `docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/manifest-v0.json:171`

派发与技术方案要求 P13C 至少验证 `detail_open`，且 `selected` / `focused` 必须早于 `detailRequested`。当前实现中 `ClipboardPanelActionKind` 只有 `selectOnly` / `paste` / `copyPlainText` / `ocrRetry` / `remove`，`handleRecordAction(...)` 也没有 detail 分支；也就是说没有实际 detail action 会经过 `selectAndFocusRecord(...)`、`nextInteractionToken()` 和 `recordPanelInteractionEvent(...)` 后再触发。

同时，实际 hover detail 仍由 `ClipboardFloatingDetailCard.onAppear` / `onChange(record.id)` 调用 `loadHoverPayload()`，并在 `loadHoverPayload()` 内直接执行 `clipboardStore.readPayload(recordID: record.id, purpose: .hoverDetail)`。这条路径没有经过 `handleRecordAction(...)`，也不会先写 `focusedRecordID` 或 interaction token。

P13C 当前只从 manifest 读取 `detail_open` / `detailRequested` 事件并校验事件顺序，没有静态校验代码中存在 detail action 或 hover detail 由 handler 驱动。因此脚本能输出 `interactionScenarios=5` 和 `ok=true`，但这个 PASS 不能支撑当前代码满足 detail 契约。

建议修复：

- 如果 hover detail 属于 Step 3 的 detail load，需把 hover/detail open 路径也接入局部 activation/detail handler，先写 selected、focused 和 token，再读 detail payload 或打开 detail surface。
- 如果 hover detail 明确不属于 `detail_open`，则需要由项目负责人/产品/架构收敛口径，移除或改写 `detail_open` 验收项；P13C 和 manifest 不能继续声称 `detailRequested` 已覆盖。
- P13C 应增加代码级 fail-closed 检查，例如要求存在 `.detailOpen` / `detailRequested` 等价 action，并且该 action 在 handler 中先执行 select/focus/token，再调用实际 detail load。

### P2 - hover safe bridge 没有显式 hit-test 透明约束，P13C 也未验证点击遮挡风险

文件：

- `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift:72`
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py:314`

`ClipboardFilterClickGroup` 在 expanded 状态下通过 `Color.clear` background 叠加负 padding 形成 safe bridge / safe region，但没有 `.allowsHitTesting(false)` 或等价注释/结构来证明该区域不会捕获搜索框、trailing actions 或列表点击。PRD 和技术方案要求 safe bridge 不遮挡 search、settings、close、paste activation 和 clear filter。

当前 P13C 只检查源码中出现 `collapseDelay`、`safeBridgePadding`、`safeRegionInflation`、`pendingFilterCollapseTask`、`cancelPendingFilterCollapse` 这些 token，没有验证 safe bridge 是否 hit-test transparent，也没有验证该负 padding 区域不会扩大点击遮挡。

建议修复：

- 用明确的 geometry / tracking 方案区分 hover safe region 和点击命中区域，或在可安全的位置加 `.allowsHitTesting(false)` 并通过其他 tracking 机制维持 hover 容错。
- P13C 增加 fail-closed 断言：safe bridge / overlay 必须有点击透明实现或等价证明，不能只看 token。

### P2 - P13C 的 direct paste 静态检查过于字面化

文件：

- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py:318`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift:360`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift:488`

当前 row/card 手势已从旧的 `TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() }` 改成 `onPrimaryActivation(...)`，实现本身没有看到旧 direct paste 回流。

但 P13C 只负向匹配一个旧源码字面量：`TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() }`。如果未来代码以 `TapGesture(count: 2).onEnded { onPaste() }`、换行闭包、`performPaste()` 包装或其他等价直连方式回流，该检查仍会 PASS。这不符合派发中“row/card direct paste must fail closed”的门禁要求。

建议修复：P13C 应扩大为结构化或更稳健的静态扫描，例如在 row/card body 范围内禁止 `onPaste()`、`pasteClipboardRecord`、`.paste` 直连绕过 `onPrimaryActivation` / `handleRecordAction`，并保留当前正向 handler 检查。

## 3. 重点复核结论

- Activation handler：paste / OCR retry / copy / remove 的 context menu 与 row/card 主体路径基本满足“先 select/focus/token，再执行动作”；detail 路径未闭合，见 P1。
- `focusedRecordID` / `latestInteractionToken` / hover state：当前命中集中在 `ClipboardFloatingPanelView.swift`，未发现进入 AppState / Store / Repository / schema / persistence。
- hover delayed collapse / re-enter cancel：`pendingFilterCollapseTask`、`scheduleExpandedFilterCollapse`、`cancelPendingFilterCollapse` 存在；点击透明和实际遮挡风险未被实现或 P13C 充分证明，见 P2。
- paste activation：顶部主控件已退出 `Menu` / dropdown，并使用 `ClipboardPanelSettings.Keys.pasteActivationMode` / `clipboard.panel.pasteActivationMode`。
- row/card density：`ClipboardRecordDensityMetrics`、row min height、card fixed width/height、metadata/status slot 存在；未做真实 UI 截图/运行时点击验证。
- Step 1 / Step 2 回归：P13A、P13B、P8、P9B、P11E 均通过；本次未发现明显改写搜索/OCR底座或标签事实源的行为回流。

## 4. 已运行命令

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
git diff --check
rg -n "focusedRecordID|latestInteractionToken|pendingFilterCollapseTask|panelInteractionEvents|ClipboardPanelInteractionEvent|ClipboardFilterHoverConfiguration|NSEvent\\.addGlobalMonitorForEvents|NSEvent\\.addLocalMonitorForEvents|TapGesture\\(count: pasteActivationMode\\.tapCount\\)|onPaste\\(\\)" apps/Blocks tools/verification docs/项目管理库/004_剪贴板打磨/step_3
rg -n "detailRequested|detail_open|case detail|handleRecordAction\\([^\\n]+detail|ClipboardPanelActionKind" apps/Blocks/BlocksApp/Views tools/verification/p13c_clipboard_panel_interaction_layout_checks.py docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/manifest-v0.json
```

命令结果摘要：

- P13C：`ok=true`、`interactionScenarios=5`、`viewportEvidence=9`、`keyboardChecklists=1`、`voiceOverChecklists=1`。审查判断：该 PASS 未覆盖 P1 所述实际 detail code path。
- P8：`ok=true`，Step 2 clear-all 当前事实源迁移通过。
- P13A：`ok=true`。
- P13B：`ok=true`。
- P11E：`ok=true`。
- P9B：`ok=true`。
- `git diff --check`：通过，无 whitespace error。

未运行：

- 未运行真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。
- 未运行 xcodebuild；项目负责人验收记录显示 App / CLI build 已独立通过。本轮因已有 P1 阻断，代码审查未重复构建。
- 未运行 P9A smoke；项目负责人验收记录显示已独立通过。本轮重点放在 Step 3 interaction/layout 与 P13C。

## 5. Residual Risk

- SwiftUI 单击 / 双击 gesture 的真实事件顺序仍未由本审查线程运行时验证。当前静态实现比旧 direct paste 路径收敛，但仍需要后续低敏 UI 或测试/质量路径确认 double-click 模式下单击事件不会造成意外重复 paste。
- P13C evidence manifest 是静态 fixture / 自述事件，不是真实 UI 自动化截图、录屏或 VoiceOver 运行证据。
- `ClipboardPasteActivationMode.title/menuTitle` 仍是硬编码中文；本轮未将其列为阻断，但若 Step 3 要严守中/英/日多语言控件文案验收，应由 UI/交互或产品决定是否纳入返工。
