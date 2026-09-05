# 004_剪贴板打磨 Step 4 R1 测试/质量定向复审 v0

日期：2026-07-07
角色：测试/质量
范围：Step 4 R1 / R1a 定向复审，仅复核详情编辑与元数据组织 R1 返工证据；不进入 Step 5。

## 1. 结论

结论：`approve`。

P0/P1：清零。从测试/质量视角，上一轮五个 P1 均已有可复跑的 deterministic fixture、静态绑定证据或低敏 verifier 证据支撑，未发现新的 P0/P1。

建议项目负责人可以进入 Step 4 最终接受准备；最终接受仍由项目负责人决定。本复审不替代真实 UI / 真实剪贴板 / 真实 VoiceOver 的后续实物回扫。

## 2. 复审输入

- `项目负责人-Step4开发复审收敛-v0.md`
- `项目负责人-开发派发-Step4-R1-v0.md`
- `开发记录-Step4-R1-v0.md`
- `开发记录-Step4-R1a-v0.md`
- `项目负责人-Step4-R1验收-v0.md`
- `产品经理-PRD-v1.md`
- `App架构师-技术方案-v1.md`

## 3. P1 关闭情况

| 原 P1 | 复核结论 | 主要证据 |
| --- | --- | --- |
| P13D 假 PASS | 已关闭 | `p13d_clipboard_detail_edit_checks.py` 会编译并执行临时 Swift fixture；fixture 编译失败、执行失败、JSON 不合法、scenario 缺失、evidence 缺字段、scenario assertion false、purpose negative reuse 非 0 都进入 failures。实跑输出 `ok=true`、`failure_summary.count=0`、29 个 scenario 均 PASS。 |
| OCR user-edited guard | 已关闭 | P13D `detail_ocr_user_edited_retry_004` 覆盖 user-edited save -> late completion -> retry -> second completion，断言 text/source/locked revision 保留；`detail_ocr_late_completion_ignored_004` 覆盖 late completion rejected。 |
| Dirty-navigation 三动作 | 已关闭 | P13D `detail_dirty_navigation_004` 覆盖 pending navigation action、request open/close guard、Save and Continue / Discard Changes / Continue Editing、confirmation dialog、overlay close guard、record switch open guard。当前证据是静态绑定 + store path，不声称真实点击已覆盖。 |
| Metadata full value read/copy | 已关闭 | P13D `detail_full_value_read_004` 输出显式 `detailFullValueRead`；`detail_full_value_copy_fake_pasteboard_004` 输出 fake copy attempt、full value feedback、category layout、accessibility hint，且 real pasteboard write 为 0。 |
| Rich text 编辑合同 | 已关闭 | P13D `detail_rtf_format_004` 覆盖 link、paragraph、inline style、list、kind remains rich text、plain text derivation updated；`detail_rtf_fidelity_failure_004` 覆盖 malformed RTF fail closed 且 mutation/revision 不变。 |

补充判断：P13D 当前证据中的 `development_record` 已指向 `开发记录-Step4-R1-v0.md`，R1a 指针问题已关闭。

## 4. P13D 可信度复核

P13D 当前不是仅靠 token presence 的门禁。脚本中存在 `run_swift_fixture`，会使用 `swiftc` 编译临时 Swift fixture，并执行 repository fixture。动态 scenario 覆盖保存成功、URL valid/invalid、rich text、OCR guard、fault injection、revision conflict、cache invalidation、pasteboard、full value、migration。

本次实跑关键结果：

- `failure_summary.count=0`
- `purpose_matrix.negative_reuse_count`：`hoverDetail`、`paste`、`copyPlainText`、`translationPreview`、`ocrInput`、`searchIndex`、`provider` 均为 0。
- save path `pasteboard_read_attempts=0`、`pasteboard_write_attempts=0`。
- invalid / conflict / rollback / record missing / payload missing 类 scenario 的 `mutation_count=0` 或具备等价无部分提交断言。
- sanitizer self-check PASS，输出样例已脱敏为 `<ROOT>`、`<HOME>`、`<EMAIL>`、`<PATH>`、`<REDACTED_TCC_REQUIREMENT>`。

