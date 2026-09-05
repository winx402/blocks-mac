# 004_剪贴板打磨 Step 6 App 架构师收口复审 v0

日期：2026-07-07
角色：App 架构师
范围：Step 6 集成验收与收口覆盖回扫复审
结论：`approve-with-changes`

## 1. 结论

从 App 架构视角，本轮未发现阻塞 004 收口的 P0/P1 级架构遗漏。

P0：0。

P1：0。

结论使用 `approve-with-changes`，原因不是要求返工 Step 1-5 已接受实现，而是建议 Step 6 最终接受前补一份低敏集成证据矩阵：把 P13A / P13B / P13C / P13D / P13E / P11E / P8 / P8I / P9A / P9B 的最新执行状态、当前事实源定位和 residual 统一落到 Step 6 验收材料中。否则项目负责人只能引用阶段历史验收，存在“旧阶段 PASS 被当成最新工作区 PASS”的收口假通过风险。

该 changes 属于 Step 6 验收证据收敛，不是业务代码返工。

## 2. Findings

### P0

无。

### P1

无。

### P2-1：Step 6 需要最新低敏集成证据矩阵，不能只转述阶段历史 PASS

事实依据：

- 产品经理收口回扫已正确指出 Step 1-5 均最终接受，并保留各阶段 P2 residual。
- Step 5 最终验收记录显示 P13A / P13B / P13C / P13D / P13E / P11E / P8 / P8I / P9A / P9B 均曾 PASS。
- 但 Step 6 是整体收口，若最终接受只引用阶段验收记录，而不说明最新工作区是否复核这些 gate，容易形成技术假 PASS。

建议回写：

- Step 6 最终接受前增加一张低敏 gate matrix，至少包含：
  - gate name。
  - command。
  - latest run status。
  - evidence file / stdout summary。
  - 本轮是否运行。
  - 若未运行，明确 `not rerun in Step 6`，不得写成 Step 6 实测 PASS。
- 可以由测试/质量或项目负责人执行，不要求 App 架构师本轮运行。

### P2-2：搜索 + 标签 + 详情编辑后的索引一致性建议补低敏组合 fixture 或明确 residual

事实依据：

- P13A / P9A 覆盖搜索文档、FTS、OCR、类型 token、tag token 进入 search document。
- P13B 覆盖标签事实源、RecordTag、favorite、tag search rebuild、旧 pinned 退出。
- P13D 覆盖详情编辑保存时 payload / summary / search document / FTS / updatedAt / contentRevision 原子更新。
- 这些门禁分阶段成立，但 Step 6 关注的是组合路径：同一条记录在已有标签后被详情编辑，编辑后的正文 / URL / rich text plain text / OCR text 与标签筛选同时生效。

建议回写：

- 最稳做法：新增一个低敏集成 fixture，使用 isolated temp repository 验证 `tag attached -> detail edit save -> search query + selected tag filter`。
- 若不新增 verifier，则 Step 6 最终接受文档必须明确：该组合路径由 P9A + P13B + P13D 分段覆盖，未做单一端到端 fixture，作为 P2 residual 接受。

### P2-3：旧 pinboard / pinned / redacted / hardening fact source 退出已分层覆盖，但 Step 6 应补一次当前事实源审计摘要

事实依据：

- Step 1 验收关闭旧 `redacted` 间接路径，P13A / P8I / P11E 纳入断言。
- Step 2 验收确认旧 pinboard / pinned 不作为 active App UI / Store / filter / search / verifier ok 事实源，P13B / P9B / P8 / P8I 覆盖。
- P11E 继续守 payload allowlist / denylist、默认路径不读 payload、`filtered_records_no_pinned_display_name` 等 hardening 边界。

风险：

- 旧 token 仍可能作为 legacy storage、baseline reference 或历史文档存在。Step 6 若只做全文 token 检索，容易误报；若完全不检索，又容易漏掉 active path 回流。

建议回写：

