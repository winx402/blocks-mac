# P7-H 真实交互回归修复

状态：implemented with automated checks; stable signing and core TCC paths passed in P7-O

本轮回应 P7-G 后真实交互测试暴露的问题：Debug App 使用 ad-hoc signing 和 DerivedData 路径导致 TCC 身份不稳定，Screen Recording / Accessibility 授权后仍可能无法闭环；Clipboard 自动粘贴对目标 App 激活失败缺少明确分型；Permission Assist 的箭头和按钮需要更稳定；Translation 交换语言后 result metadata 没有立即同步。

## References

- Supersedes P7-G follow-up: [P7-G story](p7-g-permission-settings-interaction-rework.md)
- Apple Screen & System Audio Recording permission: <https://support.apple.com/guide/mac-help/allow-apps-to-use-screen-and-audio-recording-mchl592e5686/mac>
- Apple Accessibility permission: <https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac>

## Issue Ledger

| ID | User issue | Research | Plan | Dev | Test | Close |
| --- | --- | --- | --- | --- | --- | --- |
| P7-H-01 | Screen Recording 授权后截图仍不可用，重启 App 后仍失败。 | Apple Development 身份可用后曾发现 System Settings 中 `JDTool` 为 on，但 App `CGPreflightScreenCaptureAccess()` 仍为 false；根因是旧 TCC `csreq` 绑定到旧 cdhash，稳定 App 重建后不再匹配。 | `build_and_run.sh` 固定到 ASCII staging app path，并在没有稳定签名身份时 fail-fast 可选、UI 直接显示身份不稳定诊断。 | build 脚本将构建产物复制到 `~/Applications/JDToolDev/Debug/JDTool.app`；权限 snapshot 增加 running paths、signature kind、Team ID、usage description 和 identity issue；P7-O 对 `com.jdtool.app` 做针对性 ScreenCapture reset 后由稳定 App 重新授权。 | `p7h_stable_signing_permission_identity_checks.py` 覆盖；P7-O 真实区域截图已通过。 | `closed_by_p7o`. |
| P7-H-02 | Accessibility 授权后 Clipboard 双击仍不可用。 | 自动粘贴只能保证写入系统剪贴板并发送 `Cmd+V`，目标 App 激活可能失败，且从 JDTool/System Settings 打开的面板不能作为粘贴目标。 | 自动粘贴分型为写入剪贴板、已发送命令、缺权限、目标丢失、目标激活失败；不再把失败包装成成功。 | `ClipboardAutoPasteCoordinator` 移除 deprecated activation 路径，使用目标 App 激活结果做 `target_activation_failed` 分型，并清理 stale target；P7-O 增加面板级 Return 粘贴路径并实测双击卡片。 | `p7h_clipboard_autopaste_activation_checks.py` 覆盖；P7-O TextEdit 真实粘贴已通过。 | `closed_by_p7o`. |
| P7-H-03 | Permission Assist 面板按钮和箭头仍不够稳定。 | 面板需要可访问性可点击控件，箭头动画应只作用于箭头自身并指向系统设置窗口。 | 完成/关闭按钮使用有稳定 frame 的控件；箭头用循环展开动画，不抖动整个面板。 | `PermissionAssistPanelPresenter` 调整 close/completed button frame 和 arrow animation loop。 | `p7h_stable_signing_permission_identity_checks.py` 与 P7-F/P7-G 回归覆盖静态边界；真实 System Settings 相对定位仍需人工验收。 | `implemented`; close after manual Permission Assist pass. |
| P7-H-04 | Translation 交换语言后目标语言、结果卡片和复制内容可能不同步。 | 交换语言只更新 picker，不立即刷新 preview / route / mock result。 | 交换后立即刷新 preview 并触发一次自动翻译；本地 mock result 记录真实 source language mode。 | `TranslationFloatingPanelView.swapLanguages()` 调用 immediate refresh；`OpenAITranslationRuntimeService.localMockResult` 接收 source language mode。 | `p7h_translation_swap_result_sync_checks.py` 覆盖。 | `implemented`; close after low-sensitive language swap pass. |

## Verification

- `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build`
- `./script/build_and_run.sh --verify`
- `python3 tools/verification/p7h_stable_signing_permission_identity_checks.py`
- `python3 tools/verification/p7h_clipboard_autopaste_activation_checks.py`
- `python3 tools/verification/p7h_translation_swap_result_sync_checks.py`
- P7-G / P7-F / P7-A 回归脚本
- `python3 tools/spikes/p2_action_smoke.py validate-schemas`
- `python3 tools/spikes/p2_action_smoke.py smoke`

## Manual Acceptance Still Required

- 使用 Apple Development 或等价稳定签名身份构建后，重新授权 Screen Recording，再执行 Region / Window / Fullscreen 低敏截图。
- 在 TextEdit 或 Notes 中聚焦输入框后打开 Clipboard，双击低敏可恢复 fixture，确认状态显示到 `已发送粘贴指令` 或明确失败原因。
- Accessibility 列表中如果没有当前稳定 App，按权限页诊断中的 app path 重新添加后再点击“我已完成”刷新。
- Permission Assist 必须在 System Settings 出现后展示，箭头方向与窗口相对位置一致，拖 App 图标不移动面板。
- Translation 中文/英文/日文输入交换语言后，目标语言、结果卡片和复制译文一致。

## Notes

- 本轮不使用 `tccutil reset`，不修改系统权限数据库，不伪造授权成功。
- 当前机器没有有效 Apple Development signing identity；自动化只能证明代码路径、诊断和 UI 状态分型，不能证明真实 TCC 已通过。
- 本轮不新增 OCR runtime、长期 Login Item、真实截图/OCR 外发、剪贴板历史完整内容恢复或 provider 商业策略。
