# Step 4C-4 Clipboard hardening Go/No-Go App 架构评估 v0

评估日期：2026-07-06
评估角色：App 架构师
结论：`split-to-step4d`

## 1. 总体判断

建议不要把 conditional Step 4C-4 Clipboard hardening 继续留在 Step 4C 开发。Step 4C core 已在干净基线 `10d7766 feat: complete step 4c settings shell slice` 完成；4C-4 要满足 PRD 的“默认列表 / 普通面板 / Settings summary / CLI 默认输出不读取完整 payload”，需要重切 Clipboard read model、Store API、AppState facade、列表/hover/paste/copy/translation 调用点、降级 UX 和 P11E 门禁。这个范围已经超过 Step 4C core 的收口尾项，更适合作为 Step 4D 独立切片。

本轮不是说 Clipboard hardening 不该做；结论是它不应在当前 Step 4C core 完成后继续作为 4C 尾项派开发。主 agent 应写 Step 4D handoff record，并把 read model / allowlist / P11E / 安全与测试矩阵补成开发可执行方案后再派发。

## 2. 事实依据

- 工作区核对：`git status --short` 无输出，HEAD 为 `10d7766 feat: complete step 4c settings shell slice`。
- Step 4C-3 stop/go 明确：Step 4C-4 尚未启动；若 P11E、payload allowlist / denylist、UX contract、安全/质量门禁无法闭合，应拆 Step 4D。
- PRD 对 4C-4 的要求包括：`repositoryUnavailable` 用户可见降级；默认列表 metadata-first / redacted；完整 payload 只允许 paste、copy、hover detail、translation preview；P11E 必须输出 read model allowlist / denylist 摘要。
- 当前 `tools/verification/` 下不存在 `p11e_clipboard_hardening_checks.py`。
- `ClipboardStore.loadRepositoryState(limit:)` 在加载 recent records 后立即执行 `payloads = try loadPayloads(for: recentRecords, repository: repository)`，`loadPayloads` 循环 `repository.readPayload(recordID:)`，即默认加载阶段会预取完整 payload。
- `ClipboardStore.preview(for:)` 和 `filteredRecords(query:)` 当前依赖 `payloads` 字典，说明 payload 已参与普通预览和筛选路径。
- `ClipboardFloatingPanelView` 在底部卡片、侧边列表和 hover overlay 中直接把 `appState.clipboardPayload(for: record.id)` 传入 `ClipboardFloatingRecordCard`、`ClipboardFloatingRecordRow`、`ClipboardHoverDetailItem`。其中卡片/行是普通列表渲染路径，不是仅 hover detail。
- `ClipboardRecordPreview.preview(payload:)` 在 text/richText/url/fileURL/image 上会使用 payload 文本、URL 或图片生成 preview；普通列表依赖 `preview.title` / `preview.body`。
- `ClipboardLiveCaptureService` 为 fileURL、URL、richText、text 生成 record `summary` 时使用 `shortPreview(...)`，`shortPreview` 最多保留 96 字符正文片段。因此 Step 4D 不能只把 payload 延迟读取，还必须定义 `summary` 是否可用于默认 redacted list。
- `apps/Blocks/BlocksCLI/main.swift` 当前未暴露 clipboard 默认输出路径；CLI 侧目前应作为“继续禁止开启完整 payload 默认输出”的门禁项。
- 现有 `p8_clipboard_product_polish_checks.py`、`p8i_settings_clipboard_system_checks.py`、`p9a_clipboard_repository_storage_smoke.py`、`p9b_clipboard_appstate_repository_integration_checks.py`、`p9c_no_reset_fixtures_ui_checks.py` 不覆盖 P11E 所需的默认 read model allowlist / denylist。

## 3. Go/No-Go 结论

### 4C-4 是否适合留在 Step 4C

不适合。原因：

1. 当前问题不是单点修复，而是默认读取模型迁移：repository load、store cache、preview/search、AppState facade、panel render、hover detail、copy/paste/translation 均在同一敏感边界内。
2. `summary` 也可能包含正文片段；如果只禁止 `readPayload`，仍可能无法满足 redacted list 的产品和隐私目标。
3. P11E 尚不存在，现有 P8/P9 门禁也不会 fail closed 地捕捉默认列表 payload 读取。
4. Step 4C core 已完成并提交；继续追加敏感 payload 改动会扩大最终接受范围，使 Step 4C core closeout 和 Clipboard hardening 验收边界混在一起。

