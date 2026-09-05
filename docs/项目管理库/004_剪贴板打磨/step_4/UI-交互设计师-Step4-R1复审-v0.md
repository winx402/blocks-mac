# Step 4 R1 UI/交互设计师复审 v0

状态：`rework-required`
日期：2026-07-07
角色：UI/交互设计师
范围：004_剪贴板打磨 Step 4 R1 / R1a 定向复审

## 1. 结论

结论：`rework-required`。

P0：0。
P1：1，未清零。
P2：若干 residual，可随最终验收或后续 Step 6 回扫保留。

R1 已经明显补上上一轮多项核心体验合同：详情编辑器内的 dirty 三动作确认、record switch guard、overlay close guard、metadata full value 显式读取、OCR user-edited guard、rich text representative fixture 和 P13D fail-closed 证据都有当前实现与低敏 verifier 支撑。

但本轮用户和项目负责人明确要求复核“关闭详情、overlay / 面板关闭等入口是否统一有 guard”。静态源码显示，面板级关闭路径仍可绕过 `ClipboardDetailStore` 的 dirty guard：toolbar close、SwiftUI `.onExitCommand`、presenter 的 Escape、外部点击 dismiss monitor、`ClipboardHistoryPanelPresenter.close()` 都会进入 `onClose()` / `panel.close()`，未先询问 dirty detail editor。这个问题仍属于 Step 4 dirty-navigation 核心合同缺口，不能降为 P2。

## 2. 复审输入

- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发复审收敛-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1a-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4-R1验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`

重点静态源码：

- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Services/ClipboardHistoryPanelPresenter.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`

