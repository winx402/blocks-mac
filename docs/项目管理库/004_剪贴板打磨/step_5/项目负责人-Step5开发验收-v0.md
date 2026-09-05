# Step 5 开发验收 v0

日期：2026-07-07
角色：项目负责人
对象：`004_剪贴板打磨` Step 5：隐私页真实 App 清单与 CLI 广义对象管理
状态：rework-required

## 1. 验收输入

- [产品经理 PRD v1](产品经理-PRD-v1.md)
- [App 架构师技术方案 v1](App架构师-技术方案-v1.md)
- [项目负责人开发派发 Step5 v0](项目负责人-开发派发-Step5-v0.md)
- [开发记录 Step5 v0](开发记录-Step5-v0.md)

## 2. 验收结论

本轮 Step 5 开发不接受，要求开发 R1 返工。

阻塞原因不是主功能方向，而是 P13E hard gate 的证据合同没有按已接受技术方案 v1 和测试/质量 v1 定向复审收敛落地。当前 P13E 可以 `ok=true`，但未输出被接受的顶层 evidence schema，也未使用被接受的 required scenario id，因此存在假 PASS 风险。

Step 5 继续停留在开发返工阶段；R1 验收通过前不进入角色复审，也不进入 Step 6。

## 3. 已通过的验收项

项目负责人独立复跑以下验证，通过：

- `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py`
- `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py`
- `python3 tools/verification/p13b_clipboard_tags_model_checks.py`
- `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py`
- `python3 tools/verification/p13d_clipboard_detail_edit_checks.py`
- `python3 tools/verification/p11e_clipboard_hardening_checks.py`
- `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py`
- `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py`
- `python3 tools/verification/p8_clipboard_product_polish_checks.py`
- `python3 tools/verification/p8i_settings_clipboard_system_checks.py`
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build`
- `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build`
- `DerivedData/Blocks/Build/Products/Debug/blocks --help`
- `git diff --check`

构建未启动 App；`blocks --help` 只读取 CLI help，没有执行 policy mutation。

## 4. P1：P13E evidence schema 与 accepted contract 不一致

### 4.1 事实

技术方案 v1 与测试/质量 v1 定向复审接受的 P13E stdout 顶层结构要求包含：

- `ui_interaction`
- `capture_bridge`
- `performance`

其中 `ui_interaction` 至少包含：

- `search_fields`
- `filter_combination`
- `sort_stability`
- `a11y`
- `layout`

当前项目负责人复跑 P13E 后解析 stdout，结果为：

```text
top_keys = baseline_reference, checked_files, current_evidence, failures, gate, ok, required_categories, scenarios, sensitive_output_summary
top_level_ui_interaction = False
top_level_capture_bridge = False
top_level_performance = False
```

当前 P13E 把证据放在 `required_categories` 和 `scenarios[].category` 下，而不是 accepted contract 要求的顶层 evidence schema。这样即使顶层 `ui_interaction` / `capture_bridge` / `performance` 缺失，P13E 仍返回 `ok=true`。

### 4.2 影响

这违反了技术方案 v1 第 9.2 / 9.4 / 9.5 节和测试/质量 v1 定向复审对两个 P1 的关闭条件。

如果接受当前实现，后续复审者会看到 P13E PASS，但无法按已接受 schema 稳定断言 UI interaction、capture bridge 和 performance evidence 是否存在，属于 P1 假 PASS。

## 5. P1：required scenario id 未使用 accepted id

### 5.1 事实

技术方案 v1 / 测试质量 v1 定向复审 / 项目负责人开发派发已明确要求 P13E 至少包含以下 exact scenario id：

UI interaction / layout：

- `privacy_app_search_fields_004`
- `privacy_app_filter_combination_004`
- `privacy_app_sort_stability_004`
- `privacy_app_row_a11y_004`
- `privacy_app_narrow_width_004`
- `privacy_app_long_text_i18n_004`

Capture bridge：

- `privacy_capture_bundle_restricted_004`
- `privacy_capture_bundle_allowed_004`
- `privacy_capture_app_path_precedence_004`
- `privacy_capture_default_allow_004`
- `privacy_capture_missing_path_fallback_004`
- `privacy_capture_snapshot_low_sensitive_004`

当前项目负责人复跑 P13E 后解析 `scenarios[].scenario_id`，上述 12 个 accepted id 全部缺失。P13E 当前使用的是另一组 `_005` 命名，例如：

- `ui_search_name_bundle_source_status_005`
- `ui_filter_policy_status_and_identity_005`
- `ui_sort_stable_with_icon_updates_005`
- `ui_row_accessibility_labels_005`
- `capture_snapshot_restricted_bundle_id_005`
- `capture_snapshot_allowed_bundle_id_005`
- `capture_snapshot_restricted_path_hash_precedence_005`

### 5.2 影响

场景内容可能有重叠，但当前 accepted contract 依赖 exact scenario id 做 fail-closed 验收。自行改名会导致文档、复审和 verifier 的对齐关系断裂，也会让后续角色无法直接按 PRD/技术方案核查是否覆盖必验项。

## 6. R1 返工要求

开发 R1 只需优先关闭上述 P1；不要扩大到 Step 6，不做无关重构。

必须做到：

- P13E stdout 顶层包含 `ui_interaction`、`capture_bridge`、`performance`。
- `ui_interaction` 顶层对象必须至少包含 `search_fields`、`filter_combination`、`sort_stability`、`a11y`、`layout`。
- `capture_bridge` 顶层对象必须至少包含 `snapshot_shape` 与 `scenarios`。
- `performance` 顶层对象必须至少包含技术方案 v1 要求的 `elapsed_ms`、`threshold_ms`、`fixture_count`、`sample_count`。
- P13E 的 required scenario id 使用 accepted exact id，不得仅用自定义 `_005` 名称替代。
- 如果保留 `_005` 名称作为内部实现别名，也必须在 stdout 和 fail-closed required scenarios 中输出 accepted `_004` id。
- P13E 必须 fail-closed：缺上述顶层字段、子字段或 exact scenario id 时 `ok=false`。
- 更新开发记录或新增 R1 开发记录，明确 P13E schema / id 对齐结果。

建议 R1 最小验证：

- `python3 tools/verification/p13e_clipboard_privacy_policy_checks.py`
- 一个解析脚本确认顶层 `ui_interaction` / `capture_bridge` / `performance` 存在，12 个 accepted id 不缺失。
- `git diff --check`

如果 R1 修改 Swift 实现或 target membership，需要复跑对应构建和相关回归门禁。

## 7. 非阻塞观察项

`excludedBundleIdentifiers` 仍存在于 `ClipboardRecorderPolicy` schema 和 fixture document 中，但当前静态调用点检查未发现 `.policy.excludedBundleIdentifiers` 被读取，也未出现在 `ClipboardCapturePolicy` / `ClipboardStore` / `AppModel` active fact source 中。此项暂不作为 P1，但 R1 不应重新把它接回 active policy input。
