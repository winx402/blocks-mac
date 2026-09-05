# Step 5 PRD 派发 v0

日期：2026-07-07
角色：项目负责人
派发对象：产品经理
范围：004_剪贴板打磨 Step 5 隐私页真实 App 清单与 CLI 广义对象管理

## 1. 任务结论

请基于 Step 5 范围产出阶段 PRD v0。

本阶段只做产品设计与验收口径，不进入技术方案或开发。Step 1、Step 2、Step 3、Step 4 已验收接受，Step 5 可以启动；不要回改前序已接受阶段的范围。

## 2. 阶段目标

Step 5 目标是让剪贴板隐私页从抽象或不完整的应用管理，升级为可浏览、可搜索、使用真实系统 App 图标的 App 清单；同时定义 CLI 面向 agent 的广义隐私对象管理口径。

本阶段必须覆盖用户原始需求第 9 条：

- 剪贴板隐私页面，App 图标最好从系统里获取真实 App 图标。
- 默认将电脑里所有 App 都展示出来。

以及后续澄清：

- UI 默认展示 `/Applications`、`~/Applications`、`/System/Applications` 下真实 `.app`。
- 登录项、helper、命令行工具等更广义对象可以通过 CLI 管理，主要面向 agent 使用。

## 3. 必须覆盖

### 3.1 隐私页 App 清单

- 默认扫描并展示 `/Applications`、`~/Applications`、`/System/Applications` 下可识别 `.app`。
- 使用系统真实 App 图标；图标读取失败时提供稳定 fallback。
- 列表支持搜索 / 过滤 / 稳定排序，避免“所有 App”不可浏览。
- 每个 App 必须有清晰身份展示和策略状态展示。
- 长 App 名、重复名称、重复 bundle id、无 bundle id、图标读取失败、损坏 App、隐藏 App 等边界需要有产品口径。
- 隐私页 UI 默认不展示登录项、helper、命令行工具，除非产品经理认为必须展示；若要展示，必须说明信息结构和范围膨胀影响。

### 3.2 CLI 广义对象管理

- CLI 可管理 UI 外的隐私对象：登录项、helper、命令行工具等。
- 需要定义 typed subject model 的产品口径，例如 app bundle、path、bundle id、launch service label、helper id、command path 等。
- 冲突对象必须有低歧义展示和选择方式。
- CLI 应偏向 agent 可用：输出结构清晰、可审计、可 dry-run。
- destructive 或系统状态变更类动作如启停、删除、授权、重置、打开系统设置等，不应在本阶段默认扩大；如 PRD 认为要支持，必须单独列出确认 / dry-run / `--yes` / 白名单边界。

### 3.3 权限与数据边界

- App 清单与图标读取应是本地枚举、本地展示，不上传 provider。
- 不为了 App 清单或图标静默请求 ScreenCapture、Accessibility、Automation、Full Disk Access、TCC reset 或跳转系统设置。
- 图标读取失败不应启动 App 或触发权限请求。
- CLI / 日志 / 验收证据不得输出真实敏感凭据、Authorization header、私钥、验证码、provider secret。

## 4. 明确不覆盖

- 不重开 Step 1 的明文展示、搜索底座、OCR。
- 不重开 Step 2 的标签 / 收藏模型。
- 不重开 Step 3 的面板布局打磨。
- 不重开 Step 4 的详情编辑与 dirty guard。
- 不做真实系统权限申请、TCC reset、打开系统设置或外部 provider 上传。
- 不要求本阶段产品 PRD 直接写技术实现细节；技术方案阶段再由 App 架构师定义扫描、缓存、权限和 CLI 实现方式。

## 5. PRD 必须回答的问题

产品经理需要在 PRD v0 中明确：

1. UI App 清单的展示范围、排序规则、搜索规则、空态 / 加载 / 失败态。
2. App 身份字段：名称、bundle id、路径、来源目录、图标、策略状态等哪些展示、哪些可复制、哪些默认隐藏。
3. 重复 App、重复 bundle id、无 bundle id、损坏 App、隐藏 App、图标失败的用户可见行为。
4. 策略状态的查看 / 切换 / 失败反馈 / 保存方式。
5. CLI 管理广义对象的对象类型、标识规则、输出格式、dry-run / confirm 规则和危险动作边界。
6. UI 与 CLI 的关系：UI 是否只管理 `.app`，CLI 是否管理更广对象；两者策略事实源是否需要在产品层面统一表达。
7. 性能与体验验收：大量 App、图标懒加载 / 缓存、列表滚动、搜索响应、不可阻塞主界面。
8. 低敏验收证据：使用 synthetic / fixture 或低敏路径，不复制真实用户敏感路径清单到仓库文档。

## 6. 建议复审角色

PRD v0 完成后，建议至少派发：

- UI/交互设计师：列表信息结构、搜索过滤、长文本、图标 fallback、状态反馈和可访问性。
- App 架构师：macOS App 枚举、图标读取、缓存、typed subject、CLI 边界。
- 测试/质量：fixture、性能门槛、边界对象、回归证据。
- 安全合规顾问：本地枚举、权限、日志、CLI 危险动作、provider 不上传边界。

## 7. 交付物

请产出：

- `docs/项目管理库/004_剪贴板打磨/step_5/产品经理-PRD-v0.md`

PRD 需要同步说明它如何覆盖 `需求覆盖矩阵-v0.md` 中与隐私页真实 App 清单、真实图标、CLI 广义对象管理相关的需求点。
