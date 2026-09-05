# Step 5 App 架构师 PRD v1 定向复审 v0

日期：2026-07-07
角色：App 架构师
对象：`004_剪贴板打磨` Step 5 PRD v1
结论：`approve`

## 1. 结论

Step 5 PRD v1 已关闭上一轮 App 架构 P1，可以进入技术方案阶段。

本轮没有发现新的 P0 / P1，也没有发现明显 Step 5 越界。剩余问题均为 P2，适合在技术方案、P13E gate 和后续测试验收中细化，不应阻塞 PRD 接受。

## 2. 复审输入与边界

按任务要求只读：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v1.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/项目负责人-PRD-v1预审-v0.md`
- `docs/项目管理库/004_剪贴板打磨/step_5/App架构师-PRD复审-v0.md`

未读取代码，未触发真实 App、真实剪贴板、provider、Keychain、TCC、系统设置、Finder 或自动化动作。

本轮不是 v0 全量重审，只定向核对上一轮 P1 回写、是否产生新 P0/P1，以及是否仍可作为技术方案输入。

## 3. 上一轮 P1 关闭情况

### P1-1：`.app` 枚举范围歧义

状态：已关闭。

v1 已明确：

- root 仅限 `/Applications`、`~/Applications`、`/System/Applications`。
- 使用受控递归覆盖 root 内用户通常认为属于该 root 的 `.app`。
- 遇到 `.app` bundle 后视为叶子，不扫描 bundle 内部。
- 不跟随逃出三 root 的 symlink / alias。
- unreadable directory、alias 失败、单个 App 损坏进入 partial / row-failed，不让整页空白。
- 技术方案必须定义最大递归深度、跳过规则、symlink / alias、unreadable directory 和 partial 状态；缺失不得进入开发。

判断：PRD 层已经把“受控递归”写成产品口径，最大深度和跳过规则交给技术方案是合理分工。

### P1-2：App identity / policy subject / policy fact source 分层不足

状态：已关闭。

v1 已明确三层产品事实模型：

- `AppInstance`：UI row 事实源，含 displayName、bundleID、canonicalPath、sourceDirectory、pathSummary、pathHash、iconState、identityStatus、policySubjectRef、policyStatus。
- `PolicySubject`：UI 与 CLI 共享的策略 subject，首版支持 `bundle_id`、`app_path`、`app_bundle`、`login_item`、`helper`、`launch_label`、`command_path`。
- `PolicyRule`：绑定到 PolicySubject 的 `Default`、`Allowed`、`Restricted`。

v1 还补充了 duplicate bundle id、missing bundle id、damaged / unreadable App、hidden App、`app_path` 与 `bundle_id` 命中时的处理规则。

判断：三层模型足以作为技术方案输入。

### P1-3：UI / CLI 策略事实源关系不够硬

状态：已关闭。

v1 已把 v0 的“同一或可映射”收紧为：

- UI 与 CLI 必须共享同一隐私策略事实源。
- UI 是 `.app` AppInstance 的可视化子集。
- CLI 是 PolicySubject 的广义管理入口。
- CLI subject 输出包含 `ui_visible`、`ui_match_count`、`policy_subject_ref` 等映射字段。

判断：单一策略事实源边界清楚，后续技术方案不应再引入 UI / CLI 双事实源。

### P1-4：CLI typed subject / subject_ref / 本地解析边界不够硬

状态：已关闭。

v1 已明确：

- CLI subject 是“本 App 隐私策略 subject”，不是系统对象生命周期控制器。
- `subject_ref` 是稳定 opaque id 或低敏 hash，不等同于完整真实路径。
- `app_bundle` / `bundle_id` / `app_path` 来源限 UI 三目录 App index、已有策略事实源或显式 typed 输入。
- `command_path` 默认只接受显式输入或受控 fixture / allowlisted enumeration；不全盘扫描、不扫描 PATH、不执行命令、不读取命令输出、不展开 shell。
- `login_item` / `helper` / `launch_label` 如无法无权限、低敏、稳定枚举，首版仅支持已有策略记录或显式 typed 输入。
- ambiguous 只返回候选，不执行 mutation。
- `--confirm` / `--yes` 只确认本 App policy mutation，系统动作 hard-block。

判断：CLI 本地边界已经足够硬，可进入技术方案。

## 4. 定向问题判断

### 4.1 受控递归、`.app` 叶子、单一策略事实源、三层模型

结论：足以作为技术方案输入。

v1 已完成产品层边界：三 root、受控递归、`.app` 叶子、partial / row-failed、三层事实模型、单一策略事实源。技术方案需要补具体扫描器、缓存、错误模型和 gate，不需要 PRD 再定方向。

### 4.2 `bundle_id` / `app_path` precedence、path-scoped override、missing bundle id、damaged app

结论：无产品层 P1。

v1 已给出可执行规则：

- bundle id 唯一时默认映射 `bundle_id`。
- duplicate bundle id 显示 shared-policy，mutation 前说明影响范围。
- missing bundle id 可在技术方案接受 path-scoped 策略时映射 `app_path`，否则 Unsupported。
- damaged / unreadable App 可展示但默认 Unknown / Unsupported，不静默创建不可靠 rule。
- 同一 App 同时命中 `app_path` 与 `bundle_id` 时推荐 `app_path` 优先；若技术方案暂不支持 override，则 mutation Unsupported 或 confirm-required。

这里保留了技术方案选择空间，但没有让技术方案替产品做无边界决定。

### 4.3 CLI typed subject、subject_ref、本地解析边界

结论：足够硬。

v1 对 subject model、解析来源、危险动作 hard-block、低敏输出、ambiguous 不 mutation 都有明确合同。技术方案阶段可直接拆 CLI schema、subject resolver、policy store mutation 和 P13E 断言。

### 4.4 新 P0 / P1 或 Step 5 越界

结论：未发现。

v1 没有回开 Step 1-4，也没有把 Step 6 真实运行回扫写成 Step 5 完成项。UI 首版可写策略属于 Step 5 隐私策略事实源范围，不是越界；PRD 同时明确不触发系统权限、不执行系统生命周期动作。

## 5. P0 / P1 / P2

### P0

无。

### P1

无。上一轮 App 架构 P1 已关闭。

### P2

1. 受控递归最大深度、目录跳过规则、symlink / alias 细节仍待技术方案明确。PRD 已要求缺失不得进入开发，因此不阻塞 PRD 接受。
2. 图标读取、缓存 key、stale / missing / failed 状态、fallback 图标来源仍待技术方案设计。PRD 已给出稳定尺寸、不启动 App、不请求权限、异步不改排序和 P13E 方向。
3. `app_path` 优先和 path-scoped override 是推荐口径，不是强制实现。技术方案需要明确是否支持 override；若不支持，必须按 PRD 走 Unsupported 或 confirm-required。
4. large-list 数值阈值、first page readiness、search / filter response、memory / output bound 仍待技术方案量化。PRD 已规定缺数值不得进入开发。
5. P13E 作为 hard gate 的具体脚本组合、fixture 数据和低敏 schema 仍待技术方案与测试/质量复审。

## 6. 可直接吸收的建议

建议项目负责人在 PRD 接受记录或技术方案派发中补一段承接文字，避免后续开发误读：

```markdown
App 架构复审确认 Step 5 PRD v1 已关闭 PRD 层 P1。技术方案阶段不得改变以下产品事实：三 root 受控递归、`.app` 叶子、UI / CLI 单一策略事实源、AppInstance / PolicySubject / PolicyRule 三层模型、CLI subject 只代表本 App policy subject、dangerous action hard-block。技术方案只负责把最大递归深度、图标缓存、subject_ref 生成、policy store schema、path override 支持与否、性能阈值和 P13E gate 落成可验证实现合同。
```

给技术方案的具体输入建议：

- 明确 `app_path` override 是否进入首版；如果不进，duplicate / missing bundle id 的 UI 与 CLI mutation 必须按 PRD 降级为 Unsupported 或 confirm-required。
- P13E 应把 forbidden action scan 与 low-sensitive output scan 作为 fail-closed，不只做场景名称检查。
- 图标读取应使用 fake icon provider / fixture 证明 success / failed / fallback，不以真实机器图标作为唯一证据。

## 7. 本轮验证

本轮只做 PRD 定向复审。按任务要求，完成文档后运行：

```bash
git diff --check -- docs/项目管理库/004_剪贴板打磨/step_5/App架构师-PRD-v1复审-v0.md
```

结果：PASS。
