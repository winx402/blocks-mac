# 015 翻译工具完善

状态：implementation-in-progress

最后审阅：2026-07-31

## 目标

将原有单输入、单服务、单结果的翻译骨架收敛为统一翻译工具，覆盖：

- 手动输入、严格 AX 划词、截图 OCR 和显式剪贴板条目入口。
- 最多四个服务并行且顺序稳定的结果卡。
- Apple 本地、OpenAI-compatible、官方外部翻译源和 Blocks 原生插件。
- 整次翻译收藏、检索、重新翻译和导出。
- 独立 Selection Helper 与插件 XPC 的最小权限隔离。

## 当前阶段事实

- 已进入用户明确批准的实施阶段；项目状态继续保持
  `implementation-in-progress`，不因代码或自动化阶段性通过而标记完成。
- 本轮收口处理统一翻译方向解析、不可运行服务过滤、AppKit 输入同步、单结果卡重试
  和连接详情、稳定操作栏及结果卡持久化拖动排序；不改变既有数据库、收藏、语言
  偏好或 Helper 配对。
- 数据库当前迁移目标为 v14：
  - v12 保存翻译收藏、收藏结果和插件元数据。
  - v13 新增 `translation_service_profiles`，保存稳定 Profile ID、模板、名称和
    非敏感配置；凭据不进入 SQLite。
  - v14 为翻译收藏新增 `unicode61` FTS 索引及同步触发器，迁移既有收藏；中文、
    日文和带变音符号文本不再依赖线性 `LIKE` 扫描。
- 当前内置服务代码包含 Apple 本地、OpenAI-compatible、DeepL API Free、
  Microsoft Translator、Google Cloud Translation Basic、阿里云机器翻译和
  LibreTranslate。外部源默认关闭；配置完整即可保存并启用，“已配置”和“连接已验证”
  是两个独立状态，连接测试由用户另行触发。
- 免配置社区网页源当前生产列表包含 MyMemory、Google 网页翻译和腾讯翻译君网页源；
  三者均默认关闭且首次启用需要独立风险确认。DeepL 网页协议的本地解析实现存在，
  但当前真实低敏请求返回 HTTP 429，因此没有暴露为可启用服务。
- LibreTranslate 不再使用静态语言列表或固定 `en → zh` 验证：连接验证会读取实例
  `/languages`，保存 source→target 有向能力图，并从该实例真实支持的语言对中选择
  低敏验证文本。能力快照按 Profile ID 与配置 revision 独立缓存；缓存缺失、损坏、
  超限或与当前配置不匹配时，首次翻译按需发现能力，不以“未验证”阻止已配置实例运行。
- LibreTranslate Base URL 在写入 SQLite 前使用与运行时端点构造相同的规范化策略：
  拒绝 user-info、query、fragment、非 loopback HTTP 和非 loopback 私网地址，并规范化
  scheme/host；Secret 不能借 URL 组件进入普通配置。
- v13 Profile 读取会逐行隔离无法解码的记录；单个损坏 Profile 不再清空同批健康
  Profile。数据库级读取失败时保留上一份有效运行状态，不执行破坏性空列表回写。
- `.blocksplugin` Manifest 当前目标版本为 v3，并继续兼容 v1/v2；配置字段支持
  `text`、`url`、`secret`、`boolean`、`choice` 和 `sessionCredential`。v1
  `permissions.secrets` 与 v2/v3 敏感配置字段均进入真实保存、删除和 Keychain
  生命周期，不把“可解码”误写成完整兼容。
- v2/v3 Manifest 要求 `permissions.secrets` 与敏感配置字段一一对应；同 ID 插件
  升级会比较 schema 版本、敏感字段类型和规范化后的 `allowedDomains`。删除字段、
  改变类型、改变会话凭据域名、输入能力或数据权限都会撤销旧审批；Secret 契约不变
  时保留，
  中断升级继续由持久化 tombstone 前向恢复。
