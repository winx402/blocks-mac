# Step 2 R1 项目负责人验收 v0

状态：development-rework-verified-pending-targeted-review
日期：2026-07-07
角色：项目负责人
对象：`开发记录-Step2-R1-v0.md` 与当前工作区 Step 2 R1 实现

## 1. 结论

Step 2 R1 返工通过项目负责人独立门禁验收，可以进入定向二次复审。

本结论不是 Step 2 最终接受。由于上一轮代码审查存在 tag search 重建路径 P1，R1 仍需代码审查、测试/质量和 UI/交互做定向复核；复核收敛前不进入 Step 3。

## 2. R1 收口范围

本轮独立验收重点覆盖 `项目负责人-Step2开发复审收敛-v0.md` 中的返工项：

- R1：tag search 重建 / 缺失 search document 路径补回当前标签 token。
- R2：tag-only filter 下全局清除筛选入口可见，并能同时清除普通 filter 和 tag filter。
- R3：active App 层旧 `pinnedCount` facade 退出，并由 P13B / P9B 负向门禁覆盖。

开发已一并收口部分 P2：

- 标签操作错误文案迁入 String Catalog。
- 条目 tag chips 超过 3 个时显示 `+N`。
- 右键默认新建标签文案改为 `Create "New Tag"`，不再暗示后续输入流程。

明确未覆盖：

- Step 3 hover / toolbar / 选中反馈 / 密度专项。
- Step 4 详情编辑。
- Step 5 隐私页 App 清单 / CLI 广义对象。
- 真实 App UI、真实剪贴板、provider、Keychain、TCC、系统设置或自动化动作。

## 3. 独立验证命令

项目负责人在当前工作区独立执行以下命令，均退出码为 0：

```bash
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

关键证据：

- P13B：`ok=true`，`tag_search.e2e_gate=pass`，`legacy_exit.active_store_paths_clear=true`，sanitizer 通过。
- P9A：`ok=true`，`verified_tag_fixtures` 包含 `tag_search_missing_document_repair` 和 `tag_search_rebuild_path`。
- P9B：`ok=true`，旧 `pinnedCount` active path 负向检查通过。
- P8：`ok=true`，包含 `step2_clear_all_includes_tag_filter=true`。
- P8I / P11E / P13A / P9C：均通过，未发现 Step 1 / Settings / fixture / hardening 回归。
- Blocks App / BlocksCLI：构建通过。
- CLI help：仅输出 CLI usage 和 `blocks.screenshot.capture` action，未触发真实系统动作。
- `git diff --check`：无 whitespace error。

## 4. 残余风险

- P2：Settings 标签管理的行内反馈未做真实 UI 体验改造。
- P2：右键菜单新建标签仍是固定默认名，完整命名输入交互未在本轮实现。
- P2：未做真实 macOS UI 自动化验收；Settings / context menu / filter 行为由静态门禁、repository smoke、构建覆盖。
- P2：`FloatingPanelSupport.swift` 既有 main-actor warning 保留，本轮构建通过，非 Step 2 R1 阻塞。

## 5. 下一步

派发定向复审：

- 代码审查：只复核 R1/R2/R3 是否闭合，以及是否引入新的 P0/P1/P2 代码风险。
- 测试/质量：只复核 R1 verification matrix 是否足以关闭上一轮 P1，并检查 P13B / P9A / P9B / P8 / P8I / P11E / P13A 当前输出是否可接受。
- UI/交互：只复核 R2 clear-all、`+N` tag chips、`Create "New Tag"` 文案、标签错误本地化和剩余 P2 是否可接受。

三方复审收敛后，项目负责人再决定 Step 2 最终接受、继续返工或带残余接受。
