# Blocks Login Item Probe

状态：P2-J spike，仅用于验证 `sandbox-first` 下 `SMAppService` Login Item/helper 运行形态，不是正式 App 工程。

## Commands

```bash
./tools/spikes/blocks_login_item_probe/scripts/build.sh
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --status
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --approval-status
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --register
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --roundtrip --seconds 8
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --recorder-roundtrip --seconds 8
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --restart-policy-check
tools/spikes/blocks_login_item_probe/.build/BlocksLoginItemProbe.app/Contents/MacOS/BlocksLoginItemProbe blocks-login-helper --unregister
```

默认使用 ad-hoc signing。修改 helper 可执行文件后，先注销再重新注册，避免系统继续使用旧的后台项目约束。若本机有有效 Apple Development/local signing identity，可用：

```bash
CODESIGN_IDENTITY="Apple Development: Example" ./tools/spikes/blocks_login_item_probe/scripts/build.sh
```

不要提交 `.build/`、签名产物、本机登录项状态、日志或任何凭据。

P2-K 新增的 recorder roundtrip 会在命令内注册 helper、发送 start 通知、写入低敏剪贴板 fixture、等待 redacted event，然后注销清理。helper 默认心跳不读取剪贴板内容。