- Step 6 做一次 targeted low-sensitive audit，按 active path 而不是全文 token 判断：
  - App UI / Store / AppModel / filter / search / CLI / Settings 不以 `pinned`、`pinboard`、`redacted` 作为 current fact。
  - legacy storage / baseline reference 可以存在，但不得进入 `ok` evidence。
  - P11E / P13B / P8I / P9B 输出中的 `baseline_reference` 必须明确 old archives not used for ok。

### P2-4：Step 5 legacy migration 已可接受，但若后续隐私策略继续演进，应补 temp DB runtime harness

事实依据：

- Step 5 已关闭 R2/R3 P1：旧 `clipboard.policy.excludedBundleIDs` 迁移为 `privacy_policy_rules` restricted `bundle_id` rule，且已有 current rule 时不会被旧 key 覆盖。
- P13E 增加了 legacy conflict 场景和 Swift / CLI implementation evidence。
- Step 5 最终验收也明确 P13E legacy conflict 覆盖仍是静态语义 + 合成场景，不是临时 SQLite repository 运行时 migration harness。

判断：

- 作为 004 收口 P2 可接受，不构成 P1。
- 若 Step 6 仍要求更强证据，应补低敏 temp DB fixture，而不是触发真实用户数据库 migration。

### P2-5：真实 UI / VoiceOver / 真实系统环境 residual 不应升级为架构返工

事实依据：

- Step 2-5 均保留真实 UI、真实 VoiceOver、真实剪贴板、真实系统 App 枚举或真实数据库 mutation 未覆盖的 P2。
- Step 6 当前边界禁止触发真实 App、真实剪贴板、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。

判断：

- 这些 residual 不应在 App 架构复审中升级为 P1。
- 可以作为发布前人工验收、低敏截图 / 录屏、辅助功能专项或后续质量清理。

## 3. 跨阶段核心架构边界判断

### 搜索索引

当前分层合理：

- Step 1：Search document / FTS / bounded preview / OCR 状态成为搜索底座，旧 visible/redacted filter 不再是当前搜索事实源。
- Step 2：标签字段进入 search document，标签 rename / merge / attach / detach 通过 invalidation / rebuild 进入索引。
- Step 4：详情编辑保存时同步更新 payload、summary、search document、FTS、updatedAt、contentRevision。

未发现搜索索引事实源冲突。需要 Step 6 关注的是组合 fixture 是否补齐，而不是重新设计搜索模型。

### 标签与收藏

当前分层合理：

- Tag / RecordTag 是独立事实源。
- Favorite 是 built-in tag。
- 旧 pinned / pinboard 只允许作为 legacy storage / baseline reference。
- `ClipboardStore` 可以桥接 `ClipboardTagStore.objectWillChange`，但不复制 tag facts。

未发现需要回到 Step 2 返工的架构遗漏。

### 详情编辑

当前分层合理：

- Repository 是 payload、派生字段、summary、search document、FTS、contentRevision 的唯一持久化写入边界。
- DetailStore 是 draft-only，不成为持久化事实源。
- 系统 pasteboard 不写入通过 fake pasteboard / purpose matrix / P13D 低敏证据约束。

未发现 Step 4 与 Step 1/2 搜索标签模型冲突。

### 隐私 policy fact source

当前分层合理：

- `PrivacyPolicyRepository` 是单一策略事实源。
- UI 使用 AppInstance read model，CLI 使用 typed PolicySubject，二者都写 PolicyRule。
- `ClipboardCapturePolicy` 应消费 `PrivacyPolicySnapshot`，不再只消费旧 `excludedBundleIdentifiers`。
- P13E 将 UI interaction、capture bridge、legacy migration conflict 和 low-sensitive 输出纳入 gate。

未发现 Step 5 与 clipboard hardening / search / tag / detail facts 冲突。

## 4. Verifier 组合判断

现有组合可以支撑 Step 6 收口，但需要 Step 6 最新证据矩阵避免旧 PASS 假通过。

