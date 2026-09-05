# Step 4C-1 ScreenshotStore 测试/质量验收记录 v0

日期：2026-07-06
角色：测试/质量
结论：accepted-with-residual-risk

## 验收范围

- 本次仅验收 Step 4C-1 ScreenshotStore 子批次。
- 未启动、未验收 4C-2 ShortcutStore、4C-3 Settings shell、4C-4 Clipboard hardening。
- 未创建分支、未提交 commit、未修改业务代码。
- 角色职责文档使用更正后的 `agents/测试-质量.md`。

## 已验证项

- `ScreenshotStore.swift` 存在并进入 Blocks app target；P11A target membership 检查通过。
- `ScreenshotStore` 成为 `lastCaptureSummary`、`recentCaptures`、截图启动流程和 recent capture 记录的事实源。
- `AppState.lastCaptureSummary`、`AppState.recentCaptures` 为 computed facade；`AppState` 持有 `screenshotStore`，并通过 `bindScreenshotStore()` 桥接 `screenshotStore.objectWillChange`。
- `AppState.startScreenshot(mode:)` 委托 `screenshotStore.startScreenshot(mode:)`；Screen Recording 缺权时仍由 AppState 调用既有 `showScreenRecordingAlert()` 协调 UI。
- `ScreenshotStore.startScreenshot(mode:)` 中权限顺序为 `permissionRefresher()` 后读取 `permissionSnapshotProvider()`，再检查 `screenRecordingGranted`。
- `ScreenshotStore` 不直接持有 `ProviderStore`，AI route preview 通过 `routeResolver` closure；结果 presenter / view 不再依赖 `AppState` environment object。
- P11A forbidden token 检查通过：`ScreenshotStore.swift` 内未发现 Keychain、network、provider runtime、CLI、pasteboard、ScreenCaptureKit 低层、OCR、upload、base64、windowTitle、screenText 等禁止 token。
- P3D/P3E/P3F/P7Q 均使用当前 Step 4C PRD、当前 4C-1 开发记录和当前代码作为阻断事实源；输出显示旧归档/旧 story 仅为 baseline reference，且不参与 `ok`。
- P7Q CLI dry-run 覆盖 window/fullscreen，输出使用 `<ROOT>` 脱敏；未暴露窗口标题、屏幕文本、截图、base64、OCR、剪贴板正文、secret 或 Authorization header。
- 未发现开发范围静默扩大到 ShortcutStore、Settings shell、Clipboard hardening、真实 provider、Keychain、TCC/signing 改动、ScreenCaptureKit 低层或真实 OCR/图片外发。

## 命令结果

| 命令 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p11a_screenshot_store_boundary_checks.py` | PASS | `ok=true`，failures 为空；target membership、AppState direct fact source、forbidden tokens、historical gate current sources 均无命中。 |
| `python3 tools/verification/p3c_screenshot_checks.py` | PASS | app verify、CLI region/window/fullscreen/bad-mode dry-run、entitlements、helper embedded、localizable resource 均通过。 |
| `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py` | PASS | P3C regression 通过；localization checked=10；privacy forbidden hits 为空；`legacy_story_used_for_ok=false`。 |
| `python3 tools/verification/p3e_screenshot_result_polish_checks.py` | PASS | P3D regression 通过；copy/save outcome 与本地化检查通过；privacy forbidden hits 为空；`legacy_story_used_for_ok=false`。 |
| `python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py` | PASS | P3E、P5M regression 通过；privacy forbidden hits 为空；`image_upload=not_present`；`legacy_story_used_for_ok=false`。 |
| `python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py` | PASS | window/fullscreen capture path、overlay cancel、result panel mode/source/size、CLI dry-run modes 全部 true；`legacy_archive_used_for_ok=false`。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`；未出现 copy login item / signing / DerivedData 失败。存在既有 Xcode 多 destination warning、`FloatingPanelSupport.swift` MainActor/NSApp warning、AppIntents metadata skipped warning。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `BUILD SUCCEEDED`；未出现 signing / DerivedData 失败。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出包含 `blocks.screenshot.capture`，usage 为 `blocks list | blocks run blocks.screenshot.capture --dry-run [--mode region|window|fullscreen]`。 |
| `git diff --check` | PASS | 首轮检查无输出。 |

说明：收到并发 DerivedData/build 争用协调更新后，重型命令按测试/质量线程串行执行。未遇到 copy login item、signing、DerivedData 相关失败，因此未触发稳定性复跑。

## 未验证项 / 环境限制

- 未触发真实 region/window/fullscreen 截图；未采集真实屏幕图像。
- 未在真实 TCC 缺权 / 刚授权需重启 / 授权撤销环境下操作 Screen Recording missing path。
- 未触发真实权限请求、系统设置跳转、Show in Finder、restart 或系统级动作。
- 未实物操作 Screenshot Result 面板 copy/save/retake/close；copy/save 成功、失败、取消仅由代码结构和静态门禁覆盖。
- 未调用真实 provider、真实 OCR、图片上传或外部网络；本次仅验证其未被接入当前路径。
- 未做 VoiceOver / 多语言实机截图验收；本次覆盖本地化资源结构和关键 key。

## P0 / P1 / P2

- P0：未发现。
- P1：未发现。
- P2：真实 UI/TCC 实物验收仍未覆盖，建议在主 agent 做 4C-1 stop/go 后，作为后续人工或 UI 专项补证，不阻断本子批次代码门禁。
- P2：`FloatingPanelSupport.swift` MainActor/NSApp warning 和 AppIntents metadata skipped warning 仍存在；本轮未见其导致 4C-1 失败，但建议在独立技术债或后续门禁中跟踪。

## 质量判断

自动化门禁与代码抽查足以支撑 Step 4C-1 ScreenshotStore 子批次进入主 agent stop/go。残余风险主要集中在真实桌面/TCC/UI 操作未覆盖，测试/质量不替主 agent 接受该残余风险。

建议：允许主 agent 基于本记录做 4C-1 stop/go；若进入后一子批次，应继续执行 PRD 中的子批次硬门禁，且前一子批次 P0/P1 未关闭时不得启动后一子批次。
