# 积木工具阶段性公开发布

状态：mutable-worktree-evidence-current / immutable-release-candidate-blocked / external-distribution-blocked
最后更新：2026-09-06
负责人：项目负责人

## 当前工作（2026-09-06）

双击自动粘贴已改为不依赖 Helper 的 App/窗口路由并更新安装版（PID 82454）；保留沙盒，Helper 仅提供可选只读增强。TextEdit、Safari、Chrome 各 20 次真实插入通过，同窗口换输入框、固定面板换目标、多行和窗口变化保护也有证据。最后增量定向 28/28、Helper 35/35；较早本轮完整回归 1875 项中 1859 pass / 16 skip / 0 fail。Codex 因自动化安全限制仍待用户受控确认，不能标记全链路验收完成。详见[双击自动粘贴修复与验收](双击自动粘贴修复-2026-09-06.md)。

用户新增目标为修复顶部截图超时提示无法关闭及布局占位，核对遗留验收并开始准备发布。关闭控件被整窗鼠标穿透屏蔽的问题已修复；去掉固定高度，保留现有样式。通知/外观定向 113/113，产品修复后的完整 1865 total / 1849 pass / 16 skip / 0 fail。开发签名主 App 已更新到稳定路径，PID 33038；旧实例退出，独立 Helper 未动。空白附件已拒绝，随后通过 CUA 观察生产通知组件实图并实际点击关闭，确认卡片消失；临时观察代码撤下后永久回归 108/108。候选变更精确盘点共 322 项，已区分 App、私有文档、排除图和网站，未暂存/提交/上传。详细证据、安装状态与剩余模块见[发布准备状态](发布准备状态-2026-09-06.md)。当前完成修复、盘点及发布准备，仍未冻结或放行公开发布；下方保留前次来源记录。

## 前次完整验收快照（2026-09-05）