- 设置侧栏已经改为 AppKit Source List：5 个不可选择的分组标题、11 个真实可选
  路由；内部 `.settings` 路由保持稳定，用户可见名称为“通用”。旧“扁平 11
  路由”口径已废止。
- Direct 与 App Store 主 App 统一连接独立安装、非沙箱的
  `Blocks Selection Helper.app` 读取单次选区；主 App 继续启用 App Sandbox，且没有
  `com.apple.axserver` 或旧 Selection Agent Mach lookup 临时例外。
- 主 App 已删除旧 Helper/LaunchAgent 的依赖、嵌入和注册逻辑；独立 Helper 自己管理
  开机启动与辅助功能权限。
- 本机 Debug Helper 已签名安装并真实监听 IPv4/IPv6 loopback；正式下载 URL、
  Developer ID、公证、用户配对和辅助功能授权仍待外部条件。
- 设置已改为“母语＋有序关注语言”，并增加 Apple 离线语言对状态、系统翻译语言入口
  和 Dictionary App 入口。系统不提供下载百分比，因此界面只显示不定进度和阶段。
- 划词触发当前会先展示非阻塞面板骨架，再等待 Helper；无论成功或失败都会请求真实
  输入框焦点，用户已经输入后迟到结果不得覆盖内容。
- 安装脚本不再使用宽泛的 `pkill -x Blocks`，也不再以“存在同 Bundle ID 进程”作为
  启动成功：替换前按精确稳定 App bundle 枚举旧 PID、发送 `SIGTERM` 并最多等待
  5 秒；启动后要求新 PID、精确可执行路径、`finishedLaunching=true`，且运行进程的
  Identifier、TeamIdentifier 和 CDHash 与刚安装产物一致。独立 Selection Helper
  不由主 App 安装脚本停止或替换。
- 2026-07-31 收口工作树已实现：固定标题栏；原文先由 72/96pt 收缩至 48pt、语言栏
  固定、结果独立滚动；全局 micro 操作组；结构化 AppKit 拖放；Action/CLI requestID
  级 Task 取消；Apple 系统确认期间关闭保护；Profile 精确回滚；插件可选枚举“未设置”；
  OCR 与截图附件独立 revision；翻译收藏 v14 FTS；译文复制历史契约；CLI 安装入口及
  设置分组 AX 语义。本段只记录实现事实，自动化和安装版结论以本轮最终证据为准。
- 2026-07-31 语言阻断项收口新增有方向的翻译源能力判断和返回目标语种校验。真实请求
  确认腾讯网页源会把英文到希伯来语、印地语、泰语、斯洛伐克语和马来语等请求回退为
  中文；该结果不再被当作成功。语言菜单现按母语、最近使用关注语言、其余关注语言优先，
  再显示本地化排序的全部语言。完整事实和边界见
  `evidence/runtime/translation-language-blocker-closeout-2026-07-31.md`。
- `Blocks Input Echo` Manifest v3 示例源已形成安装版 CLI/XPC 闭环；最终保留为已安装、
  已验证、关闭，不占用四源上限。该闭环同时修复了包物化的 Foundation fatal error 和
  Plugin Runner 沙箱身份查询导致合法宿主被拒绝的两项真实阻断。

## 当前验证结论

### 当前自动化与产物事实

- 完整 `BlocksAppTests` 共形成五类当前证据：
  - 一轮 698 项、4 项按设计跳过、0 失败。
  - 随后的冷启动轮次中，既有
    `LocalVisionOCRServiceTests.testRealVisionDiagnosticCorpus` 的 latin 耗时
    13.956 秒，超过 8 秒诊断阈值，形成 1 项失败；第一次独立冷复跑仍为 8.231 秒并
    失败。
  - 第二次热复跑为 0.838 秒，之后完整 warm-verified 轮次 698 项、4 项跳过、0 失败。
  - 两个 P1 修复后的一次冷启动全量执行共 704 项、4 项跳过、1 项失败；唯一失败仍是
    `LocalVisionOCRServiceTests.testRealVisionDiagnosticCorpus` 的 latin 冷初始化
    11.706 秒超过 8 秒诊断阈值。随后同一用例 warm 定向复跑 1/1 通过，latin 为
    0.162 秒。
  - 最新工作树又暴露并修正了 deadline 取消确认测试的执行器竞态；相关 3 项定向
    通过后，完整 warm 全量复跑为 704 项、4 项跳过、0 失败。
  因此最新完整回归已通过，但历史冷启动失败仍作为性能边界保留，不能用 warm 全量
  通过抹掉。
