# 004_剪贴板打磨 Step 5 测试/质量 PRD 复审 v0

日期：2026-07-07
角色：测试/质量
对象：`step_5/产品经理-PRD-v0.md`
范围：Step 5 PRD v0，只复审隐私页真实 App 清单与 CLI 广义对象管理；不进入技术方案、开发或真实运行验证。

## 1. 结论

结论：`approve-with-changes`。

PRD v0 范围基本正确，没有把 Step 1-4 或 Step 6 明显拉回 Step 5；UI 三目录 `.app` 清单、真实图标 / fallback、搜索过滤排序、边界 App、CLI typed subject、dry-run / confirm / dangerous blocked 和本地/低敏边界都有主线口径。

但从测试/质量视角，进入 PRD v1 / 技术方案前仍需补几处 P1：否则后续验收会出现“知道要测什么，但不能稳定判定 pass/fail”的问题。

## 2. P0 / P1 / P2

### P0

无。

### P1-1：UI 策略状态是否可变更仍不够硬

PRD 已要求每个 App 展示策略状态，并提到“状态切换如进入本阶段技术方案，必须有 pending / saving / saved / failed 反馈”，但没有明确 Step 5 UI 是否包含策略变更。

风险：
- 如果开发理解为 UI 可变更策略，当前缺少最小保存 / 失败 / 回滚 / 重试 / 共享 bundle id 影响范围验收矩阵。
- 如果开发理解为 UI 只读，测试不能用“策略失败”和“状态切换反馈”判断是否缺功能。

建议 PRD v1 直接补充：

```text
Step 5 UI policy scope:
- Option A: UI 仅展示策略状态，不提供策略变更。策略变更只由 CLI 管理；UI 验收只覆盖状态读取、失败态和刷新。
- Option B: UI 提供 App 级策略变更。必须覆盖 Default -> Allowed / Restricted、pending、saving、saved、failed、retry、cancel、duplicate bundle id 共享影响提示、mutation 失败不部分提交。

PRD v1 必须二选一；未选择前，开发不得自行决定 UI 是否可写策略。
```

### P1-2：P13E 需要从“建议”升为 Step 5 hard gate

PRD 第 14 节建议 P13E，但当前语气仍偏建议。Step 5 的风险面比普通 UI polish 更大：涉及真实 App identity、真实图标、本地路径、CLI mutating action 和 dangerous action blocked。仅靠既有 P13A-D、P8、P9、P11E 不能替代。

建议 PRD v1 补充：

```text
Step 5 acceptance requires P13E or equivalent fail-closed gate.
P13E must fail when:
- current fact source 不是 Step 5 PRD / 技术方案 / 开发记录；
- UI scan scope 超出三目录，或把 helper / login item / command path 默认放进 UI；
- search / filter / sort / large-list fixture 缺失；
- duplicate name、duplicate bundle id、missing bundle id、damaged、hidden、unsupported、icon failed 任一 fixture 缺失；
- CLI typed subject / ambiguity / dry-run / confirm / dangerous blocked / JSON schema 任一 fixture 缺失；
- verifier 输出包含真实完整路径清单、home path、secret、Authorization header、provider token；
- 触发 provider、真实权限请求、TCC reset、System Settings、Finder、App launch 或真实系统状态变更。
```

既有门禁边界建议：
- P13E：Step 5 主门禁，负责 App inventory、identity、icon、policy、CLI typed subject。
- P8 / P8I：只做现有 clipboard/settings UI 回归，不替代 P13E。
- P9A / P9B：只证明 repository / AppModel 既有边界，不替代 CLI subject 和策略事实源验收。
- P11E：继续守 payload / default denied surface，不替代真实 App 清单低敏验收。
- P13A-D：只作为 Step 1-4 回归，不能作为 Step 5 主验收。

### P1-3：性能与大量 App pass/fail 需要最小数值口径

