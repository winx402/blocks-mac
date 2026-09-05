# 004_剪贴板打磨 Step 4 开发派发 v0

## 任务结论

状态：`assigned-to-development`。

Step 4 PRD v1 和技术方案 v1 已接受。现在派发开发实现 Step 4：详情编辑与元数据组织。

开发完成后输出：

- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md`

## 输入文档

开发必须先阅读：

- `AGENTS.md`
- `agents/开发.md`
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-PRD-v1复核-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-技术方案-v1复核-v0.md`

## 开发范围

只实现 Step 4。

必须覆盖：

1. P13D baseline red，然后随实现转绿。
2. Schema migration v4：contentRevision / OCR source。
3. Bounded detail read model 和 metadata snapshot。
4. `detailEditRead`、`detailFullValueRead`、`detailEditSave`，如实现 copy full value 则明确 `detailCopyFullValue` 或等价动作。
5. 单一 Store / Repository detail save command。
6. Plain text 编辑保存。
7. URL 编辑保存与本地 validation。
8. Rich text fidelity gate；不能保真时停止并反馈项目负责人，不静默降级。
9. OCR user-edited 文本保存、retry / late completion 防覆盖。
10. Stable detail editor、默认阅读态 + Edit、fixed action bar、dirty-navigation sheet。
11. 编辑区 2 行默认 / 4 行上限 / 超过内部滚动。
12. 元数据短项两列、窄宽度单列、长项 copy full value / bounded snapshot。
13. P13D per-scenario evidence、deterministic fixtures、fault injection、pasteboard read/write spy、state ownership、purpose matrix、call graph negative scan、sanitizer / denylist。

明确不覆盖：

- Step 5 隐私页真实 App 清单、系统图标、CLI 广义对象管理。
- Step 6 集成验收。
- 图片本体或文件本体编辑。
- 完整富文本编辑器工具栏。
- 保存时同步写系统剪贴板。
- Provider、外部 OCR、自动化、网络可达性检查、Finder / System Settings / TCC 动作。

## 实现策略要求

- 同一顶层 Step 内可以合并开发批次，但证据必须保留 P13D baseline red、实现后 green、回归矩阵和低敏输出。
- 不允许 View 分散写 payload、summary、search document、FTS 或 OCR 状态。
- 不允许 AppState / AppModel / ClipboardController 成为 detail payload、OCR text、search document 或 save result 的事实源。
- 保存默认走同一 repository transaction；如果实现发现必须启用异步 reindex，先停止并反馈项目负责人。
- Rich text 最低 fidelity fixture 不通过时，先停止并反馈项目负责人；不要自己选择降级。
- Custom scheme 放开、file URL 编辑、空 payload 恢复等未接受范围，先停止并反馈项目负责人。

## 必须运行的验证

开发完成前至少运行：

```bash
python3 tools/verification/p13d_clipboard_detail_edit_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
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

P13D 是 Step 4 专属 gate，必须排在最前；P13D fail 时不得把后续回归 PASS 写成 Step 4 通过。

## 证据边界

- 不触发真实 App、真实剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化。
- 使用低敏 fixture / temp database / fake pasteboard / spy。
- 输出不得包含真实剪贴板正文、真实 home path、真实文件路径、URL 全文、OCR 原文、图片/base64、邮箱、secret、Authorization header、二维码、验证码。

## 开发记录要求

`开发记录-Step4-v0.md` 至少包含：

- 改动文件清单。
- P13D baseline red 证据。
- 实现后 P13D green 证据。
- 各验证命令结果。
- Rich text fidelity 结果或阻塞说明。
- OCR user-edited / retry / late completion 结果。
- Pasteboard read/write = 0 证据。
- 低敏输出说明。
- 未覆盖项和 residual risk。
