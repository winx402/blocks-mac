# Step 2 项目负责人开发验收 v0

状态：development-verified-pending-review
日期：2026-07-07
角色：项目负责人
对象：`开发记录-Step2-v0.md` 与当前工作区 Step 2 实现

## 1. 结论

Step 2 开发实现通过项目负责人独立门禁验收，可以进入代码审查、测试/质量复核和 UI/交互复核。

本结论不是 Step 2 最终接受。Step 2 最终接受需要复核意见收敛后再判断；未最终接受前不进入 Step 3。

## 2. 已验收范围

本轮独立验收覆盖：

- `Tag / RecordTag` 独立事实源。
- favorite built-in tag。
- 面板单标签筛选。
- 条目右键标签增删 / 新建入口。
- 设置页标签管理。
- 收藏从旧 pinned / pinboard 迁出。
- 标签搜索 contract / e2e gate。
- P13B fail-closed verifier。
- P8 / P8I / P9A / P9B / P9C / P11E 当前事实源迁移。
- Step 1 P13A 回归。

明确未验收：

- Step 3 hover / toolbar / 选中反馈 / 密度专项。
- Step 4 详情编辑。
- Step 5 隐私页 App 清单 / CLI 广义对象。
- 真实 App UI、真实剪贴板、provider、Keychain、TCC、系统设置或自动化动作。

## 3. 独立验证命令

项目负责人在当前工作区独立执行以下命令，均退出码为 0：

```bash
python3 tools/verification/p13b_clipboard_tags_model_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

关键证据：

- P13B：`ok=true`，`legacy_exit` 全 true，`tag_search.contract_gate=pass`，`tag_search.e2e_gate=pass`，sanitizer 通过。
- P9A：schema v3，`clipboard_tags` / `clipboard_record_tags` / `tag_tokens_json` smoke 通过，fixture 包含 `favorite_builtin`、`record_tag`、`tag_search`、`clear_unfavorited`、`preserve_favorite_policy`、`body_excludes_tag_name`。
- P8 / P8I：包含 Step 2 单标签筛选、右键 tag menu、favorite surface、设置页标签管理、旧 pinboard UI / settings 退出证据。
- P9B：AppModel / ClipboardStore / ClipboardTagStore / search coordinator 当前事实源证据通过。
- P11E：Step 2 tag/favorite UI/store 默认路径无 payload read / system sensitive token。
- P13A：Step 1 明文展示、OCR、设置页清理回归通过。
- Blocks App / BlocksCLI：构建通过。
- CLI help：正常输出 usage。
- `git diff --check`：无输出。

## 4. 残余风险

- P2：面板右键 `New Tag...` 当前是固定默认名 `New Tag` 的最小入口；完整右键原地命名和冲突处理未做，设置页提供完整管理能力。此项不阻塞 Step 2 开发验收，但 UI/交互复核需判断是否接受为阶段残余。
- P2：旧 `clipboard_pinboards` / `clipboard_pinned_metadata` 与 `ClipboardRecorderRecord.pinned` 仍作为 legacy storage / baseline 代码存在；当前门禁确认不作为 active UI / Store / filter / policy ok 证据。
- P2：未做真实 macOS UI 自动化验收；Settings / context menu / filter 行为由静态门禁、repository smoke、构建覆盖。后续复核可要求低敏截图或手工证据。
- P2：`FloatingPanelSupport.swift` 既有 main-actor warning 保留，非 Step 2 引入。

## 5. 下一步

派发：

- 代码审查：重点看数据模型/迁移、repository 事务、Store/UI 事实源、旧 pinned 退出、search tag tokens、低敏输出。
- 测试/质量复核：重点看验收矩阵、fixture 覆盖、P13B / P9A / P8 / P8I / P9B / P11E 是否足以证明 PRD。
- UI/交互复核：重点看标签筛选、右键菜单、Settings tag row、favorite immutable、长标签/窄宽度/可访问性和右键 `New Tag...` 残余是否可接受。

复核收敛后，项目负责人再决定 Step 2 最终接受、返工或带残余接受。