PRD 说“具体性能阈值由技术方案确认”，但 PRD 层至少需要定义必须量化的项目，否则技术方案可能只给“不卡顿”这类不可验收描述。

建议 PRD v1 补充最低性能验收模板：

```text
Performance acceptance must define numeric thresholds in technical plan:
- large-list fixture count: at least 500 / 1000 / 3000 synthetic apps, choose one explicit target.
- initial visible list readiness: under N ms on fixture environment, or render first page before full icon load.
- search/filter response: under N ms after app index loaded.
- refresh behavior: refresh must not blank the list unless first load has no data.
- icon loading: icon success/failure must not change row height or sorting order.
- memory/output bound: verifier output must summarize counts, not dump full app list.
```

如果项目负责人不希望 PRD 写具体数值，也应写成“技术方案必须给数值，缺数值不得进入开发”。

### P1-4：CLI fixture 覆盖不足以证明边界对象完整

PRD 的 CLI fixture 覆盖 app bundle、duplicate bundle id、login item、helper、command path、dry-run、confirm、dangerous blocked、JSON output，但与 UI 边界矩阵相比仍少了几类容易出假 PASS 的对象。

建议补充 CLI fixture：

| fixtureID | 建议用途 |
| --- | --- |
| `privacy_cli_missing_bundle_id_004` | app bundle 无 bundle id，返回 unsupported 或 path-scoped 策略，不静默当 bundle id 处理。 |
| `privacy_cli_damaged_app_004` | damaged / unreadable app 输出 stable error code，不阻塞其他 subject。 |
| `privacy_cli_hidden_app_004` | hidden app subject 可解析，`ui_visible` 与过滤语义一致。 |
| `privacy_cli_unsupported_subject_004` | 不支持对象返回 `unsupported_subject`，不执行 mutation。 |
| `privacy_cli_path_conflict_004` | 路径摘要相同或 canonical path 冲突时返回 ambiguity，不静默选择。 |
| `privacy_cli_policy_failed_004` | 策略事实源读写失败时输出低敏 error code，dry-run 不改变事实源。 |

同时建议 PRD v1 定义最小 CLI action matrix：

```text
CLI acceptance must cover at least:
- list subjects
- resolve subject
- get policy
- dry-run policy change
- apply policy change with confirm
- blocked dangerous action

Each action must support JSON output with stable fields and low-sensitive errors.
```

## 3. P2 / 可后续优化

### P2-1：搜索匹配细节可留给技术方案，但建议给默认口径

PRD 已列搜索字段，但未说明大小写、空格、特殊字符、多语言、bundle id 分隔符、路径摘要匹配的默认规则。

建议补充可吸收口径：

```text
Search acceptance:
- case-insensitive for display name and bundle id.
- bundle id supports segment match, e.g. `apple mail` / `com.apple` style tokenization by technical plan.
- path summary search only matches sanitized source directory / file name summary, not full raw home path.
- query with no result shows empty state and clear search action.
- search never uploads query and never reads clipboard payload.
```

### P2-2：过滤组合规则建议写清

PRD 列了过滤维度，但未明确多个 filter 的组合规则。

建议补充：

```text
Filter acceptance:
- same dimension multi-select uses OR.
- different dimensions combine with AND.
- clear-all clears search and filters, or PRD must explicitly separate clear search / clear filters.
- loading / partial state under filters must not show stale counts as final.
```

### P2-3：稳定排序建议补充 tie-breaker 与图标异步约束

PRD 已有排序顺序。建议补充：

```text
Sorting acceptance:
- sort key must not depend on icon load completion.
- duplicate display name + duplicate bundle id uses source directory priority and sanitized path summary / stable path hash as final tie-breaker.
- refresh with same fixture preserves row order.
```

### P2-4：可访问性 evidence 模板建议提前写入

PRD 已提键盘 / VoiceOver，但测试阶段需要模板。

建议补充：