非阻断证据 polish：P13D `current_evidence.dispatch` 仍指向原 Step 4 开发派发文档，而不是 R1 派发文档；因 PRD v1、技术方案 v1、R1 开发记录和动态 fixture 已参与本轮判断，这不构成 P1。建议后续把 R1 dispatch 明确加入 current evidence 或新增 `rework_dispatch` 字段，降低追溯歧义。

## 5. 回归矩阵结果

| 命令 | 结果 | 复审备注 |
| --- | --- | --- |
| `python3 tools/verification/p13d_clipboard_detail_edit_checks.py` | PASS | Step 4 专属 hard gate 通过。 |
| `python3 tools/verification/p13a_clipboard_plaintext_search_ocr_checks.py` | PASS | Step 1 明文搜索 / OCR / 设置页边界未见回归。 |
| `python3 tools/verification/p13b_clipboard_tags_model_checks.py` | PASS | Step 2 标签 / 收藏 / tag search / legacy pinboard 退出未见回归。 |
| `python3 tools/verification/p13c_clipboard_panel_interaction_layout_checks.py` | PASS | Step 3 面板交互 / layout / sanitizer 证据未见回归。 |
| `python3 tools/verification/p8_clipboard_product_polish_checks.py` | PASS | product polish、tag-only clear all、bounded preview 通过。 |
| `python3 tools/verification/p8i_settings_clipboard_system_checks.py` | PASS | Settings clipboard/system 边界通过。 |
| `python3 tools/verification/p9a_clipboard_repository_storage_smoke.py` | PASS | schema version 4、search/tag/OCR fixtures 与 `<TMP>` storage root 通过。 |
| `python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py` | PASS | AppModel / repository / tag/search integration 未见假 PASS。 |
| `python3 tools/verification/p11e_clipboard_hardening_checks.py` | PASS | 默认 payload denied sites、legacy Step 4D baseline-only 通过。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | 有既有 Swift actor-isolation warning 和 AppIntents metadata skipped warning；未阻塞构建。 |
| `xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build` | PASS | CLI target 构建通过。 |
| `DerivedData/Blocks/Build/Products/Debug/blocks --help` | PASS | 只输出 usage 与 `blocks.screenshot.capture` action。 |
| `git diff --check` | PASS | 写文档前通过。 |

## 6. 低敏与真实动作边界

本轮未运行真实 App，未读取或写入真实系统剪贴板，未触发 provider、Keychain、TCC、System Settings、Finder 或自动化动作。`blocks --help` 仅执行 help 输出。

Verifier 输出未发现真实剪贴板正文、真实 OCR 原文、完整 URL query、secret、Authorization header 或图片/base64 泄漏。Xcode build 日志按工具默认会包含本地构建路径；本复审文档不复制这些路径作为验收证据。

## 7. P2 Residual

P2-1：真实 UI 点击、dirty-navigation sheet 默认焦点、overlay dismiss、record switch 的实物路径未自动化覆盖。当前以 store path、Swift 编译和静态绑定证据支撑，建议 Step 6 或最终手工回扫。

P2-2：真实 VoiceOver 未实测。当前只能确认低敏 accessibility binding / checklist 证据，不能声称系统读屏实际体验通过。

P2-3：真实系统剪贴板 copy full value 未覆盖。本轮实现和验收使用 explicit full value read + fake copy evidence，不写真实 pasteboard；如后续产品要求真实复制，需要单独验收 user-triggered pasteboard adapter。

P2-4：Rich text fidelity 覆盖代表性 RTF fixture，不等价于覆盖所有真实来源 RTF 变体。当前策略是无法证明保真时 fail closed，不静默降级保存；真实跨 App 富文本仍需后续实物样本补证。

P2-5：构建仍有既有 Swift actor-isolation warning，可后续统一收口；本轮未见与 Step 4 R1 验收直接相关的 build blocker。

## 8. 建议

可以进入 Step 4 最终接受准备。最终接受前建议项目负责人保留上述 P2 residual，并确认是否需要在 Step 6 集成回扫中补真实 UI、真实 VoiceOver、真实 pasteboard adapter 和跨 App rich text 样本。
