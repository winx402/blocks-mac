---
stepsCompleted: [1, 2, 3, 6]
inputDocuments:
  - docs/项目管理库/V1产品规格.md
  - docs/技术知识库/AI-agent-CLI-Hook能力边界.md
workflowType: 'research'
lastStep: 6
research_type: 'technical'
research_topic: 'P2 action core, provider, CLI and hook validation for AI-native Mac tools'
research_goals: 'Define the smallest verifiable action schema, CLI JSON contract, provider validation boundary, and macOS permission risk map for screenshot, clipboard, and translation tools.'
user_name: 'Bot'
date: '2026-07-01'
web_research_enabled: true
source_verification: true
---

# Research Report: technical

**Date:** 2026-07-01
**Author:** Bot
**Research Type:** technical

---

## Research Overview

本技术调研服务 P2 验证，不产出最终架构决策。研究对象是截图、剪贴板、翻译三类 V1 工具共用的 action core、CLI JSON 形态、local CLI/API provider 接入边界和 hook 安全模型。

本轮结合了项目内 V1 产品规格、AI/Agent/CLI/Hook 能力边界、本机 CLI 快照，以及 Apple 官方开发者资料。结论已同步到技术知识库和调研与验证库；正式决策仍需在 spike 完成后进入决策记录库。

---

## Technical Research Scope Confirmation

**Research Topic:** P2 action core, provider, CLI and hook validation for AI-native Mac tools

**Research Goals:** Define the smallest verifiable action schema, CLI JSON contract, provider validation boundary, and macOS permission risk map for screenshot, clipboard, and translation tools.

**Technical Research Scope:**

- Architecture Analysis - action core shared by UI, CLI, agent and hook runtime.
- Implementation Approaches - dependency-free smoke harness and confirmation-first execution.
- Technology Stack - macOS APIs, local CLI provider candidates, API provider boundary.
- Integration Patterns - JSON envelope, provider adapters, hook manifest.
- Performance Considerations - not benchmarked in this pass; reserved for native spike.

**Research Methodology:**

- Current Apple official documentation search for system permissions and distribution constraints.
- Local command inspection for available CLI providers.
- Minimal executable smoke harness to test action JSON shape.
- Confidence levels retained by marking outputs `proposed`, `spike design`, or `execution log`.

**Scope Confirmed:** 2026-07-01

## Technical Stack and Integration Findings

### macOS platform surfaces

Screen capture should be validated against ScreenCaptureKit. Accessibility, pasteboard access, sandbox entitlements, Apple Events, Login Items, Developer ID signing, Hardened Runtime, and notarization all affect the product surface. These are system boundaries, not implementation details.

Primary sources:

- <https://developer.apple.com/documentation/screencapturekit/>
- <https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions>
- <https://developer.apple.com/documentation/AppKit/NSPasteboard>
- <https://developer.apple.com/documentation/bundleresources/security-entitlements>
- <https://developer.apple.com/developer-id/>

### Local CLI provider candidates

Local verification found `codex` and `gh`; `claude`, `qoder`, and `opencode` were not in PATH. Codex CLI exposes a non-interactive `exec` command with JSON and output-schema options, so it is the first local CLI provider candidate. GitHub Copilot CLI is not installed locally and should not be downloaded during this pass.

### API provider boundary

API provider validation is blocked until the project defines secret injection and data egress confirmation. This is a deliberate boundary: no API key, token, subscription link, or real sensitive payload should be saved in the repository.

### Action schema

The smallest useful schema covers:

- `jdtool.screenshot.capture`
- `jdtool.clipboard.search`
- `jdtool.translate.text`

All actions return a common envelope with `ok`, `action`, `result`, `warnings`, `audit_id`, optional `requires_confirmation`, and optional `error`.

### Hook boundary

Hook runtime should remain design-only in V1. The key finding is that hook safety depends on the same action schema and confirmation model as agent and CLI calls. Agent-generated hooks must remain drafts until a user enables them.

## Synthesis

P2 should not start with a full Mac app. It should start by proving that the three tool families can share one action contract and that sensitive operations return structured confirmation requirements instead of being executed silently.

The immediate implementation artifact is the local smoke harness under `tools/spikes/p2_action_smoke.py`. The immediate product architecture artifact is `docs/技术知识库/Action-Schema-v0.md`. The immediate risk artifact is `docs/技术知识库/macOS权限与分发风险清单.md`.

## Next Technical Steps

1. Run and preserve CLI smoke test output.
2. Create a hook manifest v0 draft that references the action schema.
3. Validate Codex CLI with a non-mutating, read-only, structured-output invocation.
4. Define secret handling before any real API provider call.
5. Build the smallest native macOS permission spike for screenshot, pasteboard and hotkeys.