- 插件 Secret 升级契约定向 9/9、插件 Manager/Validator 类 49/49、因新 v2
  一一对应约束而更新的回归夹具 5/5 通过。
- `BlocksScreenshotCoreTests` 220/220、两个 58.5MP 资源用例 2/2 通过。
- Libre URL 持久化与端点安全定向 3/3 通过，覆盖安全 URL 规范化、敏感 URL 组件写入
  前拒绝及公网 HTTPS/字面 loopback 策略。
- Direct Release、AppStoreRelease 和 Xcode Analyze 成功；Direct/App Store
  Selection Agent 产物审计通过。
- Debug 已成功构建并复制到 `~/Applications/BlocksDev/Debug/Blocks.app`，严格签名
  校验通过，主二进制 SHA-256 为
  `34b33caf88fa69eb18f77c657b14aedfeaac45005804be8d87c4828a2602515c`，
  Agent 与 LaunchAgent 均已嵌入。真实进程 PID 10862 的
  `NSRunningApplication.finishedLaunching=false`；新版安装校验要求新 PID、精确
  bundle/executable、finishedLaunching 以及 Identifier、TeamIdentifier、CDHash
  一致，因此正确失败，不再被旧 PID、测试进程或“进程存在”假阳性误导。
- 当前翻译/架构相关 P5-Q、P7-H、P7-M、P10-A、P11-C 门禁及
  `git diff --check` 通过。
- Selection Agent 安全与时序定向测试：
  - 6 项身份、超时、取消和产物边界测试通过。
  - 4 项立即骨架、焦点和迟到结果保护测试通过。
- Selection Agent 签名 Team、Hardened Runtime、最小 entitlement 与系统框架依赖
  已完成静态产物检查。
- 项目不存在独立 `BlocksCoreTests` scheme；现有 `BlocksCore` scheme 未配置 test
  action，因此不能声称该测试套件通过。Core 行为由 `BlocksAppTests` 中对应测试覆盖。

### 尚不能判定项目完成

- 最新完整 warm AppTests 为 704 项、4 项跳过、0 失败；历史冷启动轮次仍出现
  Vision OCR 初始化超过 8 秒阈值，因此功能回归已闭合，但冷启动性能结论仍未闭合。
- 受系统状态影响的真实签名宿主/安装版路径仍须闭合。
- 当前没有最后工作树对应的安装版 UI/AX/运行时证据。
- Debug App 已复制但没有完成启动，不能把“已安装”外推为“已运行”或 UI/AX 已验。

### 安装版/外部服务待验证

- 当前真实签名测试宿主与安装版阻塞的最终 sample 已定位到当前用户 `secinitd`：
  `app.blocks.app` 串行队列正在
  `appsandboxContainerSync → displaySharingConsentPrompt → CFUserNotificationReceiveResponse`
  等待 macOS“共享同意”系统提示响应，尚未进入 App/test main。这说明当前停滞不是
  App 代码死锁；Finder 桌面截图没有显示该提示，而自动化控制因安全策略不能代用户
  操作 `com.apple.UserNotificationCenter`，因此真实 UI/划词验收仍被系统交互阻塞。
- Selection Agent 的 SMAppService 注册、登录项批准、Helper 辅助功能权限和真实 XPC
  连接尚未闭合。
- Option+D 在 TextEdit、Safari、Electron/Codex 和 Preview PDF 的真实选区读取、
  输入框第一响应者、剪贴板不变化仍待验证。
