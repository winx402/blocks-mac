# P4-H App Group Readiness Gate

状态：implemented
日期：2026-07-02
来源级别：implementation record

## Summary

本轮在 P4-G 显式 recorder debug session 之后补齐 App Group / provisioning 的 readiness gate：helper preflight 会区分 application group entitlement、共享容器可用性、共享模式和签名配置状态；主 App Clipboard 面板可以显式运行 App Group readiness preflight，并展示用户可读的 sandbox isolated / ad hoc without App Group 结果。

P4-H 不启用 App Group entitlement，不引入 Developer Team / provisioning profile，不注册 Login Item，也不改变当前 sandbox-first 本地构建策略。

## Implemented

- `JDToolLoginItemHelper --recorder-preflight` 新增字段：
  - `application_group_entitlements`
  - `app_group_container_available`
  - `sharing_mode`
  - `provisioning_assessment`
- helper 使用 `SecTaskCopyValueForEntitlement` 只读检查当前签名里的 `com.apple.security.application-groups`，不读取用户数据、不修改权限。
- 当前默认 ad hoc / no App Group 构建下，preflight 返回：
  - `app_group_candidate_status=not_configured_for_app_group`
  - `sharing_mode=sandbox_isolated`
  - `provisioning_assessment=ad_hoc_without_app_group`
  - `backend=sandbox_application_support`
- Clipboard 面板新增：
  - sharing mode badge
  - provisioning badge
  - `Check App Group Readiness` 按钮
- 三语 String Catalog 增加 P4-H 新增 UI 文案。
- 新增 `tools/verification/p4h_app_group_readiness_checks.py`：
  - 构建正式 App。
  - 检查 App / helper 签名 entitlements 仍为 sandbox-first 且没有 application-groups。
  - 运行 helper preflight 并校验 readiness 字段。
  - 检查 UI 本地化和关键 runtime symbols。
  - 检查 workspace debug store 仍未写入。

## Boundaries

- P4-H 不是共享容器落地；它只是把“当前没有 App Group / provisioning”变成可检测、可展示、可回归的工程状态。
- `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 在当前环境可能返回候选 URL，但没有 entitlement 时不可作为可用共享容器；P4-H 以 entitlement + container 可用性作为 `app_group_container_available` 的判断基础。
- 主 App 仍不直接读取 `NSPasteboard`；系统剪贴板读取仍只发生在显式 helper debug path 内。
- 真实长期 Login Item recorder、App Group 共享 store、长期功耗、真实用户内容恢复和 App Store 审核边界仍未完成。

## Verification

- `python3 tools/verification/p4h_app_group_readiness_checks.py --timeout 180`
- `python3 tools/verification/p4g_clipboard_long_recorder_checks.py --timeout 180`
- `python3 tools/verification/p4f_clipboard_runtime_gate_checks.py --timeout 180`
- `python3 tools/verification/p4e_clipboard_recorder_restore_preflight_checks.py --timeout 180`
- `python3 tools/verification/p5f_provider_connection_gate_checks.py --timeout 180`

完整回归结果以本轮提交前命令输出为准。