| Gate | 架构职责 | Step 6 判断 |
| --- | --- | --- |
| P13A | 明文展示、搜索文档、OCR、旧 redacted / visible filter 退出、低敏输出 | 足够支撑 Step 1 边界；Step 6 可作为搜索底座回归 |
| P13B | 标签 / 收藏模型、旧 pinboard / pinned 退出、tag search contract | 足够支撑 Step 2 边界；Step 6 应看 active path 而非全文 token |
| P13C | 面板交互、hover / selected / focused、布局 evidence | 足够支撑 Step 3 架构边界；真实 UI residual 保留 P2 |
| P13D | 详情编辑事务、contentRevision、search document / FTS 更新、pasteboard fake evidence | 足够支撑 Step 4 边界；组合搜索路径建议补 fixture |
| P13E | 隐私 App 清单、policy fact source、CLI typed subject、capture bridge、legacy migration | 足够支撑 Step 5 边界；temp DB migration harness 可作 P2 |
| P11E | payload 访问 allowlist / denylist、默认 read model、输出边界 | 必须保留为 Step 6 output-boundary / hardening 回归 |
| P8 / P8I | 产品 polish / Settings 当前事实源 | 可作为 Settings 与面板表层回归，不替代 P13 系列 |
| P9A / P9B | Repository storage smoke / AppModel-repository integration | 可作为跨 store / repository 集成回归，不替代专属 P13 gate |

假 PASS 风险主要来自两个方面：

- 把某阶段历史 PASS 当成 Step 6 最新 PASS。
- 用 P8/P8I/P9A/P9B 这种宽回归替代 P13A-E 的专属边界。

只要 Step 6 最终材料明确 gate matrix 与专属 gate 优先级，该风险可控。

## 5. 必须补的低敏 verifier / fixture / 证据

以下是 Step 6 最终接受前建议补齐的低敏证据，不要求触发真实系统动作：

1. 最新 gate matrix：P13A / P13B / P13C / P13D / P13E / P11E / P8 / P8I / P9A / P9B / build / CLI help / `git diff --check` 的最新状态。未运行则标明未运行。
2. 旧事实源 active path audit：用 P13B / P11E / P8I / P9B 输出和 targeted static scan 证明旧 pinned / pinboard / redacted 只作为 legacy storage 或 baseline reference。
3. 搜索 + 标签 + 详情编辑组合证据：优先补 isolated temp repository fixture；若不补，明确为 P2 residual。
4. P13E legacy migration runtime fixture：可选 P2；若不补，保留现有静态语义 + 合成场景 residual。

## 6. 可接受的架构级 P2 residual

- 真实 App UI、真实 VoiceOver、真实鼠标 hover / click / double click、真实窄宽度、真实 icon 截图。
- 真实系统剪贴板读写、真实用户数据库 mutation、真实 `/Applications` 三目录枚举、真实 hidden / unreadable / damaged app 枚举。
- Step 3 P13C `.label` localization keys 覆盖不足。
- Step 4 P13D dispatch evidence 指向通用派发文档。
- Step 5 legacy migration 未做 temp SQLite runtime harness。
- 既有 SwiftUI actor-isolation warning / AppIntents metadata warning。

这些 residual 都不应写成已实测通过；可进入发布前人工验收、后续质量清理或专项。

## 7. 本轮复审边界与证据

本轮读取：

- `docs/项目管理库/004_剪贴板打磨/step_6/项目负责人-收口派发-Step6-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_6/产品经理-收口覆盖回扫-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_6/项目负责人-收口预审-v0.md`
- Step 1-5 项目负责人最终验收记录。
- Step 1-5 App 架构师技术方案 v1 关键架构段落。
- `tools/verification/` 下 P13A / P13B / P13C / P13D / P13E / P11E / P8 / P8I / P9A / P9B 脚本的静态片段。

本轮未运行 P13A-E、P11E、P8/P8I、P9A/P9B，因此本文不声明这些 gate 在本轮 Step 6 实测 PASS。本文只基于文档与脚本静态抽查判断架构覆盖充分性。

本轮未触发真实 App、真实剪贴板、provider、Keychain、TCC、System Settings、Finder、App launch、真实系统枚举或真实系统状态变更。
