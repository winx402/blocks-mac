# P8 Clipboard Product Polish Acceptance Record

日期：2026-07-03
状态：`automated_passed / pending_manual_ui_acceptance`
来源 story：[P8-B/E Clipboard 产品化打磨纵切](../stories/p8-b-e-clipboard-product-polish.md)

## Automated Acceptance

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| P8 static product gate | passed | `python3 tools/verification/p8_clipboard_product_polish_checks.py --timeout 180` returned `ok=true` on 2026-07-03. |
| Xcode build | passed | `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build` returned `** BUILD SUCCEEDED **`. |
| Build and run verify | passed | `./script/build_and_run.sh --verify` returned `** BUILD SUCCEEDED **` for App and CLI with Apple Development signing. |
| P2 action smoke | passed | `python3 tools/spikes/p2_action_smoke.py validate-schemas && python3 tools/spikes/p2_action_smoke.py smoke` returned `ok=true`. |
| Clipboard bottom window regression | passed | `python3 tools/verification/p7i_clipboard_bottom_tray_window_checks.py` returned `ok=true`. |
| Clipboard position / auto-paste static regression | passed | `python3 tools/verification/p7e_clipboard_position_autopaste_checks.py --timeout 180` returned `ok=true`. |
| String Catalog JSON | passed | `python3 -m json.tool apps/JDTool/JDToolApp/Resources/Localizable.xcstrings` returned 0. |
| String Catalog compile | passed | `xcstringstool compile --dry-run --output-directory /tmp/jdtool-xcstrings-check apps/JDTool/JDToolApp/Resources/Localizable.xcstrings` produced all three locale outputs. |
| Diff whitespace | passed | `git diff --check` returned 0. |
| Sensitive scan | passed_with_expected_rule_hits | Scan found only documentation/check-script references to forbidden token classes, not real credentials. |

## Test Limitation

- `p4k_clipboard_recorder_policy_checks.py` still nests older P4-J/P4-I/P4-B aggregate scripts, which repeatedly invoke `build_and_run.sh --verify` and can timeout in this repo state. P8 uses the direct P8 gate plus direct build/run, P2 smoke, String Catalog and focused Clipboard regressions above instead of relying on that nested aggregate.

## Manual UI Acceptance

| 项目 | 状态 | Notes |
| --- | --- | --- |
| Clipboard bottom panel header is compact | pending_manual | Search + filters should sit close to card tray. |
| No persistent bottom hint text | pending_manual | Common state should not show footer instructions. |
| Content-first cards | pending_manual | Cards should show content preview/time first, not implementation summary. |
| Format-specific rendering | pending_manual | Text/RTF/image/URL/file/mixed should look distinguishable. |
| Hover detail near item | pending_manual | Detail should appear near hovered card/row and avoid fixed panel corner behavior. |
| Context menu management | pending_manual | Pin/delete/move/rename/copy actions should live in right-click menu. |
| Combined filters | pending_manual | Format/time/group/source filters can be combined and cleared at once. |
| Clipboard Privacy route | pending_manual | App list + toggle should be easier than raw bundleId editing. |
| Agent CLI/MCP authorization settings | pending_manual | Summary access and full-content authorization boundary are visible. |

## Not Covered

| 项目 | 状态 | 原因 |
| --- | --- | --- |
| Full Pinboard editor | deferred | P8 implementation adds metadata and move/name action, not full CRUD UI. |
| Paste Stack | deferred | Explicitly scoped as later P8 follow-up, not this vertical slice. |
| Text / rich text preview editing | deferred | Needs separate editor and persistence design. |
