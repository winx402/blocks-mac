# P7-J 修复建议 Backlog

status: proposed
created: 2026-07-03

## P0

### P0-1 修复稳定签名与 TCC 身份

- 证据：`03-permissions.png`、`12-screenshot-permission-action.png`
- 现象：权限页显示当前 App 为 ad-hoc 签名、Team ID 无；`build_and_run.sh --verify` 也提示 Apple Development 信任设置不是系统默认，回退 ad-hoc。
- 影响：Screen Recording 和 Accessibility 授权可能绑定到错误身份或路径，导致用户授权后仍无法截图/自动粘贴。
- 建议：先做一个单独修复 story，恢复 Apple Development 证书系统默认信任，固定 Debug App 路径，确认系统设置列表中的 Blocks 与当前运行路径一致。
- 验收：权限页显示稳定签名、Team ID 非空、当前路径与系统设置授权项一致；授权后重启 App 能通过 preflight。

### P0-2 重做 Permission Assist 出现与关闭状态机

- 证据：`13-permission-assist-after-open-settings.png`
- 现象：点击打开系统录屏设置后，只出现系统设置窗口，没有出现 Blocks 辅助授权面板。
- 影响：用户仍需要自己理解系统权限列表，之前承诺的拖拽图标和箭头引导不可用。
- 建议：把 assist 面板显示绑定到 System Settings 窗口检测结果；若窗口出现但面板未能定位，显示 fallback 小面板。增加日志态 session reason，区分 waiting、shown、failed_to_attach、cancelled、granted。
- 验收：打开录屏/辅助功能设置后，Blocks 主窗口隐藏，assist 面板稳定出现在系统设置旁边，箭头方向正确；授权完成、系统设置关闭或用户关闭时面板消失。

## P1

### P1-1 Clipboard hover detail 没有形成明确体验

- 证据：`05-clipboard-hover-detail.png`
- 现象：hover 后 pin/delete 按钮出现，但未看到明确的详情 popover。
- 影响：用户无法理解“默认不展示详情，hover 才展示详情”的设计，条目信息不足。
- 建议：卡片 hover 后在卡片上方或下方显示固定尺寸 popover，至少包含完整摘要、类型、来源、时间、隐私状态和可执行动作；键盘选中时也应显示同等详情。
- 验收：鼠标 hover 和键盘选中都能显示详情；详情不遮挡搜索栏和主要卡片带。

### P1-2 Clipboard bottom tray 视觉仍偏大遮罩

- 证据：`04-clipboard-bottom-tray.png`
- 现象：bottom tray 满宽贴底正确，但右侧存在大片模糊空白，卡片带视觉重心偏左。
- 影响：不像成熟剪贴板工具的高密度历史 tray，显得空、重、像调试面板。
- 建议：限制卡片带最大内容宽度或让卡片均衡铺开；降低无内容区域的背景权重；增强卡片层级、hover、选中态和类型图标一致性。
- 验收：底部 tray 在 1920 宽屏下仍以卡片历史为视觉主体，不出现大片无意义空白。

### P1-3 Clipboard 双击自动粘贴真实链路未闭环

- 证据：`05-clipboard-hover-detail.png`，自动检查 `p7h_clipboard_autopaste_activation_checks.py` 仅证明代码分型通过。
- 现象：本轮未能完成 TextEdit/Notes 真实输入框端到端粘贴；系统辅助访问链路不稳定。
- 影响：Clipboard 核心工作流不可验收。
- 建议：在稳定签名修复后，用 TextEdit 低敏样本做真实验收；UI 状态区明确显示已写剪贴板、已发送 Cmd+V、目标激活失败或缺 Accessibility。
- 验收：从 TextEdit 聚焦输入框打开 Clipboard，双击可恢复条目后面板关闭并发送粘贴；失败时显示准确原因。

### P1-4 Translation 设置语言状态冲突

- 证据：`10-translation-settings.png`
- 现象：页面同时显示默认目标语言为“简体中文”，又显示“目标语言 English”。
- 影响：用户不知道 Option+D 当前到底会翻译到什么语言。
- 建议：拆成“默认目标语言偏好”和“当前自动检测后的实际目标语言”；或在设置页只展示偏好，不展示运行态结果。
- 验收：设置页没有互相矛盾的语言状态；Translation 浮层负责展示本次检测与实际目标。

## P2

### P2-1 主窗口首页工程阶段文案过重

- 证据：`01-main-window.png`
- 现象：首页标题为 `P3-B 截图模式`，说明文字像开发里程碑。
- 建议：改成产品任务语言，例如“截图”“快速捕获区域、窗口或全屏”，把阶段信息移到 About/Debug。

### P2-2 Provider 页面架构词过多

- 证据：`07-provider-settings.png`
- 现象：`placeholder`、`adapter`、`边界` 等词偏开发者。
- 建议：按用户任务拆为“模型服务”“翻译服务”“OCR 服务”；高级诊断折叠。

### P2-3 Shortcuts 设置页信息密度不合理

- 证据：`08-shortcuts-settings.png`
- 现象：一屏看不完三大工具快捷键，截图下方内容被裁切。
- 建议：三大工具快捷键用紧凑表格显示，录入/恢复默认作为行内操作。

### P2-4 Settings 内容滚动可见性弱

- 证据：`02-settings-general.png`、`08-shortcuts-settings.png`
- 现象：内容被窗口底部裁切，但滚动条和“还有内容”的提示不明显。
- 建议：内容区保留底部渐隐/滚动条常显策略，或使用更紧凑的 section。

### P2-5 Translation 浮层结果卡片偏工程化

- 证据：`06-translation-panel.png`
- 现象：结果卡片里 audit id、route、provider metadata 占据较多空间。
- 建议：默认只显示译文和短错误；调试信息折叠到“详情”。

## P3

### P3-1 玻璃视觉仍偏暗重

- 证据：`01-main-window.png`、`04-clipboard-bottom-tray.png`、`06-translation-panel.png`
- 现象：材质统一，但透明感不明显，整体偏厚重。
- 建议：继续减少叠层 regular material，保留边框和阴影，允许系统 Reduce Transparency 时显示诊断。

### P3-2 自动化验收脚本需要串行构建策略

- 证据：P4-K / P5-Q 并发运行时出现 build 65 和 helper copy failed；之后串行 `./script/build_and_run.sh --verify` 通过。
- 建议：P7 聚合脚本先构建一次，再把 build products 传给子检查；禁止多个脚本并发写同一 DerivedData。

## 建议修复顺序

1. P0-1 稳定签名与 TCC 身份。
2. P0-2 Permission Assist 状态机。
3. P1-3 Clipboard 自动粘贴真实链路。
4. P1-1 / P1-2 Clipboard tray 视觉与 hover detail。
5. P1-4 Translation 语言状态。
6. P2 设置页与 Provider 文案产品化。
7. P3 玻璃视觉和验证脚本工程化。
