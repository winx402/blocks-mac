---
id: P7-A-ACCEPTANCE
title: P7-A Low-Sensitive Acceptance Record
status: pending_low_sensitive_manual_acceptance
date: 2026-07-03
sourceStory: ../stories/p7-a-low-sensitive-acceptance-gate.md
---

# P7-A Low-Sensitive Acceptance Record

本记录用于保存 P7-A 的自动化 gate 和低敏人工验收结果。状态必须使用 `passed`、`pending_low_sensitive_manual_acceptance`、`not_covered` 或 `blocked`；没有真实执行的项目不能写成 `passed`。

## Automated Gate

| Item | Status | Evidence |
| --- | --- | --- |
| JDTool Debug build | passed | `xcodebuild -project apps/JDTool/JDTool.xcodeproj -scheme JDTool -configuration Debug -derivedDataPath DerivedData/JDTool build` returned 0 on 2026-07-03. |
| Build and launch verify | passed | `./script/build_and_run.sh --verify` returned 0 on 2026-07-03. |
| P7-A aggregate gate | passed | `python3 tools/verification/p7a_low_sensitive_acceptance_gate_checks.py --timeout 180` returned `ok=true` on 2026-07-03. |
| P6-C shortcut acceptance regression | passed | Covered inside P7-A aggregate gate; `p6c_shortcut_acceptance_gate_checks.py` returned 0. |
| P4-K clipboard policy regression | passed | Covered inside P7-A aggregate gate; `p4k_clipboard_recorder_policy_checks.py` returned 0. |
| P5-Q translation language / error UX regression | passed | Covered inside P7-A aggregate gate; `p5q_translation_language_error_ux_checks.py` returned 0. |
| P3-F screenshot AI route-ready regression | passed | Covered inside P7-A aggregate gate; `p3f_screenshot_ai_route_ready_checks.py` returned 0. |

## Shortcut Acceptance

Low-sensitive sample: `jdtool low sensitive sample`.

| Item | Status | Evidence / Notes |
| --- | --- | --- |
| Option+A triggers region screenshot | pending_low_sensitive_manual_acceptance | Requires foreground App, current input focus and low-sensitive screen content. |
| Option+V opens Clipboard history panel | pending_low_sensitive_manual_acceptance | Verify panel opens without exposing full clipboard content. |
| Option+D opens Translation panel | pending_low_sensitive_manual_acceptance | Verify clipboard prefill follows Settings toggle. |
| Shortcut diagnostics show registered / disabled / failed counts | pending_low_sensitive_manual_acceptance | Verify Settings diagnostics after App launch. |

## Screenshot Acceptance

| Item | Status | Evidence / Notes |
| --- | --- | --- |
| Region screenshot shows non-zero result panel | pending_low_sensitive_manual_acceptance | Test only on low-sensitive screen area. |
| Window screenshot hover highlights a candidate window | pending_low_sensitive_manual_acceptance | Do not capture sensitive windows. |
| Fullscreen screenshot captures current display | pending_low_sensitive_manual_acceptance | Multi-display coverage depends on current machine. |
| Copy and Save As show in-panel result feedback | pending_low_sensitive_manual_acceptance | Save only to a user-chosen low-sensitive location. |
| OCR / Translate / Summarize cards show route-ready preview only | pending_low_sensitive_manual_acceptance | Must not execute OCR, upload image or call provider. |
| Multi-display and permission revoke / regrant | not_covered | Environment-dependent; do not fake pass. |

## Clipboard Acceptance

| Item | Status | Evidence / Notes |
| --- | --- | --- |
| Option+V opens bottom panel by default | pending_low_sensitive_manual_acceptance | Panel should show redacted summaries only. |
| Settings switches Clipboard panel to left / right | pending_low_sensitive_manual_acceptance | Reopen panel after changing position. |
| Search filters redacted summary rows | pending_low_sensitive_manual_acceptance | Use low-sensitive fixture summaries. |
| Pin, delete summary and pause recording controls behave locally | pending_low_sensitive_manual_acceptance | Operations must affect in-memory redacted records only. |
| Apply Clipboard policy respects retention / max items / pinned / excluded bundle settings | pending_low_sensitive_manual_acceptance | Policy must not read current system clipboard. |
| Complex third-party clipboard samples | not_covered | Requires controlled browser, Office, design app or password-manager dummy samples. |

## Translation Acceptance

| Item | Status | Evidence / Notes |
| --- | --- | --- |
| Option+D opens Translation panel | pending_low_sensitive_manual_acceptance | Verify focus lands in input. |
| Clipboard prefill toggle on uses low-sensitive clipboard text | pending_low_sensitive_manual_acceptance | Use only `jdtool low sensitive sample` or equivalent. |
| Clipboard prefill toggle off opens empty input | pending_low_sensitive_manual_acceptance | Existing input should not be overwritten unexpectedly. |
| Default target language and remember-last-target preferences apply | pending_low_sensitive_manual_acceptance | Verify target language selection after running local mock. |
| Local Mock translation works without network | pending_low_sensitive_manual_acceptance | Must not require saved user secret. |
| `runtime gate disabled` blocks real external translation | pending_low_sensitive_manual_acceptance | Error copy should be short and localized. |
| Real provider manual acceptance | not_covered | Requires separately approved external-transfer test with user-owned credentials. |

## Privacy And Safety

| Item | Status | Evidence / Notes |
| --- | --- | --- |
| No real screenshot files enter git | pending_low_sensitive_manual_acceptance | Verify with `git status --short --ignored`. |
| No real clipboard original text is stored in story, record or verification output | pending_low_sensitive_manual_acceptance | Static scan must pass. |
| No provider raw output or credential material is stored | pending_low_sensitive_manual_acceptance | Static scan must pass. |
| External transfer remains gated | pending_low_sensitive_manual_acceptance | Screenshot AI cards remain preview / route only; translation runtime depends on Settings gate. |

## Follow-Up

- Convert each `pending_low_sensitive_manual_acceptance` row to `passed`, `not_covered` or `blocked` only after a real low-sensitive run.
- If a manual row blocks Alpha readiness, create the next story with the smallest reproducible defect and keep P7-A as the evidence record.
