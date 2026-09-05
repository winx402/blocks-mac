# P8-M Clipboard Architecture Modularization 验收记录

状态：verified with automated gates / code review follow-up fixed / manual physical QA pending
日期：2026-07-04

## 验收矩阵

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| Architecture spine 已建立 | passed | `docs/项目管理库/规划产物/architecture/p8-m-clipboard-modularization/ARCHITECTURE-SPINE.md` |
| Story 已建立并进入 review | passed | `docs/项目管理库/实施记录/stories/p8-m-clipboard-architecture-modularization.md` |
| 产品基线已更新到重构后实现路径 | passed | `docs/产品知识库/工具/文本/剪贴板历史-当前产品与实现逻辑.md` |
| 大视图不再定义 moved components | passed | `p8m_clipboard_modularization_checks.py` 检查 `ClipboardFloatingPanelView.swift` 不含 moved component 定义 |
| Presenter 不再拥有自动粘贴实现 | passed | `p8m_clipboard_modularization_checks.py` 检查 presenter 不含 `ClipboardAutoPasteCoordinator` / Accessibility paste event 实现 |
| 自动粘贴 coordinator 独立 | passed | `ClipboardAutoPasteCoordinator.swift` 负责 payload 写回、Accessibility、目标 App 激活和 `Command + V` |
| 详情 child panel 独立 | passed | `ClipboardHoverDetailLayer.swift` 包含 `ClipboardHoverDetailPanelCoordinator`、`addChildWindow`、`convertToScreen` 和 tracking view |
| 筛选 / Pinboard / Preview / Localization 分文件 | passed | `ClipboardFilters.swift`、`ClipboardPinboard.swift`、`ClipboardRecordPreview.swift`、`ClipboardRecorder+Localization.swift` |
| settings key/default/clamp 集中 | passed | `ClipboardPanelSettings.swift` 包含 card width、paste activation、filter settings keys 和 width clamp |
| AppState 兼容转发存在 | passed | `AppState` 委托 `ClipboardController.defaultRecords/defaultPayloads/preview/ingestLiveCapture/filteredRecords/sourceFilterOptions` |
| P8-M 模块边界门禁 | passed | `python3 tools/verification/p8m_clipboard_modularization_checks.py --timeout 180` |
| 详情退出不只依赖 local mouseMoved | passed | P8-M 门禁 `detail_exit_tracking_not_local_only` 检查详情打开期间的 mouse-location polling 和 stop path |
| P7-D resize hover 回归 | passed | `python3 tools/verification/p7d_clipboard_panel_resize_hover_checks.py --timeout 180` |
| P7-E position/autopaste 回归 | passed | `python3 tools/verification/p7e_clipboard_position_autopaste_checks.py --timeout 180` |
| P7-I bottom tray window 回归 | passed | `python3 tools/verification/p7i_clipboard_bottom_tray_window_checks.py --timeout 180` |
| P7-I tray visual structure 回归 | passed | `python3 tools/verification/p7i_clipboard_tray_visual_structure_checks.py --timeout 180` |
| P7-L experience gate 回归 | passed | `python3 tools/verification/p7l_clipboard_experience_gate_checks.py --timeout 180` |
| P8-I settings clipboard system 回归 | passed | `python3 tools/verification/p8i_settings_clipboard_system_checks.py --timeout 180` |
| P8-K settings fullscreen/height 回归 | passed | `python3 tools/verification/p8k_settings_fullscreen_section_clipboard_height_checks.py --timeout 180` |
| P8-L bottom height anchor 回归 | passed | `python3 tools/verification/p8l_clipboard_bottom_height_anchor_checks.py --timeout 180` |
| `git diff --check` | passed | 无 whitespace error |
| Xcode Debug build | passed | `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build` |
| 项目 verify | passed | `./script/build_and_run.sh --verify` |
| 独立 code review | passed_after_followup | 只读 review agent 发现 1 个 P2 hover detail 退出风险；修复后复核通过，无新增 finding |
| 实物验收：真实复制文本/图片 | not_covered | 需要启动 Debug app 后真实操作 |
| 实物验收：筛选展开/点击/取消 | not_covered | 需要真实鼠标操作 |
| 实物验收：hover 详情切换和进入 | not_covered | 需要真实鼠标操作和截图 |
| 实物验收：条目宽度拖动 | not_covered | 需要真实鼠标操作 |
| 实物验收：bottom 高度 resize | not_covered | 需要真实鼠标操作 |
| 实物验收：单/双击粘贴持久化 | not_covered | 需要真实 app 重开或重启验证 |
| 实物验收：外部点击关闭 | not_covered | 需要真实面板操作 |

## Code Review Notes

- finding：详情离开联合区域不一定会立即隐藏。原因是旧实现主要依赖 app-local `.mouseMoved` monitor，鼠标离开 App 事件流后可能无法继续触发 union 判断。
- fix：`ClipboardHoverDetailLayer.swift` 在详情打开期间启动 `Timer(timeInterval: 1.0 / 60.0)` 轮询 `NSEvent.mouseLocation`，复用现有 `hideDetailIfMouseIsOutsideUnion`；详情隐藏、view 离窗和 deinit 时停止 timer。
- guardrail：`p8m_clipboard_modularization_checks.py` 新增 `detail_exit_tracking_not_local_only`，防止回退到 local-only hover detail 退出路径。
- follow-up review：审查 agent 复核确认 P2 已修复，未引入第二套详情渲染、旧 overlay fallback、`detailHoverDismissTask`、`Task.sleep` 或明显资源泄露。

## 风险与后续

- 本轮验证强度主要来自静态门禁、构建和只读 code review；AppKit/SwiftUI 鼠标事件仍需要实物 QA 或 UI harness。
- 详情退出的 60Hz polling 只在详情打开期间运行，逻辑上用于补足 App local event 盲区；仍建议实物确认没有肉眼迟滞或异常耗电。
- `AppState` 已开始委托 `ClipboardController`，但固定、删除、移动分组、重命名、copy/paste 等 use case 仍可继续下沉。
- live capture 仍是当前内存态产品路径；生产持久化和保存前 capture policy 不在 P8-M 范围内。
