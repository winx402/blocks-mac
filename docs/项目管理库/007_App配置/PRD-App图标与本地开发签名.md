# PRD：App 图标与本地开发签名

状态：approved-and-implemented
最后审阅：2026-07-12

## 目标

为 `app.blocks.app` 建立可被 macOS 系统面板识别的正式 App 图标，并让本机 Debug 构建可以使用 Apple Development 证书签名，同时不把账号或凭据写进仓库。

## 已确认输入

- 图标主源为 `docs/产品知识库/brand-assets/blocks-ai-avatar-confetti.png`，保留彩屑活泼版。
- 图标加工去除外部洋红底，保留积木主体、彩屑、阴影和品牌主色，并给圆角主体保留安全边距。
- 本轮仅覆盖本地 Debug 开发签名；外部分发、Developer ID、notarization 与 App Store Connect 必须由后续独立项目处理。

## 交付与接口

| 项目 | 交付 |
| --- | --- |
| 图标资源 | `apps/Blocks/BlocksApp/Resources/Assets.xcassets/AppIcon.appiconset/`，含 16、32、128、256、512 px 及各自 2x 位图 |
| Xcode 接入 | `Blocks` target 的 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，并将资产目录放入 Resources build phase |
| 共享签名默认值 | `apps/Blocks/Config/Signing.shared.xcconfig`，默认 ad-hoc，可选加载本机覆盖 |
| 本机私有签名 | `apps/Blocks/Config/Signing.local.xcconfig`，git-ignore；只存本机 Team ID 与 Apple Development identity |
| 可提交示例 | `apps/Blocks/Config/Signing.local.example.xcconfig`，只含占位符 |

## 行为

- App bundle 编译资产目录并生成 `AppIcon.icns`；Dock、Finder、App Switcher、`NSWorkspace.shared.icon(forFile:)` 等系统请求使用该 bundle 图标。
- Debug build 的共享配置先使用 ad-hoc 兜底；存在本机覆盖时改用 Apple Development 和对应 Team ID。
- `build_and_run.sh` 的命令行覆盖优先级保持不变，因此现有 CI 或本机命令可以继续使用环境变量指定签名信息。

## 安全与非目标

- 本项目不得新增或提交真实 Team ID、账号邮箱、证书、私钥、profile、`.pem`、`.key`、Apple 登录信息或任何 secret。
- 不改 Bundle ID `app.blocks.app`、sandbox entitlement、Release signing、Developer ID、notarization 或发布流程。

## 验收标准

- `AppIcon.appiconset/Contents.json` 列出完整 macOS 十个尺寸槽位，所有 PNG 尺寸匹配且具有 alpha 通道；16/32/64 px 预览仍可辨识，透明边缘没有洋红残留。
- Xcode 资源编译成功，构建后的 `Blocks.app/Contents/Resources/AppIcon.icns` 存在，且 `Info.plist` 与 bundle id 仍有效。
- `Signing.local.xcconfig` 被 git 忽略，本项目新增或修改的已追踪文件中不包含真实 Team ID 或签名凭据。
- `BLOCKS_REQUIRE_STABLE_SIGNING=1 BLOCKS_USE_STABLE_SIGNING=1 ./script/build_and_run.sh --verify` 成功；`codesign` 显示 identifier `app.blocks.app` 和非空 TeamIdentifier。
- 在已安装的 Debug App 中检查系统图标，以及权限辅助和隐私设置中通过 `NSWorkspace` 读取的图标。
