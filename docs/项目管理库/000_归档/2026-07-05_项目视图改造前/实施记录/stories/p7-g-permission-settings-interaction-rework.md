# P7-G 权限与设置交互重构评审

状态：implemented with automated checks; superseded by P7-H for signing / TCC interaction follow-up

本轮回应 P7-F 后继续暴露的问题：设置侧边栏“工具/偏好”分组语义混乱、Screen Recording 授权后仍不可用且缺少 request/recover 诊断、Accessibility 授权入口不完整、Clipboard 双击自动粘贴缺少明确 attempt 状态，以及 Permission Assist 仍需要显式状态机约束。

后续 P7-H 已进一步收敛稳定签名、运行路径、TCC 身份诊断、Clipboard target activation 分型和 Translation 交换同步；当前真实交互验收应以 [P7-H story](p7-h-real-interaction-regression-fix.md) 为准。

## References

- Apple Screen & System Audio Recording permission: <https://support.apple.com/guide/mac-help/allow-apps-to-use-screen-and-audio-recording-mchl592e5686/mac>
- Apple Accessibility permission: <https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac>
- Apple ScreenCaptureKit guide: <https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos>
- Apple `AXIsProcessTrustedWithOptions`: <https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions>
- Supersedes targeted P7-F follow-up: [P7-F story](p7-f-settings-permission-regression-fix.md)

## Issue Ledger

| ID | User issue | Research | Plan | Dev | Test | Close |
| --- | --- | --- | --- | --- | --- | --- |
| P7-G-01 | 设置侧边栏分成“工具/偏好”，但工具只剩 Screenshot，语义不成立。 | 当前主入口已经是浮层快捷键，侧边栏更像设置目录；继续显示工具分组会制造错误心智模型。 | 移除可见分组，只保留 `Screenshot`、`Clipboard`、`Translation`、`Shortcuts`、`Providers`、`Permissions`、`General` 七个设置分类。 | `AppSection` 移除 `AppSectionGroup`；`ContentView` 直接渲染分类列表；Clipboard / Translation 继续映射到设置页。 | `p7g_permission_settings_interaction_checks.py` 和更新后的 `p7d_settings_routes_sidebar_visual_checks.py` 覆盖。 | `implemented`; close after manual sidebar pass. |
| P7-G-02 | Screen Recording 授权后截图仍失败，重启 App 后也可能失败。 | Apple 支持文档确认权限必须在 Privacy & Security 中显式授权；当前 Debug 包是 ad-hoc signing，TCC 识别可能不稳定。旧实现只有 `CGPreflightScreenCaptureAccess()`，缺少主动 request 和诊断。 | 权限页提供 Check / Request / Recover：显示 app path、bundle id、签名、Team ID、usage description、preflight 和建议动作；点击授权先调用 `CGRequestScreenCaptureAccess()`，再打开系统设置 fallback。 | 新增 `PermissionDiagnosticSnapshot`；Info.plist 增加 `NSScreenCaptureUsageDescription`；权限页显示诊断卡片、Finder 定位、完成后刷新和 ad-hoc signing 说明。 | `p7g_permission_settings_interaction_checks.py`、`p7f_permission_state_refresh_checks.py` 和构建验证覆盖；真实 TCC 结果仍需低敏人工验收。 | `implemented`; close after low-sensitive Screen Recording pass. |
| P7-G-03 | Accessibility 授权后 Clipboard 双击仍不工作。 | Accessibility 需要 `AXIsProcessTrustedWithOptions(prompt: true)` 触发请求；自动粘贴只能发送 `Cmd+V` 事件，不能承诺目标输入框一定接受。 | 权限页提供独立 Accessibility 请求；自动粘贴前重新检查 AX trust；缺权限进入 assist，用户点击“我已完成”后只重试 pending paste 一次。 | `PermissionStateService.requestAccessibilityAccess()` 调用 `AXIsProcessTrustedWithOptions`；AppState 授权入口和 pending paste retry 接入统一权限刷新。 | `p7g_permission_settings_interaction_checks.py`、`p7f_clipboard_autopaste_permission_retry_checks.py` 覆盖；真实 TextEdit / Notes 仍需低敏人工验收。 | `implemented`; close after low-sensitive Accessibility pass. |
| P7-G-04 | 自动粘贴失败时缺少具体原因，容易误以为已成功。 | 当前系统事件只能证明已发送 paste 指令，无法证明目标输入框接受。目标 App 也可能丢失、是 JDTool / System Settings，或条目不可恢复。 | 双击条目后记录 `ClipboardPasteAttempt`，关闭浮层，恢复目标 App，写 pasteboard，发送 `Cmd+V`；失败分型为未授权、目标丢失、条目不可恢复、payload 缺失、事件创建失败等。 | 新增 `ClipboardPasteAttempt` / state / failure reason；自动粘贴排除 JDTool 和 System Settings；状态文案改为 typed failure。 | `p7g_permission_settings_interaction_checks.py` 覆盖 attempt 模型和失败分型。 | `implemented`; close after low-sensitive paste pass. |
| P7-G-05 | Permission Assist 呼出、定位、箭头和关闭逻辑仍不稳定。 | 面板必须等 System Settings 窗口出现后再定位；箭头方向应该永远指向权限列表；拖 App 图标不应拖动整个面板。 | 改成显式状态机 `idle -> openingSystemSettings -> waitingForSettingsWindow -> guiding -> checkingPermission -> granted / failed / cancelled / timedOut`。 | 新增 `PermissionAssistSession`；Presenter 等待 System Settings、按窗口左右定位、同步箭头方向、关闭背景拖动，并通过“我已完成”触发 checking。 | `p7g_permission_settings_interaction_checks.py`、`p7f_permission_assist_position_drag_checks.py` 覆盖；真实窗口相对位置仍需人工验收。 | `implemented`; close after manual Permission Assist pass. |

## Verification

- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `python3 tools/verification/p7g_permission_settings_interaction_checks.py`
- `python3 tools/verification/p7d_settings_routes_sidebar_visual_checks.py`
- `python3 tools/verification/p7f_permission_state_refresh_checks.py`
- `python3 tools/verification/p7f_permission_assist_position_drag_checks.py`
- `python3 tools/verification/p7f_clipboard_autopaste_permission_retry_checks.py`

## Manual Acceptance Still Required

- 设置侧边栏只显示七个设置分类，不再出现“工具/偏好”分组。
- Screen Recording 权限页能显示 bundle id、app path、签名、Team ID、usage description 和建议动作；授权后点击“我已完成”能刷新状态。
- 如果 Screen Recording 仍失败，UI 必须显示 ad-hoc signing / stable signing 诊断，而不是假装已解决。
- Accessibility 权限页可独立触发请求；授权后低敏 fixture 双击只声明“已发送粘贴指令”，失败时显示具体原因。
- Permission Assist 在 System Settings 出现后再弹出，贴近系统设置窗口，箭头方向一致，拖 App 图标不会移动面板。

## Notes

- 本轮不使用 `tccutil reset`，不修改系统权限数据库，不伪造授权成功。
- 当前 Debug 阶段仍允许 ad-hoc signing；如果低敏验收继续证明 TCC 不稳定，下一步应单独做 Apple Development / 稳定签名 story。
