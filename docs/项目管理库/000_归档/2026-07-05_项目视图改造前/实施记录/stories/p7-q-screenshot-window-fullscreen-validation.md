# P7-Q Screenshot Window / Fullscreen UI Validation

状态：implemented / real UI pass recorded

## Scope

P7-Q 只关闭 P7-P 留下的 Screenshot Window / Fullscreen 真实 UI 点击验收缺口。它不新增截图功能，不接 OCR/provider，不保存运行时截图到仓库。

## Changes

- 使用当前稳定签名 App：`/Users/bot/Applications/JDToolDev/Debug/JDTool.app`。
- 在已授权 Screen Recording 状态下真实点击主窗口的 Window / Fullscreen 截图入口。
- 记录 Window overlay hover 高亮、`Esc` 取消、候选窗口点击捕获、Fullscreen 当前 display 捕获和结果浮层 mode/source/size。
- 将 no-candidate window、多屏和权限撤销/重授权继续作为环境依赖项，不伪造通过。

## Acceptance

- Window mode shows full-screen selection overlay and hover highlight.
- `Esc` cancels Window selection and removes the overlay.
- Clicking a visible candidate window produces a screenshot result panel with `mode=window`, non-zero pixel size, and source summary.
- Fullscreen mode produces a screenshot result panel with `mode=fullscreen`, non-zero pixel size, and display source summary.
- Runtime screenshots used during validation remain outside the repository.

## Verification

- `./script/build_and_run.sh --verify`
- `JDTOOL_REQUIRE_TCC=1 ./script/build_and_run.sh --verify-permissions-existing`
- `python3 tools/verification/p7q_screenshot_window_fullscreen_checks.py --timeout 180`
- Manual UI evidence is recorded in [P7-Q acceptance record](../acceptance/p7-q-screenshot-window-fullscreen-acceptance-record.md).

## Notes

- P7-Q observed a single-display environment. Multi-display behavior remains a later environment-dependent pass.
- The Window click pass captured an on-screen candidate window and showed the result panel; the temporary desktop screenshots used for inspection were kept under `/tmp` and are not committed.
