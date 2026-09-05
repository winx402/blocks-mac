# Required Reason API 与隐私清单审计

状态：macos-scope-verified / store-privacy-review-pending
最后更新：2026-08-10

## 当前 Apple 口径

Apple 当前的 Required Reason API 要求适用于 iOS、iPadOS、tvOS、visionOS 和 watchOS。Blocks 当前是纯 macOS App，因此下列源码调用**不是当前 macOS Archive 必须填写 Required Reason reason code 的硬门禁**，也不能为了“看起来完整”猜测 reason code 并生成错误的 `PrivacyInfo.xcprivacy`。

参考：

- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Adding a privacy manifest to your app or third-party SDK](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)

## 已完成的源码与依赖核对

静态扫描确认项目会使用以下系统 API 类别：

- `UserDefaults` / `@AppStorage`：设置、迁移、快捷键、翻译、截图和插件状态。
- 文件时间戳与属性：插件、截图水印、长截图会话和输出协调器。
- `stat` / `fstat` / `lstat` / `fstatat`：剪贴板 Broker 和插件包校验。
- 系统运行时计时：自动粘贴、插件运行器和长截图支持。

当前 Xcode 工程未发现第三方 Swift Package、第三方 `.framework` 或 `.xcframework`；BlocksCore、BlocksScreenshotCore 和 JavaScriptCore 均为项目自身产物或系统 framework。因此暂不存在“列入 Apple 清单的第三方 SDK 必须自带 privacy manifest”的已确认缺口。

## 仍需完成的 Store 隐私工作

Required Reason API 不构成当前 macOS 硬门禁，不代表隐私审核已完成。上传前仍须：

1. 逐项核对 App Privacy 数据类型、用途、是否与用户身份关联、是否用于跟踪。
2. 将诊断导出、网络请求、插件外发、剪贴板、截图、OCR、翻译和用户选择文件的真实行为与隐私政策、审核说明保持一致。
3. 最终 Archive 再次扫描所有嵌套产物和新增依赖；若引入要求 privacy manifest 的第三方 SDK，必须验证其签名和 manifest。
4. 若 Apple 后续把相关要求扩展到 macOS，按当时官方文档重新审计并加入准确 manifest。
5. 不得把本记录写成 App Privacy、出口合规或商店审核已经通过。
