# 004_剪贴板打磨 Step 3 开发记录 v0

## 结论

Step 3 面板交互与布局打磨已完成实现与本地验证，结论为 `DONE_WITH_EVIDENCE`。

## 改动范围

- 新增 `tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`，作为 Step 3 fail-closed 门禁。
- 新增 `docs/项目管理库/004_剪贴板打磨/step_3/evidence/p13c/manifest-v0.json` 与低敏 fixture artifacts。
- 修改 `apps/Blocks/BlocksApp/Views/ClipboardFloatingPanelView.swift`：面板级 activation handler、view-local focused/interaction token、toolbar metrics、paste activation 显性切换、filter hover 延迟收起。
- 修改 `apps/Blocks/BlocksApp/Views/ClipboardFilterBarView.swift`：hover 安全区域配置、re-enter cancel 入口、短延迟收起入口。
- 修改 `apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift`：row/card 主激活统一进入 handler、focused 视觉状态、density metrics、稳定 metadata/status slot。

## 未改范围

- 未进入 Step 4 详情编辑。
- 未进入 Step 5 隐私页 App 清单。
- 未重做 Step 1 搜索 / OCR 或 Step 2 标签事实源。
- 未触发真实用户剪贴板、provider、Keychain、TCC、系统设置或真实 UI 自动化。

## P13C baseline red

命令：

```bash
python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py
```

基线结果：`FAIL`，符合预期红灯。失败项包括 `dev_record_present`、`hover_delayed_collapse`、`paste_activation_menu_removed`、`direct_paste_gesture_removed`、`activation_handler_present`、`focused_view_local`、`interaction_token_view_local`、`toolbar_metrics_present`、`density_metrics_present`、`manifest_missing`。

## 实现说明

- Hover：`ClipboardFilterClickGroup` 暴露 hover enter / exit，面板持有 `pendingFilterCollapseTask`；离开后短延迟收起，重新进入会取消待收起任务。选中筛选项时立即收起展开组。
- Activation：row/card 不再直接把 tap gesture 绑定到 paste；统一回到 `onPrimaryActivation`，先写 selected/focused 和 interaction token，再按单击/双击模式请求 paste。键盘 Enter 和 context menu 也先进入同一 action handler。
- Focus：`focusedRecordID` 和 `latestInteractionToken` 只保留在 `ClipboardFloatingPanelView`，不进入 AppState / Store / Repository。
- Toolbar：新增 `ClipboardPanelToolbarMetrics`，bottom / side 共用搜索、筛选和右侧操作区约束；paste activation、clear filter、settings、close 保持右侧可见。
- Density：新增 `ClipboardRecordDensityMetrics`，row/card 使用稳定 min height、metadata slot、OCR/status slot，避免不同状态撑动布局。
- Evidence：P13C 使用当前 Step 3 PRD、技术方案、派发文档、开发记录、当前代码和低敏 manifest，不读取旧归档作为阻断依据。

## 验证结果

已运行：

- `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`：PASS。`viewportEvidence=9`，`interactionScenarios=5`，`keyboardChecklists=1`，`voiceOverChecklists=1`，sanitizer PASS。
- `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`：PASS。
- `python3 tools/verification/p13b_clipboard_tags_model_checks.py`：PASS。
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`：先因旧 header 扫描口径报 `step2_clear_all_includes_tag_filter` FAIL；已把 P8 current evidence 改为检查新的 `trailingActionGroup` / `clearAllFiltersFromToolbar()` / `ClipboardStore.clearFilters()`，复跑 PASS。
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`：PASS。
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`：PASS。输出使用 `<TMP>`，包含 search document、OCR state/search、tag search repair fixture。
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`：PASS。
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`：PASS。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。保留既有 `FloatingPanelSupport.swift` main-actor warning。
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build`：PASS。
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`：PASS，输出 CLI usage 与 `blocks.screenshot.capture` action。
- `git diff --check`：PASS。

## 残余风险

- 低敏 evidence manifest 是静态 fixture 证据，不是现场真实 UI 自动化截图或辅助功能录屏。按派发边界，未触发真实 App / 真实剪贴板 / 系统权限。
- SwiftUI 单击与双击 gesture 的实际事件顺序仍需后续人工或受控 UI 验收确认；当前实现通过面板级 handler 降低直接 paste 风险，并用 interaction token 保证 stale completion 不更新当前状态。

## 安全隐私声明

本轮未读取或输出真实剪贴板正文、OCR 原文、完整本地路径、真实 App 名、邮箱、凭据、Authorization header、验证码、二维码或图片字节内容。验证 evidence 使用合成 fixture ID 与低敏状态描述。
