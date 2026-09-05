# P7-Q Screenshot Window / Fullscreen 验收记录

日期：2026-07-03
状态：`passed with environment-dependent items retained`
运行 App：`/Users/bot/Applications/JDToolDev/Debug/JDTool.app`
Bundle ID：`com.jdtool.app`
默认快捷键：`Control + Option + A/V/D`

## 自动门禁

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| Stable app build/run | `passed` | `./script/build_and_run.sh --verify` 通过并启动稳定路径 App。 |
| Existing TCC gate | `passed` | `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing` 通过；Screen Recording / Accessibility TCC rows 均为 granted。 |
| Screenshot mode code paths | `passed` | `ScreenshotCaptureService` 保留 `captureInteractiveWindow()`、`captureFullscreenOnCurrentDisplay()`、`preferredDisplay(from:)`、`noCandidateWindow`；`WindowSelectionController` 保留 hover highlight 和 `Esc` cancel。 |

## 真实 UI 验收

| 项目 | 结果 | 实际观察 |
| --- | --- | --- |
| Fullscreen click | `passed` | 点击主窗口 `全屏` 后出现 `截图结果` 浮层，显示 `模式：全屏`、`3,840 x 2,160 px` 和 `来源：显示器 1`。 |
| Window overlay hover | `passed` | 点击主窗口 `窗口` 后出现全屏 overlay，`CGWindowList` 显示 JDTool layer `1000` overlay；鼠标悬停候选窗口时蓝色高亮和窗口标签可见。 |
| Window Esc cancel | `passed` | Window overlay 打开后发送 `Esc`，overlay count 变为 `0`，没有残留高层窗口。 |
| Window candidate capture | `passed` | 重新进入 Window mode 并点击可见候选窗口后出现 `截图结果` 浮层，显示 `模式：窗口`、`912 x 1,944 px` 和 `来源：Simulator 窗口`。 |
| Runtime screenshot persistence | `passed` | 验收截图只用于当次观察并保存在 `/tmp`，没有写入仓库或 staged diff。 |

## 尚未覆盖

| 项目 | 状态 | 原因 |
| --- | --- | --- |
| No-candidate window UI | `not_covered_environment` | 当前桌面存在可捕获窗口，无法自然进入 no-candidate 状态；代码路径和本地化仍由自动门禁覆盖。 |
| Multi-display window/fullscreen | `not_covered_environment` | 当前验收环境为单屏；多屏当前 display 优先级和跨屏窗口边界留到多屏机器复测。 |
| Permission revoked/regrant screenshot path | `not_covered_policy` | 本轮不使用 `tccutil reset` 或修改系统隐私数据库；撤销/重授权留到单独环境复测。 |

## 结论

P7-Q 关闭 P7-P 中 `Screenshot Window UI 点击验收` 和 `Screenshot Fullscreen UI 点击验收` 两个未覆盖项。截图模式仍不是完整截图产品：OCR/provider runtime、持久截图历史、多屏和权限撤销/重授权仍未进入通过范围。
