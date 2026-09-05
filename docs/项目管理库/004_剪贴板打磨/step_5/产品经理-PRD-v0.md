# Step 5 产品经理 PRD v0：隐私页真实 App 清单与 CLI 广义对象管理

状态：prd-draft-v0
起草日期：2026-07-07
起草角色：产品经理
所属项目：004_剪贴板打磨
所属阶段：Step 5
来源级别：基于 `../step.md`、`../需求澄清记录-v1.md`、`../需求覆盖矩阵-v0.md`、`项目负责人-PRD派发-Step5-v0.md` 起草，待项目负责人预审。

## 1. 阶段目标

Step 5 聚焦隐私页真实 App 清单与 CLI 广义对象管理。

目标：

- 让隐私页默认展示本机三目录下可识别 `.app`，并使用真实系统 App 图标。
- 让用户能搜索、过滤、排序和理解每个 App 的身份与当前策略状态。
- 让 CLI 面向本地 agent 管理 UI 范围外的广义隐私对象，例如登录项、helper、命令行工具。
- 保持本地枚举、本地展示、本地策略管理，不上传 provider，不静默请求系统权限或重置系统权限状态。

本阶段只做产品设计和验收口径，不进入技术方案或开发，不回改 Step 1 / Step 2 / Step 3 / Step 4 已接受范围。

## 2. 需求覆盖矩阵对齐

| 矩阵 ID | 本阶段覆盖口径 |
| --- | --- |
| R9 | 隐私页默认展示 `/Applications`、`~/Applications`、`/System/Applications` 下真实 `.app`，使用真实系统 App 图标，图标失败时 fallback。 |
| C8 | UI 只默认展示 Applications 三目录中的 `.app`；CLI 管理登录项、helper、命令行工具等更广义对象。 |
| C1 / C12 | 延续“真实内容可访问，交互输出可控”原则：本阶段允许本地枚举 App / 对象身份，但 UI、CLI、日志和验收输出仍需低敏、可读、可控。 |
| C13 | 不引入复杂权限开关或静默权限请求；不自动请求 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset 或 System Settings。 |
| C16 | UI App identity 与 CLI typed subject model 需为后续扩展留出空间，不用路径、bundle id、进程名混作一个字段。 |
| C17 | 覆盖大量 App 列表、长名称、重复身份、图标失败、搜索过滤、可访问性、低敏证据等体验质量。 |

不属于本阶段：

- R1.1、R1.2、R2、C2、C3、C4、C11：Step 1 明文展示 / 搜索 / OCR。
- R7、R8、C5、C6、C7：Step 2 标签 / 收藏。
- R3、R4、R5、R6、R10、R11、C10：Step 3 面板交互与布局。
- R12、R13、C9、C14、C15：Step 4 详情编辑与元数据组织。
- P5：Step 6 最终覆盖回扫。

## 3. 明确非目标

本阶段不覆盖：

- 不重开 Step 1 明文展示、搜索底座或 OCR pipeline。
- 不重开 Step 2 标签 / 收藏模型。
- 不重开 Step 3 面板 hover、toolbar、点击模式或条目密度。
- 不重开 Step 4 详情编辑、保存事务或 dirty guard。
- 不扫描 UI 范围外的所有对象到隐私页；登录项、helper、命令行工具默认只进入 CLI。
- 不做任意系统状态变更执行器。
- 不静默请求 ScreenCapture、Accessibility、Automation、Full Disk Access。
- 不执行 TCC reset。
- 不静默打开 System Settings。
- 不上传 App 清单、图标、路径、策略或 CLI 输出到 provider。
- 不启动 App 来读取图标或身份。
- 不删除、禁用、启停、kill、安装或卸载登录项、helper、命令行工具。

## 4. UI 隐私页 App 清单

### 4.1 默认扫描范围

隐私页 UI 默认扫描并展示以下目录下可识别 `.app`：

- `/Applications`
- `~/Applications`
- `/System/Applications`

范围边界：

- 只纳入可识别 `.app` bundle。
- 不递归扫描任意用户目录。
- 不默认展示登录项、helper、命令行工具或 launch agent，除非后续项目负责人另行扩大范围。
- 不为识别 App 静默请求额外系统权限。
- 读取失败、目录不可访问或单个 App 损坏时，列表仍可用，并显示低干扰错误或问题标记。

### 4.2 App 身份展示