- 当前执行约束：用户已确认低敏文稿进入截图编辑器，并明确要求跳过后续人工验收。后续不再请求用户按键、框选或进行其他人工验收操作；这些项目标记为“用户要求跳过 / 未验证”，不计为通过。继续自主可完成的代码审查、自动化测试和修复；既有发布门槛与未解决缺陷不因此自动关闭。
- 最新产品修复：剪贴板搜索先截取 5000 条候选再筛选，会漏掉更旧的匹配记录；5002 条合成记录的对照用例已确认该问题。现每批最多 256 条候选，筛选后才计入结果限制，继续到填满或耗尽；FTS/LIKE 与错误传播保持可验证边界。定向 5/5、完整 1864 项中 1848 pass / 16 skip / 0 fail。没有 UI/布局变化，安装版与 Helper 未替换。
- P006-E 已移除退休详情编辑器路径依赖，将四项旧检查映射到当前模块；随后随实际搜索修复强化为“先筛选再限制结果”，9 个反例自测通过。P8-M/P9-B 同步适配且通过，源码检查不替代运行验收；OCR 关闭后立即重启的重叠边界仍未验证。
- P9-B 的五项旧架构检查已映射到当前清理/删除转发、写入凭据与近期记录、异步自动粘贴、Store 管线和显式详情读取；9 条源码契约与 9 个自测通过（含逐项移除关键调用等反例）。本轮未改产品代码、未重跑无关完整测试；相关运行行为沿用已核实的最新完整回归证据，不把源码检查当作新的运行验收。
- 焦点与结构修复：记录列表焦点缓存的失败重试/所有者隔离问题已由 5 个新增回归覆盖；随后将 Store 绑定、取色类型、采集持久化按职责分离，AppModel 1470 行、ClipboardFeatureCoordinator 609 行，原 P8-M 非增长基线不变且检查通过。P8-N 的旧接口匹配也已修正并通过反例检查；无 UI/布局/动画改动，安装版未替换。
- 滚动截图捕获协调器职责拆分已完成：544 行主文件、405 行调度扩展、260 行终态扩展，49 个方法迁移前后代码一致（除必要可见性调整）。P16-B 专项 63 项：61 pass / 2 默认资源 skip / 0 fail；两项资源随后单独 2/2 通过。P16-C 与 12 项检查脚本自测通过。当前安装版未因拆分重新安装，旧安装版的人工观察与最新源码自动化证据分别记录。
- 仍是可变工作树验收，尚未形成冻结发布候选，所有渠道不放行。下方 8 月记录按历史事实保留，其中“当前”仅指各记录当时，不代表本节日期。
- 最新正常全量为 `blocks-search-batches-full-20260905.xcresult`：1864 total / 1848 pass / 16 skip / 0 fail，覆盖焦点缓存、职责拆分与搜索筛选修复，指定诊断扫描未命中。逐用例对比上一轮仅新增两个搜索回归，没有删除用例。较早 `blocks-full-after-scrolling-split-20260905-1788605180.xcresult` 曾有 1 组 CA/NSCGS 告警，该历史告警仍未定位；本轮安静日志不是根因修复证明。独立核心和大图资源专项保持各自范围，不改写全量 skip。
- 告警取栈尝试未成功附加/暂停独立测试宿主；诊断运行有 1 个 Broker 测试被 SIGKILL，随后不附加调试器单独重跑该项 1/1 通过。诊断干扰与产品故障原因尚不能等同，未改系统调试授权，也未用延时/全局事务刷新掩盖告警。窗口问题保持“已复现、原因未定”。
- 后续测试内诊断：两组各 40 轮重入场景均通过且未复现告警；按原日志精确执行的 782 项前序（781 pass / 1 skip）也未复现。窗口通知探针确实工作，但没有取得含提交符号的栈；仅能说明这些诊断范围未复现，不能关闭原告警。临时测试代码已撤下，哈希恢复原值，重新构建及原始单项 1/1 通过；安装版/Helper 未动。
- 公网 TLS 本次为 0 pass / 1 skip / 0 fail；独立 curl 在相同数字 IP、TLS 主机名和证书校验条件下也握手超时。当前没有 TLS 成功证据，不能由退出码 0 推断通过。
- Helper 发布版本/build/release name 一致性已完成静态、夹具和 unsigned 产物核验；真实签名与配对握手仍未完成。系统冷态 OCR、外部 App/实体快捷键、VoiceOver、多屏、干净机/系统版本矩阵、正式分发与冻结来源仍是未关闭的验收项。
- 本地安装入口的失败恢复修复已由 18 个隔离用例覆盖；用户已批准的 App ID、单台开发设备及 Development profile 配置均已完成。签名文件校验并导入后，主 App/CLI 真实开发签名构建、稳定路径替换与启动验证均 exit 0；旧包备份保留。
- 当前主 App PID 63359，安装包与构建产物主可执行文件 SHA-256 一致，签名严格校验通过，包内 profile 与下载文件逐字节一致。权限页显示屏幕录制/辅助功能/输入监控已授权；快捷键注册为主要 4、快速粘贴 9、失败 0，原有 Option 全局修饰键与剪贴板 Shift + Command + V 自定义保留。此处只证明注册和当前显示，不证明实体按键/外部 App 焦点链路。
- 独立 Helper 仍为原 8 月 10 日安装包、PID 1463、哈希未变；权限页显示已安装但尚未配对。当前源码的新 Helper 签名与配对验收仍缺；没有借更新主 App 改写这项边界。详细签名配置和启动证据见验收记录末尾。
- 当前安装版已实际完成菜单启动截图→选择层→Escape 取消→再次启动/取消两轮；原窗口恢复。CLI 捕获因未启用集成而明确返回 `broker_unavailable/explicit_enable_required`，未擅自启用。自动化 Option+A 在合成 TextEdit 文稿中仅输入字符，不能据此判定实体快捷键通过或失败；已恢复测试文本，真实键盘/外部 App 捕获仍待验证。
- 随后用户确认实体 Option+A 已出现截图选择层，当前快捷键页也新增截图项“已真实触发”标记，支持该次真实入口触发通过。此后只读检查时选择层已不在前台；文稿捕获→编辑器→输出及其他快捷键/外部 App 矩阵仍未完成，不将单次触发扩写为全链路通过。
- 详细结果、资源指标及证据边界见[门禁与验收记录：2026-09-05 滚动截图资源、截图核心与公网 TLS](门禁与验收记录.md#2026-09-05-滚动截图资源截图核心与公网-tls)。没有预先定义并核实的加权验收分母，不能把测试通过率当作整体目标完成百分比。

## 目标与顺序

本项目按“官网直下 Beta 先行、TestFlight 随后开放、Mac App Store 最后正式上架”推进。首发范围为免费、Apple Silicon、macOS 14+，中英日同步。源码不公开，公开入口只提供二进制、校验值、发布说明和必要的开源许可。

放量顺序保持为：Direct Beta 1 低调公开 → Beta 2 手动升级验证 → 7 天 P0/P1 门禁 → TestFlight 外部测试 → Beta 3 Sparkle 验证 → 14 天 P0/P1 门禁 → Mac App Store 正式提交。

## 历史快照：2026-08-15 已完成的本地基础

- 建立编译期 `development`、`direct-beta`、`app-store-beta` 渠道，能力边界不依赖运行时隐藏。
- Direct Beta 明确为 arm64、macOS 14、Hardened Runtime，并提供构建、逐层签名、DMG、SHA-256、公证与 Gatekeeper 检查脚本。
- AppStoreBeta 构建会从产物移除 CLI、ActionBroker 和 LaunchAgent；Selection Helper 及外部插件入口在编译期关闭。
- Store 版 entitlement 收敛到 App Sandbox、用户选择文件读写和网络客户端；ClipboardBroker 与内置 PluginRunner 保留。
- 增加本地脱敏诊断 JSON 导出，不自动上传；设置页提供 Direct Beta 手动更新入口和渠道能力差异说明。
- 建立 24 页中英日纯静态官网草案，覆盖产品、版本、已知问题、隐私、条款、支持、安全和渠道差异；当前 `noindex`、无下载、无表单、无遥测、无客户端脚本或 Worker。
- 建立静态门禁、产物审计和敏感诊断字段自动化测试。
- 当前全量 `/tmp/blocks-full-current-20260815-r30.xcresult` 结果 Passed：1,660 项执行、1,644 通过、16 跳过、0 失败，约 05:12–05:16。它已纳入 Scrolling HUD “恢复检查中”禁用 Restart 的显示／处理一致性修复及其确定性回归；对应定向 `/tmp/blocks-scrolling-hud-targeted-20260815-r1.xcresult` 为 6／6。导出的 `/tmp/blocks-full-current-20260815-r30-diagnostics/` 对 NSCGS／CA transaction、SwiftUI view-update／`onChange`、AttributeGraph、Main Thread Checker／Sanitizer、data race、fatal error／`EXC_BAD_ACCESS`、测试取消／失败等关键词合并扫描为 0。默认跳过中的 12 个 Selection Helper receiver／response loopback 已由 `/tmp/blocks-p14h-current-20260815-r6.xcresult` 12／12 覆盖；两项 58.5MP 资源画像由 `/tmp/blocks-scrolling-resource-current-20260815-r4.xcresult` 2／2 覆盖。独立 `BlocksScreenshotCoreTests` 仍由 `/tmp/blocks-screenshot-core-current-20260815-r1.xcresult` 证明 221／221，Helper suite 由 `/tmp/blocks-helper-full-current-20260815-r4.xcresult` 证明 30／30；各自相关源码均早于结果。仍无成功证据的只剩公网 TLS opt-in 1 和已签名／配对安装 Helper 握手 1，不能写成全覆盖。
- Provider 当前静态门禁 `/tmp/blocks-p5d-current-20260815-r1.json`（P5-D `ok=true`，五段 chain 与 mutations true）和 `/tmp/blocks-p5f-current-20260815-r4.json`（P5-F `ok=true`、P5E `regression=true`，并覆盖连接测试与翻译外传的配置、Keychain worker、准入、撤权复核和最终发布边界及结构 mutation）均为 `--skip-build` 静态门禁；编译／运行证据来自 r30 全量，不是 P5-F 自己构建。P14-F `/tmp/blocks-p14f-current-20260815-r7.json` 与当前重新生成的 P19-A `/tmp/blocks-p19a-current-20260815-r4.json` 为 PASS；P19-A 明确 runtime percentiles／soak budgets 仍需要 Release 运行证据。P20 `/tmp/blocks-p20-current-20260815-r7.log` 02:15 exit 0，`PASS: release distribution static checks`，其脚本和签名审计输入均早于该结果；它仍只是 hermetic/static 契约，不证明真实签名、公证、DMG、Gatekeeper、Archive/upload。
- 公网 TLS opt-in 已在新建的当前测试宿主中实际发起一次固定 `one.one.one.one`／`1.1.1.1:443` 的无凭据 GET；连接持续至 10 秒请求 deadline 后由当前网络环境 reset，测试按设计记为 environment skip，而不是通过或产品失败。结果包 `/tmp/blocks-public-tls-current-20260815-r2.xcresult` 为 1 项执行、1 跳过、0 失败；因此该外部出口证据仍缺，不能从全量跳过列表删除。
- 本轮新增的三个生命周期／辅助功能证据已在同一当前测试产物上串行通过：Scrolling HUD 公告调度 4／4（`/tmp/blocks-scrolling-hud-announcement-1786722379-r4.xcresult`）、Permission Assist 真实动效 completion 2／2（`/tmp/blocks-permission-assist-real-motion-1786722413-r4.xcresult`）、ScreenshotStore 单帧超时后立即重试 1／1（`/tmp/blocks-screenshot-timeout-retry-1786722434-r4.xcresult`）；三份 diagnostics 未发现 NSCGS／CA transaction 关键词。发布审计同时把 `BlocksPluginRunner.xpc` 容器纳入独立 Team／Authority／leaf SHA-1 钉扎，Direct／Store P20 fixture 已覆盖容器三类错配并通过；这仍不等于真实签名产物。
- r30 后未再发生源码／测试／门禁脚本变更；当前主 App 又完成一轮 Debug Analyze，命令退出 0，`/tmp/blocks-analyze-current-20260815-r2.log` 因 `-quiet` 为空。正式脚本复用既有 DerivedData，重新生成并审计 Direct Beta、App Store Beta 与 Selection Helper 的 unsigned Release 结构产物；日志分别为 `/tmp/blocks-direct-current-20260815-r5.log`、`/tmp/blocks-store-current-20260815-r2.log`、`/tmp/blocks-helper-release-current-20260815-r2.log`，均有 `BUILD SUCCEEDED` 与对应 audit PASS，架构 arm64、最低 macOS 14，Bundle ID 分别为 `app.blocks.app`／`app.blocks.selection-helper`。这些步骤未启动用户安装版，但 Xcode 会注册临时 bundle 到 LaunchServices；工作树仍未冻结，unsigned／Analyze 结果不证明真实证书、签名 entitlement 层、公证、DMG、Gatekeeper、profile、Archive 或上传。
- 较早的 Debug App 曾在本机以 Apple Development 身份完成安装与基础验收；其二进制早于当前源码，不能再称为当前候选，也不能代替 Developer ID 公证、Gatekeeper 或 Store Archive 验收。历史 PID、CDHash、Team 与路径仅保留在内部门禁记录中，冻结公开材料前还需按发布手册决定统一脱敏或内部留存。
- 剪贴板清理的破坏性事务、详情异步读取、单击/双击互斥、物理写入后的 recency／失效副作用分离、辅助功能重试、复制任务生命周期、插件安装风险披露、钉图 OCR 编辑/复制/重试等本轮修复已进入自动化回归。钉图 OCR 在 UI 关闭后仍可完成显式 copy，同时 controller ownership 会释放；较早完整套件已在累积 AppKit 状态下验证该释放，最新增量仍须纳入最终全量。
- Permission Assist 的 8 秒 fallback 仍保持可见、90 秒终止、重入清理与 generation 保护，以及静态门禁 mutation 均已有修复与 `AppAppearanceTests` 72/72 通过证据。
- 截图会话已占用时的重复菜单／快捷键请求不再静默：新版显示去重的“截图正在进行”非激活提示，且不重复启动捕获；自动化与最新安装版均已验证。

详细边界见[渠道能力矩阵](渠道能力矩阵.md)，操作入口见[发布操作手册](发布操作手册.md)，本轮证据见[门禁与验收记录](门禁与验收记录.md)，当前工作树范围见[候选冻结清单](候选冻结清单.md)，每个候选包须按[上线前检查清单](上线前检查清单.md)逐项留存证据。

品牌、域名、公开 URL 与 Bundle ID 的冻结结果见[外部身份锁定](外部身份锁定.md)。

## 历史快照：2026-08-15 外部阻断项

品牌、域名、公开 URL 与 Bundle ID 已锁定；以下项目完成前，不得生成对外分发包、部署 Pages/R2、创建 App Store 记录或上传 Archive：

1. 将当前大量已修改和未跟踪文件收敛为经过复核的干净提交，并从该提交重新执行构建、测试和产物审计；当前工作树不是不可变发布候选。
2. `app.blocks.app` Explicit App ID 和对应 Mac App Store provisioning profile。
3. `Blocks for Mac` 的 App Store Connect 名称可用性和 App 记录。
4. 支持、隐私和安全邮箱的真实收发验证。
5. App Store 类别、年龄分级、隐私标签、出口合规、审核说明和截图素材。
6. 使用真实 Developer ID / Apple Distribution 身份完成分层签名产物、DMG、公证、Gatekeeper、Store Archive 和上传验证。
7. 在不依赖 Computer Use 的真实全局输入链路中完成 Control + Option + D / Control + Option + V / Control + Option + A 与外部 App 焦点验收；若候选安装版存在用户自定义或禁用，以“设置 > 快捷键”显示的当前绑定为准。
8. 在 macOS 14、15、26 的干净安装矩阵完成渠道分别验证。项目历史上不存在独立 `BlocksCoreTests`；测试治理已明确以完整 `BlocksAppTests` 中直接导入 `BlocksCore` 的契约测试，加独立 `BlocksScreenshotCoreTests` 作为当前替代门禁，但两套都必须从冻结提交重新执行，且不宣称覆盖 Core 全部 public API。
9. 当前 P18 `/tmp/blocks-p18-current-20260815-r5.json` status=fail，唯一 failure 为 `performance.cold:light-2x-mixed:13958.5ms`（精确 cold `13958.522708ms`）；warmP95 `102.145209ms`、CER 0、3／3，4K `240.571375ms` 24／24，tall `647.742875ms` 72／72。新增低敏分段证据显示首次 service 总时长 `13958.424416ms`，其中 Apple Vision `perform` 为 `13934.679417ms`（约 99.83%）；请求配置 `18.4085ms`，handler 构造 `4.952375ms`，queue wait `0.111208ms`，request 构造 `0.015541ms`，mapping `0.025584ms`。这是慢点位于同步 Vision `perform` 的事实，不是系统模型加载根因证明；硬门槛仍失败，绝不能写成放行，也不能靠降语言、降质量、放宽阈值或把预热冒充冷态修复。
10. 文档更新前只读复核工作树为 214 个 tracked 修改、22 个 untracked 入口（展开为 64 个文件），staged 0、conflicts 0；HEAD `d8982e398db4ecd90a20c4790224eab33051ac03`，`git diff --check` 通过。当前树不是冻结候选；真实签名、公证、DMG、Gatekeeper／App Store Archive、干净机安装、外部 App 物理快捷键、VoiceOver、多屏最终证据均缺，Direct Beta、TestFlight、Mac App Store 不放行。
11. `03-clipboard-bottom.jpeg`、`04-clipboard-left.jpeg`、`05-clipboard-right.jpeg` 含内部 Codex／额度重置文字，不得原样进入对外材料；应在冻结前重截为纯合成内容，或排除该证据目录。`site/public/product/settings.jpeg` 与 `translation.jpeg` 已逐张目视及元数据复核，未见凭据、个人信息、内部 Codex／额度文字或来源／定位元数据，可进入候选；`clipboard.jpeg` 同样未见敏感信息，但画面仍是 `Synthetic clipboard/performance record` 压测文案并在右缘截断卡片，只能视为安全的内部占位素材，公开前应以脱敏且真实的产品示例重截。真实外部 App、物理全局快捷键、VoiceOver、真实多屏和签名 Helper 也仍未由当前源码候选验收。
12. 历史 XCTest 同一宿主曾在窗口压力→后续 Clipboard 组合出现 NSCGS／CA commit 警告；当前 r30 全量与本节定向 diagnostics 扫描均为 0，但仍没有可归因到生产代码的首发调用栈。冻结候选安装版仍需完成相同窗口生命周期压力并证明不复现；不得把单次安静日志、延时或全局 transaction flush 冒充根因修复。

2026-08-08 本机已配置一张有效的 Developer ID Application 和一张有效的 Apple Distribution，均包含本机私钥；创建过程中产生的重复 Distribution 已在 Apple 后台撤销并按证书指纹从钥匙串删除。Apple Developer 后台当前仍无 App ID 和 provisioning profile；`app.blocks.app` 只完成了未提交的可用性校验，因此仍不得生成对外分发包。

## 明确未实施

- 未建站、未绑定域名、未创建 R2 桶或公开下载 URL。
- 未创建 App Store Connect 记录，未上传 TestFlight/Mac App Store 产物。
- 未生成签名 DMG，未提交 Apple 公证，未创建 Notary 凭据、App ID 或 provisioning profile；发布证书私钥仅保存在本机钥匙串，未写入仓库。
- 未接入 Sparkle、支付、订阅、许可证或遥测。
- 未把源码推送到公开或私有远程；仓库仍没有远程配置。
- 未把 unsigned 结构构建或本机 Debug 安装版当作可公开分发候选包。

这些项目不是遗漏，而是由阶段 0 外部身份门禁和用户计划中的授权边界主动阻止。

## 2026-08-15 r48 当前可变工作树证据更新

- 当前 incremental `BlocksAppTests` Debug build-for-testing 在 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO` 下 exit 0；`/private/tmp/blocks-latest-critical-targeted-1786784400.xcresult` 为 28/28 pass、0 skip/fail，覆盖最新 Provider、Official profile、Screenshot committed-truth、Shortcut fixture。
- ShortcutController 新增 DEBUG-only no-Carbon fixture backend，生产默认仍为 system；fixture register/unregister/route/epoch 走完且 system counter=0。targeted diagnostics 仅两条主动模拟 event-delivered，handler-install/hotkey-register/hotkey-unregister=0；无 UI／布局／交互改动。
- P14-H `/private/tmp/blocks-p14h-current-1786784600.xcresult` 经 gate `verify_xcresult` 精确 12/12、0 skip/fail；scrolling resource `/private/tmp/blocks-scrolling-resource-current-1786784800.xcresult` 为 2/2，详见门禁记录。全量 `/private/tmp/blocks-full-current-1786785000.xcresult` 为 1761/1745/16/0，16 skip 语义未改写。
- 本轮直接命令 P5-F --skip-build、P14-F、P14-H --self-test、P18 --self-test、P19-A、`verification_build_helpers_self_test`、P20 均 exit 0；P20 输出 `PASS: release distribution static checks`。这些命令未重定向持久结果路径；P18 仅 evaluator 自检，不是完整 OCR gate。
- 当前工作树为 216 tracked modified + 22 collapsed untracked entries（展开 64 files），collapsed total 238，staged 0/conflicts 0，HEAD `d8982e398db4ecd90a20c4790224eab33051ac03`，`git diff --check` 通过，仍未冻结。r46 P18 cold 14286.1ms 硬失败及所有真实签名/profile/notary/DMG/staple/Gatekeeper/Archive/upload、clean install、external App/physical shortcut、VoiceOver、multiscreen、public TLS success、signed Helper handshake 缺口继续保留，全渠道不放行。

## 2026-08-15 r36 当前工作树证据更新

- 最新全量结果 `/private/tmp/blocks-full-current-20260815-r36.xcresult` 为 1,707 项执行、1,691 通过、16 跳过、0 失败，finish epoch 为 `1786755045.848`。导出 diagnostics `/private/tmp/blocks-full-current-20260815-r36-diagnostics` 对 CA、NSCGS、CoreAnimation、crash、fatal、assertion 的精确扫描为 0。该结果仍只说明当前可变工作树的 XCTest 宿主回归；不替代安装版、外部 App 或可访问性验收。
- 专用 Selection Helper loopback `/private/tmp/blocks-p14h-current-20260815-r7.xcresult` 为 12／12、0 skip、0 fail；门禁清理了 2 个 `ibtoold`，当前无残留。静态 P5-D `/tmp/blocks-p5d-current-20260815-r2.json`、P5-F `/tmp/blocks-p5f-current-20260815-r5.json`、P19-A `/tmp/blocks-p19a-current-20260815-r5.json` 均为 PASS；P19-A 仍不代替 Release runtime percentile 或 soak 证据。
- 当前会话直接运行的 P18 gate exit 1，唯一 failure 为 `performance.cold:light-2x-mixed:13855.7ms`，严格门槛为 `<8000ms`。质量、warm 约 `102.9ms`、tall 约 `666.0ms`／72 行、4K 约 `274.1ms`／24 行均通过。分段显示 primary `perform` 约 `13849.7ms`、queue 约 `0.111ms`、request config 约 `5.228ms`；事实只支持瓶颈位于外部 Vision `perform`，不表示问题已解决，也未生成独立 P18 输出路径。
- r36 后对 `apps/Blocks`、`tools/verification`、`script/release` 的非生成文件复核未发现晚于结果的源码变更。当前工作树为 215 个 tracked/index entries 加 22 个 untracked entries，staged 0、conflicts 0，仍未冻结。P18、真实签名／公证／DMG／Gatekeeper／App Store Archive／upload，以及安装版外部 App、物理快捷键、VoiceOver、多屏验收均未关闭；Direct Beta、TestFlight 与 Mac App Store 不放行。P20 的静态／unsigned 证据不构成真实签名证据。

## 2026-08-15 r37 当前工作树证据更新

- `/private/tmp/blocks-full-current-20260815-r37.xcresult` result Passed：1,708 项执行、1,692 通过、16 跳过、0 失败，执行约 09:13–09:17。`apps/Blocks`、`tools/verification`、`script/release` 的非生成源均未晚于结果 finish；`xcodebuild`／test host 已退出，用户安装 App PID 45481 与 Broker PID 45490 未触碰。
- r37 diagnostics 出现 1 个真实 NSCGS／CA commit 告警簇（日志镜像重复不另计簇），发生于纯 pagination 测试。HUD 前缀 r1 4／4 和完整 `ScreenshotAppStateTests` r1 605／605 均未出现同类告警或 crash；证据不足以归因，保留为间歇性待定位项，不能写成 diagnostics 为 0。
- P5-D `/private/tmp/blocks-p5d-current-20260815-r3.json` 与 P5-F `/private/tmp/blocks-p5f-current-20260815-r6.json` 均以 `--skip-build` exit 0。P18 `/private/tmp/blocks-p18-current-20260815-r3.json` exit 1，唯一 failure 为 cold `light-2x-mixed:13519.4ms`，严格门槛 `<8000ms`；质量、warm、tall、4K 通过，慢段仍位于外部 Vision `perform`，不放行。
- P20 r7 与 P19 r5 仍晚于各自脚本并有效，但仅为静态／治理证据，绝非正式签名或安装证据。官网 npm lint/test exit 0，24 个静态多语言页与 5／5 Node rendered tests 通过；in-app Browser 两次未能 attach，故无视觉／交互浏览器验收。冻结提交、正式签名／profile／notary／DMG／Gatekeeper／Archive／upload、安装版外部 App／物理快捷键／VoiceOver／多屏仍缺，所有渠道继续不放行。

### r37 补充覆盖与工作树盘点

- `/private/tmp/blocks-scrolling-resource-current-20260815-r5.xcresult` 在当前已编译产物上为 2／2、0 skip、0 fail，diagnostics 对同类 NSCGS／CA 精确扫描为 0、crash 为 0。因此 r37 的 16 项 skip 中，12 项 Helper receiver 已由 P14-H r7 覆盖，2 项 58.5MP resource 已由 r5 覆盖；仍无成功证据的是公网 pinned TLS 1 项与已签名／配对 Helper handshake 1 项。专用 PASS 不会把 r37 原有 skip 改写为 pass，也不替代冻结候选重跑。
- `/private/tmp/blocks-p14f-current-20260815-r8.json` 与 `/private/tmp/blocks-p19a-current-20260815-r6.json` 均为 PASS；P19 仍不替代 Release runtime 或 soak 证据。
- 候选冻结清单已按当前精确盘点刷新：展开 279 = 215 tracked + 64 untracked，互斥 A236／B22／C3／D18；折叠 porcelain 仍为 237 = 215 + 22，staged 0、conflicts 0。工作树仍未冻结。
- 公网 pinned TLS 已在当前已编译测试产物实际重跑：`/private/tmp/blocks-public-tls-current-20260815-r3.xcresult` 为 1 项执行、0 pass、1 skip、0 fail；约 10.04 秒后明确 `Public TLS fixture is unreachable in the current environment`，日志显示 `1.1.1.1:443` 路径 satisfied 但 flow failed。它只证明 opt-in 及有界环境失败路径可达，仍无 TLS 成功证据；diagnostics 无 NSCGS／CA／crash。故没有成功证据的仍仅为该项与已签名／配对 Helper handshake。

## 2026-08-15 r38 当前工作树自动化更新

- `/private/tmp/blocks-full-current-20260815-r38.xcresult` 使用与 r37 相同的 09:09 已编译二进制，以 `test-without-building` 执行，result Passed：1,708 项执行、1,692 通过、16 跳过、0 失败，约 09:41–09:45。diagnostics `/private/tmp/blocks-full-current-20260815-r38-diagnostics` 对 NSCGS、CA、CoreAnimation、fatal、assertion 及 crash 文件扫描为 0；`apps/Blocks`、`tools/verification`、`script/release` 无非生成源晚于 finish，`xcodebuild`／test host 已退出，用户 PID 45481／45490 未被触碰。
- r36 clean、r37 有 1 个真实告警簇、r38 clean：同一当前工作树下症状为间歇性且本轮未复现，不证明根因已修复。冻结候选仍须完成窗口压力与调用栈验收；不得将 CA 问题写成已关闭。

## 2026-08-15 r39 当前可变工作树证据更新

- 事实：`/private/tmp/blocks-full-current-20260815-r39.xcresult` result Passed，1,710 total／1,694 pass／16 skip／0 fail，约 10:31–10:35。diagnostics `/private/tmp/blocks-full-current-20260815-r39-diagnostics-v1` 共 4 文件；对 NSCGS、CA commit、Entangling/API handler、SwiftUI view-update、AttributeGraph、Main Thread Checker、Sanitizer/data race、fatal/`EXC_BAD_ACCESS`、取消/失败关键词扫描均为命中文件 0，且无本轮 Blocks crash report。
- 推断边界：r36、r38、r39 clean，而 r37 曾有 1 个真实 cluster；这只说明 r39 未复现相关症状，不能证明 CA 根因已修复。
- 事实：16 skip 仍由 12 项 Helper receiver/response、2 项 58.5MP resource、1 项公网 TLS、1 项签名配对 Helper handshake 组成。专用 `/private/tmp/blocks-p14h-current-20260815-r7.xcresult` 为 12/12 pass，当前 `P14-H --self-test` 输出 `/private/tmp/blocks-p14h-selftest-current-20260815-r6.json` 为 pass；`/private/tmp/blocks-scrolling-resource-current-20260815-r9.xcresult` 为 2/2 pass。这些专用结果不能改写全量原 skip。公网 `/private/tmp/blocks-public-tls-current-20260815-r4.xcresult` 为 0 pass/1 skip/0 fail，`1.1.1.1:443` 约 10 秒不可达，只证明有界失败路径，不是成功；签名配对 Helper 仍无当前成功证据。
- 静态门禁事实：`/private/tmp/blocks-p5d-current-20260815-r2.json` `ok=true`；`/private/tmp/blocks-p5f-current-20260815-r6.json` `ok=true`、P5E `regression=true`；`/private/tmp/blocks-p14f-current-20260815-r8.json` pass；`/private/tmp/blocks-p19a-current-20260815-r6.json` `ok=true`、`status=pass`；`/private/tmp/blocks-p20-current-20260815-r8.log` 为 `PASS: release distribution static checks`。它们均只证明各自声明范围。
- 事实与阻断：P18 `/private/tmp/blocks-p18-current-20260815-r4.json` `status=fail`，唯一 failure `performance.cold:light-2x-mixed:13748.6ms`；outer `13748.605833ms`、service `13748.4985ms`、Vision `perform` `13742.42ms`、warmP95 `95.8775ms`、tall `636.010375ms`（72/72）、4K `261.657333ms`（24/24）。事实仅表明慢段位于 `perform`，不能称根因或修复；严格 `<8000ms` 继续阻断。
- freshness 与未验证：r39 后唯一相关非生成变更为 `tools/verification/p5f_provider_connection_gate_checks.py`（10:39:52），晚于 r39；因此 r39 证明当前 App/测试源码，但不能称完整工作树全量。P5F r6 在该脚本后单独通过。工作树当前 215 tracked modified + 22 collapsed untracked entry，staged 0、conflicts 0，未冻结。正式签名/profile/notary/DMG/staple/Gatekeeper/Store Archive/upload、干净机安装升级、外部 App 物理快捷键、VoiceOver、多屏仍缺；P18、TLS、签名 Helper handshake 也未关闭，所有渠道不放行。

## 2026-08-15 r42 当前证据摘要

- 当前会话直接执行的 incremental build-for-testing 在新增插件修复后 exit 0；首次构建曾因新增测试的 3 处 `await` 位于 `XCTAssert` autoclosure 而 exit 65，修复后重新构建 exit 0。本轮没有持久日志路径，不伪造路径。
- `/private/tmp/blocks-plugin-destructive-current-20260815-r5.xcresult` 为 4／4 pass，覆盖 record update、tag delete、schedule enable，以及新增 tag detach／rename／favorite；background／scheduled fail closed，且 `explicitUser` 持久化。`/private/tmp/blocks-provider-official-current-20260815-r1.xcresult` 为 16／16，`/private/tmp/blocks-screenshot-sink-current-20260815-r2.xcresult` 为 3／3。
- `/private/tmp/blocks-full-current-20260815-r42.xcresult` 为 total 1716／pass 1700／skip 16／fail 0；diagnostics `/private/tmp/blocks-full-current-20260815-r42-diagnostics` 对 NSCGS、CA、View-update、AttributeGraph、TSan、MainThread、EXC、fatal 扫描 0，未发现新的 crash report。16 skip 语义仍为 12 项 Helper loopback、2 项资源、1 项公网 TLS、1 项签名配对 Helper；专用既有 P14H 12／12 与资源 2／2 不改写全量 skip。
- `/private/tmp/blocks-ca-window-stress-current-20260815-r2.xcresult` 覆盖 5 个不同测试、每项 10 轮，共 50 test runs、0 fail；同类 diagnostics 警告为 0。
- 静态门禁：P5F r7 ok、P14F r9 pass、P19A r7 pass、P20 r9 PASS；仅声明各自范围，不替代真实签名或运行时证据。
- P18 `/private/tmp/blocks-p18-current-20260815-r5.json` status `fail`，唯一 failure 为 cold `13937.174375ms`（显示 `13937.2`）；service total `13937.061041`、Vision `perform` `13931.629708`、queue `0.108458`、request config `4.737375`、warmP95 `97.65`、CER 0、3／3 行，tall `646.689375`／72，4K `248.540375`／24。严格阈值为 `<8000`，不能推断具体系统根因。默认 P18 cold 只是 corpus 进程首调用；系统级 cold 仍需受控干净启动证据，process-first seam 不能混称系统 cold。
- 当前状态：工作树 215 tracked modified + 22 collapsed untracked，staged 0、conflicts 0，HEAD `d8982e…`，未冻结。只读身份盘点为 Developer ID Application 1、Apple Distribution 1、Apple Development 1、Developer ID Installer 0；名称／SHA 不显示。`ReleaseIdentity.local` 不存在，`Signing.local` 存在但内容未读；release selection、profile、notary 未锁定；今天未发现 dmg、pkg 或 xcarchive。
- 正式签名／公证／DMG／Gatekeeper／Archive／upload、干净机、外部 App 物理快捷键、VoiceOver、多屏、公网 TLS 成功、签名配对 Helper 仍缺；全渠道不放行。本节仅记录当前可变工作树事实与缺口，不称冻结候选。

## 2026-08-15 r43 插件边界终审与当前全量

- host action 逐项终审继续关闭两处同源缺口：`clipboard.record.bring_to_front` 现在要求用户发起，后台／定时来源不能持久化 `lastCopiedAt` 或重排历史；`system.open_plugin_page` 也在 section、navigation、opener 与激活副作用前要求用户发起。后台 Smart Tagger 的 `tag.ensure`／`attach`／`ensure_and_attach` 保持原有允许范围，没有改 UI、布局或交互。
- 当前会话在这两处修改后重新完成 incremental build-for-testing，exit 0；定向 `/private/tmp/blocks-plugin-destructive-current-20260815-r6.xcresult` 为 6／6 pass、0 skip／fail。随后 `/private/tmp/blocks-full-current-20260815-r43.xcresult` 为 total 1718／pass 1702／skip 16／fail 0；diagnostics `/private/tmp/blocks-full-current-20260815-r43-diagnostics` 对 NSCGS、CA、View-update、AttributeGraph、TSan、MainThread、`EXC_BAD_ACCESS`、fatal 扫描 0，且无新 crash report。结果后 `apps/Blocks`、`tools/verification`、`script/release` 没有非生成文件变更。
- r42 记录的 P18、静态门禁、签名身份与外部验收边界未被本轮改变：工作树仍为 215 tracked modified + 22 collapsed untracked，staged 0、conflicts 0、未冻结；P18 cold、正式签名／公证／DMG／Gatekeeper／Archive／upload、干净机、外部 App 物理快捷键、VoiceOver、多屏、公网 TLS 成功及签名配对 Helper 继续阻断，全渠道不放行。

## 2026-08-15 r46 当前可变工作树证据更新

- Provider cancelled alias migration recovery notice 不含 secret。`ProviderStore` 发布状态覆盖初始值、异步 startup recovery 与每次 user-secret gate；设置页已直接观察：valid 时复用既有 Credential section／`SettingsFeedbackSlot` 与既有 destructive confirmation，删除目标为 destination alias，保存保持禁用；malformed fail-closed。本轮没有大改布局。
- 复用 `apps/Blocks/build/DerivedData` 的 `xcodebuild … build-for-testing`，并设置 `CODE_SIGNING_ALLOWED=NO`／`CODE_SIGNING_REQUIRED=NO`，exit 0；无独立日志路径，不伪造。定向 `/private/tmp/blocks-provider-cancelled-alias-notice-current-20260815-r1.xcresult` 为 6／6 pass、0 skip／fail，覆盖启动恢复晚发布、destination 精确删除／清 notice、删除失败保留阻断、malformed notice、stale replacing alias、duplicate／destination conflict。
- 静态门禁：`/private/tmp/blocks-p5d-current-20260815-r4.json` `ok=true`；`/private/tmp/blocks-p5f-current-20260815-r8.json` `ok=true` 且 P5E `regression=true`，均为 `--skip-build`，只证明静态门禁。P20 `/private/tmp/blocks-p20-current-20260815-r10.log`、P14F r9、P19A r7 的较早当前证据也仍只按各自静态／治理范围，不扩写为运行或签名证据。
- 全量 `/private/tmp/blocks-full-current-20260815-r46.xcresult` result Passed：1,721 total／1,705 pass／16 skip／0 fail，start `1786771745.351`、finish `1786771985.168`，约 239.5 秒。16 skip 语义保持为 12 Helper loopback、2 项 58.5MP resource、1 项公网 TLS、1 项签名配对 Helper；既有专用通过不改写这些全量 skip 为本身通过。
- diagnostics `/private/tmp/blocks-full-current-20260815-r46-diagnostics` 共 4 文件；NSCGS、Invalid CA transaction、CA::Transaction、Entangling fence、API cannot add handler、SwiftUI view-update、AttributeGraph、Main Thread Checker、ThreadSanitizer/data race、`EXC_BAD_ACCESS`、Fatal error、`objc_release` 均为 0，时间窗无新 Blocks／xctest crash report。r37 的间歇 cluster 仍未获根因证明，不能称已修复。
- 全量 finish 后 `apps/Blocks`、`tools/verification`、`script/release` 无非生成文件变更；`xcodebuild`／`xctest` 已退出。用户安装 Blocks PID 45481、Broker PID 45490、Helper PID 55248 未触碰。
- P18 `/private/tmp/blocks-p18-current-20260815-r6.json` `status=fail`，唯一 failure cold `14286.1ms`；outer `14286.103167ms`、service `14286.01575ms`、Vision `perform` `14277.438ms`、warmP95 `98.303667ms`、CER 0／3 行、tall first `655.521375ms`／72 行（p95 `664.069292`）、4K `257.823833ms`／24 行。严格 `<8000ms` 仍阻断；证据仅定位慢段在 Vision `perform`，不声称根因或修复。
- 当前工作树为 215 tracked modified + 22 collapsed untracked entries，staged 0、conflicts 0、HEAD `d8982e398db4ecd90a20c4790224eab33051ac03`，未冻结。正式签名／profile／notary／DMG／staple／Gatekeeper／Archive／upload、干净机安装升级、外部 App 物理快捷键、VoiceOver、多屏、公网 TLS 成功、签名配对 Helper 仍缺；全渠道不放行。

## 2026-08-15 r62 当前可变工作树证据更新

本节仅追加当前可变工作树证据；不改写 r48 及更早历史，不构成冻结候选、签名分发或任何渠道放行。

- 当前 incremental unsigned Debug `BlocksAppTests` build-for-testing exit 0；本轮无持久 build 日志，故不伪造路径。定向 `/private/tmp/blocks-final-fixes-targeted-r61.xcresult` 为 3/3 pass，覆盖 destructive confirmation task 取消即时 dismiss 且迟到 callback 不污染下一次、旧 plugin execution generation 确认后拒绝、Screenshot output lease 后撤权/取消仍返回 committed file truth；无布局或文案改变。
- 全量 `/private/tmp/blocks-full-current-r62.xcresult` 为 total 1768/pass 1752/skip 16/fail 0，start `1786793338.752`、finish `1786793572.275`；diagnostics 为 0，相关非生成源无晚于 finish，`xcodebuild`/`xctest` 已退出，用户安装 PID 45481、Broker 45490、Helper 55248 未触碰。16 skip 仍精确为 12 Helper loopback、2 项 58.5MP resource、1 项 public TLS、1 项 signed paired Helper；P14H r58 经当前 gate verify 为 12/12、resource r59 为 2/2，均不改写全量 skip；public TLS 与 signed Helper 仍无成功证据。
- 静态持久证据：P5D r62 `ok=true`、P5F r62 `ok=true`/P5E regression=true、P14F r62 pass、P19A r62 pass（Release percentiles/soak 仍缺）、P20 r62 `PASS: release distribution static checks`；P14H/P18/build helper self-test 本轮也 exit 0，均只证明各自范围。
- P18 `/private/tmp/blocks-p18-current-r60.json` 当前脚本 exit 0/status pass：light process-first outer `299.169084ms`、warmP95 `94.620541ms`、CER 0、tall `635.995709ms`（72/72）、4K `241.953583ms`（24/24），measurementScope=`current-corpus-process-first-service-call`。本次运行时系统 Vision 已被先前调用加热，脚本/Corpus 也明确不作 system-cold claim；历史同日多次 system-cold/首次环境约 14.286s（>=8s）证据未被否定，安装/重启冷态门禁仍未关闭。
- 当前盘点为 217 tracked modified、22 collapsed untracked entries（expanded 64）、collapsed 239/expanded 281，staged 0/conflicts 0、HEAD `d8982e…`、`git diff --check` pass，未冻结。正式签名/profile/notary/DMG/staple/Gatekeeper/Archive/upload、干净机、外部 App 物理快捷键、VoiceOver、多屏、public TLS 成功、signed Helper handshake、system-cold OCR 均仍缺；全渠道不放行。
## 2026-08-15 r73 当前可变工作树证据

- r70 首次 build-for-testing exit65 的唯一明确新增集成错误为 `OpenAICompatibleConnectionService.swift:278 extra argument 'deadline' in call`；随后为 `BlocksNativePluginPinnedHTTPRequest` 增加含可选 deadline 的 initializer。r71 当前源码 build-for-testing 在 `CODE_SIGNING_ALLOWED/REQUIRED=NO` 下 exit0；无用户安装 App 启动。
- r72 targeted result Passed（20/20），覆盖 deadline、official loopback 上限、截图 admission revoke/admit/cancel、committed truth、official profile gate；diagnostics 指定扫描0、crash0。r73 full result Passed（1778/1762/16/0），diagnostics 指定扫描0、crash/ips0；16 skip 仍为 12 Helper loopback、2 resource、1 public TLS、1 signed Helper handshake，专用通过不改写全量 skip。
- P5F exit0/ok=true/P5E regression=true，P19A exit0/pass 但 Release percentiles/soak 仍缺，P14F exit0/pass。工作树未冻结（217 tracked、22 collapsed untracked、staged0、conflicts0）；P18 system-cold OCR 约14.286s仍>8s，正式签名与外部验收缺口继续保留，所有渠道不放行。当前数据卷约617MiB可用，存在继续构建/归档操作风险。

## 2026-08-16 r79 当前可变工作树证据

- unsigned Debug 增量 build-for-testing 最终 exit0；首次因 `ScreenshotStore.swift` defer 内非法 `guard ... else { return }` exit65，机械修正后构建成功。测试旧期望触发 assertion 并使 XCTest 进入 CoreSymbolication 卡顿，已精确终止本轮 test host/xcodebuild（未触碰用户 PID）；测试现期望 `plugins_disabled_by_safe_mode`。五份定向结果均 1/1 pass、0 skip/fail：`/private/tmp/blocks-plugin-confirmation-20260816-r79.xcresult`、`/private/tmp/blocks-plugin-capability-20260816-r79.xcresult`、`/private/tmp/blocks-tag-fallback-20260816-r79.xcresult`、`/private/tmp/blocks-screenshot-cancel-before-20260816-r79.xcresult`、`/private/tmp/blocks-screenshot-cancel-after-20260816-r79.xcresult`，覆盖 destructive confirmation lifecycle/requestID 一次性能力、tag fallback 锁序及截图 caller cancel 的 archive/output-file admission 窗口。
- full `/private/tmp/blocks-full-current-20260816-r79.xcresult` Passed（total1807/pass1791/skip16/fail0；start `1786814913.711`、finish `1786815161.169`）；16 skip 为 12 Helper receiver/response、2 58.5MP resource、1 public TLS、1 signed paired Helper。diagnostics `/private/tmp/blocks-full-current-20260816-r79-diagnostics` 4 文件，既定 NSCGS/CA/CoreAnimation/SwiftUI view-update/AttributeGraph/MainThread/TSan/ASan/data race/EXC/SIGSEGV/fatal/test-failed/hotkey 模式命中文件均为0；finish 后 apps/Blocks、tools/verification、script/release 无非生成源更新。P14-H `/private/tmp/blocks-p14h-current-20260816-r79.xcresult` 经门禁核验为 12/12 pass、0 skip/fail；构建阶段发现并受控清理 2 个 `ibtoold`，结果返回时无该目标残留。P5F --skip-build/P5E regression true、P14F、P11E、P13D、P19A、P20 均 exit0，P20 输出 `PASS: release distribution static checks`；P19A 不替代 Release percentiles/soak。
- Direct `DerivedData/DirectBeta/Blocks.app`、AppStore `DerivedData/AppStoreBeta/Blocks.app`、Helper `DerivedData/SelectionHelperBeta/Blocks Selection Helper.app` unsigned/no-launch 结构构建/audit 最终均 PASS；首次残留 ibtoold 的 Direct/AppStore 受控清理后增量重跑才计 PASS，Debug Analyze 同样清理后增量重跑干净 exit0，均不证明签名。P18 `--self-test` 与 corpus Swift parse pass 不是完整 Vision 运行；历史 system-cold 约14.286s>=8s 仍硬阻断。工作树 tracked modified221、collapsed untracked22、expanded untracked64、collapsed243/expanded285、staged0/conflicts0、HEAD `d8982e3`，diff-check pass，未冻结；用户安装 PID 45481/45490/55248 未触碰。真实 signing/profile/notary/DMG/staple/Gatekeeper/Archive/upload、clean install、external App/physical shortcut、VoiceOver、多屏、public TLS success、signed Helper handshake、system-cold OCR 仍缺，所有渠道不放行。
## 2026-08-16 r84 当前可变工作树证据

- BlobStore/sidecar 三个 P1 已修；无 UI、布局或交互改动。unsigned incremental build-for-testing 最终受控 exit0；首次/增量各曾因脱离 `ibtoold` 被监管器清理并返回70，清理后重跑才计 exit0，不将70记 PASS。定向 BlobStore 9/9、Clipboard repository 66/66；full 1816/1800/16/0，diagnostics 4 文件且指定扫描均0。
- 当前 P11E、P13D、P19A 均 exit0/pass（P19A 不替代 Release percentiles/soak）；工作树 tracked221、collapsed untracked22（expanded64），staged0/conflicts0，HEAD `d8982e3`，未冻结，用户 PID 45481/45490/55248 未触碰。全局签名、安装、外部 App、可访问性、多屏、public TLS、signed Helper、system-cold OCR 等缺口仍在，所有渠道不放行。

## 2026-08-16 r90 当前可变工作树证据

- 本轮修复 Clipboard sidecar/outbox：BlobStore retry ENOENT 仍同步 root directory；ClipboardRepository/DetailEdit 用 rollback tracker 在外层事务回滚后持久化新建 sidecar 至 outbox 并 best-effort drain；cleanup journal INSERT 失败时直接 durable delete，双失败明确 `sidecarCleanupPersistenceFailed`。无 UI、布局或交互改动。
- 目标 SHA-256：BlobStore `4d0f6c4c47d0ae5c1e8c286d7a42db88992000042b0874239a80d80b07f36d03`；ClipboardRepository `bf384ce3d1c8e3024a08f2741ca958d69dad6ecd43924dc6cc03c372995696a5`；DetailEdit `3f22713d110611db2f09e06a16129d084822558bdaee3739f1be749014d3395f`；tests `f1512c20dbcc1b21c944552a472b0a85b0200bfa53bafd0ff0e28e5f6dbe1de0`。
- standard 与 `-D DEBUG` Swift frontend parse、scoped/whole-tree diff-check 通过；首次 build direct child rc0 但残留 1 个 ibtoold，监管器清理并返回70，不计PASS；同配置增量重跑 `ok=true`/return0 才计PASS。
- 定向 sidecar rollback 8/8、ClipboardRepository 69/69；full r90 Passed 1819/1803/16/0，约250.5秒。16 skip 为12 Helper loopback、2 个58.5MP resource、1 public TLS、1 signed paired Helper；diagnostics 4文件且指定扫描0。P11E、P13D、P19-A 通过，P19-A 不替代 Release percentiles/soak。
- freshness：test 源 03:05:35、BlocksAppTests binary 03:06:08、xctestrun 03:06:20、full finish 03:12:43；结果后无相关非生成源改动。HEAD `d8982e398db4ecd90a20c4790224eab33051ac03`，tracked modified221、collapsed untracked22、staged0、conflicts0，未冻结。
- 数据卷约3.9GiB可用、98%；用户 PID 45481/45490/55248 存活且未触碰；无本轮构建残留。system-cold OCR约14.286s>=8s，签名/公证/安装/外部 App/VoiceOver/多屏/public TLS success/signed Helper handshake仍缺，所有渠道不放行。

## 2026-08-16 r108 当前可变工作树证据

- Tag CAS 终审修复 `clipboard.tag.ensure_and_attach` 在 nil `expectedRevision` 的并发首次创建：repository 单个 `BEGIN IMMEDIATE` 内完成 normalized-name `ON CONFLICT`、立即 `changes()` 判 `created`、幂等 membership 与 trigger 后实际 revision；显式 revision CAS 和普通 UI duplicate 语义不变。无 UI、布局或交互改动。最终 SHA-256：`ClipboardTagRepository` `ceed02ec24d288e730b4018331cef3cc3944ca2cebe7e2cc06da308ab0f584ae`；`ClipboardTagStore` `f923635a470dd65ce8e359bc32c90af317366b6a14c6de6952940ba4490b5ad6`；`ClipboardStore` `16d6454f3f8f69df8fc81dcea3bc82fd448c1801b774aece5dccfd1c3549cd36`；`AppModel` `d84dc1c3cf7283504a7c64df01003d86e940ba4212e2da3c7e3c6576aa196c66`；Tests `634972df5b21d41b0e4f9aee58f51784237e7b0fbf4e6023338bd8ce5fd9fd17`。
- standard + DEBUG parse、scoped/whole-tree diff-check 通过。首次 build 有 child0 但发现 1 个 exact-token `ibtoold` residual，清理后 return70 不计 PASS；同 DerivedData 增量重跑 clean return0 才计 PASS。
- 修复后 full `/private/tmp/blocks-full-current-20260816-r108.xcresult` Passed：1824 total／1808 pass／16 skip／0 fail；r104 基线 1823／1807／16／0 不替代最终。16 skip 仍为 12 helper loopback、2 resource、1 public TLS、1 signed paired Helper；专用通过不改写 full skip。
- P11E/P13B/P14F/P19A exit0/pass；P19A 不替代 Release percentiles/soak。system-cold OCR 约14.286s（>=8s）及正式签名、安装、外部 App、VoiceOver、多屏、public TLS、signed Helper 等缺口继续保留，所有渠道不放行。

## 2026-09-05 当前可变工作树证据

- HEAD `d8982e398db4ecd90a20c4790224eab33051ac03`；tracked 226、untracked 22、staged 0、conflicts 0，工作树未冻结。
- 本轮最终 SHA：P006F `f72276650a7117f09a68d467435f119f0f0403b02b5aa6eb40f49bcf8e4e2938`、P13D `0f579248afed266ba49271b9b8962aaa45ff8012a96c3bff11a794037ab9aebc`、Official adapter `c16d6860933c93875376ff39396ea1c7a40fc2fe7713ca9df89ca5abea879a1b`、TranslationStoreTests `f7019f941b6300e4579c7aaa538ca0a6178bd3f03d450ee865251c7248f7d24a`、Scrolling coordinator `bcf4c5d9fabab5ea05ec673adcf5d3f772bec2e90156151763cc0bbcc3bef921`。
- P006F/P13D 原失败是门禁漂移；P13D 加入 120/30 秒 timeout 与 `scenario_contract_version=2`，退休旧 fake-copy/replacement reveal。P5F/P14F/P19A/P20/build-helper、P7F/P7H/P7L/P11E 当前直接 exit 0；P19A 不替代 Release percentiles/soak。
- targeted 13/13、相关类 89/89、final redirect deny+allow 2/2、scrolling stop 2/2、ScreenshotAppStateTests 646/646。最终 full `/private/tmp/blocks-full-current-20260905-r2-1788583360.xcresult` 为 1845 total/1829 pass/16 skip/0 fail，diagnostics 0；无 Swift/project 文件晚于 finish。16 skip 为 12 Helper receiver、2 个 58.5MP resource、1 个 public TLS、1 个 signed paired Helper。P14H `/private/tmp/blocks-p14h-current-20260905-r1.xcresult` 为 13/13 pass，不改写 full skip。
- CA 前一 full 1844/1828/16/0 有 1 个 cluster；isolated 1、pair 2、prefix 25、Screenshot class 646 及 final full 均 0，未稳定复现，未宣称已修，不改 UI。P18 一次误传 `--help` 只证明 warm process-first 约 351ms，不能替代 system-cold；历史 system-cold 约 14.286s（>=8s）仍未关闭。
- 正式 signing/profile/notary/DMG/staple/Gatekeeper/Archive/upload、clean install、external App physical shortcuts、VoiceOver、多屏、public TLS、signed Helper 仍缺，全渠道不放行。

## 2026-09-05 快捷键与 Selection Helper 收口

- ShortcutController 最终 SHA-256 `fcda1ae06d1d51c18f49b1419b35a105fc3be5afc5719ae9b85c757fa15611e5`；ScreenshotAppStateTests `0fdc22435327be51e4c0ab8fc9adb49872121ded26df08e552ff13bcbd6a3f26`；TranslationEntryBridgeTests `60487f56f3987f3969b3ca819bb09faad384e2afc659a3f162d3fabe287d49b6`。
- 快捷键/Selection Helper 收口：Carbon unregister 失败 ref 由 instance pending 转入 deinit process orphan registry；下次注册先撤当前 controller route/action、按稳定序重试，handler failure 保留 `runtimeDisabled`。录制按物理 keyCode 表，覆盖 47 主键及 legacy keypad 0–9、`.`、`/`、`-`、`=`；空/未知 modifier 与非法/direct mismatch fail closed，保留旧 keypad 迁移；无 UI 布局变化。
- 定向最终 16/16：`/private/tmp/blocks-shortcut-final-r2-20260905-1788587836.xcresult`；ScreenshotAppStateTests 658/658：`/private/tmp/blocks-screenshot-appstate-shortcut-20260905-1788588055.xcresult`。P14H r3 13/13、diagnostics 0：`/private/tmp/blocks-p14h-current-20260905-r3.xcresult`；full r4 1857 total/1841 pass/16 skip/0 fail、diagnostics 0：`/private/tmp/blocks-full-current-20260905-r4-1788588976.xcresult`。
- P14H 首轮 12 pass/1 fail 为 JSONEncoder 原始字节键序差异却同 56 bytes，已改为 decode `SelectionHelperWirePacket` 语义比较；首次 build 清理 2 个 `ibtoold` 后重试。全渠道仍不放行：外部实体键盘、非拉丁布局、TextEdit/Safari/Preview/Electron、签名 Helper handshake，以及 release artifact 版本/build/release name 一致性 P2 仍待验证/决策。

## 2026-09-05 Helper 发布版本与 DMG 命名核验

- Helper 产物版本/build/release name 一致性 P2 已补齐：Direct profile 显式锁定 `0.1.0` / `1` / `0.1.0-beta.1`，Helper audit 比对三项字符串；默认构建流程在最终重签前执行该审计。运行时继续以已认证协议判断兼容，不新增营销版本下限。
- 主 App 与 Helper 的 DMG `--release-name` 必须匹配包内 `BLOCKS_RELEASE_NAME`；缺失、错误类型、旧版本名及尾随换行均在签名/制盘工具前失败。
- 完整 P20 exit 0：`/private/tmp/blocks-p20-helper-release-20260905.log`。实际 Helper unsigned Release 构建由受控 runner 干净 return 0；产物复审 PASS，见 `/private/tmp/blocks-helper-release-audit-20260905.log`。本轮未修改 App Swift 或 UI，未重跑无关全量 XCTest。
- 版本标签一致不证明二进制来自冻结源码，也不构成正式签名、公证、安装配对或外部 App 验收。其余发布阻断不变，全渠道不放行。