## 3. 已运行命令

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
git diff --check
```

结果：

- P13D：PASS，`failure_summary.count=0`，`status=pass`。
- P13D 当前证据指向：`docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`。
- P13D `purpose_matrix.negative_reuse_count` 全为 0。
- P13D 保存路径 `pasteboard_read_attempts=0`、`pasteboard_write_attempts=0`。
- `git diff --check`：PASS，无输出。

证据边界：本轮未触发真实 App、真实系统剪贴板、provider、Keychain、TCC、系统设置、Finder、自动化或真实 VoiceOver。

## 4. P1 findings

### P1-1：面板级关闭路径仍绕过 dirty navigation guard

级别：P1
结论：必须修复后再接受 Step 4 R1。

PRD v1 要求 dirty 状态下“切换条目、关闭详情、关闭面板或执行会离开当前编辑上下文的动作”必须使用 `Save and Continue` / `Discard Changes` / `Continue Editing` 三动作阻断式确认，且 Esc / 关闭确认应等价于继续编辑。

R1 当前已经覆盖这些正向路径：

- `ClipboardDetailStore` 增加 `pendingNavigationAction`，`requestOpen(recordID:)`、`requestClose()` 统一进入 `requestNavigation`。
- `ClipboardDetailEditorView` 提供 `confirmationDialog("Unsaved changes")`，包含 `Save and Continue`、`Discard Changes`、`Continue Editing` 三动作。
- 详情页内 close button 调用 `store.requestClose()`。
- record action `editDetail` 调用 `clipboardStore.openDetailEditor(recordID:)`，最终走 `detailStore.open(recordID:)`。
- overlay 点击调用 `clipboardStore.closeDetailEditor()`。

但面板级退出仍未统一走 dirty guard：

- `ClipboardFloatingPanelView` 的 `.onExitCommand` 在没有展开筛选组时直接调用 `onClose()`。
- `ClipboardFloatingPanelView` toolbar close button 直接调用 `onClose()`。
- `ClipboardHistoryPanelPresenter.present` 传入的 `onClose` 是 `self?.panel?.close()`。
- `ClipboardHistoryPanelPresenter.close()` 直接 `panel?.close()`。
- `ClipboardHistoryPanelPresenter` 的 `onEscape` 调用 `self?.close()`。
- `FloatingPanelDismissMonitor` 的 dismiss 回调调用 `self?.close()`。
- `windowWillClose` 只做 frame 保存、monitor stop、`onClosed?()`，没有发现 dirty detail editor guard。

用户可见影响：

- 用户在 detail editor 中改了草稿后，按 Escape、触发面板外部 dismiss、或走面板 close 路径时，可能直接关闭整个剪贴板面板，而不是看到三动作确认。
- 即使 draft 仍暂存在 `AppModel.clipboardStore.detailStore`，用户感知上也已经离开编辑上下文，和 PRD 要求的阻断确认不一致。
- 这会让“关闭详情有 guard”与“关闭面板无 guard”形成交互不一致，用户无法预期哪些离开动作会保护草稿。

P13D 证据缺口：

- `detail_dirty_navigation_004` 当前只检查 `ClipboardDetailStore` / `ClipboardDetailEditorView` / `ClipboardFloatingPanelView` 的静态绑定。
- P13D 覆盖了 `overlay_uses_close_guard` 和 `record_switch_uses_open_guard`，但没有检查 `ClipboardHistoryPanelPresenter` 的 `onEscape`、dismiss monitor、`close()`、`panel.close()` 是否被 dirty guard 包住。
- 因此 P13D PASS 不能证明“面板关闭”合同闭合。

建议修复口径：

- 增加一个面板级 close guard，例如 `requestClosePanel()` / `requestDismissPanel()`，由 presenter 或 `AppModel` 统一协调。
- 所有会关闭整个剪贴板面板的入口都必须进入同一 guard：toolbar close、`.onExitCommand`、Escape、dismiss monitor、open settings 前的 close、外层 `close()`。
- 如果 `clipboardStore.detailStore.isDirty == true`，不得立即 `panel.close()`；应让现有 detail dirty confirmation 出现，并把 pending action 表达为“保存/丢弃后关闭面板”。
- `Continue Editing` 取消面板关闭并保留 draft；`Save and Continue` 保存成功后关闭面板，保存失败停留当前记录；`Discard Changes` 丢弃草稿后关闭面板。
- P13D 或等价低敏 verifier 应新增面板级断言，例如 `panel_close_uses_dirty_guard`、`escape_uses_dirty_guard`、`dismiss_monitor_uses_dirty_guard`、`on_exit_command_uses_dirty_guard`，避免后续再次只验证 overlay / record switch。

## 5. 已关闭或基本可接受项

### Dirty sheet 三动作与布局稳定

`ClipboardDetailEditorView` 已提供 `Save and Continue`、`Discard Changes`、`Continue Editing` 三动作，且取消确认时通过 binding setter 调用 `store.continueEditing()`。编辑区和 action bar 位于稳定 editor 容器内，按钮显隐风险较上一轮明显降低。

残留：action bar 仍是 VStack 内部 HStack，不是真实运行截图证明的 pinned footer；保存中也未看到真实 spinner / 防重复点击的视觉证据。作为 P2 residual，不阻塞当前 P1 修复。

### Metadata full value 入口

`metadataGrid` 已按 short / long 分组；`fullValueAvailable` 时提供 `Show full value` 按钮，调用 `store.fullValueText(item:purpose: .detailFullValueRead)` 和 `store.revealFullValue(item:)`。UI 有反馈 `Full value loaded.` / `Full value unavailable.`，并有 accessibility hint。

该路径不挤压正文编辑区的风险可接受：full value 展开在 metadata item 内，编辑区仍维持 2 到 4 行高度约束。

残留：当前用户可见控件是“Show full value”，不是明确“Copy full value”。P13D 的 copy 证据使用 fake pasteboard / spy，符合低敏边界；如果产品最终要求真实复制完整值，需要后续用显式用户动作和 fake pasteboard 测试补一个独立 UI 控件。当前不作为 P1。

### 编辑区 2 / 4 行、保存/取消与错误反馈

`TextEditor` 使用 `minEditorLines=2`、`maxEditorLines=4` 计算高度，字体固定为 `.body`，不受列表字体设置直接影响。Save / Cancel 位于同一 action bar，URL invalid、rich text fidelity failed、revision conflict、record unavailable、generic save failed 都有可见 validation message。

残留：未运行真实 UI，无法证明长文本、多语言、窄宽度和 VoiceOver 下不会溢出或读序混乱；新增文案仍多为硬编码英文。作为 P2 residual。

### Rich text / URL / OCR 失败状态

URL invalid、rich text fidelity failed、record unavailable、revision conflict 均有用户可理解的短文案；OCR user-edited guard 在 P13D 中覆盖 late completion、retry、second completion 不覆盖用户编辑文本。

残留：`OCR text is not editable` 对 pending / running / failed / succeeded empty 的区分仍偏粗；如果后续要让用户理解 OCR retry 或等待状态，建议在最终 UI polish 或 Step 6 回扫中细化。当前不阻塞 R1。

## 6. P2 residual

- 真实 App / 真实 VoiceOver / 键盘焦点顺序 / 窄宽度 / 多语言长句未实测。
- `ClipboardDetailEditorView` 固定宽度 520，窄窗口降级只靠静态推断，缺低敏截图证据。
- action bar 保存中 / 保存失败的视觉质感仍可打磨，例如 loading、Retry Save 文案和失败后可恢复路径更显性。
- metadata full value 的实际系统复制未实测；当前只认可为显式读取 / 展开 + fake pasteboard 证据。
- 新增 detail editor 文案仍有本地化和 VoiceOver polish 风险。

## 7. 建议最终验收门槛

在 P1-1 修复后，建议项目负责人要求开发补充：

- P13D 增加 presenter / panel close 级别的 dirty guard 静态或低敏 fixture 断言。
- 低敏 evidence 记录四类关闭入口：detail header close、overlay click、record switch、panel close / Escape / outside dismiss。
- 最终接受记录保留真实 UI / VoiceOver / 窄宽度 / 多语言未覆盖边界，不把这些说成已通过。

若 P1-1 修复且 P13D / `git diff --check` 继续 PASS，UI/交互侧可进入下一轮定向复审；在此之前不建议项目负责人接受 Step 4。
