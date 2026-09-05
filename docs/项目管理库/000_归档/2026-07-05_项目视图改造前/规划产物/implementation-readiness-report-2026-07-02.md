---
title: Implementation Readiness Assessment Report
project: Mac 工具集
date: 2026-07-02
status: final
overallReadiness: NEEDS WORK
stepsCompleted:
  - step-01-document-discovery
  - step-02-prd-analysis
  - step-03-epic-coverage-validation
  - step-04-ux-alignment
  - step-05-epic-quality-review
  - step-06-final-assessment
inputDocuments:
  - docs/项目管理库/规划产物/prds/prd-Mac 工具集-2026-07-02/prd.md
  - docs/项目管理库/规划产物/prds/prd-Mac 工具集-2026-07-02/addendum.md
  - docs/项目管理库/规划产物/architecture/p2-l-app-scaffold-architecture/ARCHITECTURE-SPINE.md
  - docs/技术知识库/正式AppScaffold架构-v0.md
  - docs/项目管理库/规划产物/ux-designs/ux-Mac 工具集-2026-07-02/DESIGN.md
  - docs/项目管理库/规划产物/ux-designs/ux-Mac 工具集-2026-07-02/EXPERIENCE.md
  - docs/项目管理库/规划产物/epics.md
---

# Implementation Readiness Assessment Report

**Date:** 2026-07-02
**Project:** Mac 工具集 / 奇点 AI 工具箱
**Assessor:** Codex readiness review
**Readiness status:** NEEDS WORK

本文评估 V1 PRD、UX Spec、Architecture 和 Epics/Stories 是否足以支撑 P3 开发。结论不是代码质量评审，也不是 P3-A scaffold 计划；本轮不创建正式 App、不修正文档源内容、不执行真实 provider 或系统权限变更。

## Document Discovery

### PRD Documents

**Selected documents:**

- `docs/项目管理库/规划产物/prds/prd-Mac 工具集-2026-07-02/prd.md`，26734 bytes，2026-07-02T01:47:00
- `docs/项目管理库/规划产物/prds/prd-Mac 工具集-2026-07-02/addendum.md`，3425 bytes，2026-07-02T01:43:30

**Discovery note:** 默认 `*prd*.md` / `*prd*/index.md` 模式没有直接命中该嵌套 run 目录；本次按项目索引和用户计划固定使用以上文件。

### Architecture Documents

**Selected documents:**

- `docs/项目管理库/规划产物/architecture/p2-l-app-scaffold-architecture/ARCHITECTURE-SPINE.md`，6702 bytes，2026-07-02T01:21:26
- `docs/技术知识库/正式AppScaffold架构-v0.md`，6141 bytes，2026-07-02T01:21:26

### Epics & Stories Documents

**Selected documents:**

- `docs/项目管理库/规划产物/epics.md`，39023 bytes，2026-07-02T02:12:44

### UX Documents

**Selected documents:**

- `docs/项目管理库/规划产物/ux-designs/ux-Mac 工具集-2026-07-02/DESIGN.md`，8923 bytes，2026-07-02T02:01:47
- `docs/项目管理库/规划产物/ux-designs/ux-Mac 工具集-2026-07-02/EXPERIENCE.md`，17290 bytes，2026-07-02T02:01:50

### Discovery Issues

- No duplicate whole-versus-sharded conflicts were found.
- No `project-context.md` file exists in the project; no persistent facts were loaded from that glob.
- The selected documents are sufficient for readiness assessment, but simple discovery patterns should not be treated as complete for this repository's nested planning artifact layout.

## PRD Analysis

### Functional Requirements

FR-1: Menu Bar Entry — 用户可以从菜单栏打开截图、剪贴板、翻译、暂停剪贴板记录、最近状态和设置入口。

FR-2: Configurable Hotkeys — 用户可以配置、禁用、恢复默认截图、剪贴板和翻译快捷键；截图默认 `Option + A`，剪贴板默认 `Option + V`，翻译默认未设置并由设置页引导。

