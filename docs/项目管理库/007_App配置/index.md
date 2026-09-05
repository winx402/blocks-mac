# 007_App配置

状态：implementation-complete-verified
最后审阅：2026-07-12
来源级别：project control

本项目只覆盖 Blocks macOS App 的图标接入和本地 Debug 开发签名配置。它不处理 Developer ID、notarization、App Store Connect、证书私钥、provisioning profile 或发布流水线。

## 当前交付

- `Blocks` target 使用 `AppIcon` 资产目录；资产来自已确认的彩屑版品牌图，经绿色键控外底去除和安全边距处理后生成 macOS 标准尺寸集。
- Debug target 读取 `apps/Blocks/Config/Signing.shared.xcconfig`，并可选包含 git-ignored 的 `Signing.local.xcconfig`。
- 本项目配置中的真实 Team ID 只允许存在于本机 `Signing.local.xcconfig`，不得新增或提交到仓库；示例文件只保留 `YOUR_TEAM_ID` 占位符。
- 既有环境变量覆盖仍由 `script/build_and_run.sh` 支持：`BLOCKS_CODE_SIGN_IDENTITY`、`BLOCKS_DEVELOPMENT_TEAM`、`BLOCKS_USE_STABLE_SIGNING`、`BLOCKS_REQUIRE_STABLE_SIGNING`。

## 验收边界

- 静态验收确认完整的 `AppIcon.appiconset`、Xcode target 引用和本机私有配置忽略规则。
- 构建验收使用稳定 Apple Development 签名，确认 bundle id 为 `app.blocks.app` 且 TeamIdentifier 非空。
- Finder、Dock、App Switcher、权限辅助面板和隐私设置中的系统 App 图标都应由同一构建产物提供；本项目不将开发签名包的 Gatekeeper `spctl` 拒绝视为失败。

## 当前文档

- [PRD：App 图标与本地开发签名](PRD-App图标与本地开发签名.md)

## 关联入口

- [项目管理库](../index.md)
- [Blocks 正式 macOS App](../../../apps/Blocks/README.md)
