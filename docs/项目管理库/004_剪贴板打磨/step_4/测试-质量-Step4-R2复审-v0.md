# 004_剪贴板打磨 Step 4 R2 测试/质量定向复审 v0

日期：2026-07-07
角色：测试/质量
范围：Step 4 R2 定向复审，仅复核 R1 遗留 P1“面板级关闭路径绕过 dirty navigation guard”。不进入 Step 5，不复审 R1 已关闭内容。

## 1. 结论

结论：`approve`。

P0/P1：清零。R2 新增 P13D 场景 `detail_panel_close_dirty_guard_004` 覆盖了项目负责人要求的面板级关闭入口，并且本轮独立复跑低敏矩阵全部 PASS。未发现新的 P0/P1。

真实 UI 点击、真实 VoiceOver 和真实系统剪贴板仍未覆盖；在 R2 范围内可作为 P2 residual 保留，不构成 P1。

## 2. 复审输入

- `测试-质量-Step4-R1复审-v0.md`
- `项目负责人-Step4-R1复审收敛-v0.md`
- `项目负责人-开发派发-Step4-R2-v0.md`
- `开发记录-Step4-R2-v0.md`
- `项目负责人-Step4-R2验收-v0.md`

## 3. R2 P1 关闭判断

| 要求 | 复核结果 | 证据 |
| --- | --- | --- |
| panel close 统一 dirty guard | 通过 | `ClipboardHistoryPanelPresenter.close()` 调用 `requestClosePanel()`；P13D `panel_close_uses_dirty_guard=true`。 |
| toolbar close guard | 通过 | `ClipboardFloatingPanelView.onClose` 注入到 presenter `requestClosePanel()`；P13D `toolbar_close_uses_dirty_guard=true`。 |
| `.onExitCommand` guard | 通过 | View 仍调用 `onClose()`，最终走 presenter guard；P13D `exit_command_uses_dirty_guard=true`。 |
| Escape guard | 通过 | presenter Escape handler 调用 `requestClosePanel()`；P13D `escape_uses_dirty_guard=true`。 |
| dismiss monitor / outside dismiss guard | 通过 | dismiss monitor callback 调用 `requestClosePanel()`；P13D `dismiss_monitor_uses_dirty_guard=true`。 |
| open settings 前 close guard | 通过 | `requestClosePanel(afterClose: openSettings)`；P13D `settings_close_uses_dirty_guard=true`。 |
| 程序化 `panel.close()` 不外露 | 通过 | P13D 排除 `closeImmediately()` 后统计直接 `panel.close()`；输出 `programmatic_panel_close_guarded=true`。 |
| DetailStore 承接 closePanel pending action | 通过 | `requestPanelClose(after:)`、`.closePanel`、`pendingPanelCloseHandler` 存在；P13D `detail_store_has_panel_close_action=true`、`panel_close_save_continue_handler=true`。 |

质量判断：P13D 对 R2 场景不是只扫场景名。脚本会读取 presenter / panel / detail store 源码，提取 method block，排除唯一允许的 `closeImmediately()` 后检查直接 `panel.close()`，并分别追踪 toolbar、exit command、Escape、dismiss monitor、settings close 是否进入 `requestClosePanel` 链路。该证据足以关闭“明显绕过 dirty guard”的 P1。

## 4. 实际运行命令

| 命令 | 结果 | 备注 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS | `failure_summary.count=0`；新增 `detail_panel_close_dirty_guard_004` PASS；9 项 R2 assertions 全为 true。 |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS | Step 3 面板交互 / layout 回归通过；真实 App/剪贴板不参与 ok。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | 产品 polish 与 bounded clipboard surface 未见回归。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | AppModel / repository integration 未见回归。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | 默认 payload deny 边界未见回归。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 仍有既有 `FloatingPanelSupport.swift` actor-isolation warning 和 AppIntents metadata skipped warning；未阻塞。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI target 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 仅输出 usage 和 `blocks.screenshot.capture` action。 |
| `git diff --check` | PASS | 写文档前通过。 |

本轮未补跑 P13A / P13B / P8I / P9A，原因与项目负责人 R2 验收一致：R2 实际改动仅涉及 `ClipboardDetailStore`、`ClipboardHistoryPanelPresenter` 和 P13D；未触碰 repository、OCR、search document、tags 或 settings active UI。当前矩阵对 R2 定向 P1 足够，不属于明显缺口。

## 5. 证据边界

本轮未启动真实 App，未读取或写入真实系统剪贴板，未触发 provider、Keychain、TCC、System Settings、Finder 或自动化动作。`blocks --help` 只执行 CLI help 输出。

P13D / P13C / P8 / P9B / P11E 输出未发现真实剪贴板正文、真实 OCR 原文、完整 URL query、secret、Authorization header 或图片/base64 泄漏。Xcode build 日志按工具默认包含本地构建路径；本复审文档不复制这些路径作为验收证据。

## 6. P2 Residual

P2-1：真实 UI 点击未覆盖。当前证据为静态结构断言、store/presenter 代码路径和构建验证，未实测 toolbar close、Escape、outside dismiss、open settings 在真实窗口中的焦点和时序。

P2-2：真实 VoiceOver 未覆盖。R2 没有新增真实读屏证据，该风险延续 R1 残余，可放入 Step 6 或最终手工回扫。

P2-3：真实系统剪贴板未覆盖。R2 不涉及真实剪贴板；metadata full value 仍以 explicit reveal / fake copy evidence 为主。

P2-4：未来如果新增面板关闭入口，必须继续接入 `requestClosePanel` 并扩展 P13D，否则可能重新引入同类绕过风险。

## 7. 建议

从测试/质量视角，R2 已足以进入 Step 4 最终接受准备。建议项目负责人在最终记录中保留上述 P2 residual，并明确真实 UI / VoiceOver / 系统剪贴板不作为 R2 已实测事实。