FR-3: Permission Guidance — 用户可以在设置页看到屏幕录制、辅助功能、剪贴板 recorder、文件访问、登录项和 provider 配置状态，并获得可恢复引导。

FR-4: Data Management — 用户可以在设置页清理截图历史、剪贴板历史、翻译历史、AI Action 记录和审计摘要；清理不得误删 Keychain secret。

FR-5: Screenshot Capture Modes — 用户可以通过截图快捷键进入截图选择视图，并选择区域、窗口或全屏截图。

FR-6: Screenshot Result Overlay — 截图完成后，用户看到包含图片预览和功能组的轻量浮层。

FR-7: Basic Screenshot Output Actions — 用户可以对截图执行复制、保存、另存为、拖拽和重新截图。

FR-8: Screenshot AI Actions — 用户可以从截图结果浮层进入 OCR、翻译、总结和内容识别；外发前必须确认。

FR-9: Screenshot History — 系统保存截图结果摘要和后续 Action 摘要，供用户在历史或审计中找回。

FR-10: Clipboard Recorder Controls — 用户可以开启、暂停、恢复剪贴板记录，并设置保存时间和数量上限。

FR-11: Clipboard History Panel — 用户可以通过剪贴板快捷键打开历史面板，按时间倒序浏览并搜索 Clipboard Item。

FR-12: Format Preservation And Restore — 系统保存文本、富文本、图片、链接、文件引用的可恢复表示。

FR-13: Pin, Group, Delete, And Cleanup — 用户可以固定、分组、删除单条或批量清理 Clipboard Item；Pinned Item 不受普通过期策略影响。

FR-14: Privacy Exclusions — 用户可以排除指定 App，命中排除时系统不读取内容快照。

FR-15: Clipboard Item AI Processing — 用户可以对单条 Clipboard Item 执行翻译、改写、总结或敏感信息识别，只处理当前条目。

FR-16: Translation Input Sources — 用户可以从手动输入、选中文本、当前剪贴板、剪贴板历史条目和截图 OCR 文本发起翻译。

FR-17: Translation Result Panel — 用户看到原文/译文对照、来源、目标语言、provider、处理状态和操作按钮。

FR-18: Language Coverage — V1 至少支持中英互译，并保留自动检测语言入口。

FR-19: Screenshot OCR Translation — 用户可以从截图 OCR 文本进入翻译；OCR 文本必须先可见。

FR-20: Agent Translation Action — Agent 可以通过 `jdtool.translate.text` 提交结构化翻译任务。

FR-21: Provider Settings — 用户可以配置本地 CLI provider 和 API provider 的名称、模型、base URL、Keychain account alias、超时和启用状态。

FR-22: External Transfer Confirmation — 任何外部 provider、API 或 CLI 可能接收用户内容前，系统必须展示 `external_transfer` 确认。

FR-23: Preview Confirmation — 读取完整剪贴板内容、真实截图或本地敏感内容预览前，系统必须使用 `preview` 确认或已有显式授权策略。

FR-24: Audit Log — 系统为敏感 Action 生成 Audit Log，用户可以查看和清理。

FR-25: Action Catalog And Schema — CLI 可以列出 Action、查看 schema、执行 Action，并返回统一 JSON envelope。

FR-26: Sensitive Agent Requests — Agent 读取完整剪贴板、截图内容、选中文本或外发内容时，不得绕过 Confirmation。

FR-27: Result Reuse — Action 输出的结果可以被用户复用，也可以被 agent 继续处理；失败时保留结构化错误。

FR-28: Hook Draft Review — 用户可以在设置页查看 agent 生成的 Hook 草稿。

FR-29: Hook Enablement Confirmation — 用户启用、阻断、修改、删除或自动外发类 Hook 前，必须通过 `destructive_or_hook` 确认。

**Total FRs:** 29

### Non-Functional Requirements

NFR-1 Performance: 截图选择、结果浮层、剪贴板历史面板、翻译面板必须给出快速首屏反馈；具体延迟预算在 P3 scaffold 和 UX Spec 中量化。

