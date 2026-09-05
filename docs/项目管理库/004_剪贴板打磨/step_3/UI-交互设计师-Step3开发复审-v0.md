# 004_剪贴板打磨 Step 3 UI/交互开发复审 v0

日期：2026-07-07
角色：UI/交互设计师
范围：Step 3 面板交互 / 布局实现复审；只读静态与低敏 verifier 复审，不触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

## 1. 结论

结论：`approve-with-changes`

UI/交互侧未发现 P0。Step 3 的主体方向成立：hover 延迟收起、re-enter cancel、toolbar 固定右侧动作、paste activation 退出 Menu、row/card activation handler、view-local focused/token、row/card density 和 P13C 低敏 evidence 都已形成可复审闭环。

但当前实现仍有 1 个 P1 级 UI/可访问性问题需要在最终接受前关闭或由项目负责人明确降级接受：paste activation 顶部显性控件的视觉/可访问性语义还不够完整，且模式文案仍是中文硬编码而非 String Catalog 本地化。另有若干 P2 残余风险需要写入最终接受记录。

## 2. 复审输入

已读取：

- `AGENTS.md`
- `agents/UI-交互设计师.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/UI-交互设计师-技术方案复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-开发派发-Step3-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/开发记录-Step3-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/项目负责人-Step3开发验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/manifest-v0.json`

重点静态源码：

- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`
- `apps/Blocks/BlocksApp/Support/ClipboardPanelSettings.swift`
- `apps/Blocks/BlocksApp/Resources/Localizable.xcstrings`
- `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`

## 3. 已运行命令

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
git diff --check
```

结果：

- P13C：PASS。`viewportEvidence=9`、`interactionScenarios=5`、`keyboardChecklists=1`、`voiceOverChecklists=1`、`failures=[]`。
- P8：PASS。`failures=[]`。
- `git diff --check`：无输出。

另做只读静态检查：`rg` / `nl` / `git status --short` / `git diff -- ...`，以及只读解析 `Localizable.xcstrings` 的 locale 信息。未启动真实 App。

## 4. 主要 UI 事实依据

### 4.1 Hover 交互

实现侧已有：

- `ClipboardFilterHoverConfiguration.default` 提供 `collapseDelay`、`safeBridgePadding`、`safeRegionInflation`。
- `ClipboardFilterClickGroup` 在展开时增加 transparent background 区域，并通过 `onHover` 分发 enter / exit。
- `ClipboardFloatingPanelView` 持有 `pendingFilterCollapseTask`；离开时 schedule，重新进入时 cancel；点击筛选项、切换筛选组、Esc、关闭时会清理展开状态。
- 未发现全局 `NSEvent.addGlobalMonitorForEvents`。

体验判断：hover 安全桥和 180ms 短延迟的结构目标基本满足，re-enter cancel 与明显离开后收起路径成立。

### 4.2 Toolbar 空间优先级

实现侧已有：

- `ClipboardPanelToolbarMetrics` 按 bottom / side 区分 search min/max、filter max 和 trailing action group 宽度。
- 搜索框、筛选组、固定右侧动作在同一 header 内，右侧动作使用 `fixedSize` 和 min width。
- trailing action group 保留 paste activation、active clear、settings、close。
- P13C manifest 覆盖 bottom / side 共 9 个低敏 viewport evidence。

体验判断：对 bottom / side 场景，右侧关键动作优先级、search 最小宽度和 filter strip 的空间让渡方向符合 PRD。未发现 toolbar 被 filter expanded layer 覆盖的静态证据。

### 4.3 Paste activation

实现侧已有：

- 面板顶部主控件已不再使用 `Menu` / dropdown。
- 通过 `ClipboardPanelSettings.Keys.pasteActivationMode` 复用同一 key。
- 控件使用两个互斥按钮，当前项加 `.isSelected` accessibility trait。

体验判断：结构上比原 Menu 更接近 PRD 的“常显互斥控件”。但当前视觉和可访问性仍有 P1 缺口，见 5.2。

### 4.4 Selected / focused / hover / active filter

实现侧已有：

- `focusedRecordID`、`latestInteractionToken`、`pendingFilterCollapseTask` 均为 view-local state。
- `handleRecordAction` 先 `selectAndFocusRecord`，再记录低敏 event，再触发 paste / copy / OCR retry / remove。
- row / card 通过 selected active surface、focused stroke、hover border 区分状态。
- context menu paste / copy / OCR retry / remove 也进入同一 handler。

体验判断：selected / focused / hover 状态层级和动作前置顺序符合 Step 3 目标。真实 SwiftUI 单击 / 双击事件顺序仍需 P2 实物验证。

### 4.5 Row / card density

实现侧已有：

- side row 设定 `rowMinHeight=86`、metadata/status slot 固定高度/宽度。
- bottom card 使用固定 card width/height，body line limit 随卡片高度和字体调整。
- OCR 状态、标签、favorite、excluded/skipped 等位于 metadata/status slot，降低外部尺寸跳动风险。

体验判断：静态实现满足“密度提高但不牺牲点击目标和状态稳定性”的底线。真实长内容、长标签和多语言布局仍需 P2 实物截图确认。

## 5. Findings

### P0

无。

### P1

#### P1-1 Paste activation 顶部控件的视觉 / 可访问性语义仍需补齐

事实：

- `ClipboardFloatingPanelView.swift` 中 `pasteActivationModeControl` 是两个 icon-only button；选中项显示 `checkmark.circle.fill`，未选中项显示单击 / 双击图标。
- 同一控件用 `mode.menuTitle` 作为 help 和 accessibility label，并通过 `.accessibilityAddTraits(.isSelected)` 表示选中。
- `ClipboardPanelSettings.swift` 中 `title` / `menuTitle` 直接返回 `"单击"`、`"双击"`、`"单击粘贴"`、`"双击粘贴"`，未进入 `Localizable.xcstrings`。当前 String Catalog 存在 `zh-Hans`、`en`、`ja` 三个 locale。

