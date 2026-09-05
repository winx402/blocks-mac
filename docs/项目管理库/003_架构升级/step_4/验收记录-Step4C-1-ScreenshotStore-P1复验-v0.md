# Step 4C-1 ScreenshotStore 安全 P1 修复测试/质量复验记录 v0

日期：2026-07-06
角色：测试/质量
结论：accepted-with-residual-risk

## 复验范围

- 本次只复验安全合规提出的 P1：P3C / P3D / P3E / P3F / P5M / P7Q 失败路径输出低敏不足。
- 事实源：`开发记录-Step4C-1-ScreenshotStore-P1修复-v0.md`、上一轮 `验收记录-Step4C-1-ScreenshotStore-v0.md`、相关 verification 脚本。
- 未复验或启动 4C-2 ShortcutStore、4C-3 Settings shell、4C-4 Clipboard hardening。
- 未修改业务代码、未创建分支、未提交 commit。

## 复验结论

- P0：未发现。
- P1：已清零。安全 P1 低敏输出问题经独立串行复验关闭。
- 结论保留 `accepted-with-residual-risk`，原因是上一轮记录中的真实 UI / TCC / 实物截图残余风险仍未在本轮覆盖；本轮只处理 verifier 输出卫生。

## 已验证项

- `verification_sanitizer.py` 提供共享低敏 helper，覆盖 ROOT、HOME、邮箱、绝对本地路径、长 hex payload、TCC row / csreq / requirement 类输出。
- P3C / P3D / P3E / P3F / P5M / P7Q 的 subprocess stdout / stderr tail / command 输出接入共享 sanitizer。
- P11A 新增并通过 `sanitized_failure_output` 门禁，覆盖 P3C、P3D、P3E、P3F、P5M、P7Q。
- P11A self-check 输出只包含占位符 `<ROOT>`、`<HOME>`、`<EMAIL>`、`<PATH>`、`<REDACTED_TCC_REQUIREMENT>`，未暴露原始本地路径、home、邮箱、TCC raw requirement 或 csreq payload。
- 本轮复验命令输出未出现完整本地路径、用户 home、邮箱、TCC raw requirement、csreq payload、secret、Authorization header、截图/base64/OCR、窗口标题、屏幕文本或剪贴板正文。
- 本轮未触发真实截图、真实权限请求、系统设置、Show in Finder、restart、TCC reset、provider call 或图片外发。

## 命令结果

| 命令 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p3c_screenshot_checks.py` | PASS | `ok=true`，failures 为空；app build、verify、CLI region/window/fullscreen/bad-mode dry-run、entitlements、helper embed、本地化资源、P2 smoke 均通过。 |
| `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py` | PASS | `ok=true`，failures 为空；P3C regression 通过；`legacy_story_used_for_ok=false`；输出仅含相对文档路径。 |
| `python3 tools/verification/p3e_screenshot_result_polish_checks.py` | PASS | `ok=true`，failures 为空；P3D regression 通过；`legacy_story_used_for_ok=false`；privacy forbidden hits 为空。 |
| `python3 tools/verification/p5m_provider_routing_error_localization_checks.py` | PASS | `ok=true`，failures 为空；本地化 key checked=33；router runner 为结构化模拟输出，未触发真实 provider call。 |
| `python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py` | PASS | `ok=true`，failures 为空；P3E / P5M regression 通过；`image_upload=not_present`。 |
| `python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py` | PASS | `ok=true`，failures 为空；CLI dry-run 命令路径为 `<ROOT>/.../blocks`；window/fullscreen 输出均为 dry-run。 |
| `python3 tools/verification/p11a_screenshot_store_boundary_checks.py` | PASS | `sanitized_failure_output.gates` 包含 P3C/P3D/P3E/P3F/P5M/P7Q；`missing_gate_usage=[]`；self-check `ok=true`。 |
| `git diff --check` | PASS | 复验命令完成后运行，无输出。 |

所有命令按用户要求串行运行，未遇到 DerivedData / app process 争用失败。轻量状态追问后未再启动 P3F/P3E/P5M/xcodebuild 等重型门禁。

## 未覆盖项 / 残余风险

- 未覆盖真实 region/window/fullscreen 截图。
- 未覆盖真实 TCC 缺权、授权撤销、刚授权需重启路径。
- 未实物操作 Screenshot Result 面板 copy/save/retake/close。
- 未做多语言 / VoiceOver 实机验收。
- 未验证真实 provider、真实 OCR 或图片上传；本轮只确认相关路径未被触发且 verification 输出低敏。

## 质量判断

安全 P1 修复范围与证据闭合：相关 verifier 低敏输出已由共享 sanitizer 和 P11A fail-closed 门禁覆盖，指定复验命令均 PASS，P0/P1 清零。

建议主 agent 可以基于本记录继续 Step 4C-1 stop/go；真实 UI/TCC 残余风险仍需主 agent 单独决定是否接受，测试/质量不替主 agent 接受该风险。
