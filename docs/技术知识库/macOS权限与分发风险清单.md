# macOS 权限与分发风险清单

状态：proposed
最后审阅：2026-07-02
来源级别：technical verification

本文记录 V1 三类工具进入实现前必须验证的 macOS 权限、分发和用户信任风险。涉及系统能力的描述基于 2026-07-01 至 2026-07-02 对 Apple 官方资料的核验，但具体行为仍需要在目标 macOS 版本上实测。

## 核验来源

- ScreenCaptureKit：[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/)；[Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- Accessibility：[AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- Pasteboard：[NSPasteboard](https://developer.apple.com/documentation/AppKit/NSPasteboard)；[Pasteboard detection patterns](https://developer.apple.com/documentation/appkit/nspasteboard-detection-patterns)
- Sandbox / entitlements：[Security entitlements](https://developer.apple.com/documentation/bundleresources/security-entitlements)；[User Selected File read-write entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)；[Automation Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
- Login item / helpers：[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- Distribution：[Signing your apps for Gatekeeper](https://developer.apple.com/developer-id/)；[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)；[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 风险表

| 能力 | 可能涉及的系统能力 | 主要风险 | P2 验证动作 |
| --- | --- | --- | --- |
| 区域/窗口/全屏截图 | ScreenCaptureKit / 屏幕录制权限 | 用户必须理解为什么读取屏幕；开发签名、权限重置、多屏行为和完整选区体验需要实测。 | P2-C 已验证 display、rect、window 基础捕获链路；P2-F 已验证临时 overlay 拖拽选区；P2-K 已验证 boundary suite；后续补拒绝/撤销/重授权、多屏和完整截图 UI。 |
| 截图后 OCR/翻译/总结 | 屏幕截图 + OCR/provider | 截图内容可能包含敏感信息，外发 AI 风险高。 | 在 action schema 中强制预览和确认；P5-H 已把 OCR engine 与 LLM provider 分层；真实 OCR 前仍需记录本地 Apple Vision、multimodal LLM 和云 OCR 的数据流。 |
| 全局快捷键，默认 `Option + A` / `Option + V` 且可配置 | 全局热键、事件监听或 Input Monitoring | 不同实现路径可能触发不同权限；与系统/其他 App 快捷键冲突。 | 验证不使用低层键盘监听的热键方案；如需事件监听，记录 Input Monitoring 体验；验证更换、禁用、恢复默认和冲突提示。 |
| 选中文本翻译 | Accessibility、Services、快捷键复制或 AppleScript 等候选路径 | 读取当前 App 选区可能需要辅助功能或自动化权限；兼容性不稳定。 | 分别验证 Accessibility、复制桥接、Services/快捷指令路径，选择权限最少的方案。 |
| 剪贴板历史 | NSPasteboard | 长期记录剪贴板是高敏感行为；格式保留、隐私排除、暂停记录必须可靠。 | P2-D 已验证文本、RTF、PNG、URL、file URL 的低敏 fixture 恢复写回；P2-I 已验证 recorder 数据链路；P2-K 已验证复杂低敏 fixture 和 helper recorder roundtrip；后续补第三方实物样本、长期功耗和正式 UI。 |
| 粘贴历史回填到前台 App | NSPasteboard + 可能的事件发送/Accessibility | 写入剪贴板后触发粘贴可能需要辅助功能或事件发送权限。 | 先验证“选择条目后只写入剪贴板”；自动粘贴作为高风险增强单独验证。 |
| 文件保存/另存为/拖拽 | App Sandbox 文件权限、安全范围书签 | 官方沙盒直发包必须保持可解释的文件访问与用户提示。 | 验证用户选择文件夹、保存截图、拖拽导出和后续访问权限。 |
| 调用外部 CLI provider | 子进程、PATH、配置文件、凭据 | CLI 能力、输出格式、交互模式和许可边界不一致。 | 先只做 `--help`/无头能力探测；真实调用必须隔离工作目录、超时和输出 schema。 |
| API / LLM / OCR provider | 网络、API key、Keychain、接口错误 | 不能把密钥写仓库；外发数据需要确认；OCR 图片比普通文本更敏感。 | P2-E 已验证 Keychain 低敏 dummy secret 生命周期；P2-K 已验证 provider 设置确认 smoke；P5-G 已在正式 App 中验证固定低敏 Keychain fixture UI gate；P5-H 已加入 LLM / Translation / OCR profile catalog；P5-I 已加入 LLM adapter boundary 和本地 mock adapter；P5-K 已加入用户 API key Keychain 保存门禁和 OpenAI connection dry-run；P5-L 已加入低敏 OpenAI-compatible test connection 和主 App network client entitlement；真实工具内容调用前仍需接口路由、错误归一化、本地化错误文案和必要的外发确认。 |
| Hook runtime | 本地脚本/配置/agent 生成代码 | 任意脚本执行风险高；自动拦截和修改用户内容风险更高。 | V1 只定义 manifest 草案；P2-L 决定 helper 默认不运行 hook，hook 默认关闭，agent 只能生成草稿。 |
| 登录项/后台常驻 | SMAppService | 剪贴板历史和快捷键通常需要常驻；用户需要可见控制。 | P2-J 已验证 sandbox 下最小 Login Item/helper 的注册、状态、launchd 启动心跳、注销和清理；P2-K 已验证低敏 recorder roundtrip 和非零退出观察；P2-L 决定 helper 首轮优先承载 recorder、心跳和轻量事件采集；后续验证长期 recorder、功耗和用户撤销。 |
| 官方沙盒直发 | Developer ID、Hardened Runtime、Notarization | 未签名/未 notarize 会损害信任和安装体验；安装、更新和恢复链路必须真实验收。 | 当前规则固定为 MIT 开源、Developer ID 沙盒直发；不计划 App Store。 |

## 当前判断

- 截图、剪贴板、翻译三类工具都触碰高敏感本地数据，权限解释和数据流预览必须是产品基础能力，不是设置页附属能力。
- 官方发行当前锁定为 Developer ID 沙盒直发；`LocalDevelopment` 非沙盒且与官方身份、数据和 Keychain 隔离。前期不购买云服务器、不接真实支付。
- V1 不应默认启用自动粘贴、自动外发 AI、自动 hook 拦截这三类行为。
- 官方直发的签名、公证、更新和用户信任成本必须真实验证；不得以 App Store 路线替代这些验收。

## P2-B 本机实测摘要

执行时间：2026-07-01

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| 屏幕录制权限预检 | `BlocksMacOSProbe blocks-screen --preflight` | `authorized` | 只检查授权，不保存截图。 |
| 屏幕录制权限请求路径 | `BlocksMacOSProbe blocks-screen --request` | `authorized` | 当前环境已授权；未触发新的可见授权弹窗。 |
| Accessibility 检查 | `BlocksMacOSProbe blocks-accessibility --check` | `trusted` | 后续选中文本复制路径可继续验证。 |
| Accessibility 提示路径 | `BlocksMacOSProbe blocks-accessibility --prompt` | `trusted` | 当前环境已授权；未触发新的可见授权弹窗。 |
| 剪贴板摘要 | `BlocksMacOSProbe blocks-pasteboard --summary` | 读取到 1 个条目和类型列表 | 未输出剪贴板原文。 |
| 剪贴板文本预览 | `BlocksMacOSProbe blocks-pasteboard --include-text-preview` | 文本长度 9，短哈希 `023660ff9df7` | 原文未输出，仅用于验证读取链路。 |
| 默认热键注册 | `BlocksMacOSProbe blocks-hotkey --register-defaults` | `Option+A` 和 `Option+V` 注册后释放，OSStatus 均为 0 | 证明 Carbon `RegisterEventHotKey` 方案可做下一轮候选。 |
| 选中文本复制桥接 | `BlocksMacOSProbe blocks-selection-copy --manual --send-copy` | 已发送 Command+C，剪贴板未变化 | 当前前台环境没有产生新的选区复制结果；输出仍只含长度和哈希。 |

## P2-C 本机截图捕获实测摘要

执行时间：2026-07-01

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| 内容枚举 | `BlocksMacOSProbe blocks-capture --list` | 1 个 display、26 个 window、9 个候选 window | 只输出 ID、尺寸、app 名、标题长度；不输出窗口标题全文。 |
| 全屏 display 捕获 | `BlocksMacOSProbe blocks-capture --display-index 0 --write-png` | `ok=true`，3840x2160，1665946 bytes，短哈希 `80b43bd59024` | PNG 写入 ignored 本地目录 `tools/spikes/blocks_macos_probe/captures/`。 |
| 区域捕获 | `BlocksMacOSProbe blocks-capture --display-index 0 --rect 0,0,400,300 --write-png` | `ok=true`，800x600，175764 bytes，短哈希 `7cd39b8d8332` | CLI rect 以 display points 输入，当前 Retina 缩放为 2。 |
| 窗口捕获 | `BlocksMacOSProbe blocks-capture --window-index 0 --write-png` | `ok=true`，2648x1880，231530 bytes，短哈希 `2f093b9b00c5` | 使用 `SCContentFilter(display:including:)` + `sourceRect`；标题仅记录长度。 |

已知边界：

- 初始 `SCContentFilter(desktopIndependentWindow:)` 路径在当前 CLI 上触发 CoreGraphics assertion；已避开，但正式 App 仍需验证不同运行上下文。
- 当前机器只有 1 个 display，多屏未覆盖。
- 未测试屏幕录制权限拒绝、撤销、重授权路径。
- P2-C 当轮未实现拖拽选区 UI；只验证 CLI 矩形参数。

## P2-F 本机截图选择 UI 实测摘要

执行时间：2026-07-01

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| `NSScreen` 映射摘要 | `BlocksMacOSProbe blocks-capture --list` | `display_count=1`，`nsscreen_count=1`，`display_id=6`，scale 为 2 | 只输出屏幕 frame、visible frame、scale 和 display id。 |
| 交互区域截图 | `BlocksMacOSProbe blocks-capture --interactive-region --write-png --timeout 10` | `ok=true`，200x150 points 输出 400x300 PNG，58960 bytes，短哈希 `ab6d1382f26d` | PNG 写入 ignored `captures/`，不输出图片原文或 base64。 |
| 坐标转换 | 同上 | global rect `500,430,200,150` 转换为 display-local rect `500,500,200,150` | AppKit 全局坐标转换为 ScreenCaptureKit display-local `sourceRect`。 |
| 取消 | 同上，发送 `Esc` | `ok=false`，`status=cancelled` | 不写 PNG。 |
| 超时 | `--timeout 1` 且不操作 | `ok=false`，`status=timed_out` | 不写 PNG。 |
| 过小选区 | 极小拖拽 | `ok=false`，`status=selection_too_small` | 最小阈值 8x8 points，不写 PNG。 |

已知边界：

- 当前机器只有 1 个 display/NSScreen，多屏和跨屏拖拽未覆盖。
- 屏幕录制权限当前为 authorized；拒绝、撤销和重授权路径未覆盖。
- 本轮没有实现模式切换、窗口 hover 高亮、截图结果浮层、标注、OCR、翻译或 AI 总结。
- 交互成功、取消和过小选区用本机合成低敏键鼠事件验证。

## P2-D 本机剪贴板格式恢复实测摘要

执行时间：2026-07-01

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| 当前格式摘要 | `BlocksMacOSProbe blocks-pasteboard --formats` | `ok=true`，输出当前 item 数、类型列表、长度、尺寸和短哈希等 redacted 摘要 | 未输出原文或完整路径；具体 item 内容随当前剪贴板变化。 |
| 低敏 fixture 恢复写回 | `BlocksMacOSProbe blocks-pasteboard --fixture-roundtrip --kind all` | `text`、`rtf`、`image`、`url`、`file-url` 均 `roundtrip_equal=true` | 会覆盖当前剪贴板；不保存用户原剪贴板。 |
| 图片 fixture | 同上 | PNG 64x32，277 bytes，短哈希 `253a2f0e10f9` | 文件写入 ignored `fixtures/`。 |
| 文件引用 fixture | 同上 | basename `blocks-fixture-file.txt`，file URL 短哈希 `87584f0ce8de` | 不输出用户真实文件路径。 |
| 短时监听 | `BlocksMacOSProbe blocks-pasteboard --watch --seconds 10` | 捕获 1 次低敏文本 change；source app candidate 为 `com.openai.codex` | source app 只是 frontmost app 候选信号。 |
| 排除规则 | `BlocksMacOSProbe blocks-pasteboard --watch --seconds 10 --exclude-bundle-id com.openai.codex` | `excluded=true` 且 `snapshot_skipped=true` | 命中排除时不读取内容快照。 |

已知边界：

- P2-D 不是剪贴板历史库；未实现持久化、去重、搜索、固定、分组或过期清理。
- NSPasteboard 不可靠提供历史来源 App；正式 App 需要后台 recorder 在 changeCount 变化时记录 frontmost app 候选。
- 未覆盖密码管理器、浏览器隐私字段、Office/设计软件和其他复杂第三方 pasteboard 类型。
- 未验证自动粘贴到前台 App。

## P2-I 本机剪贴板 recorder 实测摘要

执行时间：2026-07-02

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| recorder fixture 全链路 | `BlocksMacOSProbe blocks-pasteboard --recorder-fixture-run --seconds 8 --store-name p2i-fixture --retention-seconds 3600 --max-items 20` | `ok=true`；`stored_count=5`，`duplicate_skipped_count=1`，`search_hit_count=5`，`restore_verified=true` | 只写入低敏 fixture；store 位于 ignored `recorder/` 目录。 |
| 过期清理与固定保留 | 同上 | `expired_removed_count=1`，`pinned_preserved=true` | 验证未固定过期项可清理，固定项不因过期删除。 |
| 隐私排除 watch | `BlocksMacOSProbe blocks-pasteboard --recorder-watch --seconds 5 --store-name p2i-watch --exclude-frontmost` | 手动写入低敏文本后 `skipped_count=1`，`snapshot_skipped=true` | 命中排除时不读取内容快照，只记录 source app candidate 和 skip reason。 |
| 非排除 watch | `BlocksMacOSProbe blocks-pasteboard --recorder-watch --seconds 5 --store-name p2i-watch-open` | 手动写入低敏文本后 `stored_count=1`，`restorable=false` | 真实 pasteboard 事件只保存类型、长度、短哈希和来源候选，不保存原文或可恢复 payload。 |
| recorder inspect | `BlocksMacOSProbe blocks-pasteboard --recorder-inspect --store-name p2i-watch-open` | 输出 redacted store 摘要 | 即使 fixture store 内部有低敏 payload，inspect 输出也会移除 payload。 |

已知边界：

- P2-I 仍是 CLI spike，不是正式剪贴板历史库 UI。
- P2-J 已验证最小 Login Item/helper 后台常驻链路；本轮没有把 recorder 迁入 helper。
- 真实用户剪贴板事件不可恢复；只验证脱敏索引，不保存真实原文、RTF、图片 base64、URL 原值或真实文件路径。
- 复杂第三方类型、密码管理器、浏览器隐私字段和 Office/设计软件格式仍未覆盖。

## P2-J 本机 Login Item/helper 实测摘要

执行时间：2026-07-02

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| 最小 App/helper 构建 | `tools/spikes/blocks_login_item_probe/scripts/build.sh` | 构建通过；主 app 和 helper 均 ad-hoc signed 且包含 App Sandbox entitlement | 本轮不使用 Developer ID；本机无有效 codesigning identity。 |
| 状态读取 | `BlocksLoginItemProbe blocks-login-helper --status` | 初始 `status=not_registered` | 可结构化区分未注册状态。 |
| 注册 | `BlocksLoginItemProbe blocks-login-helper --register` | `ok=true`，`status=enabled` | `SMAppService` 注册成功，未触发手动批准。 |
| 启动心跳 | `BlocksLoginItemProbe blocks-login-helper --roundtrip --seconds 8` | `ok=true`，`status=heartbeat_observed`，`observed_heartbeat_count=1` | helper 由 launchd 启动，心跳只含 bundle id、pid、sequence 和 timestamp。 |
| 注销清理 | `BlocksLoginItemProbe blocks-login-helper --unregister` | `ok=true`，`status=not_registered`；`pgrep` 无残留 | 注销前发送 stop notification。 |
| sandbox IPC 修正 | distributed notification `object` JSON | 通过 | 带 `userInfo` 的 distributed notification 会被 sandbox 拦截。 |

已知边界：

- P2-J 不是正式 App scaffold；没有实现 UI、长期 recorder、全局热键、外部 CLI 或 hook runtime。
- 修改 helper 可执行文件后必须先注销再重新注册，避免 stale registration 或 launch constraint 异常。
- 当前本机未覆盖用户在系统设置中撤销或要求批准后的 `requires_approval` 路径。

## P2-K 批量边界实测摘要

执行时间：2026-07-02

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| 截图 boundary suite | `BlocksMacOSProbe blocks-capture --boundary-suite --write-png` | display、edge rect、window 均 `ok=true`；当前 `display_count=1` | 多屏和跨屏仍未覆盖；PNG 只写 ignored `captures/`。 |
| 复杂剪贴板 fixture | `BlocksMacOSProbe blocks-pasteboard --complex-fixture-roundtrip --kind all` | HTML、multi、transient、file-list 均 `roundtrip_equal=true` | 只用低敏 fixture；不代表密码管理器/Office/设计软件实物样本已覆盖。 |
| Pasteboard detection patterns | `BlocksMacOSProbe blocks-pasteboard --detection-patterns-fixture` | SDK 支持状态可记录，但运行时调用标记 `detection_patterns_not_covered` | Swift refined API 命名需要单独 compile spike。 |
| helper recorder | `BlocksLoginItemProbe blocks-login-helper --recorder-roundtrip --seconds 8` | helper 收到 start 后发送 1 条 redacted pasteboard event，hash 匹配低敏 fixture | 默认心跳不读取剪贴板内容；不证明长期轮询功耗。 |
| helper 非零退出观察 | `BlocksLoginItemProbe blocks-login-helper --restart-policy-check` | 非零退出请求已发送；短窗口未观察到 restart heartbeat；注销后无残留 | 只记录当前 launchd 行为，不等于正式崩溃恢复策略。 |
| Provider 设置确认 | `python3 tools/spikes/blocks_provider_settings_smoke.py smoke` | mock API / CLI profile 均输出 `external_transfer` preview | 不读 env、Keychain、CLI token，不访问网络。 |

已知边界：

- 多屏、权限撤销、第三方复杂样本和长期 helper 性能仍是环境依赖复测项。
- P2-K 不证明 App Store 审核边界、真实 API 调用或完整 hook runtime。

## P2-L 正式 App scaffold 架构摘要（历史，运行/分发规则已被当前规则取代）

执行时间：2026-07-02

| 约束 | 当时结论 | 风险影响 |
| --- | --- | --- |
| scaffold 形态 | `SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core` | P3 起步约束，不代表完整 App 已创建。 |
| Main App | UI、权限引导、设置、确认卡片、Keychain、审计展示 | 用户可见授权集中在主 App，降低 helper/CLI 绕过确认风险。 |
| Helper | 剪贴板 recorder、后台心跳、轻量事件采集 | 默认不执行外部 CLI provider、hook 或自动粘贴。 |
| CLI / agent | `blocks` 前缀和统一 JSON envelope | 需要确认时必须返回或触发 `requires_confirmation`。 |
| Provider / hook | 外发、启用、阻断、修改、删除必须确认和审计 | 真实 API 调用和 hook enabled 仍未进入正式实现。 |

## P4-D / P4-E / P4-F / P4-G / P4-H 正式工程剪贴板 recorder 摘要

执行时间：2026-07-02

| 能力 | 验证 | 当前结果 | 说明 |
| --- | --- | --- | --- |
| 真实 watch debug path | `p4d_clipboard_real_recorder_debug_checks.py` | helper 可短时监听低敏 pasteboard change 并写入 redacted metadata | 不注册 Login Item，不长期常驻，不输出真实原文。 |
| preflight | `p4e_clipboard_recorder_restore_preflight_checks.py` | 当前 backend 为 `sandbox_application_support`，`app_group_entitlement_enabled=false` | 本地 `Sign to Run Locally` 不启用 App Group，避免 provisioning profile 阻塞。 |
| 低敏 payload store | 同上 | `schema_version=0.2.0`，低敏 fixture `payload_count=4` | 只为 fixture 写 payload；inspect/watch/UI 不输出 payload。 |
| fixture 恢复写回 | 同上 | text、rich text、image、URL fixture 均可恢复写回 pasteboard | 会覆盖当前剪贴板；输出只含类型、长度/字节数、短哈希和 changeCount。 |
| 不可恢复路径 | 同上 | excluded record 返回 `record_not_restorable`，missing record 返回 `record_not_found` | 真实 watch 事件继续 `restorable=false`。 |
| runtime gate | `p4f_clipboard_runtime_gate_checks.py` | 主 App 可显式运行 preflight、10 秒 redacted watch、导入 helper 脱敏摘要和 reset debug store | 不注册长期 Login Item；主 App 不直接读取 `NSPasteboard`。 |
| long debug session | `p4g_clipboard_long_recorder_checks.py` | helper 在 fixture 事件后保持运行，stop/terminate 前已 flush redacted record；App Group candidate 为 `not_configured_for_app_group` | 不启用 App Group entitlement；不注册 SMAppService Login Item。 |
| App Group readiness gate | `p4h_app_group_readiness_checks.py` | App/helper 签名仍无 application-groups entitlement；helper preflight 返回 `sandbox_isolated` / `ad_hoc_without_app_group` | 只验证 readiness 和 UI 诊断；不创建 provisioning profile，不启用共享容器。 |

已知边界：

- P4-H 是 readiness gate，不是开机常驻 recorder，也不是正式 App/helper 共享容器落地。
- 真实用户剪贴板内容仍不保存 payload，不开放恢复写回。
- App Group 共享容器需要在开发签名 / provisioning 决策后复测；当前 ad hoc 构建下 `containerURL` 即使返回候选 URL，也不代表 entitlement 或共享写入已可用。

## P2-E 本机 Keychain secret 实测摘要

执行时间：2026-07-01

| 能力 | 探针 | 本机结果 | 说明 |
| --- | --- | --- | --- |
| Keychain fixture 生命周期 | `BlocksMacOSProbe blocks-keychain --fixture-roundtrip --delete-after` | `ok=true`；add/read/update/read/delete/missing-read 全链路通过 | 只使用低敏 dummy secret，不输出原文。 |
| 初始清理 | 同上 | `pre_delete_existing_fixture` 返回 `errSecItemNotFound`，作为可接受初始状态 | 避免旧测试项导致 duplicate。 |
| 写入和读取 | 同上 | v1 短哈希 `d956cd35f877`，v2 短哈希 `bd95e552c241`，读回均匹配 | 输出只含长度、字节数和短哈希。 |
| 删除验证 | 同上 | 删除后读取返回 `errSecItemNotFound`，`cleanup_verified=true` | 测试结束后不保留 Keychain 项。 |

已知边界：

- 未读取真实 API key，也未读取环境变量。
- 未执行真实 API provider 调用。
- 未实现 provider 设置 UI、未提交本地配置文件、未实现审计日志。

## P5-G 正式 App Keychain UI gate 摘要

执行时间：2026-07-02

| 能力 | 验证 | 当前结果 | 说明 |
| --- | --- | --- | --- |
| 低敏 Keychain UI gate | `p5g_keychain_ui_gate_checks.py` | `ok=true`；add/read/update/delete/missing-read 全链路通过 | 固定 service 为 `app.blocks.provider.dev`，account 为 `mock-api:<alias>`。 |
| 脱敏输出 | 同上 | 输出不包含固定低敏 fixture secret 原文 | UI 和审计只展示 service、account、OSStatus、长度和 SHA-256 前 12 位。 |
| provider connection gate 回归 | 同上 | P5-F 回归通过 | BYOK API 的 Keychain fixture gate 可通过，但网络测试、真实 API key 输入和真实 provider 调用仍被阻断。 |

已知边界：

- P5-G 不提供真实 API key 输入框，不读取环境变量，不访问网络，不执行本地 CLI。
- 固定低敏测试项只用于验证 Keychain 生命周期；不代表 BYOK、真实 provider 或持久审计日志已完成。

## P5-H AI Capability provider 分层摘要

执行时间：2026-07-02

| 能力 | 当前结果 | 说明 |
| --- | --- | --- |
| LLM Provider | 已加入 profile catalog | 预留 Local Mock、OpenAI-compatible、LiteLLM / Gateway、本地 CLI / Agent；当前不执行真实调用。 |
| Translation Engine | 已与 LLM provider 分层 | 预留 LLM-backed 翻译和专用翻译 API；当前 Local Mock 仍是唯一可运行路径。 |
| OCR Engine | 已加入 profile catalog | 预留 Apple Vision、本地 mock、多模态 LLM OCR 和云 OCR；当前不读取图片、不执行 OCR。 |

已知边界：

- P5-H 只证明 Settings catalog、文案和文档边界；不代表真实 provider、真实 OCR 或真实 API key 输入已完成。
- 任意非本地 OCR / LLM / 翻译外发仍必须走 `external_transfer` 确认和审计。

## P5-I LLM adapter 边界摘要

执行时间：2026-07-02

| 能力 | 当前结果 | 说明 |
| --- | --- | --- |
| LLM adapter protocol | 已加入正式 App | 定义 request、response、error、output format 和 OpenAI-compatible profile boundary。 |
| OpenAI-compatible preview | Settings 可生成脱敏预览 | 只记录 provider、model、base URL host 摘要、Keychain account alias、来源摘要、字符数和 `external_transfer` 确认级别。 |
| 本地 mock adapter | 可生成 mock response | 不调用 API、CLI、OCR、网络、Keychain 或剪贴板。 |

已知边界：

- P5-I 不代表真实 BYOK、真实 API provider、真实 CLI provider 或真实 OCR 已完成。
- 真实工具内容 provider 调用前仍需要接口路由、错误归一化、本地化错误文案和必要的敏感内容外发确认；P5-L 只覆盖低敏 ping test connection。

## P5-J / P5-K / P5-L API key 输入、Keychain 保存与连接门禁摘要

执行时间：2026-07-02

| 能力 | 当前结果 | 说明 |
| --- | --- | --- |
| API key 输入预览 | Settings 已加入受控 `SecureField` | 候选 key 只在本地 view state 中短暂停留；preview 后清空，不写 Keychain，不输出 secret 或 hash。 |
| OpenAI connection draft | Settings 可生成 request draft metadata | 记录 base URL host、model、account alias、endpoint 和 timeout；不调用网络。 |
| 审计摘要 | 新增 `secretInputPreview` / `openAIConnectionPreview` | 只记录脱敏元数据和 audit id。 |

已知边界：

- P5-K 代表用户 API key 可显式保存到 Keychain；P5-L 代表低敏 OpenAI-compatible test connection 可在显式确认后短生命周期读取 Keychain secret。
- P5-L 不代表真实翻译、OCR、总结、截图/剪贴板内容外发、streaming、重试或持久审计已完成。

## P2-G sandbox-first 分发约束摘要（历史，已被当前规则取代）

执行时间：2026-07-01

| 约束 | 当前结论 | 说明 |
| --- | --- | --- |
| sandbox-first | 已作为当前决策记录 | 正式 App 从一开始按 App Sandbox 约束设计，敏感能力要列 entitlement/TCC/确认/失败路径。 |
| 分发渠道 | 历史上未锁死 | 当时保留 Local Dev、Direct Download、App Store 分阶段路线；现已固定为官方 Developer ID 沙盒直发。 |
| 本地开发 | 历史上不需要 Developer ID | 当时使用 Xcode/local signing；现行 LocalDevelopment 另有非沙盒隔离规则。 |
| 外部分发 | Alpha 前准备 Developer ID + Hardened Runtime + notarization | 现在不把证书、profile 或 notarization 配置写入仓库。 |
| 服务器 | 前期不购买 | 只有账号、订阅、远程撤销、设备绑定、云同步等需要后端或第三方服务。 |
| 订阅 | 不接真实支付 | 当时记录 Apple 自动续订订阅路线；现行规则不计划 App Store/StoreKit。 |

## 待实测清单

1. ScreenCaptureKit 多屏边界、跨屏选区真实交互、权限拒绝/撤销/重授权路径和完整截图 UI。
2. 自定义全局热键 UI、冲突提示、禁用和恢复默认。
3. P4-G debug session 之后的开机常驻轮询、功耗、崩溃重启、App Group 共享容器和用户暂停/排除体验。
4. 密码管理器、浏览器隐私字段、Office/设计软件等复杂 pasteboard 类型和排除策略；补 NSPasteboard detection patterns runtime。
5. 真实工具内容 provider 调用前的接口路由、错误归一化、本地化错误文案和必要的数据出境确认。
6. 在明确低敏选中文本样本上复测选中文本翻译的最低权限实现路径。
7. 自动粘贴是否需要 Accessibility 或事件发送权限。
8. sandbox 下 Login Item/helper 的用户撤销、`requires_approval`、系统设置复测和正式共享容器签名配置。
9. Alpha 前 Developer ID + Hardened Runtime + notarization 最小发布链路。