- 新的 5 组设置侧栏、11 个真实路由和“通用”名称尚未取得本轮安装版截图/AX。
- 第三方翻译源没有专用测试凭据；真实成功调用、额度/计费和服务端差异均待验证。
- 真实 Apple 语言包、macOS 14 降级、多屏/混合 DPI 截图翻译、真实插件生命周期和
  安装版性能指标仍未闭合。

## 2026-07-28 划词运行时收口事实

本节覆盖并替代上文中与旧 Selection Agent、未配对 Helper 和旧安装包有关的阶段性
描述；历史失败证据继续保留，但不再作为当前运行状态。

- 主 App 到 Helper 的请求现已完整携带目标 PID、Bundle ID、request ID、触发时鼠标
  屏幕坐标、截止时间和 revision，不再在桥接层丢失鼠标位置。
- Helper 使用唯一有界候选解析器，依次检查焦点元素、鼠标命中元素和当前窗口内受限的
  Document/WebArea/PDF/Text 候选；文本提取统一覆盖 selected text、range 和 text
  marker。安全输入框继续 fail-closed。
- Helper 查找器按正式安装路径、稳定 Debug 安装路径、DerivedData 的顺序确定唯一
  实例，避免旧构建副本被 LaunchServices 随机选中。
- 只有用户按 Bundle ID 明确授权后，AX 全部失败的 App 才能进入兼容复制取词。兼容
  路径通过 Clipboard Broker 在后台保存和恢复可恢复快照、抑制历史捕获，并在检测到
  外部剪贴板变化时放弃回写；主线程不读取旧 Pasteboard。
- Apple 本地翻译设置与运行时共用可用性协调器和有方向的语言对缓存；首次
  `.supported` 会做有界复查，语言包准备任务由功能级控制器持有，离开设置页不会
  取消正在进行的系统准备。
- 当前签名 Debug Helper 已安装、配对并具有辅助功能权限，真实 AX 树显示中文界面、
  “已配对”“已就绪”“本机连接已就绪”；IPv4/IPv6 loopback 均在监听。
- 当前签名 Debug 主 App 已安装并启动；翻译设置真实 AX 树显示 Apple 本地翻译已启用、
  母语简体中文、关注语言英语、该语言对已安装、Helper 连接和辅助功能权限正常。
- 自动化当前证据：
  - 翻译/Helper 定向 120 项执行，1 项需要测试宿主注入真实 Helper 环境的用例跳过，
    0 失败。
  - `BlocksScreenshotCoreTests` 220/220。
  - P14-G 正式两段式 AppTests、P3-C 的 P14-A～P14-G、P5-Q、P6-C、P7-D/E/H/M、
    P10-A 和 P18 OCR 门禁通过。
  - Direct Release、AppStoreRelease、独立 Helper Release、Xcode Analyze 和最新
    签名 Debug 安装通过。
- 当前仍不能宣称“划词矩阵全部通过”：现有桌面控制通道不能发出真实系统全局
  Option+D，因此最后工作树在 TextEdit、Chrome、VS Code/Electron 和 Preview PDF
  的真实硬件快捷键与选区结果仍待用户醒来后复核；第三方真实翻译源、真实 Apple
  下载确认/拒绝、macOS 14 与正式 Helper 下载/公证同样待外部条件。

## 2026-07-29 面板崩溃、设置窗口与翻译源稳定性

- 多结果诊断和截图 OCR 的两份真实崩溃报告均落在 `String.init(format:)`：
  代码把整数直接传给本地化对象占位符 `%@`，Foundation 将整数当作对象指针访问，
  分别触发多源诊断和 OCR 完成路径的 `EXC_BAD_ACCESS`。HTTP 状态码等同类路径也
  存在潜在风险。
- 翻译数值本地化已收敛到类型安全格式函数，字符数、输入上限、OCR 行数/置信度、
  翻译耗时和 HTTP 状态统一使用 `%lld` 与 `Int64`；结果卡、诊断、OCR 状态和
  无障碍播报消费同一结果。