影响：

- PRD 要求 paste activation 当前值常显、单击 / 双击语义清晰、VoiceOver 能读出当前值 / 可选项 / 互斥关系，并覆盖中文、英文、日文长文案。
- 当前 icon-only 控件虽然比 Menu 更显性，但选中项用通用 checkmark 替代具体模式图标，视觉上需要依赖位置和 tooltip 才能判断“当前是单击还是双击”。
- 非中文 locale 或 VoiceOver 场景下，硬编码中文会让顶部关键控件语义不完整。

建议修订输入：

- 将 paste activation 的短视觉标签、完整 help / accessibility label 写入 String Catalog，例如：
  - `clipboard.panel.pasteActivation.single.short`
  - `clipboard.panel.pasteActivation.double.short`
  - `clipboard.panel.pasteActivation.single.accessibility`
  - `clipboard.panel.pasteActivation.double.accessibility`
  - `clipboard.panel.pasteActivation.group.accessibility`
- 选中项不要只显示通用 checkmark。可保留 mode 图标并叠加 selected treatment，或使用短文本 `单击` / `双击`、`Single` / `Double`、`シングル` / `ダブル` 的 compact segmented。
- accessibility 需要包含动作语义和当前状态；至少确保 VoiceOver 可区分两个选项、当前选中项和互斥关系。
- P13C 可补充静态检查：paste activation 文案不得来自硬编码中文；至少校验对应 String Catalog key 存在。

### P2

#### P2-1 Hover safe bridge 参数与开发派发默认值不一致

事实：

- 项目负责人开发派发写明默认参数：`collapse delay 180ms`、`safe bridge padding 12pt`、`safe region inflation 16pt`，允许按 evidence 微调但需要说明。
- 当前实现为 `collapseDelay: 180_000_000`、`safeBridgePadding: 10`、`safeRegionInflation: 8`。
- P13C 当前只检查 `collapseDelay` / `safeBridgePadding` / `safeRegionInflation` / cancel task 等符号存在，不校验具体数值，也未在开发记录中看到参数微调说明。

判断：

- 这不直接证明 hover 体验失败，且 PRD 行为目标已由安全区域和短延迟结构覆盖。
- 但它削弱了“按技术方案 / 派发参数接受”的证据完整性。

建议：

- 开发侧要么对齐 12pt / 16pt，要么在开发记录或最终接受记录中明确说明 10pt / 8pt 的微调理由和低敏证据。
- P13C 建议增加参数范围或精确值检查，避免后续参数无意漂移。

#### P2-2 P13C 是低敏静态 evidence，不等同于真实 UI / VoiceOver 通过

事实：

- `viewport-layout-summary.json` 是 observed controls 摘要，不是真实截图。
- keyboard / VoiceOver artifact 明确写明不启动 live app，只记录 fixture checklist。
- 项目负责人验收记录也已将真实 App UI 自动化截图、VoiceOver 录屏列为残余风险。

判断：

- P13C 足以支撑本轮只读 UI 复审，但不能替代真实面板运行、真实 VoiceOver 或真实窗口尺寸检查。

建议最终接受记录保留：

- bottom / side 至少各 1 张低敏真实 UI 截图或录屏。
- paste activation 当前值、active clear、settings、close 在最小可用宽度可达。
- VoiceOver 能读出 paste activation 当前值 / 选项 / selected 状态、搜索框、filter active/all、selected/focused row、OCR retry、settings/close。

#### P2-3 单击 / 双击 SwiftUI 手势顺序需真实 UI 验证

事实：

- row / card 使用 `highPriorityGesture(TapGesture(count: 2))` + `simultaneousGesture(TapGesture(count: 1))`。
- P13C interaction event log 覆盖 single click、double click、detail、OCR retry、rapid A -> B stale completion，但属于低敏 fixture 事件，不是 App 运行时手势回放。

判断：

- 静态 handler 顺序正确：select/focus/event 先于动作。
- 双击模式下 first click 是否只 select/focus、second click 是否 paste，需要后续真实 UI 或受控 UI 自动化确认。

#### P2-4 长内容 / 多语言布局仍需低敏实物截图

事实：

- 源码有 row/card 固定尺寸、line limit、metadata/status slot 和 tag chip 限制。
- P13C manifest 覆盖长标签、长来源、多语言 fixture id，但 evidence artifact 是摘要而非截图。

建议：

- 最终接受记录保留低敏截图矩阵：bottom narrow / bottom regular / side min / side default，至少包含 long tag、long source app、zh/en/ja long sentence、OCR failed/retry、active filter、favorite。

## 6. 建议回写项

1. 在 Step 3 最终接受前，关闭 P1-1：paste activation 的视觉 selected 语义和 String Catalog 本地化。
2. 在开发记录或最终接受记录中补充 hover safe bridge 参数偏离 12pt / 16pt 的处理：对齐实现，或明确微调理由和验收风险。
3. 在 P13C 后续版本补充两类 fail-closed 检查：
   - hover safe bridge 参数值或允许范围。
   - paste activation 文案必须走 String Catalog，且 accessibility label key 存在。
4. 最终接受记录保留 P2 实物证据缺口，不要把静态 P13C 说成真实 UI / VoiceOver 已通过。

## 7. 是否建议进入最终接受

建议：可以进入项目负责人收敛，但不建议以“UI P0/P1 清零”接受。若项目负责人希望 Step 3 干净关闭，应先处理 P1-1；若因节奏选择降级接受，应在最终接受记录明确该 P1 被有意识降级为后续修复项，并保留 P2 实物证据要求。
