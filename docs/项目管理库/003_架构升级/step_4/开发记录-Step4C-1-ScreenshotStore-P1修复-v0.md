# Step 4C-1 ScreenshotStore P1 修复开发记录 v0

日期：2026-07-06

## 结论

DONE。

安全合规提出的 P1 已完成最小范围修复：P3C / P3D / P3E / P3F / P5M / P7Q verifier 的失败路径输出统一经过低敏 sanitizer，P11A 增加 fail-closed 门禁，防止完整本地路径、用户 home、邮箱、TCC raw requirement / csreq payload 等进入 verification JSON 或验收可复制输出。

## 修复背景

安全合规 Step 4C-1 实现复审结论为 `changes-requested`，P1 指向 verifier 失败路径低敏不足：历史 P3F 失败详情曾暴露完整本地路径。该问题不证明 ScreenshotStore 业务代码存在图片外发或敏感数据外发，但会污染 verification JSON / 验收记录，因此接受前必须修复。

开发线程在根因确认后长时间未回调；主会为避免阻塞 4C-1 stop/go，接手完成最小 verifier 修复收口。范围仅限 verification 输出和记录，不修改 ScreenshotStore / AppState / UI 产品行为。

## 改动文件

- `tools/verification/verification_sanitizer.py`
- `tools/verification/p3c_screenshot_checks.py`
- `tools/verification/p3d_screenshot_ai_action_entry_checks.py`
- `tools/verification/p3e_screenshot_result_polish_checks.py`
- `tools/verification/p3f_screenshot_ai_route_ready_checks.py`
- `tools/verification/p5m_provider_routing_error_localization_checks.py`
- `tools/verification/p7q_screenshot_window_fullscreen_checks.py`
- `tools/verification/p11a_screenshot_store_boundary_checks.py`
- `docs/项目管理库/003_架构升级/step_4/开发记录-Step4C-1-ScreenshotStore-P1修复-v0.md`

## 修复内容

- 新增共享低敏 helper：`verification_sanitizer.py`。
- 统一处理 ROOT、HOME、邮箱、绝对本地路径、长 hex payload、TCC row / csreq / requirement 等高风险输出。
- P3C / P3D / P3E / P3F / P5M / P7Q 的 subprocess stdout / stderr tail / command 输出接入 sanitizer。
- P11A 增加 `sanitized_failure_output` 门禁：
  - 检查 sanitizer 文件存在和接口符号存在。
  - 检查 P3C / P3D / P3E / P3F / P5M / P7Q 均接入共享 sanitizer。
  - 运行 sanitizer self-check，样例覆盖 `<ROOT>`、`<HOME>`、`<EMAIL>`、`<PATH>`、`<REDACTED_TCC_REQUIREMENT>`。

## 未改范围

- 未改 ScreenshotStore 业务行为。
- 未改 ScreenshotCaptureService / ScreenCaptureKit 底层。
- 未改 Screenshot Result copy / save / retake / close 行为。
- 未改 provider routing 业务逻辑、Keychain、network、runtime provider 调用。
- 未启动 Step 4C-2 / 4C-3 / 4C-4。

## 验证结果

以下命令已串行运行，避免 DerivedData / app process 争用：

- `python3 tools/verification/p3c_screenshot_checks.py`：PASS
- `python3 tools/verification/p3d_screenshot_ai_action_entry_checks.py`：PASS
- `python3 tools/verification/p3e_screenshot_result_polish_checks.py`：PASS
- `python3 tools/verification/p5m_provider_routing_error_localization_checks.py`：PASS
- `python3 tools/verification/p3f_screenshot_ai_route_ready_checks.py`：PASS
- `python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py`：PASS
- `python3 tools/verification/p11a_screenshot_store_boundary_checks.py`：PASS
- `git diff --check`：写入本记录前 PASS；写入后 PASS

## 残余风险

- 本次只修复 verifier 失败路径低敏输出，不补真实截图 / TCC / copy-save-retake UI 实物验收。
- P11A 是静态与输出卫生门禁，不能替代真实 UI/TCC 验收。
- P5M 仍保留其既有 story candidate 读取逻辑；本次只处理安全 P1 指向的失败输出低敏，不扩大为 P5M 事实源迁移。

## 安全隐私声明

- 未读取、保存或输出真实敏感凭据。
- 未调用真实外部 provider。
- 未上传图片，未保存真实截图 / base64 / OCR 原文。
- 未输出真实窗口标题、屏幕文本、选中文本或剪贴板正文。
- 未触发真实权限请求、系统设置、Show in Finder、restart 或 TCC reset。