NFR-2 Privacy: 默认不静默上传截图、剪贴板、选中文本或文件引用；所有外发都必须经过 Confirmation。

NFR-3 Security: API secret 进入 Keychain；普通配置和日志不得保存 secret、token、完整订阅链接、验证码、私钥或完整支付信息。

NFR-4 Reliability: 权限缺失、provider 失败、OCR 失败、保存失败、CLI 错误必须返回可恢复路径。

NFR-5 Accessibility: 核心面板和设置页必须支持键盘操作；快捷键冲突和权限状态不能只依赖颜色表达。

NFR-6 Observability: 关键 Action 必须有 audit_id 和 warnings，便于用户和 agent 理解失败原因。

**Total explicit PRD NFRs:** 6

### Additional Requirements And Constraints

- V1 scope includes screenshot, clipboard, translation, settings, CLI/agent, local security, Keychain secret, Redacted Preview, Audit Log and Confirmation.
- V1 non-goals include recording/GIF/scrolling screenshots, cloud screenshot library, cross-device clipboard sync, password manager replacement, long-document translation, file image batch processing, real payment/account/license server and unconstrained hook scripts.
- P3/P7 retest items remain: multi-display, permission denial/revocation, third-party complex clipboard samples, long-running helper power, real provider calls and App Store review boundaries.
- PRD addendum constrains P3 shape to `SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core`.
- `swift-json-schema` `0.13.1` is only a candidate spike, not an adopted dependency.

### PRD Completeness Assessment

The PRD is comprehensive and traceable at the FR/UJ level. The main readiness problem is not missing FRs; it is unresolved or stale decisions that later documents partially resolved differently. The highest-risk example is clipboard storage: PRD Open Question 3 asks whether real user content should be recoverable, UX asserts default local recoverability, the scaffold architecture v0 says real user recoverability remains undecided, and epics assume recoverable storage. This must be reconciled before implementation.

## Epic Coverage Validation

### FR Coverage Matrix

| FR | PRD requirement summary | Epic coverage | Status |
| --- | --- | --- | --- |
| FR-1 | Menu bar entry | Epic 1 Story 1.3; Epic 5 Story 5.1 | Covered |
| FR-2 | Configurable hotkeys | Epic 1 Story 1.4; Epic 5 Story 5.1 | Covered |
| FR-3 | Permission guidance | Epic 1 Story 1.5; Epic 5 Story 5.2 | Covered |
| FR-4 | Data management | Epic 5 Story 5.5 | Covered |
| FR-5 | Screenshot capture modes | Epic 2 Story 2.1 | Covered |
| FR-6 | Screenshot result overlay | Epic 2 Story 2.2 | Covered |
| FR-7 | Screenshot output actions | Epic 2 Story 2.3 | Covered |
| FR-8 | Screenshot AI actions | Epic 2 Story 2.4 | Covered |
| FR-9 | Screenshot history | Epic 2 Story 2.5; Epic 5 Story 5.4 | Covered |
| FR-10 | Clipboard recorder controls | Epic 3 Story 3.1; Epic 5 Story 5.3 | Covered |
| FR-11 | Clipboard history panel | Epic 3 Story 3.2 | Covered |
| FR-12 | Format preservation and restore | Epic 3 Story 3.3 | Covered |
| FR-13 | Pin, group, delete and cleanup | Epic 3 Story 3.4 | Covered |
| FR-14 | Privacy exclusions | Epic 3 Story 3.5; Epic 5 Story 5.3 | Covered |
| FR-15 | Clipboard item AI processing | Epic 3 Story 3.6; Epic 6 Story 6.4 | Covered |
| FR-16 | Translation input sources | Epic 4 Story 4.1 | Covered |
| FR-17 | Translation result panel | Epic 4 Story 4.2 | Covered |
| FR-18 | Language coverage | Epic 4 Story 4.3 | Covered |
| FR-19 | Screenshot OCR translation | Epic 2 Story 2.4; Epic 4 Story 4.4 | Covered |
| FR-20 | Agent translation action | Epic 4 Story 4.5; Epic 6 Story 6.2 | Covered |
| FR-21 | Provider settings | Epic 4 Story 4.6; Epic 5 Story 5.4 | Covered |
| FR-22 | External transfer confirmation | Epic 6 Story 6.4 | Covered |
| FR-23 | Preview confirmation | Epic 6 Story 6.4 | Covered |
| FR-24 | Audit log | Epic 5 Story 5.5; Epic 6 Story 6.5 | Covered |
| FR-25 | Action catalog and schema | Epic 1 Story 1.2; Epic 6 Story 6.1 | Covered |
| FR-26 | Sensitive agent requests | Epic 6 Story 6.3 | Covered |
| FR-27 | Result reuse | Epic 6 Story 6.2; Epic 6 Story 6.5 | Covered |
| FR-28 | Hook draft review | Epic 6 Story 6.6 | Covered |
| FR-29 | Hook enablement confirmation | Epic 6 Story 6.7 | Covered |