```text
Accessibility evidence:
- App row exposes display name, policy status, identity warning and source directory summary.
- Filter chips / sort controls are keyboard reachable.
- Duplicate / damaged / missing bundle id / unsupported states are not conveyed by color/icon alone.
- CLI JSON is not accessibility evidence; UI still needs keyboard/VoiceOver checklist or equivalent low-sensitive manual record.
```

## 4. 重点复审项判断

### UI fixture / CLI fixture / 性能 / 失败态

当前 UI fixture 主体完整，覆盖三目录、图标 success/failure、duplicate、missing bundle id、damaged、hidden、large list、policy failed。建议补上 UI policy mutation scope 和性能数值门槛。

当前 CLI fixture 方向正确，但需要补 missing bundle id、damaged、hidden、unsupported、path conflict、policy failed，避免 CLI 只覆盖 happy path 和 duplicate bundle id。

### 搜索、过滤、排序、大量 App、图标失败、策略失败、低敏输出

PRD 有功能点，但 pass/fail 还需要更硬：
- 搜索字段已列，需补匹配规则。
- 过滤维度已列，需补组合规则。
- 排序规则已列，需补 refresh 稳定和 icon async 不改变排序。
- 大量 App 有 fixture，需补数值阈值。
- 图标失败有 fallback，需补 row height / layout stability 明确断言。
- 策略失败有 Unknown / row-failed，需补 UI 可写或只读策略范围。
- 低敏输出方向正确，P13E 需 fail closed 扫完整路径清单与 forbidden token。

### duplicate / missing bundle id / damaged / hidden / unsupported

UI 矩阵基本完整。CLI 矩阵需要补齐同类对象，否则 UI 和 CLI 的 identity model 可能分叉。

建议 PRD v1 增加一张统一 identity edge case matrix：

| case | UI expected | CLI expected | policy expected |
| --- | --- | --- | --- |
| duplicate name | 全部展示并区分 | 候选列表 | 不静默合并 |
| duplicate bundle id | 标记共享 / 冲突范围 | `ambiguous_subject` unless exact ref | 明示共享影响 |
| missing bundle id | Unsupported 或 path-scoped | typed subject with missing id status | 不按空 bundle id 写策略 |
| damaged app | row-failed / Unknown | stable error code | 不阻塞其他对象 |
| hidden app | 可展示 / 可过滤 | `identity_status=hidden` | 正常或 Unsupported 明示 |
| unsupported subject | 不适用或 Unsupported | `unsupported_subject` | mutation blocked |

### Step 5 范围控制

PRD v0 没有明显把 Step 1-4 拉回，也没有进入 Step 6 真实集成回扫。CLI 广义对象管理边界写得比较克制：管理本 App 自己的隐私策略事实源，不做系统生命周期管理、不做权限授权、不做 TCC reset。该边界建议保留。

## 5. 建议 PRD v1 最小回写清单

1. 明确 UI 策略状态是否可写；如果可写，补保存 / 失败 / 重试 / duplicate bundle id 影响范围验收；如果只读，明确策略变更仅 CLI。
2. 将 P13E 或等价 gate 写成 Step 5 hard gate，而不是建议。
3. 要求技术方案必须给性能数值门槛；PRD 至少列出需要量化的指标。
4. 补齐 CLI edge fixture：missing bundle id、damaged、hidden、unsupported、path conflict、policy failed。
5. 补搜索匹配、过滤组合、稳定排序 tie-breaker 的默认 pass/fail 口径。
6. 补统一 identity edge case matrix，确保 UI 与 CLI 对同一对象语义一致。

## 6. 复审边界

本轮只读复审指定 PRD / 预审 / 派发文档，并对照 `需求覆盖矩阵-v0.md` 中 Step 5 相关条目。未读取业务代码，未运行 App，未触发真实剪贴板、provider、Keychain、TCC、System Settings、Finder 或自动化动作。
