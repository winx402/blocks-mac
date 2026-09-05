# Sandbox-First 划词 Helper 决策复审

日期：2026-07-28

状态：独立 Helper 架构已落地；正式下载、Developer ID 签名、公证和用户侧辅助功能
授权仍待外部分发条件与用户操作。

## 已确认事实

- 主 App 启用 App Sandbox。主进程即使显示“辅助功能已授权”，仍会被沙箱拒绝访问
  `com.apple.axserver`；权限授权和沙箱能力是两个不同边界。
- 给整个主 App 增加 axserver 临时 Mach 例外会扩大主进程权限，并增加 App Store
  审核风险。
- 剪贴板 Broker 是 App 内置、沙箱化的 I/O 隔离进程，用于把可能阻塞的 Pasteboard
  读取移出主进程；它不需要用户下载，也不具备 AX 能力。
- 划词读取需要跨进程 Accessibility，因此不能与剪贴板 Broker 合并，也不能复用职责
  更宽的 Action Broker。

## 当前唯一架构

- Direct 和 App Store 主 App 都只连接独立安装的
  `Blocks Selection Helper.app`，不再嵌入 Selection Agent。
- 主 App 不包含旧 LaunchAgent plist、Selection Agent 可执行文件或 Selection Agent
  Mach lookup entitlement。
- Helper 是独立 App，自己管理开机启动和辅助功能权限。主 App 设置页只展示下载、
  打开、配对、权限、重检、断开和版本状态。
- 下载按钮只打开构建配置
  `BLOCKS_SELECTION_HELPER_DOWNLOAD_URL`；App 不自动下载或安装 Helper。
- 没有 Helper 时，手动输入和截图翻译仍可独立使用；Option+D 失败后展开并聚焦空输入
  区。只有用户按 Bundle ID 明确允许的 App 才能在 AX 全部失败后进入兼容复制取词，
  不把旧剪贴板正文作为隐式翻译输入。

旧 `BlocksSelectionAgent`、SMAppService LaunchAgent 和 Mach XPC 运行入口已经删除，
不保留 Direct/App Store 双轨逻辑。

## 本机连接与安全边界

- Helper 仅监听 `127.0.0.1` 和 `::1` 的固定本机端口，不监听局域网地址。
- 初次配对由 Helper 显示六位码，双方使用 P-256 ECDH 派生共享密钥；配对证明使用
  HMAC-SHA256。
- 后续请求以 AES-GCM 加密认证，携带协议版本、request ID、过期时间和随机 nonce。
- Helper 保存已见 nonce，拒绝过期请求和重放；响应字符数和 wire 大小有明确上限。
- 共享密钥只存双方 Keychain；日志不记录选中文字、共享密钥或配对码。
- Helper 不访问网络、剪贴板、Blocks 数据库或用户文件；AX 请求只包含目标 PID、
  Bundle ID、request ID、触发时鼠标位置、截止时间、字符上限和 revision。
- Helper 返回选中文字、选区范围、屏幕位置、AX role/subrole、候选策略和深度或明确
  错误码。
- 快捷键触发后先冻结外部目标，再显示非阻塞翻译面板；迟到结果由 request ID 和输入
  revision 拒绝，不能覆盖用户已输入内容。

## 当前候选解析与兼容边界

- Helper 使用单一有界解析器，顺序为焦点元素父链、鼠标 AX hit-test 元素父链、当前
  窗口内的受限 Document/WebArea/PDF/Text 搜索；没有无界遍历。
- 所有候选复用同一个提取器，按 selected text、range/string-for-range、text
  marker/string-for-marker 尝试；安全输入框始终拒绝。
- AX 全部失败后的兼容取词由主 App 的显式 per-app 授权控制。剪贴板 Broker 负责
  后台快照、一次性复制、历史抑制和安全恢复；若用户或其他 App 在过程中修改了系统
  剪贴板，则放弃恢复，不覆盖新内容。
- Helper 查找优先正式 `/Applications`、稳定 Debug 安装，再考虑 DerivedData，避免
  多个同 Bundle ID 副本导致实例漂移。

## 当前产物与运行证据

- Xcode 工程存在独立 `BlocksSelectionHelper` App target；`Blocks` target 不依赖或
  Embed 该 target。
- 本轮签名 Debug Helper：
  - Identifier：`app.blocks.selection-helper`
  - Team：`LOCAL_TEAM_ID_REDACTED`
  - Hardened Runtime：启用
  - `codesign --verify --deep --strict`：通过
- 本机安装路径：
  `~/Applications/BlocksDev/Debug/Blocks Selection Helper.app`。
- 真实进程同时监听 `127.0.0.1:49317` 和 `[::1]:49317`。
- 真实 Helper AX 树显示“已配对”、辅助功能“已就绪”、开机启动和“本机连接已就绪”；
  Helper 已增加中英日 String Catalog，当前中文系统界面为中文。
- 主 App 的 Direct/App Store entitlements 均不再包含
  `app.blocks.selection-agent.xpc`。
- 构建脚本不再停止、注册或替换旧 Selection Agent；独立 Helper 有自己的安装和版本
  生命周期。

## 仍待外部条件

- 正式下载 URL 尚未提供；当前构建配置为空时，设置页明确显示下载不可用，不伪造
  跳转成功。
- 正式 Helper 的 Developer ID 签名、公证、官网下载和升级链路尚未具备。
- 当前本机已完成 Helper 配对和辅助功能授权；这只证明连接与权限就绪。桌面控制通道
  不能产生真实系统全局 Option+D，因此 TextEdit、Safari/Chrome、Electron/Codex、
  Preview PDF 的最后工作树真实选区矩阵仍必须人工验收。
- App Store 展示外部 Helper 下载入口仍有审核风险；提交前需要单独做审核材料和产品
  降级复核。

以上待验证项未关闭前，只能确认“代码架构与本机未授权运行边界已落地”，不能宣称
外部分发和真实划词全部完成。