- 划词 `.reading` 状态不再插入原文输入区；统一 HUD 通知使用固定去重键和不定进度，
  结束时只关闭对应通知，不改变输入框尺寸或第一响应者。
- App 只声明一个 `Window(id: "main")`，删除内容重复的 `Settings` Scene。
  菜单设置、`Cmd+,` 和模块跳转统一通过 `openSettings(section:)`；翻译面板明确请求
  `.translationSettings`，等待一次主线程导航提交后再关闭未钉住面板。
- 翻译源目录始终使用固定分类顺序；启用顺序独立显示在“结果顺序”区域。社区源
  首次启用改为当前单例窗口内确认；Google 网页源增加真实连接测试和分层错误反馈。
- 最新安装版真实 AX 已确认只有一个 `main` 设置窗口、侧栏“翻译”被选中、翻译源
  目录顺序固定。Google 网页翻译使用低敏文本实测返回有效译文，界面显示
  “连接成功”，而不是旧的插件通用反馈。
- 合并到 `main` 后，最新 Debug App 已再次精确替换并启动为 PID `8946`，安装路径
  `~/Applications/BlocksDev/Debug/Blocks.app`，Identifier `app.blocks.app`，
  Team `LOCAL_TEAM_ID_REDACTED`，CDHash `c9e334ffec51c6da8d499d18f380eaafd6791b54`，
  主二进制 SHA-256
  `c8542f8b372860385c9e597c17bb5386809068d2818d3fb38d6258c9d9731b8b`。
- 桌面控制通道不能生成系统全局 Option+D/Option+S，因此本轮没有把应用内定向按键
  或自动化路径冒充真实硬件快捷键验收；真实外部 App 触发仍保留为待人工复核。

## 2026-07-28 面板定位与 Apple 错误分类收口

- 划词骨架不再读取手动翻译面板保存坐标：快捷键触发前冻结的鼠标位置作为临时锚点，
  Helper 返回真实选区矩形后再精确更新；兼容取词没有矩形时继续使用临时锚点。
- 定位候选固定为选区下方、上方、右侧、左侧；优先首个完整可见位置，无法完整容纳
  时按遮挡和位移评分，并限制在目标显示器安全区域。负坐标、多屏和四边收敛已有
  自动化覆盖。
- Apple 翻译失败不再把所有异常归为“语言包下载失败”。公开
  `TranslationError`、运行阶段和准备阶段现在统一分类；只有系统状态可下载且会话
  未就绪，或 macOS 26 明确返回 `notInstalled` 时才展示下载操作。
- 已安装但会话暂未就绪、Apple 内部错误和一般运行异常只提供重试/切换来源；空文本、
  无法识别语言和不支持语言分别提供对应恢复路径；取消不进入失败提示。
- 设置页按“母语 → 关注语言”和“关注语言 → 母语”分别展示真实状态。当前安装版
  AX 已确认 `简体中文 → 英语`、`英语 → 简体中文` 均显示“已安装”。
- 本轮定向测试 135 项执行、134 通过、1 项因测试宿主未注入真实 Helper 环境按条件
  跳过、0 失败；P14-G 两段式完整 AppTests、Screenshot Core 220/220、P5-Q、
  P7-H、P7-M、P10-A、P11-C、Release 构建和 Analyze 均通过。
- 最新签名 Debug App 已在 `main` 合并后再次精确替换并启动为 PID `55083`，安装路径
  `~/Applications/BlocksDev/Debug/Blocks.app`，Identifier `app.blocks.app`，
  Team `LOCAL_TEAM_ID_REDACTED`，CDHash
  `c6aa96551ee6987269e5b413b8a5505478c538cb`。独立 Helper 保留在同目录，
  Identifier `app.blocks.selection-helper`，CDHash
  `53e659f825479f44538eb9dd2cfaf022f54c01fd`。
- Helper 启动后，真实 AX 为“已配对、辅助功能已就绪、本机连接已就绪”；重新进入
  翻译设置后主 App 显示“连接和辅助功能权限正常 · 助手 0.1.0”。