建议：拆为 Step 4D。Step 4C 最终接受记录应明确 Clipboard hardening 未完成、未验收、未被 P11E 覆盖。

## 4. P0/P1/P2

### P0

无。当前评估未发现必须立即中止仓库使用的新增 P0；本轮未运行 App、未触发剪贴板读取、未触发系统权限或 provider call。

### P1

1. 对“留在 Step 4C 并立即派开发”而言，read model 方案不足。必须先定义 metadata/redacted list item、explicit payload read API、allowlist reason、payload cache 生命周期和 `summary` 的敏感级别，否则开发很容易只移除一处 `readPayload`，但普通 UI 仍通过 summary 或 preview 暴露正文。
2. 当前默认加载和普通面板渲染都能接触完整 payload：`ClipboardStore.loadRepositoryState` 预取 payload，`ClipboardFloatingPanelView` 普通卡片/行传入 payload。这与 PRD 默认列表禁止完整 payload 的目标直接冲突，改动面需要独立阶段承接。
3. P11E 不存在，且最低职责矩阵尚未落到可执行脚本。没有 P11E，无法在开发前承诺 fail-closed 地守住 read model、日志/验证输出和 allowlist/denylist。
4. `repositoryUnavailable` / empty / unavailable / filtered / redacted 四类状态的具体 UI 承载点仍未形成开发级方案。PRD 已给目标，但还缺“Clipboard 面板哪里显示、Settings 是否显示、哪些状态来自 Store”的结构定义。

### P2

1. CLI 当前没有 clipboard 默认输出，风险较低；但 Step 4D P11E 仍应把“未新增 clipboard 默认 payload 输出”纳入 denylist。
2. 若 Step 4D 引入新的 read model 类型或 helper 文件，需要同步 Xcode target membership 和 P11E target 检查。
3. 现有搜索体验可能依赖 payload/summary 内容。Step 4D 需要明确默认列表 redacted 后，搜索仍允许查 repository FTS 结果但不能在结果列表显示正文，还是将搜索限制为 metadata。该点偏产品/体验取舍，但会影响架构 API。

## 5. 如果主 agent 仍决定留在 Step 4C，最小可维护实现边界

不建议留在 Step 4C；若主 agent 出于项目管理原因仍决定继续，进入开发前至少必须补齐以下边界，并把它们写入 4C-4 开发任务：

### Store / Repository

- `ClipboardStore.loadRepositoryState(limit:)` 默认只加载 records、pinboards、pinned metadata，不调用 `repository.readPayload(recordID:)`。
- 新增显式读取入口，例如 `readPayload(recordID:reason:)` 或等价 closure，`reason` 必须是枚举 allowlist：`paste`、`copyPlainText`、`hoverDetail`、`translationPreview`。
- Store 需要区分 `metadataRecords` / `redactedPreview` / `payloadCache`。payload cache 不得被默认列表渲染读取；cache 生命周期需明确，至少不得因为 load/reload 填满所有 recent payload。
- `repositoryUnavailable` 必须从 store 暴露为可渲染 degraded state，并区分 empty、unavailable、filtered、redacted。
- 对 `record.summary` 的处理必须明确：默认 redacted list 不应直接展示由 `shortPreview` 生成的正文片段；可展示 kind、source、timestamp、pin state、format length、byte count、file/url count 等低敏 metadata。

### AppState facade / Coordinator

- `clipboardPayload(for:)` 不应继续作为无 reason 的通用 facade；应替换或收窄为 explicit payload read facade。
- paste/copy/translation preview 通过 AppState/coordinator 调用 explicit read；普通 panel list 只拿 redacted display model。
- hover detail 是 allowlist，但必须与普通 hover tracking/list render 分离：只有 detail active 后读取，不在 overlay item dictionary 构建时为所有 filtered records 读取 payload。

### View / Read Model

- `ClipboardFloatingRecordCard` / `ClipboardFloatingRecordRow` 的默认参数不再包含 `ClipboardRecorderPayload?`。
- 普通 list/card 使用 `ClipboardRecordListItem` 或等价 redacted display model。
- `ClipboardHoverDetailItem` 可以包含懒加载状态或 payload 读取结果，但不得在普通 `ForEach(filteredRecords)` 构建时同步读取所有 payload。
- `ClipboardRecordPreview.preview(payload:)` 可保留给 explicit detail/paste/copy/translation 路径；默认列表应使用不接收 payload 的 redacted preview builder。

