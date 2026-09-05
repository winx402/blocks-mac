# P7-O 真实权限与交互验收记录

日期：2026-07-03
状态：`passed for stable-signing / screen-recording / accessibility / clipboard-autopaste core paths`
运行 App：`/Users/bot/Applications/JDToolDev/Debug/JDTool.app`
Bundle ID：`com.jdtool.app`
签名：Apple Development `89931215@qq.com`，Team ID `LOCAL_TEAM_ID_REDACTED`

## 验收结论

本轮不再按低敏边界限制操作，直接在本机真实 System Settings、TextEdit 和 JDTool Debug App 上验收。结论是：稳定签名问题已解决；Screen Recording 和 Accessibility 均能被当前稳定 App 识别；`Control + Option + V` 能在 TextEdit 前台打开 Clipboard 浮层；Clipboard 低敏 fixture 可通过 `Return` 和双击卡片写入系统剪贴板、恢复目标 App 并发送 `Cmd+V`；`Control + Option + A` 能进入区域截图 overlay，并完成一次真实区域截图；`Control + Option + D` 能打开翻译浮层、读取剪贴板文本并自动生成 Local Mock 翻译结果。

默认快捷键从 Option-only 调整为 `Control + Option + A/V/D`，原因是 Option-only 在 TextEdit 等输入场景会产生普通字符，不能作为可靠全局工具快捷键。

## 已通过

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| Apple Development 签名 | 通过 | `./script/build_and_run.sh --verify-permissions` 和 `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing` 通过；codesign 显示 Authority 为 Apple Development，Team ID 为 `LOCAL_TEAM_ID_REDACTED`。 |
| 稳定开发运行路径 | 通过 | 构建产物固定 staging 到 `~/Applications/JDToolDev/Debug/JDTool.app`，避免中文项目路径、DerivedData 和多副本影响 TCC 验收。 |
| Screen Recording | 通过 | 对 `com.jdtool.app` 做针对性 ScreenCapture TCC reset 后，用当前稳定 App 重新请求授权；TCC 行为 `auth_value=2`、`csreq` 长度 160；`Control + Option + A` 进入区域选择 overlay，并完成真实区域截图，结果浮层显示 `截图已完成 720 x 540 px`。 |
| Accessibility | 通过 | TCC 行为 `auth_value=2`、`csreq` 长度 160；Clipboard 自动粘贴能写入剪贴板、恢复 TextEdit 并发送 `Cmd+V`。 |
| Clipboard 浮层快捷键 | 通过 | TextEdit 前台按 `Control + Option + V` 打开底部 Clipboard 浮层。 |
| Clipboard 自动粘贴 - Return | 通过 | 浮层打开后按 Return，TextEdit 内容变为 `jdtool paste target: jdtool fixture text`。 |
| Clipboard 自动粘贴 - 双击 | 通过 | 双击第一张低敏 fixture 卡片，TextEdit 内容变为 `jdtool double click target: jdtool fixture text`。 |
| Screenshot 区域截图 | 通过 | `Control + Option + A` 触发区域 overlay，拖拽选区后结果浮层显示非零尺寸截图和 Copy / Save / AI 占位动作。 |
| Translation 浮层快捷键 | 通过 | TextEdit 前台按 `Control + Option + D` 打开翻译浮层，左侧预填剪贴板文本 `jdtool fixture text`，右侧展示 Local Mock 翻译结果。 |

## 本轮代码修正

| ID | 问题 | 修正 |
| --- | --- | --- |
| P7-O-01 | Screen Recording 系统记录与 App preflight 不一致。 | 采用稳定 Apple Development 签名和 ASCII staging path 后，对 `com.jdtool.app` 做针对性 ScreenCapture reset，再由当前稳定 App 重新触发授权，使 TCC `csreq` 从旧 cdhash 绑定变为证书绑定。 |
| P7-O-02 | Option-only 快捷键在输入框中被当作普通字符。 | 默认全局修饰键迁移为 `Control + Option`，并将 Carbon hot key event target 改回 application event target；AppState 初始化和 App 激活时强制注册全局快捷键。 |
| P7-O-03 | Clipboard 浮层 Return 不触发粘贴。 | 增加 `ClipboardHistoryPanel` 子类，面板作为 key window 时直接拦截 Return / Esc；当前选中条目同步到 AppState。 |
| P7-O-04 | Clipboard 双击和键盘粘贴缺少可验证闭环。 | 保留双击卡片粘贴，并增加面板级 Return 粘贴路径；两条路径均通过 TextEdit 端到端验证。 |

## 尚未关闭

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| Permission Assist 目标页定位和箭头体验 | `not_covered_this_pass` | 本轮重点关闭权限识别、快捷键和自动粘贴主链路；辅助面板体验仍按 P7-R / 后续 UX polish 处理。 |
| Screenshot Window / Fullscreen UI 手动验收 | `not_covered_this_pass` | Screen Recording 主权限已通过，区域截图已真实完成；窗口/全屏仍建议在下一轮 UI 体验回归中单独点验。 |
| 多屏、权限撤销/重授权 | `not_covered_this_pass` | 本轮只对当前机器当前授权状态做验收；不伪造多屏和撤销场景。 |

## 后续建议

1. 进入 P7-R：Permission Assist 目标页检测、相对定位、箭头方向和关闭时机继续打磨。
2. 回测 Screenshot Window / Fullscreen，基于当前已通过的 Screen Recording 状态关闭剩余截图 UI 验收项。
3. 继续做 Settings / Permission Assist 的产品化打磨，避免辅助面板和系统设置窗口的相对定位继续造成困扰。
