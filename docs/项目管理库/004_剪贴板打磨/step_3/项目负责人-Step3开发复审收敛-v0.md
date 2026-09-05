# Step 3 开发复审收敛 v0

状态：rework-required
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 3 开发实现复审

## 1. 结论

Step 3 开发实现不能最终接受，需要 R1 返工。

测试/质量结论为 `approve`，但代码审查结论为 `rework-required`，UI/交互结论为 `approve-with-changes` 且存在 P1。项目负责人不接受在 P1 未关闭时把 Step 3 标记为 accepted。

本次返工仍限定在 Step 3：面板交互与布局打磨。不得进入 Step 4 详情编辑、Step 5 隐私页，也不得重做 Step 1 搜索/OCR 或 Step 2 标签事实源。

## 2. 复审输入

- `step_3/开发记录-Step3-v0.md`
- `step_3/项目负责人-Step3开发验收-v0.md`
- `step_3/代码审查-Step3开发复审-v0.md`
- `step_3/UI-交互设计师-Step3开发复审-v0.md`
- `step_3/测试-质量-Step3开发复审-v0.md`

## 3. 角色复审结论

| 角色 | 结论 | 项目负责人判断 |
| --- | --- | --- |
| 代码审查 | `rework-required` | P1 必须返工 |
| UI/交互设计师 | `approve-with-changes` | 其中 P1 必须返工 |
| 测试/质量 | `approve` | 可吸收，P2 residual 保留 |

## 4. R1 必须修复

### 4.1 P1：`detail_open` 契约是假 PASS

问题：

- P13C manifest 声称覆盖 `detail_open` / `detailRequested`，但当前代码没有 detail action 进入 activation handler。
- `ClipboardPanelActionKind` 没有 detail 分支，`handleRecordAction(...)` 未覆盖 detail。
- 实际 hover detail payload 读取仍由 detail card 的 `onAppear` / `loadHoverPayload()` 直接执行 `.hoverDetail` payload read，没有先写 selected / focused / interaction token。
- 因此 P13C 对 `detail_open` 的 PASS 仅来自 manifest 自述，不能证明当前代码满足“detail 前 selected/focused 先写”。

R1 要求：

- 若 hover detail 属于 Step 3 的 detail open 路径，则必须把 hover/detail open 接入局部 activation/detail handler：先 select、focus、record event / token，再触发 detail payload load 或 detail surface。
- 若开发认为 hover detail 不属于本阶段 `detail_open`，不得自行删除验收项；必须回到项目负责人。本轮项目负责人取舍为：按代码审查建议修复，不降级。
- P13C 必须增加代码级 fail-closed 检查，不能只信 manifest：至少要求存在 detail action / detailRequested 等价路径，并能证明该 action 经 handler 先写 selected/focused/token 后再触发 detail load。

### 4.2 P1：paste activation 顶部控件视觉 / 可访问性 / 本地化语义不足

问题：

- 当前 paste activation 是 icon-only button，选中项使用 `checkmark.circle.fill`，未选中项使用模式图标；用户需要依赖位置或 tooltip 才能判断当前是单击还是双击。
- `ClipboardPasteActivationMode.title/menuTitle` 仍硬编码中文 `"单击"`、`"双击"`、`"单击粘贴"`、`"双击粘贴"`，未进入 `Localizable.xcstrings`。
- PRD / 技术方案要求显性控件、当前值可读、互斥关系清楚，并覆盖中文、英文、日文与 VoiceOver 语义。

R1 要求：

- paste activation 控件必须让当前值视觉可识别。可采用 compact segmented / 互斥按钮组短文本，或保留模式图标但选中状态不得只靠通用 checkmark 替代模式语义。
- 文案必须进入 String Catalog，至少覆盖中文、英文、日文可读短标签和 accessibility label。
- accessibility label / help 必须包含动作语义、当前值和互斥关系；VoiceOver 能区分两个选项和当前选中项。
- P13C 或 P8 必须补静态检查：paste activation 文案不得来自硬编码中文，关键 localization key 存在。

## 5. R1 建议同步修复

以下问题为 P2，但与 R1 相关，建议本轮顺手收口；若不处理，必须在 R1 开发记录中保留为 residual。

1. Hover safe bridge 的点击透明证据不足：
   - 当前实现通过 `Color.clear` background 与负 padding 扩大区域，但没有明确 `.allowsHitTesting(false)` 或等价结构说明。
   - P13C 只看 token，不验证 safe bridge 点击透明。
   - 建议补实现或补可证明的结构，并让 P13C fail closed。

2. P13C direct paste 检查过于字面化：
   - 当前只负向匹配旧字面量 `TapGesture(count: pasteActivationMode.tapCount).onEnded { onPaste() }`。
   - 建议扩大扫描，禁止 row/card 主体范围内绕过 `onPrimaryActivation` / `handleRecordAction` 的 `onPaste()`、`pasteClipboardRecord` 或等价直连。

3. Hover 参数与派发默认值不一致：
   - 派发默认值是 12pt / 16pt；当前实现是 10pt / 8pt。
   - 可以对齐默认值，也可以在开发记录中写明微调理由和 residual。

## 6. R1 验证要求

R1 完成前至少运行：

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

R1 开发记录必须写入：

- `step_3/开发记录-Step3-R1-v0.md`

记录需包含：

- 两个 P1 的修复说明。
- P13C / P8 或等价门禁新增断言说明。
- 是否处理了 P2 建议项；未处理项列为 residual。
- 验证命令和结果。

## 7. 下一步

派发开发 R1 返工。R1 完成后，项目负责人先做定向验收，再要求代码审查、UI/交互和测试/质量做定向复审。未关闭 P1 前，不进入 Step 3 最终接受。