### Settings / Degraded UX

- Clipboard 面板和/或 Settings pane 必须显示 repository unavailable/storage degraded，并能区分 empty、unavailable、filtered、redacted。
- Settings summary 不得调用完整 payload，也不得显示正文、图片 base64、OCR 文本或完整文件路径。

### CLI

- 不新增 clipboard 默认 payload 输出。
- 若新增 clipboard CLI，只能默认输出 metadata/redacted；完整 payload 读取必须另有显式命令、显式确认和后续 PRD/门禁，不属于当前 4C-4。

### Target membership

- 若新增 `ClipboardReadModel.swift`、`ClipboardPayloadAccess.swift`、`ClipboardDegradedState.swift` 或类似文件，必须进入 Blocks app target。
- P11E 必须解析 Xcode project，缺 target membership 时 fail closed。

## 6. P11E 架构门禁最低职责矩阵

P11E 必须是 fail-closed 脚本，不应只输出 PASS/FAIL。最低职责：

1. **当前事实源**：输出 current evidence path，包括 Step 4D/4C-4 PRD、开发记录、验收记录、当前代码路径；旧 story/archive/acceptance 只能作为 `baseline_reference`，不得参与 `ok`。
2. **文件与 target membership**：检查 `ClipboardStore`、AppState、Clipboard panel views、record preview/read model 文件、Settings Clipboard pane、BlocksCLI、Xcode project；新增 Swift read model 文件必须在 Blocks app target。
3. **默认加载 denylist**：禁止 `loadRepositoryState` 或普通 reload 路径调用 `loadPayloads` / `repository.readPayload` / 填满 `payloads`；若存在 payload cache，必须证明只由 explicit read API 写入。
4. **普通渲染 denylist**：默认列表、普通面板卡片/行、Settings summary、CLI 默认输出不得传入或读取 `ClipboardRecorderPayload`，不得调用 `clipboardPayload(for:)` 或无 reason payload facade。
5. **allowlist**：只允许 paste、copy/plain text、hover detail、translation preview 通过 explicit read reason 读取完整 payload；新增 reason 必须先更新 PRD 和 P11E allowlist。
6. **summary/redaction**：默认 redacted preview builder 不得直接展示 `record.summary` 中可能来自 `shortPreview` 的正文片段；必须使用 format metadata / kind / source / time / pin state / redacted placeholder。
7. **repositoryUnavailable 状态**：检查 UI 或 read model 中存在 empty、unavailable、filtered、redacted 的可区分状态与本地化 key。
8. **CLI / helper / App Group denylist**：BlocksCLI 不得新增默认 clipboard payload 输出；helper 生产写库、App Group、CLI 默认完整 payload 仍未开启。
9. **敏感输出扫描**：P11E 输出、开发记录、验收记录、audit/log 证据不得包含剪贴板正文、payload text、图片 base64、OCR 文本、真实完整文件路径或 provider secret。
10. **read model 摘要**：脚本输出 JSON 必须包含 allowlist、denylist、checked files、target membership source、explicit read sites、denied default sites、repositoryUnavailable state summary 和 failures。

## 7. 建议开发边界

建议主 agent 不派 4C-4 开发，而是启动 Step 4D PRD / handoff：

1. 写 Step 4D handoff record：明确 Step 4C core 完成，Clipboard hardening 未进入 4C、未验收、P11E 未通过。
2. Step 4D PRD 先锁定 read model 类型和 API：metadata list item、redacted preview、explicit payload read reason、payload cache 生命周期、summary 敏感级别。
3. 并行要求安全合规和测试/质量复审 Step 4D 方案；这类改动涉及剪贴板正文、日志、验证输出和用户显式读取动作，安全/质量不能只在实现后补审。
4. Step 4D 开发可拆为至少两个子批次：
   - 4D-1：read model / Store API / P11E 骨架，先让默认列表不预取 payload。
   - 4D-2：panel hover detail、paste/copy/translation explicit read、repositoryUnavailable UX、P8/P9 迁移和实物验收。

## 8. 回调结论

回调结论：`split-to-step4d`

主 agent 最终接受建议：

- 不启动 Step 4C-4 开发。
- 先写 Step 4D handoff record。
- Step 4C 最终接受记录只接受 core：ScreenshotStore、ShortcutStore、Settings shell split。
- Clipboard hardening 作为 Step 4D 独立项目进入 PRD / 方案复审 / 开发 / 验收闭环。
