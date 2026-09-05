# UI/交互设计师 - Step 4 开发实现复审 v0

日期：2026-07-07
项目：004_剪贴板打磨
阶段：Step 4 - 详情编辑与元数据组织
角色：UI/交互设计师
复审类型：只读 UI/交互实现复审

## 1. 结论

结论：`rework-required`

P0：0。
P1：2。
P2：5。

Step 4 的数据与仓储方向、bounded detail read model、显式 purpose、单一保存命令、URL validation、rich text fail-closed、OCR user-edited 防覆盖、保存路径不读写系统 pasteboard 等核心边界有低敏自动化证据支撑。`P13D` 和 `git diff --check` 本轮复跑通过。

但从 UI/交互实现看，当前版本仍有两个阻塞最终接受的 P1：

1. dirty-navigation 没有实现 PRD 要求的三动作确认 sheet，且当前 `Discard` 按钮实际仍调用 `cancel()`，静态代码看不到可执行的 discard / continue editing / save and continue 分支。
2. metadata full value read/copy 和短项两列/长项单行/窄宽度单列合同没有接到 UI：View 只展示 bounded metadata 文本，未使用 `fullValueAvailable`、`copyPurpose` 或 `fullValueText()`，也没有 copy full value 的可见控件和反馈。

建议项目负责人要求开发做 R1 返工；P1 清零后再进入 Step 4 最终接受。

## 2. 复审输入

