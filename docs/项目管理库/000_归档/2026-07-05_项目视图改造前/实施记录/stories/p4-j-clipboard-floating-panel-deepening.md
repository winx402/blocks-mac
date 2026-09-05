# P4-J Clipboard Floating Panel Deepening

状态：implemented
日期：2026-07-03
来源：P4-I Paste 风格浮层后续深化

## 目标

把剪贴板浮层从摘要列表推进为更接近 Paste 的可扫读面板：

- 列表支持选中态、键盘方向键选择和 Delete 删除摘要。
- 默认显示当前选中条目的详情。
- 详情只展示 redacted metadata：类型、来源候选、格式、长度、短哈希、fixture/user event、restorable/excluded/snapshot skipped flags。
- 面板继续支持搜索、pin/unpin、删除摘要、暂停记录和打开主窗口。

## 实现范围

- `ClipboardFloatingPanelView` 新增列表 + 详情布局。
- 底部位置使用宽布局，左/右位置使用窄布局。
- 新增 P4-J 验证脚本，回归 P4-I 并检查隐私边界。

## 边界

- 不实现真实用户内容恢复、自动粘贴或完整内容预览。
- 不读取 `NSPasteboard`，不调用 provider，不执行 CLI。
- 浮层里的 restore 信息只表达当前未开放真实恢复路径。

## 验证

- `python3 tools/verification/p4j_clipboard_panel_deepening_checks.py --timeout 180`
- `python3 tools/verification/p4i_clipboard_floating_panel_checks.py --timeout 180`
