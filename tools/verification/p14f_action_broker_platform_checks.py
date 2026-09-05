#!/usr/bin/env python3
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
CORE = ROOT / "apps/Blocks/BlocksCore/ActionBrokerXPC.swift"
BROKER = ROOT / "apps/Blocks/BlocksActionBroker/main.swift"
HOST = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Integration/ScreenshotActionHost.swift"
MANAGER = ROOT / "apps/Blocks/BlocksApp/Features/Screenshot/Integration/ActionBrokerServiceManager.swift"
CLI = ROOT / "apps/Blocks/BlocksCLI/main.swift"
PLIST = ROOT / "apps/Blocks/BlocksApp/Resources/app.blocks.action-broker.plist"
ENTITLEMENTS = ROOT / "apps/Blocks/BlocksActionBroker/BlocksActionBroker.entitlements"
BUILD_SCRIPT = ROOT / "script/build_and_run.sh"


def require(path: Path, tokens: list[str], failures: list[dict]) -> None:
    if not path.exists():
        failures.append({"code": "missing_file", "path": str(path.relative_to(ROOT))})
        return
    source = path.read_text()
    missing = [token for token in tokens if token not in source]
    if missing:
        failures.append({"code": "missing_contract", "path": str(path.relative_to(ROOT)), "detail": missing})


failures: list[dict] = []
require(CORE, ["BlocksActionBrokerHostXPCProtocol", "BlocksActionBrokerClientXPCProtocol", "BlocksActionHostXPCProtocol", "func cancel(", "NSXPCListenerEndpoint", "FileHandle?"], failures)
require(BROKER, [
    "NSXPCListener(machServiceName:",
    "waitForHost",
    "liveHostConnection",
    "kill(registeredHost.processID, 0)",
    "hostProcessID",
    "openApplication",
    "embeddedMainAppURL",
    "CommandLine.arguments.first",
    "ReplyOnce",
    "proxy.cancel(",
    "SecCodeCheckValidity(",
    "kSecCSStrictValidate",
    "SecCodeCopySigningInformation",
    "effectiveUserIdentifier",
    "!own.teamID.isEmpty",
    "peer.teamID == own.teamID",
    'case "app.blocks.cli", "blocks":',
    "case appHost",
    "case client",
], failures)
require(HOST, ["NSXPCListener.anonymous", "BlocksActionBrokerHostXPCProtocol", "registerHost(listener.endpoint)", "activeRequestID", "cancelCurrentAction", "task.cancel()", "waitForTask", "executeAction", "ActionBrokerTerminalResponse", "actionID: request.actionID"], failures)
require(MANAGER, ["SMAppService.agent", "service.register()", "service.unregister()", "requiresApproval"], failures)
require(MANAGER, [
    "ActionBrokerEmbeddedServiceValidator",
    "embeddedServiceAvailable",
    "case .notFound:",
    ".disabled",
    ".unavailable",
], failures)
require(CLI, [
    "NSXPCConnection(machServiceName:",
    "BlocksActionBrokerClientXPCProtocol",
    "proxy.submit",
    "O_NOFOLLOW",
    "O_EXCL",
    "S_IRUSR | S_IWUSR",
    "FileHandle(fileDescriptor:",
    "broker_unavailable",
], failures)
require(BUILD_SCRIPT, [
    "CLI_BUILD_ARGS=(",
    "-scheme BlocksCLI",
    "CLI_BUILD_ARGS+=(",
    "CODE_SIGN_IDENTITY=\"$CODE_SIGN_IDENTITY_OVERRIDE\"",
    "DEVELOPMENT_TEAM=\"$DEVELOPMENT_TEAM_OVERRIDE\"",
    'xcodebuild "${CLI_BUILD_ARGS[@]}" build',
    'codesign --force --timestamp=none --sign "$CODE_SIGN_IDENTITY_OVERRIDE" "$CLI_BINARY"',
    "CLI_TEAM_IDENTIFIER=",
    "CLI TeamIdentifier mismatch",
], failures)

if ENTITLEMENTS.exists():
    with ENTITLEMENTS.open("rb") as handle:
        broker_entitlements = plistlib.load(handle)
    if broker_entitlements.get("com.apple.security.app-sandbox") is not True:
        failures.append({"code": "broker_sandbox_entitlement_missing"})
else:
    failures.append({"code": "missing_file", "path": str(ENTITLEMENTS.relative_to(ROOT))})

combined_xpc_source = "\n".join(
    path.read_text() for path in [CORE, BROKER, HOST, CLI] if path.exists()
)
if "BlocksActionBrokerXPCProtocol" in combined_xpc_source:
    failures.append({"code": "combined_host_client_protocol_remaining"})

broker_source = BROKER.read_text() if BROKER.exists() else ""
for debug_identity_bypass in [
    "proc_pidpath",
    "Applications/BlocksDev/Debug/",
    "Documents/Mac 工具集/DerivedData/",
    "Library/Developer/Xcode/DerivedData",
]:
    if debug_identity_bypass in broker_source:
        failures.append({
            "code": "debug_identity_bypass_remaining",
            "detail": debug_identity_bypass,
        })
if "ActionBrokerRequest<ScreenshotCaptureActionInput>" in broker_source:
    failures.append({"code": "broker_not_generic", "detail": "Broker failure routing decodes screenshot-specific payloads."})
for token in ["ActionBrokerRequest<JSONValue>", "ActionBrokerTerminalResponse<JSONValue>"]:
    if token not in broker_source:
        failures.append({"code": "generic_failure_contract_missing", "detail": token})

project = PROJECT.read_text() if PROJECT.exists() else ""
for token in [
    "BlocksActionBroker */ = {",
    "BlocksActionBroker in Copy Broker Executable",
    "CodeSignOnCopy",
    "app.blocks.action-broker.plist in Copy LaunchAgent",
    "ScreenshotActionHost.swift in Sources",
    "ActionBrokerServiceManager.swift in Sources",
    "CODE_SIGN_ENTITLEMENTS = BlocksActionBroker/BlocksActionBroker.entitlements;",
    "CREATE_INFOPLIST_SECTION_IN_BINARY = YES;",
    "GENERATE_INFOPLIST_FILE = YES;",
    "PRODUCT_BUNDLE_IDENTIFIER = app.blocks.action-broker;",
]:
    if token not in project:
        failures.append({"code": "project_membership_missing", "detail": token})

if PLIST.exists():
    with PLIST.open("rb") as handle:
        launch_agent = plistlib.load(handle)
    if launch_agent.get("BundleProgram") != "Contents/MacOS/BlocksActionBroker":
        failures.append({"code": "bundle_program_wrong"})
    if launch_agent.get("MachServices", {}).get("app.blocks.action-broker.xpc") is not True:
        failures.append({"code": "mach_service_missing"})
else:
    failures.append({"code": "missing_file", "path": str(PLIST.relative_to(ROOT))})

print(json.dumps({"gate": "P14-F", "status": "pass" if not failures else "fail", "failures": failures}, ensure_ascii=False, indent=2))
raise SystemExit(0 if not failures else 1)
