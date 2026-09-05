# P8-L Clipboard Bottom 面板高度锚定验收记录

状态：verified with automated gates / manual drag review pending
日期：2026-07-04

## 验收矩阵

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| P8-K Clipboard 高度项已重开 | passed | `p8-k-settings-fullscreen-section-clipboard-height-record.md` 包含 `reopened_by_p8l` |
| Bottom frame 纯 helper 固定 `x/y/width` | passed | `clipboardBottomFrame(visibleFrame:height:)` 固定 `x = visibleFrame.minX`、`y = visibleFrame.minY`、`width = visibleFrame.width` |
| 系统 resize 只改变真实 `frame.height` | passed | `windowWillResize` 通过 `clipboardResizeSize` 固定宽度并 clamp 高度 |
| resize 过程中底边不离开 `visibleFrame.minY` | passed | `windowDidResize` 每一帧用 `anchorPanel(panel, preservingBottomHeight:)` 重建 bottom frame |
| 关闭重开后高度保持 | passed | 只保存 `floatingPanel.clipboard.bottom.height`，重开时 x/y/width 从当前 screen visibleFrame 重算 |
| Clipboard 面板不可移动 | passed | `isMovable=false`、`isMovableByWindowBackground=false` |
| P8-L 自动门禁 | passed | `python3 tools/verification/p8l_clipboard_bottom_height_anchor_checks.py --timeout 180` |
| P8-K / P8-J / P8-I 回归 | passed | `python3 tools/verification/p8k_settings_fullscreen_section_clipboard_height_checks.py --timeout 180`、`p8j...`、`p8i...` |
| 构建通过 | passed | `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build` |
| 运行验证通过 | passed | `./script/build_and_run.sh --verify` |
| Action Schema 回归 | passed | `p2_action_smoke.py validate-schemas` 与 `smoke` |
| String Catalog 校验 | passed | `python3 -m json.tool ...` 与 `xcstringstool compile --dry-run ...` |
| `git diff --check` | passed | 无 whitespace error |
| 敏感内容扫描 | passed | 未发现 secret / token 形态 |
| 人工复核：向上拖系统窗口顶部边框 | not_covered | 预期：面板变高，底边不动 |
| 人工复核：向下拖系统窗口顶部边框 | not_covered | 预期：面板变矮，底边不动 |
| 人工复核：关闭重开后高度保持 | not_covered | 预期：高度恢复，底边仍贴底，宽度仍满屏 |

## 说明

本轮验收重点不是“顶部边缘是否移动”。顶部边缘移动是高度变化的结果；真正的硬约束是 bottom panel 的底边必须始终锚定在 `visibleFrame.minY`，并且关闭重开后高度保持。
