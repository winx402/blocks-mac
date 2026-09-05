# P8-H 产品细节审计

状态：superseded by P8-I / P8-M / P8-N
创建日期：2026-07-03
范围：Settings shell、Clipboard 设置页、Clipboard floating panel 入口与展示模型

## 目的

本轮不是继续做表层样式微调，而是把当前 App 中“看起来不够像 macOS 工具”的细节问题拆成可验证的产品与工程问题。重点回应当前反馈：

- 菜单栏图标偏大、行间距偏大。
- 设置内容没有随窗口做左右自适应，控件没有贴右，缺少 Apple 风格行分隔。
- Clipboard 设置页不应把面板位置作为主要设置项，应优先只调面板高度。
- Clipboard 条目应展示真实内容，图片条目应展示图片。
- Clipboard 筛选展开不应占第二行，应从图标向右展开并推挤后续图标。
- 细节问题很多，需要系统化 check，而不是逐点堆补丁。

## 文档

- [P8-H 体验审计报告](experience-report.md)
- [P8-H 修复 Backlog](fix-backlog.md)

## 截图证据

- [01-settings-screenshot-page.png](screenshots/01-settings-screenshot-page.png)
- [02-clipboard-settings.png](screenshots/02-clipboard-settings.png)

## 本轮结论

当前实现的问题不只是单个字号或间距，而是 P8-F 规范没有完整落地：

- P8-G 只完成 settings shell 与信息架构，逐页表单系统仍未产品化。
- 本轮已先修复高影响入口和布局问题：Clipboard 设置页行模型、侧边栏密度、默认快捷键迁移、Clipboard panel 打开即关闭风险、筛选同排展开和 fixture 图片缩略图展示。
- P8-H 审计时点尚未收敛的问题包括：hover detail 屏幕边界处理、真实用户图片内容链路、Shortcuts / Permissions / Providers 全量 Apple 风格行模型，以及后续运行态截图复核；其中 Settings 行模型已由 P8-I/P8-J/P8-K 收敛，hover detail 和图片内容路径已由 P8-M/P8-N 代码与门禁覆盖，真实运行态截图复核仍应单独执行。
- `SettingsView` 在 P8-I 中已移除旧 `SettingsSection` 容器并迁移到统一设置行模型；本 P8-H 文档保留为问题来源和 partial fix 记录。
- 本文对 Clipboard 浮层入口和筛选展开的判断是 2026-07-03 审计时点的事实；后续 P8-H/P8-I/P8-M 已调整 panel 打开 guard、同排筛选展开和模块化边界，当前状态以 [剪贴板历史：当前产品与实现逻辑](../../产品知识库/工具/文本/剪贴板历史-当前产品与实现逻辑.md) 为准。
