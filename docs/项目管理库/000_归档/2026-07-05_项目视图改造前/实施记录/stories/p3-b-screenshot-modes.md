---
id: P3-B
title: 截图模式完善
status: implemented
date: 2026-07-02
sourcePlan: P3-B 截图模式完善计划
relatedDocs:
  - ../../规划产物/epics.md
  - ../../../项目进度看板.md
  - ../../../../../apps/JDTool/README.md
---

# P3-B 截图模式完善

## Scope

本轮在正式 App scaffold 上完善截图纵切，不进入 OCR、翻译、总结、完整截图历史库、剪贴板、provider 或 hook。

已实现：

- App 内截图模式统一使用 `JDToolCore.ScreenshotMode.region/window/fullscreen`。
- 菜单栏 Screenshot 改为 Region / Window / Fullscreen 三个入口，`Option + A` 仍触发 Region。
- 主窗口截图区提供三种模式按钮，并更新为 P3-B 状态说明。
- Region 保留 P3-A 拖拽 overlay。
- Window 新增 AppKit hover overlay，基于 ScreenCaptureKit window frame 进行命中和高亮，点击后捕获窗口。
- Fullscreen 捕获当前鼠标所在 display，缺失时回退到主 display，再回退到 ScreenCaptureKit 第一个 display。
- 结果浮层显示 mode、尺寸和来源摘要；Retake 按原 mode 重试。
- AppState 增加最多 5 条内存态最近截图摘要，只保存时间、mode、尺寸、来源和 capture id。
- CLI 支持 `jdtool run jdtool.screenshot.capture --dry-run --mode region|window|fullscreen`，未知 mode 返回 `invalid_mode`。
- `Localizable.xcstrings` 补齐 P3-B 新增 UI 文案的 `zh-Hans`、`en`、`ja`。

## Acceptance Notes

- Given 用户从菜单栏或主窗口触发 Region，When 拖拽区域，Then 应展示结果浮层并记录最近截图摘要。
- Given 用户触发 Window，When hover 到可捕获窗口，Then overlay 应高亮候选窗口；点击后结果浮层显示 window mode。
- Given 用户触发 Fullscreen，When 当前鼠标位于某 display，Then 捕获该 display；找不到时按主 display 和第一个 ScreenCaptureKit display 回退。
- Given CLI 执行 dry-run 并传入 mode，Then 输出 envelope 中的 `result.mode` 与请求一致。
- Given CLI 传入未知 mode，Then 输出 `ok=false` 和 `error.code=invalid_mode`。
- Given App UI 新增可见文案，Then String Catalog 中存在三语本地化。

## Privacy And Safety

- 最近截图摘要不保存图片数据、完整文件路径或持久历史。
- CLI 仍不执行真实截图；非 dry-run 只返回 `requires_confirmation`。
- 窗口候选排除 `com.jdtool.app` 和 `com.jdtool.app.helper` 自身窗口。
- 截图 overlay 不使用重毛玻璃，以免干扰用户确认被截图内容。

## Not Covered Yet

- 真实多屏机器上的窗口跨屏、全屏当前 display 和跨屏区域复测。
- 用户撤销/拒绝屏幕录制权限后的完整 UI 复测。
- 复杂重叠窗口命中精度和窗口阴影/透明窗口处理。
- OCR、翻译、总结、标注、拖拽导出和持久截图历史库。
- 剪贴板、provider、hook、Login Item 注册和长期 helper 行为。

## Verification

已执行并通过的验证：

- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `./script/build_and_run.sh --verify`
- `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `/Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings`
- `DerivedData/JDTool/Build/Products/Debug/jdtool list`
- `DerivedData/JDTool/Build/Products/Debug/jdtool run jdtool.screenshot.capture --dry-run --mode region`
- `DerivedData/JDTool/Build/Products/Debug/jdtool run jdtool.screenshot.capture --dry-run --mode window`
- `DerivedData/JDTool/Build/Products/Debug/jdtool run jdtool.screenshot.capture --dry-run --mode fullscreen`
- `DerivedData/JDTool/Build/Products/Debug/jdtool run jdtool.screenshot.capture --dry-run --mode bad-mode`
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`
- project Markdown local link check, excluding `.agents` skill templates
- `git diff --check`

未执行：

- 真实 Region / Window / Fullscreen 交互截图验收。本轮未代替用户截取屏幕内容；该项保留到低敏屏幕环境下人工验收。
