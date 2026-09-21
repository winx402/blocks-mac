# CLI 服务启动失败（#59）排查记录

## 已确认的事实

- 报告环境为 macOS27、自签且无Team ID的固定证书；本次检查机器为macOS26.6.2，现有安装使用Apple签发的Developer ID。两者不能视为等价验收环境。
- 报告中的`c[5]p[1]m[1]e[0]`表示LWCR启动约束作用于目标程序自身、匹配未通过；它不等价于“缺少某项entitlement”。[Apple DTS说明](https://developer.apple.com/forums/thread/795022)
- `a240bbd`未修改签名参数或重签实现；`095fe60`未改LocalDevelopment的空entitlement和Broker entitlement，且早于报告称成功运行的beta7。因此不能将它们直接认定为签名回归根因。
- 本机安装的主App和Broker签名校验通过，只证明本机产物身份有效，不能证明报告环境接受SMAppService启动约束。
- 当前`ScreenshotActionHost.start`的初次注册等待没有显式截止时间；安全移除路径需要先完成对Broker的认证与排空。因此系统拒绝启动时，存在“已注册、无法连接、无法完成安全注销”的恢复缺口。

## 不采用的修复

- 不猜测新增entitlement、不伪造Team ID、不自动更换用户的固定证书。
- 不将单次无PID、XPC超时或连接失败当成“所有写操作都已结束”的证明。
- 不增加无条件`launchctl bootout`或强杀Broker的自动降级路径。

## 已确认的实现方向

用户已确认：仅源码版改用主App托管CLI通道，移除其对SMAppService独立Broker启动的依赖；保留现有同用户、代码签名、安装清单/CDHash、模块授权与逐次确认。正式沙盒发行版保持现有边界。

- `LocalActionTransport` 仅编译进 LocalDevelopment，使用用户私有 Unix socket，双向校验内核 audit token 与当前构建身份。
- CLI 只启动已登记的固定安装；动作只投递一次，超时后不重放。输出文件通过描述符传递，不让 App 根据 CLI 提供的路径打开文件。
- App 复用既有 `ScreenshotActionHostService`，不绕过模块权限、逐次确认、请求取消和更新排空。总开关只控制 App 内入口，保留模块选择。
- 源码版停用和升级不等待新的独立 Broker；正式版仍使用原 XPC/SMAppService。

## 迁移与验收边界

新通道不使用旧 LaunchAgent，也不会悄悄终止它。旧注册仍存在时显示提示并阻止安装替换；可连接的旧版通过原认证排空协议升级。旧 Broker 因系统拒绝启动而不可达时，安装器仍安全失败，需保留日志、旧包和匹配的 peers.json，单独确认一次性恢复，不能以超时或无 PID 推断可强杀。

固定 socket 路径受 macOS Unix socket 长度限制；非常长的用户主目录路径会明确失败，不自动改用未经登记的路径。

本机 macOS26 的测试不能替代 macOS27 自签报告原环境复验；#59 在该原环境验证前保留未验证边界。

## 本机验证（2026-09-22）

- LocalDevelopment 主 App/CLI/Helper 编译通过；原位固定证书安装通过。未更换证书、重置权限或改动用户数据。
- DebugTesting 首轮 827 项定向测试通过；追加忙碌任务保护后，26 项生命周期测试全部通过，无跳过。真实服务挂起请求在拒绝停用后继续完成，未被取消。
- 独立传输测试覆盖 36MiB 帧、输出描述符、超时/断连后句柄生命周期、并发上限、路径替换与正式编译排除。实际 ad-hoc 签名进程通过 audit-token 双向认证，拒绝错误角色、未登记路径和身份；仅测试源码副本使用隔离主目录，生产信任实现未变。
- 固定安装的真实 CLI 返回 `integration_disabled`，同时 launchd 无 Action Broker 注册，证明响应来自主 App 新通道。启用模块后的真实业务写入/导出尚需用户临时授权，不计为已完成。
- 旧 beta11 的自动升级准备仍失败；正常退出旧 App/Helper 后安装成功，不宣称旧版准备故障已修复。