每个 App row 至少展示：

- 真实系统 App 图标或稳定 fallback 图标。
- App 显示名称。
- 当前策略状态。
- bundle id，如果可读取。
- 来源目录或路径摘要。
- 身份异常标记，如果存在，例如重复名称、重复 bundle id、无 bundle id、损坏 App、隐藏 App、图标失败。

默认不在主列表完整展示真实本机长路径。完整路径可通过显式复制、展开或详情查看；验收截图和日志必须低敏化路径。

### 4.3 策略状态展示

每个 App 必须展示当前策略状态。PRD 不重定义底层策略引擎，但首版 UI 至少需要区分：

- `Default`：没有显式 App 级规则，使用默认策略。
- `Allowed` 或等价允许状态。
- `Restricted` / `Excluded` 或等价限制状态。
- `Unknown`：身份不足、策略读取失败或冲突，不能可靠判断。
- `Unsupported`：当前 App 身份无法安全管理，例如无 bundle id 且无可用 path-scoped 策略。

状态要求：

- 状态文案、颜色和图标不能互为唯一信息来源。
- 状态切换如进入本阶段技术方案，必须有 pending / saving / saved / failed 反馈；PRD 不指定具体控件。
- 策略状态失败不能让列表空白；单个 App 失败以行内状态展示。
- 如果同一策略影响多个重复 bundle id App，必须在 UI 中说明影响范围，不能让用户误以为只改一行。

## 5. 列表搜索、过滤、排序和性能

### 5.1 搜索

隐私页 App 列表支持本地搜索。搜索字段至少覆盖：

- App 显示名称。
- bundle id。
- 来源目录或路径摘要。
- 策略状态。
- 身份异常标记，例如 `missing bundle id`、`duplicate`、`icon failed`。

搜索不调用 provider，不上传查询，不读取剪贴板正文。

### 5.2 过滤

首版过滤维度：

- 来源目录：`/Applications`、`~/Applications`、`/System/Applications`。
- 策略状态：Default、Allowed、Restricted / Excluded、Unknown、Unsupported。
- 身份健康状态：正常、重复名称、重复 bundle id、无 bundle id、损坏 App、隐藏 App、图标失败。
- 图标状态：真实图标、fallback。

过滤为空时显示空状态，说明当前过滤条件下没有匹配 App，并提供清除过滤入口。

### 5.3 稳定排序

默认排序规则：

1. App 显示名称，按本地化 / 大小写不敏感方式排序。
2. bundle id。
3. 来源目录优先级：`/Applications`、`~/Applications`、`/System/Applications`。
4. 路径摘要。

排序必须稳定：相同数据集在刷新前后顺序一致，不因图标异步加载改变排序。

### 5.4 大量 App 体验

必须满足：

- 列表可处理大量 App，不阻塞隐私页打开。
- 扫描、图标读取和策略状态加载应有 loading / partial / failed 状态。
- 图标可延迟加载或缓存，但图标出现不得导致行高跳动。
- 搜索和过滤在列表加载中仍有可理解状态，例如 `Scanning apps...`、`Showing partial results`。
- 单个 App 读取失败不影响其他 App 展示。

具体性能阈值由技术方案确认；PRD 验收至少覆盖大量 App fixture、图标失败 fixture 和局部失败状态。

## 6. App 边界对象口径

| 边界 | UI 行为 | 策略状态口径 |
| --- | --- | --- |
| 重复名称 | 全部展示；用 bundle id / 来源目录 / 路径摘要区分。 | 各自显示状态；如策略按 bundle id 共享，显示共享提示。 |
| 重复 bundle id | 全部展示；标记 duplicate bundle id。 | 若底层策略按 bundle id 生效，显示“共享策略”或等价提示；不得静默只改一份。 |
| 无 bundle id | 展示 App 名称和路径摘要，标记 missing bundle id。 | 如果支持 path-scoped 策略则可管理；否则显示 Unsupported。 |
| 损坏 App / Info.plist 读取失败 | 展示路径名或可识别名称，使用 fallback 图标，标记 damaged / unreadable。 | 默认 Unknown / Unsupported；不阻塞列表。 |
| 隐藏 App | 如位于三目录且可识别 `.app`，默认纳入列表并标记 hidden。 | 正常显示状态；可通过过滤隐藏或显示。 |
| 图标失败 | 使用稳定 fallback 图标，标记 icon failed。 | 策略状态不因图标失败而丢失。 |
| 非 `.app` helper / CLI | UI 默认不展示。 | 由 CLI typed subject 管理。 |

