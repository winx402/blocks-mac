---
id: P3-C
title: 截图稳定化
status: implemented
date: 2026-07-02
sourcePlan: 后续多步执行计划 - P3-C 截图稳定化
relatedDocs:
  - ./p3-b-screenshot-modes.md
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P3-C 截图稳定化

## Scope

本轮只稳定 P3-B 已进入正式 App 的截图纵切，不新增 OCR、翻译、总结、完整截图历史、剪贴板、provider 或 hook。

已实现：

- 新增 `tools/verification/p3c_screenshot_checks.py`，统一验证 App 构建、Run verify、CLI mode、String Catalog、entitlements、helper 嵌入和 P2 action smoke。
- 最近截图摘要容量从 `AppState` 内联逻辑收敛到 `ScreenshotHistoryList`，默认最多 5 条。
- `displayNotFound` 和 `windowDisplayNotFound` 增加明确用户可读状态，不再只依赖 generic failed 文案。
- `Localizable.xcstrings` 补齐新增失败状态三语文案。
- App README 和项目看板更新为 P3-C 状态。

## Acceptance Notes

- Given 执行 P3-C 验证脚本，When 本地构建环境正常，Then 输出 `ok=true` 且不保存截图、剪贴板或 secret。
- Given CLI dry-run 传入 `region/window/fullscreen`，Then `result.mode` 与请求一致。
- Given CLI dry-run 传入未知 mode，Then 返回 `ok=false`、`error.code=invalid_mode` 和退出码 2。
- Given App 发生 display/window display 匹配失败，Then UI 状态显示本地化恢复建议。
- Given 连续记录超过 5 条最近截图摘要，Then 内存列表只保留最新 5 条。

## Manual Checklist

仍需低敏屏幕人工验收：

- Region：拖拽低敏区域后结果浮层显示非零尺寸，Copy / Save As / Retake 可用。
- Window：hover 高亮可见，点击低敏窗口后结果浮层显示 `window` mode，`Esc` 取消不保存图片。
- Fullscreen：捕获当前 display；多屏机器记录真实覆盖情况。
- 权限撤销/拒绝/重授权：返回可恢复 UI，不自动修改 TCC。

## Verification

计划执行并记录：

- `python3 tools/verification/p3c_screenshot_checks.py --timeout 180`
- project Markdown local link check
- SwiftUI visible hard-coded text scan
- `git diff --check`
- sensitive content scan
