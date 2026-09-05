# 004_剪贴板打磨 Step 2 R1 测试/质量定向复审 v0

日期：2026-07-07

结论：`approve`

## 复审范围

本轮只复审 Step 2 R1 验证矩阵，不重新做 Step 2 全量复审，不进入 Step 3。未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置或自动化。

聚焦问题：

- P13B / P9A 是否足以证明 tag search 缺失文档与 rebuild 路径已闭合。
- P9B 是否覆盖旧 `pinnedCount` active path 退出。
- P8 是否覆盖 tag-only filter clear-all。
- P8I / P11E / P13A / P9C 是否保留必要回归边界。
- Blocks App / BlocksCLI build、CLI help、`git diff --check` 是否足以支撑 Step 2 R1 进入最终收敛。

## P0 / P1 / P2 Findings

P0：无。

P1：无。上一轮由代码审查提出、项目负责人要求 R1 修复的 tag search 缺失文档 / rebuild 路径问题，从测试/质量视角已关闭。

P2：

- 真实 UI 操作、真实剪贴板、真实 Settings 管理和系统快捷路径未执行，仍属于人工实物验收残余风险；本轮只读范围下不构成阻塞。
- 右键菜单仍使用固定默认标签名 `New Tag` 创建标签，但文案已改为 `Create "New Tag"` 口径，不再暗示会弹出输入；维持上一轮 P2 residual risk。
- Blocks App build 仍有既有 `FloatingPanelSupport.swift` `NSApp.isActive` main actor warning；本轮未见 R1 新增构建失败或 blocker。

## R1 验证判断

### tag search 缺失文档与 rebuild 路径

判断：足以支撑关闭。

证据：

- `P13B` 通过，输出 `tag_search.contract_gate=pass`、`tag_search.e2e_gate=pass`，并明确 e2e source 指向 `tools/verification/p9a_clipboard_repository_storage_smoke.py`。
- `P9A` 通过，`verified_tag_fixtures` 包含 `tag_search_missing_document_repair` 与 `tag_search_rebuild_path`，覆盖“已有 tagged record -> search doc 缺失 / rebuild -> tag search 仍可命中”的 R1 核心路径。
- `P13B` 同时保留 `fixtures_body_excludes_tag_name=true`，避免把标签名混入 body 造成假通过。

### 旧 pinnedCount active path 退出

判断：覆盖充分。

证据：

- `P13B` 通过，`legacy_exit.active_store_paths_clear=true`，forbidden store tokens 包含 `pinnedCount`。
- `P9B` 通过，覆盖 AppState / repository integration 侧旧 `pinnedCount` active path 负向检查。
- 静态抽查 `pinnedCount` 只出现在 verification forbidden token 和 BlocksCore 兼容/录制结构字段中，未出现在 Blocks App active store path。

### tag-only filter clear-all

判断：覆盖充分。

证据：

- `P8` 通过，包含 `step2_clear_all_includes_tag_filter=true`。
- R1 代码抽查显示 header clear-all 通过 `displayFilterState.hasActiveFilters` 暴露，并在 `clearFilters()` 路径清空 `tagStore.selectedTagID`。

### 必要回归边界

判断：保留充分。

证据：

- `P8I` 通过，保留 Settings clipboard system / Step 2 tag settings / legacy pinboard settings removed 边界。
- `P11E` 通过，保留 clipboard hardening 低敏和 payload read deny 边界，且 tag filter/menu/settings 均无 payload read。
- `P13A` 通过，保留 Step 1 plaintext/search/OCR 回归边界。
- `P9C` 通过，保留 no-reset fixtures UI 边界。

### build / CLI / diff

判断：足以支撑 Step 2 R1 进入最终收敛。

证据：

- Blocks App Debug build 通过。
- BlocksCLI Debug build 通过。
- `DerivedData/Blocks/Build/Products/Debug/blocks --help` 通过，输出可用命令和 usage。
- `git diff --check` 通过。

## 实际运行或抽查的命令

| 命令 / 抽查 | 结果 | 关键证据 |
| --- | --- | --- |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS | `ok=true`；`tag_search.e2e_gate=pass`；legacy exit active checks clear |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | `tag_search_missing_document_repair`、`tag_search_rebuild_path` 在 verified fixtures 中 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | `ok=true`；旧 pinboard storage 仅 baseline |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | `step2_clear_all_includes_tag_filter=true` |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS | Step 2 tag settings / legacy pinboard settings removed checks 通过 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | tag filter/menu/settings no payload reads；filtered records no pinned display name |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | `ok=true`；低敏 sanitizer 通过 |
| `python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py` | PASS | `ok=true` |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `** BUILD SUCCEEDED **`；仅见既有 warnings |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | `** BUILD SUCCEEDED **` |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 输出 `blocks.screenshot.capture` 与 usage |
| `git diff --check` | PASS | 无输出 |
| `rg -n "pinnedCount\|func pinnedCount\|static func pinnedCount" ...` | PASS / 静态抽查 | active App path 未发现旧 `pinnedCount` |
| `sed -n '180,210p' apps/Blocks/BlocksApp/Views/ClipboardRecordViews.swift` | PASS / 静态抽查 | 右键新建标签使用 `defaultQuickTagName` 与本地化文案 |
| `rg -n "clipboard\\.tags\\.createDefault\|Create \\\"New Tag\\\"\|New Tag" ...` | PASS / 静态抽查 | `Localizable.xcstrings` 中英文文案为 `Create "New Tag"` |

## 结论

Step 2 R1 的验证矩阵对本轮收敛目标是充分的：tag search 缺失文档与 rebuild 路径、旧 `pinnedCount` active path 退出、tag-only filter clear-all、必要回归边界和构建/CLI/diff 均有独立证据支撑。

建议项目负责人可将 Step 2 R1 进入最终收敛判断；是否接受 P2 实物风险仍应由项目负责人结合用户目标决策。
