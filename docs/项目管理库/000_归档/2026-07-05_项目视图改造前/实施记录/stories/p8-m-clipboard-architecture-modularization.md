---
baseline_commit: dcdff721e720e44b431a61a46f679e9635e59428
---

# P8-M Clipboard Architecture Modularization and No-Regression Refactor

状态：review
日期：2026-07-04
来源级别：implementation story execution record

## Story

作为剪贴板模块维护者，我需要把多轮快速修复后割裂的大文件实现收敛成清晰模块边界，使后续修 bug 和做交互优化时不再反复破坏已有产品能力。

## Context

不回归基线：

- `docs/产品知识库/工具/文本/剪贴板历史-当前产品与实现逻辑.md`

架构基线：

- `docs/项目管理库/规划产物/architecture/p8-m-clipboard-modularization/ARCHITECTURE-SPINE.md`

## Acceptance Criteria

1. `ClipboardFloatingPanelView.swift` 不再承载 AppKit hover/detail coordinator、filter domain、record card、width handle、detail card 等实现，只保留 panel assembly 和当前交互组合状态。
2. `ClipboardHistoryPanelPresenter.swift` 只管理窗口生命周期、frame、resize、dismiss island 和目标 app 捕获；自动粘贴 coordinator 独立。
3. `AppState.swift` 保留兼容转发入口，但剪贴板 preview、filter、source options、live ingest、默认 fixture 等领域逻辑迁到 `ClipboardController`。
4. `ClipboardRecorder+Localization.swift` 只保留 item kind 本地化；筛选、Pinboard、Preview 拆到职责明确的文件。
5. 剪贴板 UserDefaults key、底部卡片宽度范围、默认值和 clamp 集中到 typed settings 支持层，现有 key 不变。
6. No-regression contract 全部保留：真实复制新增、直接内容预览、图片缩略图、条目统一调宽、单/双击粘贴持久化、child panel 详情、点击筛选、bottom 高度 resize、自动粘贴、右键菜单、Pinboard 移动、删除、固定。
7. P7/P8 相关门禁更新为模块边界感知，不再错误绑定旧单文件；新增 P8-M 模块化门禁。
8. Xcode Debug build 和项目 verify 命令通过；若实物验收未覆盖，必须进入 acceptance record 风险项。

## Tasks / Subtasks

- [x] 建立 P8-M architecture spine 和 memlog。
- [x] 拆分 `ClipboardFloatingPanelView.swift`。
  - [x] 抽出 `ClipboardFilterBarView.swift`。
  - [x] 抽出 `ClipboardRecordViews.swift`。
  - [x] 抽出 `ClipboardCardWidthResizeHandle.swift`。
  - [x] 抽出 `ClipboardHoverDetailLayer.swift`。
- [x] 拆分 presenter 自动粘贴职责。
  - [x] 新增 `ClipboardAutoPasteCoordinator.swift`。
  - [x] 保持 presenter 的 bottom frame、resize、dismiss island 约束。
- [x] 拆分剪贴板领域支持文件。
  - [x] 新增 `ClipboardFilters.swift`。
  - [x] 新增 `ClipboardPinboard.swift`。
  - [x] 新增 `ClipboardRecordPreview.swift`。
  - [x] 收缩 `ClipboardRecorder+Localization.swift`。
- [x] 建立 typed settings 支持。
  - [x] 新增 `ClipboardPanelSettings.swift`。
  - [x] 将 view、settings、AppState 的剪贴板 key 使用切到 typed keys。
- [x] 收敛 AppState 剪贴板职责。
  - [x] 新增 `ClipboardController.swift`。
  - [x] AppState 对 preview、filter、ingest、source options、fixture 默认值改为委托。
- [x] 更新 Xcode project sources。
- [x] 更新既有静态门禁以识别新模块路径。
- [x] 新增 `p8m_clipboard_modularization_checks.py`。
- [x] 更新当前产品与实现逻辑文档，使实现路径反映重构后事实。
- [x] 补 acceptance record。

## Dev Agent Record

### Implementation Notes

- 采用 `ClipboardFloatingPanelView` 作为 composition root，而不是继续在其中定义所有子组件。
- `ClipboardHoverDetailLayer` 保留当前单 child `NSPanel` 方案，避免回到父 panel 内 overlay 裁剪。
- Code review 发现详情隐藏只依赖 local mouse moved 时，鼠标离开 App 事件流可能无法立即隐藏；已补充详情打开期间的 mouse-location polling，并在详情隐藏、view 离窗和 deinit 时停掉。
- `ClipboardAutoPasteCoordinator` 独立后，`ClipboardHistoryPanelPresenter` 不再 import `ApplicationServices` 或 `JDToolCore`。
- `ClipboardPanelSettings.Keys` 保留旧 UserDefaults key 字符串，避免用户已有配置丢失。
- 本轮没有引入生产持久化语义；live capture 仍按当前内存态路径运行。
- 顺手优化限于门禁结构和职责命名，没有新增产品功能。