稳定 fallback 图标要求：

- 不启动 App。
- 不请求系统权限。
- 保持尺寸稳定。
- 不因图标失败导致行高或布局跳动。

## 7. UI 与 CLI 的关系

产品层面分工：

- UI 隐私页默认管理真实 `.app` 清单。
- CLI 管理 UI 外的广义隐私对象，主要面向本地 agent。
- UI 与 CLI 应指向同一隐私策略事实源或可映射的策略模型，避免 UI 和 CLI 对同一对象给出互相矛盾的状态。
- UI 不需要展示所有 CLI 广义对象；CLI 需要能解释对象是否在 UI 中可见。

同一对象跨 UI / CLI 时：

- CLI 输出应能标注 `ui_visible=true/false` 或等价字段。
- CLI 管理 App bundle 时，应使用与 UI 一致的 identity 字段。
- 如果 CLI 对 helper / command 设置了策略，UI 不默认出现对应条目，但可以在 App row 中显示“关联对象由 CLI 管理”的非阻塞提示，是否显示由后续 UI / 技术方案确认。

## 8. CLI 广义对象管理

### 8.1 对象范围

CLI 可管理 UI 外的广义隐私对象：

- app bundle。
- bundle id。
- app path。
- 登录项。
- helper。
- launch service label / launch agent label。
- 命令行工具路径。
- 其他后续技术方案确认的本地可识别对象。

CLI 不默认扫描所有文件系统路径。显式 path subject 由调用方提供或由受控枚举命令返回。

### 8.2 Typed subject model

CLI 必须使用 typed subject model，不允许把 bundle id、路径、进程名、label 混在一个自由字符串里。

每个 subject 至少包含：

- `type`：对象类型，例如 `app_bundle`、`bundle_id`、`app_path`、`login_item`、`helper`、`launch_label`、`command_path`。
- `id` 或 `subject_ref`：CLI 可复用的稳定引用。
- `display_name`。
- `primary_identifier`：该类型的主要标识，例如 bundle id、canonical path、label。
- `resolved_identifiers`：解析出的相关标识，例如 bundle id、path、source directory、team id，如可用。
- `policy_status`。
- `identity_status`：normal、ambiguous、missing_bundle_id、unresolved、damaged、unsupported 等。
- `ui_visible`：是否会出现在隐私页 UI。

### 8.3 低歧义选择

CLI 遇到冲突时必须低歧义：

- 如果输入命中多个对象，默认返回候选列表，不静默选择第一个。
- 候选列表包含 type、subject_ref、display_name、bundle id、路径摘要、policy_status、identity_status。
- mutating action 必须使用精确 subject_ref 或完整 typed subject。
- 对重复 bundle id、重复名称、无 bundle id、路径冲突必须提示 ambiguity。

### 8.4 结构化输出

CLI 面向 agent，必须提供结构化输出。

要求：

- 支持 JSON 或等价结构化输出。
- 人类可读表格可以作为补充，但不能替代结构化输出。
- 输出包含 action、dry_run、requires_confirmation、subject、policy_before、policy_after、warnings、errors。
- 错误输出有稳定 code，例如 `ambiguous_subject`、`unsupported_subject`、`permission_not_requested`、`dangerous_action_blocked`。
- 日志和验收证据不得包含 secret、Authorization header、验证码、私钥或 provider token。

### 8.5 Dry-run / Confirm

CLI 所有 mutating action 必须支持 dry-run。

规则：

- 默认优先输出 change plan。
- 危险或批量动作必须 dry-run 预览，并要求显式确认，例如 `--confirm` / `--yes` 或等价机制。
- 没有确认时，不执行 destructive 或系统状态变更类动作。
- dry-run 输出不得改变本地策略事实源。
- confirm 输出必须包含受影响 subject 数量、策略变更摘要和 warnings。

### 8.6 危险动作边界

本阶段 CLI 允许的核心动作是管理本 App 自己的隐私策略事实源，不是管理系统权限或系统对象生命周期。

默认禁止：

- 删除、启停、kill、安装、卸载登录项、helper 或命令行工具。
- 静默授权 ScreenCapture、Accessibility、Automation、Full Disk Access。
- TCC reset。
- 打开 System Settings。
- 启动 App 或执行命令来探测身份。
- 上传 subject、路径、策略或图标到 provider。

