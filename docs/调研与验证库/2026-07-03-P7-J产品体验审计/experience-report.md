# P7-J 产品体验审计报告

status: completed-with-blockers
created: 2026-07-03
auditor roles: product-design:audit, UX review
product: 积木工具 / Blocks
build: `./script/build_and_run.sh --verify`

## 审计范围

本轮审计覆盖当前正式 App 的主窗口、设置导航、权限流程、截图入口、Clipboard 浮层、Translation 浮层、Provider 设置、Shortcuts 设置和基础视觉风格。审计证据只使用本次运行捕获的截图；无法完成的交互写为 blocker 或 `not_covered`。

截图证据保存在 `screenshots/`。

## 运行与验证摘要

- `./script/build_and_run.sh --verify`：通过，但警告 Apple Development 证书信任设置不是系统默认值，运行回退到 ad-hoc 签名，TCC 权限绑定不可靠。
- `p7i_clipboard_bottom_tray_window_checks.py`：通过。
- `p7i_clipboard_tray_visual_structure_checks.py`：通过。
- `p7h_stable_signing_permission_identity_checks.py`：通过。
- `p7h_clipboard_autopaste_activation_checks.py`：通过。
- `p7h_translation_swap_result_sync_checks.py`：通过。
- `p2_action_smoke.py validate-schemas`：通过。
- `p2_action_smoke.py smoke`：通过。
- `p4k_clipboard_recorder_policy_checks.py`：失败；失败点是并发构建 / helper 产物拷贝链路，不是剪贴板策略断言本身。
- `p5q_translation_language_error_ux_checks.py`：失败；失败点同样集中在构建 / helper 拷贝和 app 打开路径，不是内部 translation runner 的核心断言。

## 截图索引

1. `01-main-window.png` - 主窗口默认截图页。
2. `02-settings-general.png` - 通用设置页。
3. `03-permissions.png` - 权限与隐私页。
4. `04-clipboard-bottom-tray.png` - Clipboard bottom tray。
5. `05-clipboard-hover-detail.png` - Clipboard hover 状态。
6. `06-translation-panel.png` - Translation 浮层。
7. `07-provider-settings.png` - Provider / AI 设置。
8. `08-shortcuts-settings.png` - Shortcuts 设置。
9. `09-clipboard-settings.png` - Clipboard 设置。
10. `10-translation-settings.png` - Translation 设置。
11. `11-screenshot-home-before-action.png` - 截图首页。
12. `12-screenshot-permission-action.png` - 点击截图区域后的权限提示。
13. `13-permission-assist-after-open-settings.png` - 打开系统录屏设置后的系统设置窗口。

## 步骤审计

### 1. App 启动与主窗口

证据：`01-main-window.png`

健康度：中等。

主窗口能稳定打开，左侧菜单不再按“工具 / 偏好”分组，之前“工具只有截图”的语义问题已缓解。问题是首页仍显示 `P3-B 截图模式` 这类工程阶段文案，作为正式工具入口显得像开发面板，不像用户可直接使用的产品首页。主窗口默认仍偏大而空，首屏没有把三大核心工具的常用动作组织成一套统一启动面板。

### 2. 设置导航与通用设置

证据：`02-settings-general.png`

健康度：中等偏低。

设置页视觉已经统一了彩色图标、深色玻璃面板和较大的菜单行高，但内容区仍存在明显的“卡片堆叠”感。通用页底部内容被窗口裁切，滚动条可见性弱；用户不知道下面还有多少内容。侧边栏在当前窗口高度下可以看到主要项，但如果后续增加菜单，需要继续验证侧边栏独立滚动。

### 3. 权限与隐私诊断

证据：`03-permissions.png`

健康度：低。

权限页能显示关键信息：Bundle ID、App 路径、签名、Team ID、用途说明和身份诊断。当前状态显示 Screen Recording 未授权、签名为 ad-hoc、Team ID 为无，并明确提示系统设置中的同名 App 可能不是当前运行路径。这个诊断方向正确。

主要问题是用户行动路径仍不完整：用户需要知道“现在应该怎么修复证书/路径/权限”以及“完成后如何确认”。目前信息密度高，像工程诊断面板，不像用户授权向导。

### 4. 截图入口与未授权反馈

证据：`11-screenshot-home-before-action.png`、`12-screenshot-permission-action.png`

健康度：中等。

点击区域截图后弹出权限说明，底层页面也更新为“需要屏幕录制权限”。这比沉默失败好。问题是弹窗和页面同时出现两套说明，且弹窗只提供“打开设置”，没有展示当前签名 / 当前路径 / 完成后检查的闭环。用户授权后如果仍失败，很难从弹窗判断下一步。

由于当前系统录屏权限未开启，Region / Window / Fullscreen 的真实捕获未覆盖。

### 5. 打开系统录屏设置与 Permission Assist

证据：`13-permission-assist-after-open-settings.png`

健康度：低。

点击“打开设置”后系统设置打开到了录屏与系统录音页，Blocks 出现在列表中但开关关闭。实测没有看到 Blocks 的辅助授权面板。因此用户仍需要自己理解该去哪里打开权限，之前规划的“贴近系统设置的辅助面板 + 箭头 + App 图标”没有形成可靠体验。

另一个风险是，自动化过程中 `osascript` 被系统拒绝辅助访问，说明当前机器的辅助访问链路本身不稳定；这会影响自动粘贴和测试脚本。

### 6. Clipboard bottom tray

证据：`04-clipboard-bottom-tray.png`

健康度：中等。