- 桌面控制通道只能向指定 App 发送按键，不能产生系统全局快捷键；因此本轮未把
  自动化按键冒充真实 Option+D。安装版设置与双向状态已实测，外部 App 硬件快捷键
  和真实选区附近位置仍是明确待人工复核项。

## 文档

- [PRD 与架构边界](PRD与架构边界.md)
- [实施与验收记录](实施与验收记录.md)
- [覆盖矩阵](覆盖矩阵.md)
- [Sandbox-First 划词 Helper 决策复审](Sandbox-First划词Helper决策复审.md)

## 证据入口

- 自动化证据：[`evidence/automation/`](evidence/automation/)
  - 当前全量 AppTests：
    `current_blocks_app_tests_704_cold_failure_after_p1.log`、
    `current_blocks_app_tests_704_warm_pass.log`、
    `current_apptests_deadline_and_vision_targeted_pass.log`、
    `current_vision_ocr_warm_after_p1_pass.log`、
    `current_blocks_app_tests_698_pass.log`、
    `current_blocks_app_tests_cold_start_failure.log`、
    `current_vision_ocr_cold_rerun_failure.log`、
    `current_vision_ocr_warm_rerun_pass.log`、
    `current_blocks_app_tests_698_warm_verified.log`
  - 插件 Secret 升级契约：
    `current_plugin_secret_upgrade_targeted_9.log`、
    `current_plugin_secret_upgrade_classes_49.log`、
    `current_plugin_secret_contract_regressions_5.log`
  - 当前工程验证：
    `current_screenshot_core_tests_220.log`、
    `current_58_5mp_resource_tests_2.log`、
    `current_libre_url_security_targeted_3.log`、
    `current_direct_release_build.log`、
    `current_appstore_release_build.log`、
    `current_xcode_analyze.log`、
    `current_selection_agent_artifact_audit.log`、
    `current_gate_p5q.log`、`current_gate_p7h.log`、
    `current_gate_p7m.log`、`current_gate_p10a.log`、
    `current_gate_p11c.log`、`current_git_diff_check.log`
  - 划词运行时收口：
    `selection-runtime-targeted-tests-120.log`、
    `screenshot-core-tests-220-selection-runtime.log`、
    `p14g-app-tests-selection-runtime.log`、
    `p3c-selection-runtime.log`、`p5q-selection-runtime.log`、
    `remaining-gates-selection-runtime.log`、
    `direct-release-selection-runtime.log`、
    `appstore-release-selection-runtime.log`、
    `analyze-selection-runtime.log`、
    `helper-signed-build-localized.log`、
    `latest-debug-install-selection-runtime.log`
  - 当前阻断：
    `current_blocks_core_test_action_unavailable.log`、
    `current_secinitd_startup_block_sample.txt`、
    `current_secinitd_appstore_entitlements_startup_block.log`、
    `current_secinitd_display_sharing_consent_block.txt`、
    `current_debug_install_artifact_audit.log`、
    `current_debug_install_finished_launching_failure.log`、
    `current_debug_install_process_sample.txt`、
    `current_debug_install_secinitd_sample.txt`
- 安装版截图：[`evidence/screenshots/`](evidence/screenshots/)
  - 当前 Helper：
    `selection-helper-zh-Hans-ready-20260728.jpeg`
  - 当前翻译设置：
    `translation-settings-helper-ready-20260728.jpeg`
- 旧 AX 快照：[`evidence/ax/`](evidence/ax/)
- 运行时与导出证据：`evidence/runtime/`、`evidence/exports/`

现有以 `flat-sidebar` 命名的截图与 AX 快照只描述上一版扁平侧栏，不能作为当前
AppKit 分组 Source List 的验收证据。

## 2026-07-28 面板固定居中、设置跳转与免配置源

