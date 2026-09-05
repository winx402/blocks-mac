# Step 4C-4 Clipboard hardening Go/No-Go 测试质量评估

- 日期：2026-07-06
- 角色：测试/质量
- 范围：conditional Step 4C-4 Clipboard hardening 启动前 go/no-go 评估
- 结论：`changes-required-before-go`

## 结论

当前不建议直接启动 Step 4C-4 开发。4C-4 可以继续留在 Step 4C，但前提是先补齐开发前 gate：新增 `P11E`、迁移旧 P8/P9 当前事实源、明确完整 payload read model allowlist / denylist，并把最终验收矩阵写成阻断门禁。

如果主 agent 不安排这轮开发前 gate 修正，建议拆为 Step 4D，并写 handoff record。原因不是 4C-4 目标不合理，而是当前证据链尚不能证明敏感 Clipboard payload 读取边界可被自动化门禁稳定约束。

## 事实依据

- PRD 明确 4C-4 是 conditional：进入前必须做 go/no-go；若 P11E、payload allowlist / denylist、UX contract 或安全/质量门禁无法闭合，则拆 Step 4D。
- 最新 4C-3 stop/go 只允许进入 4C-4 go/no-go 评估，不代表 4C-4 已启动或已接受。
- 当前仓库未发现 `tools/verification/p11e_clipboard_hardening_checks.py`。
- 当前 `ClipboardStore.loadRepositoryState(limit:)` 会 `loadRecent` 后为 recent records 预加载 payload：`payloads = try loadPayloads(for: recentRecords, repository: repository)`。
- 当前 `ClipboardFloatingPanelView` 的底部卡片、列表行和 hover detail 都会向 View 传入 `appState.clipboardPayload(for: record.id)`。
- 当前 `ClipboardDirectContentPreview` 优先展示 `payload?.text ?? payload?.urlString`，不满足 PRD 对默认列表 metadata-first / redacted-first 的目标。
- `p8_clipboard_product_polish_checks.py` 仍读取旧 story / acceptance，并把 `story_and_acceptance_exist` 纳入 `ok`。
- `p8i_settings_clipboard_system_checks.py` 仍检查旧 `SettingsView.swift` 内的 route content 结构，不适合作为 Step 4C-3 后 Settings shell 当前事实源门禁。
- `p9b_clipboard_appstate_repository_integration_checks.py` 当前要求 `@Published var payloads`、`clipboardStore.loadRepositoryState` 和既有预加载结构；这与 4C-4 要收紧默认 payload read model 的方向存在冲突，必须重写为 hardening 后的新契约检查。

## P0 / P1 / P2

P0：未发现立即启动会造成不可逆破坏的证据。本轮未触发真实剪贴板读取、系统权限、provider call、Keychain 或真实 UI 操作。

P1：

- P1-1：缺少 `P11E` 阻断门禁。没有 P11E 时，无法证明默认列表、普通面板渲染、Settings summary、CLI 默认输出不读取完整 payload。
- P1-2：旧 P8/P9 脚本当前不能直接作为 4C-4 阻断门禁。至少 `p8_clipboard_product_polish_checks.py`、`p8i_settings_clipboard_system_checks.py`、`p9b_clipboard_appstate_repository_integration_checks.py` 需要迁移到当前 Step 4C PRD、4C-4 开发记录和当前代码事实源；旧 story/archive/acceptance 只能作为 `baseline_reference`，不得参与 `ok`。
- P1-3：当前产品代码默认 read model 与 4C-4 目标相反：列表/卡片/hover 已能拿到完整 payload，且 preview 优先使用正文。开发前必须把目标契约写清，否则验收容易把“UI 仍能显示内容”误判为 polish 通过。

P2：

- P2-1：`repositoryUnavailable`、empty、unavailable、filtered、redacted 四类状态需要最低实物证据；自动化可检查结构，但用户是否理解降级语义仍需低敏截图或录屏证据。
- P2-2：paste / copy / hover detail / translation preview 是 allowlist，但仍需用低敏 fixture 证明读取路径只记录 record id / action kind，不输出正文。
- P2-3：P9A repository smoke 可保留，但它验证 storage round trip，不证明 UI 默认 read model；验收时只能作为 storage regression，不可替代 P11E。

## 若留在 Step 4C，开发前必须补齐