如果后续要支持任何系统状态变更动作，必须另行 PRD / 技术方案 / 安全合规复审，不作为 Step 5 默认交付。

## 9. 权限与本地数据边界

必须满足：

- App 清单和图标只做本地枚举、本地展示。
- CLI subject 解析和策略管理只在本地执行。
- 不上传 provider。
- 不静默请求 ScreenCapture、Accessibility、Automation、Full Disk Access。
- 不执行 TCC reset。
- 不静默打开 System Settings。
- 图标读取失败不启动 App、不请求权限。
- 验收证据使用 synthetic / low-sensitive fixture；不把真实完整路径清单写入文档。

本阶段可以读取 App bundle 基础元数据和图标，但必须由技术方案确认读取方式、缓存方式和失败降级。PRD 不指定实现 API。

## 10. 状态矩阵

### 10.1 UI App 列表状态

| 状态 | 用户可见行为 |
| --- | --- |
| loading | 显示正在扫描 App，不阻塞页面基本可用性。 |
| partial | 展示已扫描 App，同时说明仍在加载图标或策略状态。 |
| loaded | App 列表、图标、身份、策略状态可用。 |
| empty | 三目录未发现可识别 `.app` 或过滤后无结果，提供清除过滤入口。 |
| row-failed | 单个 App 读取身份 / 图标 / 策略失败，行内标记，不影响其他行。 |
| refresh | 用户触发刷新时保留当前列表或显示刷新状态，不清空成空白页。 |

### 10.2 CLI 状态

| 状态 | 输出口径 |
| --- | --- |
| resolved | subject 唯一解析，输出结构化对象。 |
| ambiguous | 返回候选列表和 `ambiguous_subject`，不执行 mutation。 |
| unsupported | 对象类型或身份不支持管理，输出 `unsupported_subject`。 |
| dry-run | 输出 change plan，不改变事实源。 |
| confirm-required | 输出 `requires_confirmation=true`，等待显式确认。 |
| applied | mutation 已应用，输出 before / after。 |
| blocked | 危险动作被阻止，输出原因和下一步。 |
| failed | 本地执行失败，输出低敏错误 code，不包含 secret。 |

## 11. 验收样例与 fixture

### 11.1 UI fixture

| fixtureID | 用途 |
| --- | --- |
| `privacy_apps_three_dirs_004` | 三目录各有可识别 `.app`，默认全部展示。 |
| `privacy_app_icon_success_004` | 真实系统图标读取成功并稳定显示。 |
| `privacy_app_icon_failed_004` | 图标读取失败，显示稳定 fallback。 |
| `privacy_app_duplicate_name_004` | 重复名称通过 bundle id / 来源目录区分。 |
| `privacy_app_duplicate_bundle_id_004` | 重复 bundle id 标记共享 / 冲突策略范围。 |
| `privacy_app_missing_bundle_id_004` | 无 bundle id 显示身份异常和 Unsupported / path-scoped 状态。 |
| `privacy_app_damaged_004` | 损坏 App 不阻断列表。 |
| `privacy_app_hidden_004` | 隐藏 App 可展示并可过滤。 |
| `privacy_apps_large_list_004` | 大量 App 下搜索、过滤、排序、滚动可用。 |
| `privacy_app_policy_failed_004` | 策略状态读取失败行内展示 Unknown，不清空列表。 |

### 11.2 CLI fixture

| fixtureID | 用途 |
| --- | --- |
| `privacy_cli_app_bundle_004` | app bundle typed subject 解析和策略读取。 |
| `privacy_cli_bundle_id_duplicate_004` | 重复 bundle id 返回候选，不静默选择。 |
| `privacy_cli_login_item_004` | 登录项 subject 结构化输出。 |
| `privacy_cli_helper_004` | helper subject 结构化输出。 |
| `privacy_cli_command_path_004` | 命令行工具 path subject。 |
| `privacy_cli_dry_run_004` | mutating action dry-run 不改变事实源。 |
| `privacy_cli_confirm_required_004` | 危险 / 批量动作要求 confirm。 |
| `privacy_cli_dangerous_blocked_004` | TCC reset、System Settings、权限请求等危险动作被阻止。 |
| `privacy_cli_json_output_004` | JSON 输出字段稳定。 |