bottom 模式已经符合关键形态：满宽、贴底、横向卡片、右上角设置和关闭、底部轻量快捷键提示。相比普通窗口感已经明显改善。

主要问题是卡片区域和背景模糊层还是偏重，像一个半透明的大遮罩；Paste 的底部历史 tray 更强调“卡片带”本身，而当前面板右侧有大片模糊空白，视觉重心不够集中。搜索栏和卡片之间的比例也略松，面板高度偏高时内容仍集中在左侧。

### 7. Clipboard hover 与条目操作

证据：`05-clipboard-hover-detail.png`

健康度：中等偏低。

鼠标 hover 后能看到卡片上的 pin / delete 操作，但没有出现明显的 hover detail popover。对用户来说，“详情在 hover 显示”的设计目前不够可发现，也不够确定。若详情只在某些卡片或某些停留时间出现，需要更明确的视觉反馈。

双击自动粘贴未完成真实端到端验证。阻断原因：系统辅助访问当前不稳定，且 `osascript` 在授权设置流程后被拒绝辅助访问。本轮只能确认代码层分型检查通过，不能确认真实输入框粘贴成功。

### 8. Translation 浮层

证据：`06-translation-panel.png`

健康度：较好。

Option+D 浮层能显示左右分栏，中文剪贴板内容被预填，左侧显示“已识别：简体中文”，目标语言为英语，右侧展示 mock 翻译结果和 route ready 状态。整体已经接近 Bob 式快速翻译入口。

问题是左侧源语言 picker 仍显示“自动”，而识别结果在另一行；用户可能不确定当前源语言实际采用哪个值。中间双向箭头偏低，视觉上没有严格对齐顶部语言栏。结果卡片里 provider / audit 信息偏工程化，普通用户只需要简短结果和错误原因。

### 9. Provider / AI 设置

证据：`07-provider-settings.png`

健康度：中等。

Provider 已成为独立设置页，能表达 LLM、翻译、OCR provider 分层，以及本地 mock / OpenAI-compatible / LiteLLM 等状态。问题是这页对普通用户仍偏内部架构说明，例如“placeholder”“adapter”“边界”等词过多。正式产品里应该拆成“模型服务”“翻译服务”“OCR 服务”三块，并把技术状态折叠到高级信息。

### 10. Shortcuts 设置

证据：`08-shortcuts-settings.png`

健康度：中等。

全局修饰键、注册数量、单功能快捷键、启用开关、录入和恢复默认已经可见。问题是页面首屏只露出截图和剪贴板的一部分，信息被大卡片撑开；快捷键是高频设置，应该更紧凑，最好能一屏看完三大工具的最终快捷键与状态。

### 11. Clipboard 设置

证据：`09-clipboard-settings.png`

健康度：中等。

Clipboard 设置页能控制面板位置、保留天数、最大条目、固定保留和排除 Bundle ID，核心选项基本齐全。问题是“Recorder 诊断”“策略”这些词仍偏工程视角；用户真正关心的是“记录什么、保存多久、哪些 App 不记录、怎么清理”。

### 12. Translation 设置

证据：`10-translation-settings.png`

健康度：中等。

Translation 设置页能控制打开浮层时读取剪贴板、默认目标语言、记住上次目标语言。问题是目标语言状态同时出现“默认目标语言：简体中文”和“目标语言 English”，语义有冲突：一个像默认值，一个像当前生效值。需要明确拆成“默认目标语言”和“当前检测后的目标语言”，或只保留一个用户可理解的状态。

## UX 风险

1. 权限闭环仍是最大风险。用户可以打开系统设置，但缺少可靠的辅助面板和授权后状态恢复，Screen Recording / Accessibility 两条路径都会被卡住。
2. 签名和 TCC 身份问题已经暴露在 UI 中，但没有产品化解决动作。普通用户不会知道 ad-hoc、Team ID、路径不稳定意味着什么。
3. Clipboard panel 的基础窗口行为合格，但视觉仍像“巨大模糊调试面板”，不是足够精致的 Paste 风格历史 tray。
4. Translation 浮层可用性较好，但结果卡片和 provider route 信息仍偏开发者。
5. 设置页整体一致性比之前好，但内容文案和布局还没有完全从工程阶段迁移到产品阶段。
6. 自动验证脚本存在构建竞争问题，容易把体验回归和构建环境问题混在一起。

## Accessibility 风险

- 当前无法从截图证明完整键盘可达性、VoiceOver 标签和焦点顺序。
- Permission Assist 未出现，授权路径对低视觉能力用户仍不清晰。
- Clipboard hover detail 依赖鼠标 hover，键盘和辅助技术用户可能无法访问详情。
- 大量灰色文本在深色半透明背景上存在对比度风险，需要用系统对比检查工具复测。
- Translation panel 中双向箭头按钮缺少可见文字标签，需确认辅助技术 label。

## not_covered

- Region / Window / Fullscreen 真实截图捕获：Screen Recording 未授权且当前运行身份为 ad-hoc。
- Clipboard 双击自动粘贴到真实输入框：Accessibility 相关链路被系统阻断，未完成真实端到端验收。
- Permission Assist 完整拖拽 App 图标：辅助面板未出现。
- 三语切换后的完整 UI 截图：本轮只在中文系统界面下审计。
- 真实 OpenAI-compatible 翻译调用：本轮按计划不调用真实 provider。

## 结论

当前 App 的基础功能框架已经具备，但还不能进入“稳定 Alpha 体验”。最需要先修的是权限与 TCC 身份闭环，其次是 Clipboard tray 的视觉密度和 hover / 双击体验，第三是设置页从工程诊断语言转成用户任务语言。
