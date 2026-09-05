# Step 4 R1 开发返工派发 v0

状态：assigned-to-development
日期：2026-07-07
角色：项目负责人
对象：004_剪贴板打磨 Step 4 R1 返工

## 1. 任务结论

Step 4 开发实现复审结论为 `rework-required`。现派发开发进行 R1 返工。

本轮仍只允许处理 Step 4：详情编辑与元数据组织。不得进入 Step 5 / Step 6。

开发完成后输出：

- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-R1-v0.md`

## 2. 必须阅读

- `AGENTS.md`
- `agents/开发.md`
- `docs/项目管理库/004_剪贴板打磨/index.md`
- `docs/项目管理库/004_剪贴板打磨/step.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-技术方案-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/开发记录-Step4-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发验收-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/代码审查-Step4开发复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/App架构师-Step4开发复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/UI-交互设计师-Step4开发复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/测试-质量-Step4开发复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/安全合规顾问-Step4开发复审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_4/项目负责人-Step4开发复审收敛-v0.md`

## 3. 必须修复

R1 必须关闭以下 P1：

1. P13D 假 PASS：改成真实 deterministic fixture / fault injection / fail-closed gate。
2. OCR user-edited guard：late completion / retry / second completion 不得覆盖用户编辑 OCR 文本。
3. Dirty-navigation：实现三动作阻断确认，并覆盖切换记录、关闭详情、overlay dismiss 等离开编辑上下文入口。
4. Metadata full value：UI 接入 full value read/copy 或等价完整值路径，包含反馈、accessibility 和 category-aware layout。
5. Rich text 编辑合同：实现代表格式保真并证明；如果做不到，停止并反馈项目负责人取舍，不得自行静默降级或用保存失败替代需求。

细节以 `项目负责人-Step4开发复审收敛-v0.md` 第 3 节为准。

## 4. 不允许

- 不进入 Step 5 隐私页真实 App 清单、系统图标、CLI 广义对象管理。
- 不进入 Step 6 集成验收。
- 不触发真实 App、真实系统剪贴板、TCC、provider、Keychain、System Settings、Finder 或自动化动作。
- 不把 P13D 继续做成字符串存在检查。
- 不把 rich text 隐式降级为“看起来可编辑但大部分代表格式保存失败”的体验。
- 不同步写系统剪贴板。

## 5. 必须运行验证

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

P13D 必须排在最前；P13D 未转为可信 fail-closed gate 前，不得用其他回归 PASS 声称 Step 4 R1 完成。

## 6. 开发记录要求

`开发记录-Step4-R1-v0.md` 至少包含：

- 每个 P1 的修复说明。
- P13D 新 evidence schema 和代表输出摘要。
- OCR user-edited late completion / retry sequence 证据。
- Dirty-navigation 三动作、切换记录 guard、关闭详情 guard 证据。
- Metadata full value read/copy UI 和 fake pasteboard / spy 证据。
- Rich text 代表格式保真证据；若无法实现，写明阻塞并不要声称 R1 完成。
- 完整验证矩阵结果。
- 低敏输出说明和未覆盖 residual。
