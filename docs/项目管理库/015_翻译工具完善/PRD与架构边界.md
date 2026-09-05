# 翻译工具 PRD 与架构边界

## 产品口径

### 统一入口

- 手动输入：打开统一面板并聚焦原文区。
- 划词：快捷键触发前冻结外部目标，只通过 Accessibility 读取非空选区；空选区、焦点
  元素无文字或没有可用文字时静默进入已聚焦的手动输入，不展示失败横幅；密码框、
  Helper 连接、权限、版本或目标退出等可恢复故障继续展示明确状态。不读取旧剪贴板
  作为隐式降级。
- Direct 与 App Store 主 App 的跨进程 AX 读取统一交给独立安装的
  `Blocks Selection Helper.app`；主 App 保持 sandbox-first，不增加
  `com.apple.axserver` 临时例外，也不嵌入 Helper。未安装、未配对或未授权时，
  划词入口明确降级为已聚焦的手动输入与截图翻译。
- 无论划词成功还是失败，面板最终都展开原文区并把真实第一响应者交给输入框；用户
  已经开始输入后，迟到的 AX 结果不得覆盖其内容。
- 截图翻译：复用区域截图捕获，但不进入截图编辑器、不写剪贴板、不写截图历史；OCR 原文可编辑和重截。
- 剪贴板：只保留用户显式发起的条目翻译。

### 结果与收藏

- 对照组允许 0–4 个服务，按用户配置顺序展示；完成顺序不得改变卡片位置。
- 每张卡片独立等待、运行、流式、成功、失败、取消和重试。
- 收藏保存整次会话中当时成功的结果快照，不保存截图像素、外部窗口和 AX 位置。
- 收藏是不可变快照；服务或插件后续变化不得静默改写。

### 语言偏好与离线资源

- 设置使用“母语＋有序关注语言”，不再以“固定默认目标＋记住上次目标”作为运行
  模型。
- 自动目标规则：
  - 识别为非母语时翻译为母语。
  - 识别为母语时翻译为最近使用的关注语言，否则为关注列表第一项。
  - 语言识别不可靠时使用最近关注语言或关注列表第一项。
  - 没有关注语言时明确提示配置，不静默执行同语种翻译。
- 初次迁移把旧默认目标作为母语候选，旧上次目标在不等于母语时加入关注语言。
- 默认关注语言：母语为中文时默认英语；其他母语默认简体中文。
- Apple 离线翻译语言对只展示系统可提供的“已安装、可下载、不支持”以及下载准备
  阶段，不展示系统未提供的虚假百分比。
- 系统翻译语言和 Dictionary 词典资源继续由 Apple 系统界面管理；Blocks 只提供状态
  和明确入口。

### 插件

- 格式为 `.blocksplugin`，首版只支持 `translation` 与 `ocr`。
- JavaScriptCore 在独立 XPC 服务中运行；插件不能获得剪贴板、AX、Keychain、任意文件或进程能力。
- 网络只能由宿主按清单代理；Secret 由宿主按声明注入，插件不能枚举其他凭据。
- 未签名插件必须展示来源、哈希、能力、权限和外发域名并由用户确认。
- Manifest v3 在 v2 配置字段基础上新增 `accepted_inputs`、`context_fields`、
  `requires_explicit_source_language`、`supports_status` 和独立截图像素数据权限；
  v1/v2 插件按 text-only 兼容。会话凭据必须由用户手工录入，只允许注入清单声明的
  精确域名，跨域或重定向时剥离。
- v2/v3 `permissions.secrets` 与敏感配置字段必须一一对应；同 ID 插件升级以
  schema、敏感字段类型、输入能力、数据权限和规范化 `allowedDomains` 作为审批
  契约。权限契约变化必须撤销旧审批，Secret 契约不变才允许保留，并通过持久化
  tombstone 保证中断恢复。
- 自定义翻译源消费与内置源相同的 `TranslationSourceInvocation`，并只允许返回
  有界动态状态、诊断及唯一成功/失败终态。插件不能注入 UI、执行任意 Shell 或在
  取消、revision 过期后提交迟到结果。
- 截图像素仅在截图翻译入口、插件声明 `screenshot_image` 且用户明确批准图片外发时
  提供。附件只存在于当前会话，不进入数据库、收藏、剪贴板或日志。
- 本轮不兼容 `.bobplugin`，不做市场、自动更新、TTS 插件或自定义插件 UI。

### 翻译源

- 内置单例：Apple 本地翻译。
- 可创建多个配置实例：OpenAI-compatible、DeepL API Free、Microsoft Translator、
  Google Cloud Translation Basic、阿里云机器翻译和 LibreTranslate。
- 内置免配置社区网页源：MyMemory、Google 网页翻译和腾讯翻译君网页源。它们具有
  稳定服务 ID、默认关闭、不创建 Profile，也不保存凭据；首次启用必须确认内容外发、
  非官方协议、限流和失效风险。DeepL 网页协议只保留解析与回归实现，当前真实请求
  在连续六次双向请求中出现一次 HTTP 429，因此不进入生产可用列表。
- 社区网页源与官方 API、Apple 本地和用户插件使用不同的 `.communityWeb` 类型；
  只允许 HTTPS 白名单域名、有限超时与响应体、可取消请求、无持久 Cookie，并拒绝
  跨域重定向。单个社区源失败不得影响其他结果卡。
- 所有外部翻译源默认关闭，统一执行：
  `添加 → 配置 → 保存并启用 → 可选连接验证 → 排序`。