1. 新增 `tools/verification/p11e_clipboard_hardening_checks.py`，且 fail closed。
2. P11E 最低检查清单：
   - 检查 P11E 文件自身进入阻断矩阵，输出 `ok`、`current_evidence`、`baseline_reference`、`read_model_allowlist`、`read_model_denylist`。
   - 检查默认列表、普通面板列表、Settings summary、CLI 默认输出没有调用完整 payload 读取。
   - 检查完整 payload 只允许 paste、copy、hover detail、translation preview 四类路径读取。
   - 检查新增读取路径必须同步更新 PRD 和 P11E allowlist，否则失败。
   - 检查 helper 生产写库、App Group、CLI 默认完整 payload 仍未开启。
   - 检查验证输出、开发记录、验收记录、audit、logs 不含剪贴板正文、payload text、图片 base64 或 OCR 文本。
   - 检查 `repositoryUnavailable` 有用户可见 degraded state，并能区分 empty / unavailable / filtered / redacted。
3. 改造旧门禁：
   - `p8_clipboard_product_polish_checks.py`：删除旧 story/archive/acceptance 对 `ok` 的阻断作用；改用 Step 4C PRD、4C-4 开发记录、当前 Clipboard UI / Settings shell 代码作为阻断事实源。
   - `p8i_settings_clipboard_system_checks.py`：从旧 `SettingsView.swift` route body 检查迁移到 `Features/Settings` shell/pane 当前结构。
   - `p9b_clipboard_appstate_repository_integration_checks.py`：从“payloads 预加载结构存在”改为“repository metadata load 与 explicit payload read 边界清楚”；不得继续要求默认 preload 完整 payload。
   - `p9a_clipboard_repository_storage_smoke.py`、`p9c_no_reset_fixtures_ui_checks.py`：可保留为相关 regression，但需要确认输出不包含 payload 正文或本地敏感路径。
4. 写 4C-4 开发记录模板要求：所有 read model 证据只能写 action kind、record id 类低敏标识、计数、allowlist / denylist 摘要，不写正文。

## 建议最终验收矩阵

若 4C-4 留在 Step 4C，最终验收至少串行运行并记录：

```bash
python3 tools/verification/p11e_clipboard_hardening_checks.py
python3 tools/verification/p8_clipboard_product_polish_checks.py
python3 tools/verification/p8i_settings_clipboard_system_checks.py
python3 tools/verification/p9a_clipboard_repository_storage_smoke.py
python3 tools/verification/p9b_clipboard_appstate_repository_integration_checks.py
python3 tools/verification/p9c_no_reset_fixtures_ui_checks.py
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme Blocks -configuration Debug -derivedDataPath DerivedData/Blocks build
xcodebuild -project apps/Blocks/Blocks.xcodeproj -scheme BlocksCLI -configuration Debug -derivedDataPath DerivedData/Blocks build
DerivedData/Blocks/Build/Products/Debug/blocks --help
git diff --check
```

实物证据最低要求：

- Clipboard 面板或 Settings 至少一个可见位置展示 storage degraded / repository unavailable。
- empty / unavailable / filtered / redacted 四类状态可区分。
- 默认列表 / 普通面板列表只展示 metadata / redacted preview / kind / source / timestamp / pin state 等低敏内容。
- paste / copy / hover detail / translation preview 的完整 payload 读取使用低敏 fixture，验收记录只写读取类别和 record id 类低敏标识。
- 明确未触发真实剪贴板读取、真实系统权限请求、provider call、Keychain、helper 生产写库、App Group、CLI 完整 payload 默认读取或图片/OCR 外发。

## 建议开发边界

- 只处理 Clipboard hardening：repository unavailable 产品化、redacted / metadata-first list、explicit payload read boundary、相关 verifier 和低敏证据。
- 不启动 helper 生产写库、App Group、CLI 完整 payload、真实外部 provider、真实 OCR、权限/TCC/signing 改造。
- 不把 Settings shell、ShortcutStore、ScreenshotStore 或 Provider/Translation runtime 再次扩大重构；若发现必须重构共享状态，停止并回到主 agent 做 Step 4D 拆分判断。

## Go/No-Go

当前为 `changes-required-before-go`：

- 可以留在 Step 4C，但必须先完成 P11E 和旧门禁迁移后再启动业务实现。
- 若这些 gate 修正不能在开发前闭合，建议 `split-to-step4d`。
- 主 agent 不应在当前状态下写 `go-for-4c4-development`。