### Missing Requirements

No PRD FR is missing from the epics coverage map.

### Coverage Statistics

- Total PRD FRs: 29
- FRs covered in epics: 29
- Coverage percentage: 100%
- UJ coverage: UJ-1 through UJ-8 all mapped in `epics.md`
- UX-DR coverage: UX-DR-1 through UX-DR-12 all mapped in `epics.md`

### User Journey Coverage

- UJ-1: Covered by Epic 2 Stories 2.1, 2.2 and 2.3.
- UJ-2: Covered by Epic 2 Story 2.4 and Epic 4 Story 4.4.
- UJ-3: Covered by Epic 3 Stories 3.2 and 3.3.
- UJ-4: Covered by Epic 3 Story 3.4.
- UJ-5: Covered by Epic 3 Story 3.6 and Epic 6 Story 6.4.
- UJ-6: Covered by Epic 4 Stories 4.1, 4.2 and 4.3.
- UJ-7: Covered by Epic 4 Story 4.5 and Epic 6 Stories 6.1, 6.2 and 6.3.
- UJ-8: Covered by Epic 6 Stories 6.6 and 6.7 plus Epic 5 Story 5.5.

### UX Design Requirement Coverage

- UX-DR-1: Covered by Epic 1 Story 1.1 and Epic 5 Story 5.1.
- UX-DR-2: Covered by Epic 1 Story 1.1, Epic 2 Story 2.2, Epic 3 Story 3.2 and Epic 4 Story 4.2.
- UX-DR-3: Covered by Epic 2 Story 2.2, Epic 3 Story 3.2, Epic 4 Story 4.2 and Epic 6 Story 6.4.
- UX-DR-4: Covered by all core surfaces across Epics 1 through 6.
- UX-DR-5: Covered by Epic 2 Stories 2.1 through 2.5.
- UX-DR-6: Covered by Epic 3 Stories 3.1 through 3.5.
- UX-DR-7: Covered by Epic 4 Stories 4.1 through 4.6.
- UX-DR-8: Covered by Epic 5 Stories 5.1 through 5.5.
- UX-DR-9: Covered by Epic 1 Story 1.5 and Epic 6 Story 6.4.
- UX-DR-10: Covered by Epic 1 Story 1.4, Epic 3 Story 3.2, Epic 5 Story 5.1 and Epic 6 Story 6.4.
- UX-DR-11: Covered by Epic 1 Story 1.5, Epic 5 Story 5.2 and Epic 6 Story 6.4.
- UX-DR-12: Covered by Epic 2 Story 2.1 and Epic 5 Story 5.1.

## UX Alignment Assessment

### UX Document Status

UX documentation exists and is usable:

- `DESIGN.md` defines visual spine, tokens, components and constraints.
- `EXPERIENCE.md` defines IA, state patterns, interaction primitives, accessibility floor, tool details and UJ-1 through UJ-8 flows.

### UX ↔ PRD Alignment

