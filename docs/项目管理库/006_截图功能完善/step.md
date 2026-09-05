# 006 截图功能完善阶段总览

状态：step-2-complete-step-3-implementation-in-progress
最后审阅：2026-07-17
来源级别：project plan

## 阶段状态

| 阶段 | 状态 | 当前产物 | 进入开发条件 |
| --- | --- | --- | --- |
| Step 1 / Phase 1：采集与基础编辑 | code-blockers-closed-platform-evidence-pending | [PRD](step_1/PRD-截图采集与基础编辑.md)、[UI/交互原型](step_1/UI-交互原型与状态说明.md)、[架构与改动方案](step_1/架构与改动方案.md)、[开发与验收记录](step_1/开发与验收记录.md)、[验收审计](step_1/验收审计-2026-07-12.md) | 代码与契约阻塞项已关闭；多屏、完整 VoiceOver 和平台证据按明确风险口径收口。 |
| Step 2 / Phase 2：历史与 OCR | complete | [PRD](step_2/PRD-截图历史与本地OCR.md)、[UI/交互](step_2/UI-交互与状态说明.md)、[架构方案](step_2/架构与改动方案.md)、[验收计划](step_2/验收计划.md)、[开发与验收记录](step_2/开发与验收记录.md)、[验收审计](step_2/验收审计-2026-07-14.md) | 已完成自动化、最终安装版 Broker 冷启动、CLI 和低敏 UI 验收。 |
| Step 3 / Phase 3：滚动长截图 | implementation-in-progress | [PRD](step_3/PRD-滚动长截图.md)、[UI/交互](step_3/UI-交互与状态说明.md)、[架构方案](step_3/架构与改动方案.md)、[拼接原型报告](step_3/拼接原型报告.md)、[验收计划](step_3/验收计划.md)、[开发与验收记录](step_3/开发与验收记录.md) | 生产代码、P16 和回归门禁已完成；真实滚动闭环与资源有效上限仍需闭合。 |
| Step 4 / Phase 4：高级编辑与美化 | not-started | 仅有路线图边界。 | 统一渲染器稳定；补充并确认 Step 4 PRD/UED。 |
| Step 5 / Phase 5：AI 截图 | not-started | 仅有路线图和隐私原则。 | Provider 授权、安全合规和输出结构确认。 |
| Step 6 / Phase 6：自动化与开发者工作流 | not-started | 仅有路线图边界。 | Action bridge 稳定；补充并确认 Step 6 PRD。 |

## Step 1 实施拆分

| 子阶段 | 目标 | 状态 | 主要验证 |
| --- | --- | --- | --- |
| 1A 采集与选区 | 智能选择状态机、非激活 overlay、首拖区域手势、多屏切片捕获和会话工具条。 | implemented-pending-multidisplay-evidence | 设置入口首拖松手即捕获已实测；补真实硬件快捷键、F/Shift+F、三屏、混合 DPI、负坐标和窗口阴影证据。 |
| 1B 编辑与渲染 | `ScreenshotSceneDocument`、统一渲染器、单一原屏编辑器、稳定属性栏、实时 draft、控制柄和撤销重做。 | professional-editor-accepted-platform-evidence-pending | Core/AppTests 与 P14 已过；专业工具、对象优先编辑和属性持久化已实测，VoiceOver、外观和多屏硬件矩阵待补。 |
| 1C 输出与入口 | 自动复制、PNG/JPEG、单页设置工作台、智能快捷键、CLI/Action broker。 | implemented-platform-evidence-pending | 设置、PNG/TIFF、Broker 启停/冷启动和 PNG/JPEG 导出已实测；补真实多屏快捷键和平台矩阵。 |

## 当前实现门槛

智能选择、单一原屏编辑器、scene document、类型化工具 preset、对象优先编辑、设计 token、设置入口、`BlocksScreenshotCore` 和 `BlocksActionBroker` 已形成唯一口径。Step 2 自动化、最终安装版 Broker 冷启动、CLI 和低敏 UI 证据已闭合。

当前门槛转为 Step 3 真实验收：产品与交互边界、生产实现、代码 fixture、采样节奏和固定头部基线已经形成。最终安装版真实滚动、输出终态和资源工作集证据闭合前，不得把 Step 3 写成 complete。

## Step 3 实施拆分

| 子阶段 | 目标 | 当前状态 | 主要门禁 |
| --- | --- | --- | --- |
| 3A 拼接原型与 Core | 真值 fixture、纵向重叠、保守固定头部、到底候选、尺寸预算。 | browser-ground-truth-and-output-history-resource-profile-passed | P16-A 已过；12 帧浏览器 Page Down 序列与独立整页真值逐像素一致，58.5 MP final stitch、PNG/JPEG/TIFF 输出和截图历史提交 profile 已过。 |
| 3B 会话、权限与 HUD | 显式模式、单屏固定区域、Input Monitoring、ready Start、HUD、3 秒倒计时、失败暂停恢复。 | installed-entry-hud-passed-real-wheel-pending | P16-B/P16-C 已过；开始/重新选择/暂停/继续使用统一 36pt 命令样式，安装版入口、选区和 HUD 已验证，物理滚轮/触控板闭环待补。 |
| 3C 编辑输出与 CLI | 统一编辑器延迟提交、取消/崩溃无输出、临时清理、status/finish/cancel。 | implemented-real-output-pending | P16-D/P16-E 已过；真实 sink、Broker/CLI 会话竞争和崩溃清理证据待补。 |

## 实施与验收规则

- 未来实施采用 breaking replacement；旧三模式入口、旧结果预览窗和旧交互式路径不保留迁移分支，也不维护双逻辑并行。
- 统一编辑器重构采用 breaking replacement；禁止 `ScreenshotEditorMode`、双 surface、`ScreenshotEditCommand`、`ScreenshotEditorLayout` 和 `professional/compact` 生产分支。
- 开发按 1A、1B、1C 分批，前一批达到可验证状态后再扩大范围。
- 每批均需自动化和真实低敏截图/录屏；多屏与窗口交互不能只用静态脚本验收。
- 当前单屏实机已证明快速浮层、范围控制柄和双向模式切换可用；多屏、全工具、VoiceOver 和外观矩阵仍不能由静态门禁替代。
- 阶段完成后记录开发范围、测试证据、未覆盖项和残余风险，再由项目负责人收口。
- Step 3 捕获/拼接失败不得自动导出部分结果，崩溃后不得恢复会话；只有进程内 paused 状态可 Resume。
- Step 3 在统一编辑器完成或保存成功前不得写 clipboard/history/OCR，CLI 不提供 start/resume/no-editor。