- 翻译面板不再根据选区返回二次移动，也不再恢复手动翻译的历史位置。手动、划词、
  截图和剪贴板入口都先冻结触发屏幕，再在该屏幕 `visibleFrame` 中央设置首帧并
  关闭系统首次显示动画；Helper、兼容取词和 OCR 的迟到结果只更新内容。
- 面板“设置”使用明确的翻译路由请求。请求先更新 `.translationSettings` 和导航
  generation，再打开或激活主窗口并同步 Source List，最后关闭未钉住翻译面板，
  以覆盖主窗口已打开、已关闭和尚未创建三种状态。
- 空选区、焦点元素无文字或没有可用文字时不再显示“未读取到选中文字”横幅；面板
  展开空输入区并聚焦。Helper、辅助功能、版本、目标退出等可恢复故障继续显示明确
  原因。兼容取词和截图翻译入口收进原文区的安静操作菜单。
- 新增 `.communityWeb` 类型和三个生产可用免配置源：MyMemory、Google 网页翻译、
  腾讯翻译君网页源。三者使用 HTTPS 域名白名单、有限超时和响应、取消、禁止 Cookie
  与重定向的网络边界；默认关闭，首次启用逐项确认风险。
- DeepL 网页源已实现请求与解析测试，但 2026-07-28 连续六次双向低敏请求中出现
  1 次 HTTP 429，因此不进入生产可用列表。该事实不能被写成“DeepL 免费源已交付”。
- 本轮定向 142 项（1 条真实 Helper 宿主条件用例跳过、0 失败）、P14-G、
  Screenshot Core 220/220、Release、Analyze 和当前签名 Debug 安装均通过。
  安装版设置已确认三个社区源默认关闭；项目状态继续保持
  `implementation-in-progress`，真实硬件 Option+D 的面板帧序列和面板内设置跳转
  仍待人工复核，不提前写成全部实机通过。

## 2026-07-29 翻译运行链路与通知收口

- 通知从翻译面板内容层迁到独立非激活 HUD 子窗口；上方 8pt、下方回退，移动和
  缩放时跟随，但不改变面板 frame、原文高度、滚动位置或第一响应者。
- 原文区永久展开；删除折叠入口、折叠摘要和面板内“划词操作”恢复菜单。空选区
  静默聚焦手动输入，真实 Helper/权限/版本/连接故障仅由 HUD 说明。
- 翻译/通知定向 189 项通过（1 项条件跳过），P5-Q、Screenshot Core、Debug、
  Release、Analyze 通过。其余 AppTests 769 项通过；完整 805 项中的 30 项失败均为
  Clipboard Broker 在测试宿主继承沙箱时的 `_libsecinit_appsandbox` 环境失败，
  已保留原始和隔离复跑证据，未越界修改 Broker 安全边界。
- 合并到 `main` 后重新安装的最新签名 Debug App PID `37295`，CDHash
  `3378bd6e8f44748d9803cb9dc2312fe20ba27ed0`。Google、MyMemory、腾讯三个社区源
  安装版低敏连接测试均成功；外部 App 硬件 Option+D/Option+S 仍因当前桌面控制
  通道不能产生系统全局快捷键而明确待验。

## 2026-07-29 翻译方向、输入、结果操作与排序收口

- 会话在调用任何翻译源前生成唯一 `TranslationResolvedDirection`；极短文本不再
  盲信低置信统计识别，所有适配器使用相同方向。未配置或未验证的服务不进入运行
  队列。
- 真实安装版验收发现并修复 AppKit 输入只更新界面、不更新 Model 的生命周期缺陷。
  输入 `hello` 后，Apple 本地、腾讯网页源、MyMemory 均返回“你好”。
- 结果卡操作区固定为五个槽位；失败重试和连接详情都在右上角，单源重试不影响其他
  结果。服务名区域支持鼠标拖动，操作按钮不会启动拖动。
- 安装版真实鼠标首→尾、尾→首、关闭重开持久化均通过；验收后已通过界面恢复用户
  原顺序。截图证据为
  `evidence/screenshots/translation-result-reliability-installed-20260729.jpeg`。