Strong alignment:

- UX surfaces map directly to PRD FR groups: Menu Bar, Screenshot Selection, Screenshot Result Overlay, Clipboard History Panel, Translation Panel, Confirmation Card, Settings and Audit View.
- UX traceability lists FR-1 through FR-29.
- UX explicitly preserves the PRD constraints that AI is embedded in tools, provider external transfer requires confirmation, hook enablement is not silent, and agent defaults to summaries.

Alignment issues:

- **Major:** PRD Open Question 3 conflicts with UX clipboard behavior. PRD still asks whether real clipboard content is recoverable; UX states that non-excluded Apps default to local recoverable clipboard storage. This is not a small copy issue; it determines store schema, retention, confirmation behavior and privacy review.
- **Major:** PRD Open Question 5 asks whether provider strategy is BYOK/local CLI or built-in cloud quota; UX states BYOK/API and local CLI only, with no built-in cloud quota, account or subscription. PRD should be updated or the UX assumption should be explicitly accepted as overriding the open question.
- **Minor:** PRD Open Question 1 asks whether translation has a default shortcut; UX resolves it as "default not set." This should be removed from open questions or converted into a closed decision.

### UX ↔ Architecture Alignment

Strong alignment:

- UX foundation inherits `SwiftUI + AppKit + sandbox-first + SMAppService helper + shared action core`.
- UX assigns Main App-owned surfaces and helper-owned recorder behavior consistently with architecture.
- UX confirmation cards align with architecture's `preview`, `external_transfer` and `destructive_or_hook` gates.

Architecture alignment issues:

- **Critical:** `正式AppScaffold架构-v0.md` says clipboard events default to redacted index and that recoverable real user content remains a later formal policy decision, while UX and epics assume default local recoverable storage for non-excluded Apps. This blocks implementation readiness for Epic 3 unless resolved.
- **Major:** UX and epics require broad settings/provider/hook surfaces, but architecture explicitly says P3 scaffold should not implement complete three-tool UI or arbitrary hook runtime. P3-A must narrow the first implementation slice so developers do not interpret V1 epics as a single build target.
- **Minor:** Performance is required but unbudgeted. PRD says latency budgets will be quantified in P3 scaffold and UX Spec; UX defines fast feedback patterns but does not provide numeric budgets.

## Epic Quality Review

### Structure Summary

- Epic count: 6
- Story count: 34
- All stories use `As / I want / So that`.
- All stories include Given/When/Then acceptance criteria.
- FR, UJ and UX-DR traceability is present.

### Critical Violations

1. **Clipboard data ownership conflict makes Epic 3 not implementation-ready.**
   - Evidence: Epic 3 assumes "非排除 App 默认本地可恢复"; UX says the same; architecture v0 says recoverable real user content remains undecided; PRD keeps the same point as Open Question 3.
   - Impact: Implementers cannot decide whether to store full local clipboard payloads, redacted indexes only, or a hybrid permission model. That affects schema, helper behavior, retention, privacy UI, audit, tests and migration.
   - Recommendation: Run a targeted correction before P3: close clipboard storage policy as one explicit decision and update PRD, UX, Architecture and Epics consistently.

### Major Issues

1. **Epic 1 is partly a technical milestone, not purely user-value epic.**
   - Evidence: "Formal App Scaffold & Shared Action Core" and Story 1.2 are architecture-enabling stories. They are necessary for this greenfield app, but they violate the strict warning against technical epics if treated as a product-facing epic.
   - Recommendation: Keep Epic 1 as "Foundation" only if P3-A explicitly treats it as scaffold work. Otherwise refactor stories into a P3-A implementation plan with visible outcomes: runnable signed sandbox app, menu bar, settings shell, action envelope smoke and confirmation stub.

2. **P3 entry acceptance is not concrete enough.**
   - Evidence: Architecture v0 lists P3 entry gates: target/entitlement/helper embedding/test commands. Epics do not require a specific scaffold plan or target layout before Story 1.1 starts.
   - Recommendation: Before implementation, create P3-A scaffold / screenshot vertical slice plan that fixes project type, target names, entitlements, helper embedding, local signing, CLI packaging and test commands.

