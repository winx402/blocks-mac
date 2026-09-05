# P4-I Clipboard Floating Panel

状态：done
最后审阅：2026-07-02
来源级别：implementation story

## Story

As a 奇点工具 user,
I want `Option + V` to open a compact Paste-style clipboard history panel,
so that I can search recent clipboard summaries without switching into the full main window.

## Scope

- 新增 `FloatingPanelPosition`，支持 bottom / left / right。
- 新增 `ClipboardHistoryPanelPresenter`，使用 `NSPanel + NSHostingView` 展示独立浮层。
- 新增 `ClipboardFloatingPanelView`，展示搜索、最近 redacted 摘要、pin、删除摘要、暂停记录和打开主窗口入口。
- 菜单栏 Clipboard 入口改为打开浮层，并标注默认 `Option + V`。
- Settings 增加 Clipboard panel position 偏好，默认 bottom。
- 面板继续复用 `clipboardRecords` redacted records；不读取真实 `NSPasteboard`。

## Non-goals

- 不注册真正全局快捷键；全局 ShortcutController 留到 P6。
- 不接长期 Login Item recorder、不启用 App Group、不开放真实用户内容恢复。
- 不读取或保存真实剪贴板原文、图片 base64、URL 原值或真实文件路径。
- 不调用 provider、不执行 CLI、不上传剪贴板内容。

## Acceptance Criteria

- Given 用户从菜单栏点击 Clipboard，Then App 打开独立浮层而不是只切换主窗口。
- Given Settings 选择 bottom / left / right，When 下次打开面板，Then `ClipboardHistoryPanelPresenter` 按对应位置布局。
- Given 面板内有记录，When 用户搜索、pin 或删除摘要，Then 只操作内存态 redacted records。
- Given 用户点击 Open Main Window，Then 主窗口打开并选中 Clipboard section。
- Given 新增 UI 文案，Then `zh-Hans`、`en`、`ja` 都有 String Catalog 覆盖。

## Verification

- `python3 tools/verification/p4i_clipboard_floating_panel_checks.py --timeout 180`
- `python3 tools/verification/p4b_clipboard_panel_checks.py --timeout 180`

## Notes

- P4-I 只做 Paste 风格浮层基础；后续 P6 会把 `Option + V` 接入集中 ShortcutController。