### 11.3 最低验收矩阵

- UI 扫描范围：三目录 `.app`。
- UI 身份：名称、bundle id、路径摘要、来源目录、图标、策略状态。
- UI 边界：重复名称、重复 bundle id、无 bundle id、损坏 App、隐藏 App、图标失败、大量 App。
- UI 操作：搜索、过滤、排序、刷新、空态、失败态。
- CLI subject：app bundle、bundle id、app path、login item、helper、command path。
- CLI 输出：结构化 JSON、ambiguity、dry-run、confirm、blocked dangerous action。
- 安全边界：本地枚举、本地展示、不上传 provider、不静默请求权限、不 TCC reset、不打开系统设置。
- 低敏证据：不包含真实完整路径清单、secret、Authorization header、验证码、私钥、provider token。

## 12. 需要 App 架构师确认的问题

1. macOS 三目录 `.app` 枚举方式、是否需要缓存、刷新和失败恢复。
2. 真实系统图标读取方式、缓存策略、fallback 图标来源和失败边界。
3. App identity 的 canonical model：bundle id、path、source directory、display name 如何组合成稳定 identity。
4. 重复 bundle id 时策略事实源按 bundle id、path 还是二者组合生效。
5. 无 bundle id / 损坏 App 是否可支持 path-scoped 策略；如不支持，UI 如何显示 Unsupported。
6. 隐私策略事实源如何被 UI 和 CLI 共用或映射。
7. CLI typed subject model 的具体 schema、subject_ref 生成和冲突解析。
8. CLI 对登录项、helper、命令行工具的本地枚举范围和权限边界。
9. dry-run / confirm / dangerous action blocked 的实现边界。
10. 如何证明不上传 provider、不静默请求系统权限、不写 TCC / System Settings。

## 13. 需要角色复审的问题

### 13.1 UI / 交互设计师

- App row 信息密度：图标、名称、bundle id、路径摘要、状态、异常标记如何排列。
- 搜索 / 过滤 / 排序控件是否适合大量 App。
- 图标 fallback、重复身份、无 bundle id、损坏 App、隐藏 App 的文案和视觉处理。
- 长 App 名、长 bundle id、长路径摘要、多语言下是否重叠。
- 列表键盘导航和 VoiceOver 语义。

### 13.2 App 架构师

- 三目录 App 枚举、图标读取、缓存和 identity model 是否可落地。
- UI 与 CLI 是否共享策略事实源。
- CLI typed subject model 是否足够区分登录项、helper、命令行工具。
- 不静默请求权限 / 不触发系统设置 / 不上传 provider 的技术边界。

### 13.3 测试 / 质量

- 三目录、边界 App、大量 App、图标失败和策略失败 fixture 是否足够。
- 搜索 / 过滤 / 排序稳定性如何验证。
- CLI ambiguity、dry-run、confirm、dangerous blocked、JSON 输出如何验证。
- 低敏证据如何避免真实路径清单和敏感凭据。

### 13.4 安全合规顾问

- 本地 App 枚举和路径展示的低敏边界是否充分。
- CLI 管理登录项、helper、命令行工具是否存在滥用风险。
- dangerous action blocked 口径是否足够明确。
- 日志、JSON、验证输出是否可能泄露真实路径、secret 或 provider token。

## 14. 建议门禁方向

PRD 不指定实现脚本，但建议后续技术方案提供 Step 5 专属门禁，可命名为 P13E 或等价 gate，最低断言包括：

- PRD / 技术方案 / 开发记录引用当前 Step 5。
- UI 扫描范围只包括 `/Applications`、`~/Applications`、`/System/Applications` 下 `.app`。
- 真实图标读取成功和失败 fallback 均有 fixture。
- 搜索、过滤、稳定排序在大量 App fixture 下可复跑。
- 重复名称、重复 bundle id、无 bundle id、损坏 App、隐藏 App、图标失败均有产品状态。
- CLI typed subject model 输出稳定 JSON。
- ambiguous subject 不执行 mutation。
- dry-run 不改变事实源。
- dangerous actions 被 blocked。
- 不上传 provider，不静默请求 ScreenCapture / Accessibility / Automation / Full Disk Access，不 TCC reset，不打开 System Settings。
- 低敏输出扫描通过，不含 secret、Authorization header、验证码、私钥、provider token 或真实完整路径清单。
