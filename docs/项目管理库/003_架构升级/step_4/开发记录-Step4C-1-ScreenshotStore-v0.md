# Step 4C-1 ScreenshotStore 开发记录 v0

状态：developed
日期：2026-07-06
来源级别：development record

## 1. 结论

开发结论：DONE。

本子批次只实施 Step 4C-1 ScreenshotStore。已新增 `ScreenshotStore`，把 screenshot facts / actions 从 `AppState` 迁出；`AppState` 保留 AppShell / coordinator facade，负责 status banner、缺权 alert、provider route resolver 注入和 retake 回调协调。

本次未启动 ShortcutStore、Settings shell split、Clipboard hardening；未创建 branch / commit。

## 2. 改动文件

- `apps/Blocks/BlocksApp/Features/Screenshot/ScreenshotStore.swift`
- `apps/Blocks/BlocksApp/Stores/AppState.swift`
- `apps/Blocks/BlocksApp/Services/ScreenshotResultPresenter.swift`
- `apps/Blocks/BlocksApp/Views/ScreenshotResultView.swift`
- `apps/Blocks/Blocks.xcodeproj/project.pbxproj`
- `tools/verification/p11a_screenshot_store_boundary_checks.py`
- `tools/verification/p3d_screenshot_ai_action_entry_checks.py`
- `tools/verification/p3e_screenshot_result_polish_checks.py`
- `tools/verification/p3f_screenshot_ai_route_ready_checks.py`
- `tools/verification/p7q_screenshot_window_fullscreen_checks.py`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4C-1-ScreenshotStore-v0.md`

## 3. 未改范围

- 未创建 `ShortcutStore`，未触碰快捷键 store 拆分。
- 未拆 `SettingsView` / Settings shell，不新增 Settings pane。
- 未做 Clipboard hardening，不改变 clipboard payload read model。
- 未改 provider route runtime、Keychain、secret 读取或外部 provider 调用。
- 未改 TCC / signing identity / Info.plist / bundle ID。
- 未改 ScreenCaptureKit 低层 capture service 行为，只通过 `ScreenshotCapturing` 协议注入既有服务。

## 4. 关键实现决策

- `ScreenshotStore` 是 `lastCaptureSummary`、`recentCaptures`、`startScreenshot(mode:)`、`startRegionScreenshot()` 的 screenshot 事实源。
- `AppState.lastCaptureSummary` 和 `AppState.recentCaptures` 改为 computed facade，不再是 `@Published` 事实源。
- `AppState` 持有 `ScreenshotStore` 并桥接 `screenshotStore.objectWillChange`。
- 截图前权限刷新和 Screen Recording snapshot 检查在 `ScreenshotStore.startScreenshot(mode:)` 内执行：先 `permissionRefresher()`，再 `permissionSnapshotProvider()`，缺权时返回 `screenRecordingPermissionMissing`，由 `AppState` 触发既有 alert。缺权路径未静默触发真实权限请求。
- `ScreenshotStore` 不持有完整 `AppState`，只通过闭包接收 permission refresh、permission snapshot、routeResolver、statusRecorder 和 retakeHandler。
- `ScreenshotResultPresenter` 改为 `present(capture:routeResolver:retake:)`，`ScreenshotResultView` 不再依赖 `EnvironmentObject AppState`，AI route preview 通过 `routeResolver` closure 取得 `ProviderRouteResolution`。
- AI action / AI route preview 仍是本地 preview：`P3D` / `P3F` 继续验证 `provider_call_not_executed`、`image_not_uploaded` / no-upload，provider not called，image not uploaded。

## 5. P11A 检查摘要

新增 `p11a_screenshot_store_boundary_checks.py`，fail closed 覆盖：

- `ScreenshotStore.swift` 存在并进入 Blocks app target。
- `AppState` 不再直接 `@Published` 持有 `lastCaptureSummary` / `recentCaptures`。
- `AppState` 持有 `ScreenshotStore` 并桥接 `objectWillChange`，facade 仍保留。
- `ScreenshotStore` 不持有完整 `AppState`，不直接持有 `ProviderStore`。
- 截图前权限刷新和 snapshot 检查顺序存在，缺权路径不包含真实权限请求 token。
- Result presenter / route preview 通过窄接口和 routeResolver closure。
- Screenshot feature 文件不含 `URLSession`、`SecItem`、`Authorization`、`Bearer`、`Process(`、`getenv(`、ScreenCaptureKit 直连 token、`NSPasteboard.general`、OCR、upload、base64、窗口标题 / 屏幕文本输出 token。
- P3D / P3E / P3F / P7Q 不再以旧归档 / 旧 story / 旧 acceptance / 旧 AppState 字符串作为阻断事实源。

红灯证据：新增 P11A 后，未实现前运行失败，失败点包括缺 `ScreenshotStore.swift`、AppState 仍直接持有 screenshot facts、result presenter 仍依赖 AppState、旧事实源脚本命中。实现后 P11A 仅因本开发记录尚未写入而失败；写入本记录后进入最终验证。

## 6. 旧事实源处理

- `P3D`：移除旧 `p3-d-screenshot-ai-action-entries` story 依赖，阻断检查改为当前 PRD、当前开发记录和当前代码事实；输出 `baseline_reference.legacy_story_used_for_ok = false`。
- `P3E`：移除旧 `p3-e-screenshot-result-polish` story 依赖，阻断检查改为当前 PRD、当前开发记录和当前代码事实；继续覆盖 copy / save / retake / close 与 outcome banner。
- `P3F`：移除旧 `p3-f-screenshot-ai-route-ready` story 依赖，删除对 `environmentObject(appState)` 和 `present(capture: capture, appState: self)` 的旧结构断言，改为验证 `ScreenshotStore`、`ScreenshotResultPresenting` 和 `routeResolver` 当前结构。
- `P7Q`：移除旧 `000_归档` acceptance / story 读取，窗口 / 全屏阻断检查改为当前 PRD、当前开发记录、当前代码事实和 CLI dry-run。

旧归档 / 旧 story / 旧 acceptance 未参与本子批次 `ok` 判定；如需追溯，只能作为 baseline_reference / observation。

## 7. 运行命令和结果

| 命令 | 结果 |
| --- | --- |
| `python3 tools/verification/p11a_screenshot_store_boundary_checks.py` | PASS |
| `python3 tools/verification/p3c_screenshot_checks.py` | PASS |
| `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py` | PASS |
| `python3 tools/verification/p3e_screenshot_result_polish_checks.py` | PASS |
| `python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py` | PASS |
| `python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS |
| `git diff --check` | PASS |

验证说明：

- `P3C` 通过：app build / verify、CLI screenshot dry-run 三模式、invalid mode、entitlements、localization、P2 action smoke 均通过。
- `P3D` 通过：AI action entry、三语言 localization、privacy forbidden token、P3C regression 均通过；`baseline_reference.legacy_story_used_for_ok = false`。
- `P3E` 通过：copy / save / retake / close、outcome banner、in-panel result polish、P3D regression 均通过；`baseline_reference.legacy_story_used_for_ok = false`。
- `P3F` 首次复跑因 verification 迁移断言仍查找旧单行 `present(capture: capture,` 失败；已改为当前结构断言 `resultPresenter.present(` + `capture: capture,` + `routeResolver`，复跑 PASS。P3F 输出确认 P3E regression、P5M regression、AI route preview、routeResolver、provider not called、image not uploaded 均通过，且旧 story 未参与 `ok`。
- `P7Q` 通过：window / fullscreen 当前代码路径、window overlay hover/cancel、result mode/source/size、CLI dry-run window/fullscreen 均通过；输出已将 CLI command 中的项目根路径脱敏为 `<ROOT>`。
- app build 输出仍有既有 `FloatingPanelSupport.swift` actor warning 和 AppIntents metadata warning，本次未触碰相关代码。
- `blocks --help` 输出低敏 usage 和 action 列表：`blocks.screenshot.capture`。

## 8. 低敏证据

- P11A / P3D / P3E / P3F / P7Q 输出只记录代码路径、检查项、低敏状态、CLI dry-run mode 和 forbidden token 命中情况。
- `P3F` 证据包含 AI route preview、routeResolver、provider not called、image not uploaded，不包含真实截图图片、图片 base64、OCR 原文、窗口标题或屏幕文本。
- `P7Q` 证据覆盖 window / fullscreen 当前代码路径与 CLI dry-run，不记录真实屏幕内容。

## 9. 未覆盖项 / 残余风险

- 未做真实区域 / 窗口 / 全屏截图实物验收；未保存真实截图。
- 未撤销 Screen Recording 权限验证缺权真实路径；缺权路径通过当前代码和 P11A 静态门禁确认。
- 未触发真实权限请求、系统设置、Show in Finder、restart 或 TCC reset。
- 未触发 Result copy / save 的真实导出动作；copy / save / retake / close、outcome banner 保持由 P3E 静态与构建验证覆盖，真实 UI 操作留给后续测试/质量验收。
- 未调用真实 provider，不上传图片，不执行 OCR / 多模态 provider call。
- app build 预检出现既有 actor warnings，未在本子批次处理。

## 10. 安全隐私声明

- 本次未读取或保存真实敏感凭据、API key、Authorization header、完整 request body 或 provider raw response。
- 本次未上传图片，未保存真实截图 / base64 / OCR 原文，未记录真实窗口标题、屏幕文本、选中文本或剪贴板正文。
- 本次未自动触发真实权限请求、系统设置、Show in Finder、restart、TCC reset 或外部 provider call。
- 用户显式 copy / save 仍只存在于既有 Screenshot Result UI 路径；开发验证未触发这些真实导出动作。