- `AGENTS.md`
- `agents/UI-交互设计师.md`
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-开发派发-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发验收-v0.md`

重点静态源码：

- `apps/Blocks/BlocksApp/Views/ClipboardDetailEditorView.swift`
- `apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift`
- `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`
- `apps/Blocks/BlocksCore/ClipboardDetailReadModel.swift`
- `apps/Blocks/BlocksCore/ClipboardRepository+DetailEdit.swift`
- `tools/verification/p13d_clipboard_detail_edit_checks.py`

## 3. 已运行命令

```bash
python3 - <<'PY'
import json, subprocess
p = subprocess.run(['python3','tools/verification/p13d_clipboard_detail_edit_checks.py'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
print('exit=', p.returncode)
data = json.loads(p.stdout)
print('ok=', data.get('ok'), 'status=', data.get('status'))
print('failure_count=', data.get('failure_summary',{}).get('count'), 'rules=', data.get('failure_summary',{}).get('rule_ids'))
print('scenario_count=', len(data.get('scenarios',[])))
print('call_graph=', data.get('call_graph'))
print('purpose_positive=', data.get('purpose_matrix',{}).get('positive'))
print('purpose_negative=', data.get('purpose_matrix',{}).get('negative_reuse_count'))
print('state_ownership=', data.get('state_ownership'))
PY
```

结果摘要：

- `exit=0`
- `ok=True`
- `status=pass`
- `failure_count=0`
- `scenario_count=29`
- `pasteboard_read_attempts=0`
- `pasteboard_write_attempts=0`
- `save_path_forbidden_token_count=0`
- `async_reindex_enabled=false`
- `detailEditRead/detailFullValueRead/detailEditSave/detailCopyFullValue` positive 存在
- state ownership 全部为 true

```bash
git diff --check
```

结果：PASS，无输出。

未运行真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder、自动化或真实 VoiceOver。未运行 build；项目负责人验收记录已列出 build 和完整回归矩阵通过，本轮 UI 复审只补静态与低敏 verifier 证据。

## 4. P0 Findings

无。

## 5. P1 Findings

### P1-1 dirty-navigation 未实现 PRD 要求的三动作确认 sheet

事实依据：

- PRD v1 要求 dirty 状态下离开编辑上下文时使用阻断式确认 sheet，动作固定为 `Save and Continue`、`Discard Changes`、`Continue Editing`，默认焦点放在安全动作。
- `ClipboardDetailStore.cancel()` 在 dirty 时只设置 `dirtyNavigation = true`、`status = .dirtyNavigation` 和文案 `Discard unsaved changes or save before closing.`。
- `ClipboardDetailEditorView.fixedActionBar` 在 `dirtyNavigation` 下只是把 `Cancel` 按钮文案切成 `Discard`，但按钮 action 仍然是 `store.cancel()`。
- `ClipboardDetailStore.discardDirtyNavigation()` 存在，但静态搜索未发现 View 调用。
- 静态搜索未发现 `Save and Continue`、`Continue Editing`、`Discard Changes` 三个动作入口。
- overlay 背景点击调用 `clipboardStore.detailStore.cancel()`；dirty 时不会出现真正 sheet，也没有可见安全默认焦点。

体验影响：

- 用户没有 PRD 要求的三选一确认路径。
- 当前 `Discard` 文案与实际行为不一致：从代码看它不会 discard，而是再次进入 dirtyNavigation。
- 用户关闭详情、点击遮罩、试图取消 dirty 草稿时会陷入“看起来要丢弃、实际未丢弃”的不清状态。
- `Save and Continue` 失败留在当前记录的合同无法从 UI 层执行。

建议修复：

- 在 dirty 离开时展示真正的 confirmation dialog / sheet。
- 三个动作必须独立绑定：
  - `Continue Editing`：关闭 sheet，保留草稿，焦点回到编辑器或安全位置。
  - `Discard Changes`：destructive，调用 discard 路径，退出编辑或执行原导航。
  - `Save and Continue`：保存成功后执行原动作；保存失败保留草稿并回到 `save-failed`，不导航。
- `Esc`、sheet close、点击外部应等价于 `Continue Editing` 或取消导航。
- R1 需要补静态/低敏证据证明 `discardDirtyNavigation()` 或等价 discard 路径被 View 使用，并且不是复用 `cancel()`。

### P1-2 metadata full value read/copy 与布局合同未接到 UI

事实依据：

- PRD v1 要求 metadata 默认 bounded snapshot，长项至少提供 `copy full value` 或等价完整值路径；tooltip 不能是唯一完整语义路径。
- 技术方案 v1 要求 copy full value 有 `copying`、`copied`、`copy failed` 反馈，并区分 `detailFullValueRead` 与 `detailCopyFullValue`。
- `ClipboardDetailReadModel` 定义了 `fullValueAvailable`、`copyPurpose` 和 `accessibilityLabel`。
- `ClipboardDetailStore.fullValueText()` 存在。
- `ClipboardRepository+DetailEdit.metadataSnapshot` 对长 source 设置了 `fullValueAvailable` 和 `copyPurpose`。
- 但 `ClipboardDetailEditorView.metadataGrid` 只展示 `Text(item.boundedValue)`，未使用 `item.fullValueAvailable`、`item.copyPurpose` 或 `store.fullValueText()`。
- `metadataGrid` 使用 `LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)])`，没有按 `ClipboardMetadataCategory.short/long/conditionalShort` 区分短项两列、长项单行，也没有明确窄宽度单列降级。

体验影响：

- 用户看到长来源、长 URL、长路径或长 OCR 摘要时，没有显式 copy full value 或展开路径。
- 视觉截断后只能选中 bounded 文本，容易误以为复制的是完整值。
- VoiceOver 只读 `item.accessibilityLabel` 的 bounded value，无法表达“这是摘要，可复制完整值”。
- 元数据布局未兑现“短项两列、长项单行、窄宽度单列”的信息结构要求。

建议修复：

- `metadataGrid` 按 category 渲染：
  - short：常规宽度两列。
  - conditionalShort：空间不足或内容过长时降级长项。
  - long：单行/整行展示 bounded value + 显式完整值动作。
  - narrow width：全部单列。
- 对 `fullValueAvailable == true` 的项显示 copy full value 控件。
- copy full value 走独立 `detailCopyFullValue` 或等价 purpose / adapter；低敏验证使用 fake pasteboard，不触发真实系统剪贴板。
- 控件反馈至少覆盖 `copying`、`copied`、`copy failed`。
- accessibility label/hint 区分“显示摘要/截断值”和“复制完整值”。

## 6. P2 Findings

### P2-1 fixed action bar 目前是普通 VStack 尾部行，缺少布局稳定实物证据

`ClipboardDetailEditorView.fixedActionBar` 是主 `VStack` 的最后一行，未看到固定底部容器、保留高度或不同状态下按钮位置的低敏截图/manifest。右侧 Save/Edit 位置大体稳定，但 metadata 数量、validation 文案、多语言长句仍可能推动 action bar 纵向位置。

建议 R1 或最终验收补：view、edit-clean、dirty、invalid、saving、save-failed、record-unavailable 的低敏截图或 snapshot manifest，证明 action bar 高度、右侧主按钮位置、编辑区 2/4 行高度不跳动。

### P2-2 saving / failed 反馈可理解但不够精细

当前状态 pill 能显示 `Saving`、`Save failed`、`Invalid`，validation message 靠近 editor；这是可理解的最低反馈。但 Save 按钮在 `saveFailed` 下仍显示 `Save`，没有 `Retry Save`；`saving` 下没有可见 spinner，仅状态 pill 变成 `Saving`。这不是本轮 P1，但会影响事务状态的质感。

建议：保存中 Save 显示 loading 或 progress 指示；save failed 状态下主动作文案改为 `Retry Save` 或等价本地化文案。

### P2-3 非可编辑 OCR failed / pending / running 的详情动作不足

Repository 对 image OCR 只有 succeeded 且非空时可编辑，否则返回 `OCR text is not editable`。View 可显示 read-only 状态与原因，但详情 action bar 未提供 OCR retry 或更具体的 pending/running/failed/succeeded empty 状态动作。列表/右键仍有 retry，但详情页语义不完整。

建议：详情页 read-only 状态区按 OCR 状态展示 `Waiting for OCR`、`Recognizing text`、`OCR failed`、`No text recognized`，OCR failed 时在 action bar 提供 Retry OCR 或说明需从列表重试。

### P2-4 键盘与 VoiceOver 静态实现只覆盖基础 label，未覆盖默认焦点与完整语义

已有基础：

- `ClipboardDetailEditorView` 有整体 accessibility label。
- metadata item 有 accessibility label。
- Save 有 `Command-Return` shortcut。
- 按钮使用 `Label`。

缺口：

- 未看到 dirty sheet 默认焦点，因为 sheet 未实现。
- `TextEditor` 没有明确 accessibility label/hint。
- metadata full value/copy 缺失，导致对应 keyboard/VoiceOver 路径缺失。
- 未看到低敏 keyboard/accessibility manifest 证明 Edit、编辑区、Save、Cancel、metadata copy、OCR 状态可达。

这些缺口在 P1 修复后应重新验收；真实 VoiceOver 仍可作为 Step 6 或专项 P2 residual。

### P2-5 新增 Step 4 UI 文案目前为硬编码英文，未接入 String Catalog

`ClipboardDetailEditorView` 与 `ClipboardDetailStore` 中新增用户可见文案包括 `Edit`、`Save`、`Cancel`、`Ready`、`Unsaved`、`Invalid`、`Record unavailable.`、`Rich text fidelity check failed. No content was saved.` 等，当前是硬编码英文。若项目当前允许英文首版，这可以作为 P2；但 Step 4 多语言长句/可访问性验收不能把本地化说成已闭合。

建议：R1 或 Step 6 收口时把 Step 4 新文案迁入 String Catalog，并覆盖中文、英文、日文长句低敏样例。

### P2-6 详情编辑面固定宽度 520，窄宽度降级未被真实验证

当前 detail editor `.frame(width: 520)`，在面板窄宽度或侧边布局下是否会裁切、溢出或遮挡 toolbar，只能从静态代码推断，不能确认已通过。metadata 使用 adaptive grid 不等同于 PRD 的窄宽度单列规则。

建议：R1 或最终验收补 bottom / side 场景下低敏截图，覆盖长 URL、长来源、中文/英文/日文长句和长标签。

### P2-7 P13D 对 UI contract 的覆盖偏结构存在性，不足以替代 UI 复审

本轮 P13D PASS，但静态阅读发现：

- `detail_dirty_navigation_004` 没有证明三动作 sheet 真正存在和可执行。
- `detail_full_value_copy_fake_pasteboard_004` 没有证明 View 提供 copy full value 控件。
- `metadataGrid` 只作为字符串存在被检查，未验证 category layout。

建议：R1 后增强 P13D 或新增轻量 UI static verifier，检查 dirty-navigation 三动作文案/方法绑定、metadata full value action 绑定、category-aware layout，而不仅是类名或方法名存在。

## 7. 已满足的体验合同

- 详情编辑入口没有混入 hover detail。`ClipboardFloatingPanelView` 中 hover 仍走 `.detailOpen`，编辑详情走 `.editDetail` 并打开 `detailStore.open(recordID:)`。
- 默认阅读态存在。`ClipboardDetailStore.load` 对可编辑记录设置 `status = .view`，`ClipboardDetailEditorView` 只在可编辑且非 editing 时显示 `Edit`。
- 编辑区 2/4 行约束存在。`minEditorLines = 2`、`maxEditorLines = 4`，`TextEditor` 用 `.font(.body)`，不直接受列表条目字体设置影响。
- URL invalid 有 inline validation 文案，保存前阻止 mutation。
- rich text fidelity failed 有明确保存失败文案，不静默降级。
- 保存路径通过 `ClipboardDetailStore.save()` -> `ClipboardRepository.saveDetailEdit(command:)`，P13D 证明 save path pasteboard read/write 为 0。
- OCR user-edited 保存和 late completion 防覆盖在仓储/队列方向上有低敏证据；UI 只需补状态表达。

## 8. 未覆盖风险

- 未运行真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder、自动化或真实 VoiceOver。
- 未做真实 UI 截图/录屏，因此窄宽度、遮挡、焦点环、真实 VoiceOver 朗读、真实多语言排版仍未实测。
- 未运行 build；本轮只复跑 P13D 和 `git diff --check`。项目负责人验收记录中的 build PASS 可作为已有外部输入，但不是本轮独立复跑证据。
- 当前 step_4 相关实现文件在 `git status --short` 中仍显示为未跟踪状态；本复审不归因、不回滚，只按最新工作区内容评审。

## 9. 建议项目负责人决策

不建议按当前实现进入 Step 4 最终接受。建议要求开发 R1，至少修复：

1. dirty-navigation 三动作确认 sheet 及其真实 View/Store 绑定。
2. metadata full value read/copy 控件、反馈、accessibility label/hint 和 category-aware layout。

R1 后建议只做定向复审，不需要重新打开 Step 5/6，也不需要真实系统动作。定向复审重点看上述两个 P1 是否清零，并复跑 P13D / `git diff --check`，必要时补一个 UI static verifier。