- 翻译定向 161 项执行、1 项真实 Helper 宿主条件用例跳过、0 失败；
  Screenshot Core 220/220。完整签名 AppTests 原始 820 项、4 项跳过、31 项失败：
  30 项属于已确认的 Clipboard Broker 测试宿主沙箱启动问题，另 1 项为非前台
  XCTest 宿主无法让 `.nonactivatingPanel` 成为 Key Window 的 AppKit 焦点断言。
  排除这些明确的宿主环境用例后其余 783 项、4 项跳过、0 失败，不能将原始套件
  描述为全部通过。
- 功能提交 `bee48e2780a6` 已合并到 `main`；旧 Debug App 已移出安装目录并重新
  构建安装。当前 PID `70711`，CDHash
  `df60ae2473616d329c0fe2f98036607f64e4bcd3`，主二进制 SHA-256
  `d2c7f08cd3c1062092ec4a500cffab987e135bceed463a6cc21c83d9ffbfc871`。

## 2026-07-30 面板、自定义翻译源与 CLI 当前口径

本节覆盖此前有关“无约束标题拖动视图”“SwiftUI Drop 状态”“OCR 置信度百分比”
和 Manifest v2 是最新插件协议的阶段性描述。

- 翻译面板标题栏使用固定 50pt 几何；窗口高度变化只分配给结果区。窗口移动命中只
  覆盖标题及其空白区域，结果卡标题区的排序拖动不再被窗口移动抢占。
- 结果卡使用全局 `.micro` 密度：28pt 命中区、22pt 左右可见底板、11.5–12pt 图标
  和 0–1pt 间距。失败状态的刷新操作同样保留 28pt 命中区。
- 设置页翻译源行已删除固定 420pt 尾列：宽屏采用标题、状态、尾部控件三列，窄屏把
  最多两行状态移到标题下方，设置和开关仍保持固定尾部位置。免费待开启源不显示网络
  测试图标。
- 排序的载荷、拖动源、投放目标和 2pt 插入线统一由 AppKit 生命周期管理；投放直接
  解码 Pasteboard 中的 `serviceID`，一次校验、一次更新并一次持久化完整顺序。运行
  中排序只重排结果快照，不取消或重启请求；设置页消费同一顺序。
- Apple Vision 的原始 observation confidence 继续保留于诊断，但不再在产品界面
  展示百分比或用统一阈值推导质量；原文标题只显示“已识别 N 行”。
- `.blocksplugin` Manifest v3 新增 `accepted_inputs`、受限上下文字段、显式源语言
  要求、动态状态和独立截图像素权限。v1/v2 按 text-only 兼容；输入能力、域名、
  Secret 或数据权限契约变化会撤销旧审批。
- 内置、官方、社区与插件源使用相同的 `TranslationSourceInvocation` 和
  `TranslationSourceEvent` 契约。插件只允许有界状态、诊断以及唯一成功/失败终态，
  不能注入 UI 或执行任意 Shell。
- 截图附件仅存在于当前会话；只有截图翻译入口、插件声明图片输入且用户明确批准图片
  外发时才提供。输入限制为 20MB、40MP；归一化目标为最长边 4096px、最大 2.5MB，
  必要时降至 2048px。
- 设置 UI 与 CLI 共用 `TranslationSourceManagementService`。CLI 支持脚手架、
  校验、检查、安装、配置、Secret stdin、连接测试、启停、原子排序、脱敏导出和删除；
  不直接访问 SQLite、Defaults 或 Keychain，也不开放本地命令作为翻译源。
- 插件包物化与验证、Action Broker 大载荷 JSON 解码均移出主线程。连接测试失败会
  返回失败终态及非零 CLI 退出码；插件被运行时禁用后同步移出已启用顺序，不再占用
  四个结果源名额。
- 项目状态继续保持 `implementation-in-progress`。自动化通过不替代当前安装版的
  真实鼠标排序、截图翻译和自定义源生命周期证据。