- 对照组最多启用四个服务；配置完整即可启用。“已配置”和“连接已验证”必须分开
  表达，未验证不得被误写为未配置或不可运行。
- API Key、AK/SK、Token 和 Cookie 只存 Keychain；SQLite、Defaults、导出和日志
  只保存非敏感配置与稳定 ID。
- LibreTranslate 仅第一方适配器允许用户明确配置的 loopback HTTP；公网端点必须
  使用 HTTPS。插件和其他公网服务继续拒绝私网地址。
- LibreTranslate Base URL 必须在写入 Profile 前完成规范化与安全校验：拒绝
  user-info、query、fragment、非 loopback HTTP 和非 loopback 私网地址，避免 Secret
  通过 URL 组件进入 SQLite；运行时端点构造必须复用同一策略。
- LibreTranslate 的可用语言以每个实例 `/languages` 返回的 source→target 有向图为
  准，不使用全局静态列表；连接验证必须选择该实例真实支持的低敏语言对。能力快照按
  Profile ID 和配置 revision 隔离并设置数量、边数和编码尺寸上限；缺失或无效快照
  时在首次运行按需发现，不以验证状态替代配置完整性。
- “本地免费”“有免费额度”“可能计费”“可自托管”是可组合的服务属性，不承诺
  永久免费；UI 同时展示官方规则链接和核验日期。

### CLI 翻译源管理

- 设置 UI 与 `blocks translation-source` 共用
  `TranslationSourceManagementService`，CLI 不直接读写 SQLite、Defaults 或
  Keychain。
- CLI 支持列表、脚手架、校验、检查、安装、配置、Secret stdin、连接测试、启停、
  排序、脱敏导出和确认删除；连接测试失败必须返回非零退出码。
- Secret 只允许隐藏交互或 stdin，禁止命令参数、日志和导出；插件安装要求用户核对
  内容哈希。
- CLI 不支持 `/bin/sh -c`、任意本地命令或把 Shell 命令作为翻译源。

## 架构边界

### Core

- `TranslationInput`、`TranslationSessionSnapshot`、结果与语言模型。
- v12 翻译收藏、收藏结果和插件元数据表。
- v13 翻译源 Profile 表；启用顺序继续沿用既有稳定服务 ID，不重置用户排序。
- v14 翻译收藏使用 `unicode61` FTS 索引；收藏增删改必须由触发器同步索引，迁移既有
  数据且保留原收藏 ID、结果快照和排序语义。
- 收藏 Repository、插件元数据 Repository、插件清单与包校验。
- AX 选区与加密 loopback 的纯数据 DTO、校验和协议定义；主 App 与独立 Helper
  共编译同一协议源码，但 Helper 不依赖翻译业务运行模块。

### App

- `TranslationServiceRegistry`：生产适配器唯一注册表。
- `TranslationServiceProfileRepository`：非敏感配置、稳定 ID 和多实例生命周期。
- Profile Repository 的读取必须逐行隔离损坏数据；单行损坏不得清空健康 Profile，
  数据库级失败不得触发破坏性空配置回写。
- `TranslationServiceCredentialStore`：翻译源凭据的 Keychain 边界。
- `TranslationRunCoordinator`：会话 revision、并发、取消和稳定结果顺序。
- `TranslationPanelSessionModel`：单个面板输入、方向、OCR、结果和收藏状态。
- `TranslationPanelScrollCoordinator`：标题、原文、语言栏和结果的滚动边界。外层滚动
  先将手动/划词原文由 72pt、截图原文由 96pt 收缩至 48pt，再滚动结果；原文内部滚动
  不得驱动外层收缩。
- `TranslationFeatureCoordinator`：AX、截图、面板与 OCR 会话生命周期。
- `TranslationPanelPresenter`：非激活窗口、触发屏幕居中、钉住与关闭规则。手动、
  划词、截图和剪贴板面板均在触发所在屏幕的 `visibleFrame` 中央完成首帧布局；
  Helper、兼容取词或 OCR 的迟到结果只能更新内容，不能移动窗口。只持久化用户调整
  后的面板尺寸，不恢复来源相关的历史坐标。

### 插件隔离

- Host：安装审批、元数据、Keychain、网络代理与适配器。
- XPC Runner：JavaScriptCore、输入输出限制、超时、取消和进度预算。
- 任一旧运行入口迁移完成后删除，不保留生产 Mock 或双轨 Provider/Engine 逻辑。

### 独立划词 Helper 隔离

- Helper 是独立下载、签名和公证的 App，只允许读取单次选区；不访问网络、剪贴板、
  Blocks 数据库或用户文件。
- Helper 自己管理辅助功能权限和开机启动；主 App 不使用 SMAppService 注册或替换
  Helper。
- 主 App 与 Helper 通过 URL Scheme 发现和六位码配对；配对后使用 Keychain 共享密钥
  和仅监听 loopback 的加密认证协议。
- 请求携带协议版本、request ID、目标 PID、截止时间、nonce 和字符上限；取消、目标
  退出、权限撤销、重放、版本不兼容和超时必须返回明确失败。
- Direct 与 App Store 使用同一 Helper 协议，不保留嵌入式 Agent、LaunchAgent、
  Selection Mach XPC 或两套运行分支。
- 正式 Archive 必须配置非占位 HTTPS 下载地址；Developer ID、公证和外部分发在条件
  未具备时保持待验证。

## 非目标

- 不替换外部 App 的原选区。
- 不在截图原图上覆盖译文。
- 不自动保存全部翻译历史。
- 不写入或测试用户真实 API Key。
- 不读取浏览器 Cookie，不兼容 `.bobplugin`。