### Verification Log

- passed：`python3 tools/verification/p7d_clipboard_panel_resize_hover_checks.py --timeout 180`
- passed：`python3 tools/verification/p7e_clipboard_position_autopaste_checks.py --timeout 180`
- passed：`python3 tools/verification/p7i_clipboard_bottom_tray_window_checks.py --timeout 180`
- passed：`python3 tools/verification/p7i_clipboard_tray_visual_structure_checks.py --timeout 180`
- passed：`python3 tools/verification/p7l_clipboard_experience_gate_checks.py --timeout 180`
- passed：`python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180`
- passed：`python3 tools/verification/p8k_settings_fullscreen_section_clipboard_height_checks.py --timeout 180`
- passed：`python3 tools/verification/p8l_clipboard_bottom_height_anchor_checks.py --timeout 180`
- passed：`python3 tools/verification/p8m_clipboard_modularization_checks.py --timeout 180`
- passed：`xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- passed：`git diff --check`
- passed：`./script/build_and_run.sh --verify`
- code review：发现 1 个 P2 hover detail 退出风险，已修复并补 P8-M 门禁 `detail_exit_tracking_not_local_only`。

### Completion Notes

- 大视图从约 1.4k+ 行收缩到 562 行，Presenter 收缩到 437 行。
- filter、record view、width resize、hover detail、auto paste、settings、preview、pinboard、controller 均有独立文件。
- 旧的产品行为通过 P7/P8 门禁保持；P8-M 增加模块边界门禁，防止旧逻辑回流。
- 修复了 review 发现的详情退出盲区：详情打开后即使鼠标离开 App local event 流，也会通过现有 union 判断立即隐藏。
- 实物验收仍需真实启动 app 后操作覆盖，acceptance record 会明确列为未覆盖风险，避免把静态门禁当人工体验通过。

## File List

- `apps/JDTool/JDTool.xcodeproj/project.pbxproj`
- `apps/JDTool/JDToolApp/Services/ClipboardAutoPasteCoordinator.swift`
- `apps/JDTool/JDToolApp/Services/ClipboardHistoryPanelPresenter.swift`
- `apps/JDTool/JDToolApp/Stores/AppState.swift`
- `apps/JDTool/JDToolApp/Stores/ClipboardController.swift`
- `apps/JDTool/JDToolApp/Support/ClipboardFilters.swift`
- `apps/JDTool/JDToolApp/Support/ClipboardPanelSettings.swift`
- `apps/JDTool/JDToolApp/Support/ClipboardPinboard.swift`
- `apps/JDTool/JDToolApp/Support/ClipboardRecordPreview.swift`
- `apps/JDTool/JDToolApp/Support/ClipboardRecorder+Localization.swift`
- `apps/JDTool/JDToolApp/Views/ClipboardCardWidthResizeHandle.swift`
- `apps/JDTool/JDToolApp/Views/ClipboardFilterBarView.swift`
- `apps/JDTool/JDToolApp/Views/ClipboardFloatingPanelView.swift`
- `apps/JDTool/JDToolApp/Views/ClipboardHoverDetailLayer.swift`
- `apps/JDTool/JDToolApp/Views/ClipboardRecordViews.swift`
- `apps/JDTool/JDToolApp/Views/SettingsView.swift`
- `docs/产品知识库/工具/文本/剪贴板历史-当前产品与实现逻辑.md`
- `docs/项目管理库/index.md`
- `docs/项目管理库/规划产物/architecture/p8-m-clipboard-modularization/.memlog.md`
- `docs/项目管理库/规划产物/architecture/p8-m-clipboard-modularization/ARCHITECTURE-SPINE.md`
- `docs/项目管理库/实施记录/stories/p8-m-clipboard-architecture-modularization.md`
- `docs/项目管理库/实施记录/acceptance/p8-m-clipboard-architecture-modularization-record.md`
- `tools/verification/p7d_clipboard_panel_resize_hover_checks.py`
- `tools/verification/p7e_clipboard_position_autopaste_checks.py`
- `tools/verification/p7i_clipboard_tray_visual_structure_checks.py`
- `tools/verification/p7l_clipboard_experience_gate_checks.py`
- `tools/verification/p8m_clipboard_modularization_checks.py`

## Change Log

- 2026-07-04：创建 P8-M story，完成剪贴板模块化重构、门禁更新和实施记录。