3. **Stale PRD open questions will confuse implementers.**
   - Evidence: translation shortcut, clipboard recoverability and provider strategy are still open in PRD, but UX/epics already make decisions.
   - Recommendation: Do not start implementation until the stale open questions are either closed or explicitly marked as superseded by UX/P2-N decisions.

4. **Provider connection-test semantics are underspecified for P3.**
   - Evidence: Story 4.6 says "测试连接执行", while PRD/P2 constraints say no real API provider call before secret handling and no raw provider output. For V1 this can be real later, but P3 scaffold likely needs mock/config-only behavior.
   - Recommendation: In P3-A, define provider test as configuration validation and mock/CLI low-sensitive smoke only; real API test remains deferred.

5. **Helper and permission revocation cases remain story-light.**
   - Evidence: UX and Architecture preserve permission missing states, but P2 notes say permission denial/revocation and long-running helper power remain unverified. Stories cover guidance, not the full revocation/restart acceptance path.
   - Recommendation: Keep these as P3/P7 acceptance gates, and do not claim they are done when scaffold starts.

### Minor Concerns

1. **No numeric performance budgets yet.**
   - Recommendation: P3-A should define initial local budgets for screenshot overlay appearance, clipboard panel first render and translation panel response state.

2. **Discovery patterns do not match this repository layout.**
   - Recommendation: Keep future readiness reviews aware that PRD and UX are nested under run directories, not direct `*prd*.md` / `*ux*.md` files.

3. **Story list is broad for a first implementation slice.**
   - Recommendation: Select the next implementation story only after P3-A chooses a narrow vertical slice. Do not hand all 34 stories to implementation at once.

### Best Practices Checklist

| Check | Result |
| --- | --- |
| Epics deliver user value | Partial: Epic 2-6 do; Epic 1 is scaffold-heavy |
| Epic independence | Acceptable if Epic 1 is treated as foundational scaffold |
| Stories appropriately sized | Mostly yes; first implementation slice still needs selection |
| No forward dependencies | No direct forward dependency violation found |
| Database/store created when needed | Not fully assessable until clipboard storage policy is resolved |
| Clear acceptance criteria | Yes, with provider/helper/performance caveats |
| Traceability to FRs maintained | Yes |

## Summary and Recommendations

### Overall Readiness Status

**NEEDS WORK**

The planning baseline is strong: PRD, UX, Architecture and Epics exist; FR coverage is complete; user journeys and UX design requirements are traceable. The project is not ready for direct implementation because one critical data-policy conflict and several major implementation-entry ambiguities would force engineers to make product/security decisions while coding.

This is not a reset. It is a targeted correction gate before P3-A.

### Critical Issues Requiring Immediate Action

1. **Resolve clipboard storage policy across PRD, UX, Architecture and Epics.**
   - Choose one V1 policy: local recoverable by default for non-excluded Apps; redacted-index by default; or explicit per-category authorization.
   - Update the conflicting documents so helper recorder, store schema, retention, agent access and confirmation behavior are unambiguous.

### Recommended Next Steps

1. Run a targeted correction pass for clipboard data ownership and stale PRD open questions.
2. Produce P3-A scaffold / screenshot vertical slice plan that fixes target layout, entitlements, helper embedding, local signing, action core smoke and test commands.
3. Define P3-A provider behavior as mock/config-only unless a separate provider implementation plan approves real API testing.
4. Add initial performance budgets and permission/helper revocation retest gates to the P3-A plan.
5. Only after the above, create the first small implementation story rather than launching all 34 V1 stories.

### Final Note

This assessment identified 1 critical issue, 5 major issues and 3 minor concerns. Address the critical issue before starting P3 implementation. After targeted correction, the project can likely proceed to P3-A scaffold or screenshot vertical slice planning without reopening the full PRD/UX process.
