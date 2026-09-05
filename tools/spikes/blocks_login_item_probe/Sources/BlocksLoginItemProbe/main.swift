import AppKit
import CryptoKit
import Foundation
import ServiceManagement

let probeName = "blocks.login_helper"
let helperBundleID = "app.blocks.spikes.loginitem.helper"
let heartbeatNotification = Notification.Name("app.blocks.spikes.loginitem.helper.heartbeat")
let stopNotification = Notification.Name("app.blocks.spikes.loginitem.helper.stop")
let recorderStartNotification = Notification.Name("app.blocks.spikes.loginitem.helper.recorder.start")
let recorderEventNotification = Notification.Name("app.blocks.spikes.loginitem.helper.recorder.event")
let controlNotification = Notification.Name("app.blocks.spikes.loginitem.helper.control")

typealias JSONObject = [String: Any]

func auditID() -> String {
    "probe_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8).lowercased())"
}

func emitResponse(
    ok: Bool,
    status: String,
    promptRequested: Bool = false,
    observations: JSONObject = [:],
    warnings: [String] = []
) {
    let response: JSONObject = [
        "ok": ok,
        "probe": probeName,
        "status": status,
        "prompt_requested": promptRequested,
        "observations": observations,
        "warnings": warnings,
        "audit_id": auditID()
    ]
    guard JSONSerialization.isValidJSONObject(response),
          let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        fputs("{\"ok\":false,\"probe\":\"\(probeName)\",\"status\":\"json_encode_failed\"}\n", stderr)
        Foundation.exit(1)
    }
    print(text)
}

func usage() {
    emitResponse(
        ok: false,
        status: "usage",
        observations: [
            "commands": [
                "blocks-login-helper --status",
                "blocks-login-helper --approval-status",
                "blocks-login-helper --register",
                "blocks-login-helper --roundtrip --seconds <n>",
                "blocks-login-helper --recorder-roundtrip --seconds <n>",
                "blocks-login-helper --restart-policy-check",
                "blocks-login-helper --unregister"
            ]
        ]
    )
}

@available(macOS 13.0, *)
func service() -> SMAppService {
    SMAppService.loginItem(identifier: helperBundleID)
}

@available(macOS 13.0, *)
func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered:
        return "not_registered"
    case .enabled:
        return "enabled"
    case .requiresApproval:
        return "requires_approval"
    case .notFound:
        return "not_found"
    @unknown default:
        return "unknown"
    }
}

@available(macOS 13.0, *)
func statusWarnings(_ status: String) -> [String] {
    switch status {
    case "requires_approval":
        return ["Approve BlocksLoginItemProbe in System Settings > General > Login Items, then rerun status or roundtrip."]
    case "not_found":
        return ["The helper bundle was not found. Rebuild the app and verify Contents/Library/LoginItems contains BlocksLoginItemHelper.app."]
    default:
        return []
    }
}

func errorSummary(_ error: Error) -> JSONObject {
    let nsError = error as NSError
    return [
        "error_domain": nsError.domain,
        "error_code": nsError.code,
        "error_description": String(nsError.localizedDescription.prefix(240))
    ]
}

func sha256Prefix(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
}

func postJSONNotification(name: Notification.Name, payload: JSONObject) {
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let text = data.flatMap { String(data: $0, encoding: .utf8) }
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: text,
        userInfo: nil,
        deliverImmediately: true
    )
}

@available(macOS 13.0, *)
func emitStatus() {
    let currentService = service()
    let currentStatus = statusName(currentService.status)
    emitResponse(
        ok: currentStatus != "unknown",
        status: currentStatus,
        promptRequested: currentStatus == "requires_approval",
        observations: [
            "app_bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "helper_bundle_id": helperBundleID,
            "service_status": currentStatus
        ],
        warnings: statusWarnings(currentStatus)
    )
}

@available(macOS 13.0, *)
func bestEffortStopAndUnregister() -> JSONObject {
    postJSONNotification(name: stopNotification, payload: ["source": probeName])
    let currentService = service()
    do {
        try currentService.unregister()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.4))
        return [
            "attempted": true,
            "error": false,
            "service_status_after": statusName(currentService.status)
        ]
    } catch {
        var summary = errorSummary(error)
        summary["attempted"] = true
        summary["error"] = true
        summary["service_status_after"] = statusName(currentService.status)
        return summary
    }
}

@available(macOS 13.0, *)
func registerHelper() {
    let currentService = service()
    do {
        try currentService.register()
    } catch {
        var observations = errorSummary(error)
        observations["helper_bundle_id"] = helperBundleID
        observations["service_status"] = statusName(currentService.status)
        emitResponse(ok: false, status: "error", observations: observations)
        return
    }

    let currentStatus = statusName(currentService.status)
    emitResponse(
        ok: currentStatus == "enabled",
        status: currentStatus,
        promptRequested: currentStatus == "requires_approval",
        observations: [
            "helper_bundle_id": helperBundleID,
            "service_status": currentStatus
        ],
        warnings: statusWarnings(currentStatus)
    )
}

@available(macOS 13.0, *)
func unregisterHelper() {
    DistributedNotificationCenter.default().postNotificationName(
        stopNotification,
        object: probeName,
        userInfo: nil,
        deliverImmediately: true
    )

    let currentService = service()
    do {
        try currentService.unregister()
    } catch {
        var observations = errorSummary(error)
        observations["helper_bundle_id"] = helperBundleID
        observations["service_status"] = statusName(currentService.status)
        emitResponse(ok: false, status: "error", observations: observations)
        return
    }

    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    let currentStatus = statusName(currentService.status)
    emitResponse(
        ok: currentStatus != "enabled" && currentStatus != "requires_approval",
        status: currentStatus,
        observations: [
            "helper_bundle_id": helperBundleID,
            "service_status": currentStatus,
            "stop_notification_sent": true
        ],
        warnings: currentStatus == "enabled" ? ["Service still reports enabled after unregister. Recheck System Settings and running processes."] : []
    )
}

func secondsArgument(from args: [String]) -> Int {
    guard let index = args.firstIndex(of: "--seconds"),
          args.indices.contains(index + 1),
          let seconds = Int(args[index + 1]),
          seconds > 0 else {
        return 8
    }
    return seconds
}

final class HeartbeatCollector: NSObject {
    private(set) var heartbeats: [JSONObject] = []
    private(set) var recorderEvents: [JSONObject] = []

    @objc func receive(_ notification: Notification) {
        var heartbeat: JSONObject = [:]
        if let object = notification.object as? String,
           let data = object.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
            heartbeat.merge(parsed) { current, _ in current }
        }
        for (key, value) in notification.userInfo ?? [:] {
            guard let keyString = key as? String else {
                continue
            }
            if let valueString = value as? String {
                heartbeat[keyString] = valueString
            } else if let valueNumber = value as? NSNumber {
                heartbeat[keyString] = valueNumber
            }
        }
        if !heartbeat.isEmpty {
            heartbeats.append(heartbeat)
        }
    }

    @objc func receiveRecorderEvent(_ notification: Notification) {
        var event: JSONObject = [:]
        if let object = notification.object as? String,
           let data = object.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
            event.merge(parsed) { current, _ in current }
        }
        if !event.isEmpty {
            recorderEvents.append(event)
        }
    }
}

@available(macOS 13.0, *)
func waitForHeartbeat(seconds: Int, collector: HeartbeatCollector) {
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while collector.heartbeats.isEmpty && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}

@available(macOS 13.0, *)
func roundtrip(seconds: Int) {
    let collector = HeartbeatCollector()
    let center = DistributedNotificationCenter.default()
    center.addObserver(
        collector,
        selector: #selector(HeartbeatCollector.receive(_:)),
        name: heartbeatNotification,
        object: nil
    )

    waitForHeartbeat(seconds: seconds, collector: collector)
    center.removeObserver(collector)

    let currentStatus = statusName(service().status)
    let firstHeartbeat = collector.heartbeats.first ?? [:]
    let ok = !collector.heartbeats.isEmpty
    emitResponse(
        ok: ok,
        status: ok ? "heartbeat_observed" : currentStatus,
        promptRequested: currentStatus == "requires_approval",
        observations: [
            "helper_bundle_id": helperBundleID,
            "service_status": currentStatus,
            "observed_heartbeat_count": collector.heartbeats.count,
            "first_heartbeat": firstHeartbeat,
            "timeout_seconds": seconds
        ],
        warnings: ok ? [] : ["No helper heartbeat observed during the timeout window. If status is requires_approval, approve the login item in System Settings first."]
    )
}

func writeLowSensitiveRecorderFixture() -> JSONObject {
    let text = "Blocks helper recorder fixture"
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return [
        "characters": text.count,
        "sha256_12": sha256Prefix(text),
        "change_count": pasteboard.changeCount
    ]
}

@available(macOS 13.0, *)
func recorderRoundtrip(seconds: Int) {
    _ = bestEffortStopAndUnregister()
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.0))
    let collector = HeartbeatCollector()
    let center = DistributedNotificationCenter.default()
    center.addObserver(
        collector,
        selector: #selector(HeartbeatCollector.receive(_:)),
        name: heartbeatNotification,
        object: nil
    )
    center.addObserver(
        collector,
        selector: #selector(HeartbeatCollector.receiveRecorderEvent(_:)),
        name: recorderEventNotification,
        object: nil
    )

    let currentService = service()
    do {
        try currentService.register()
    } catch {
        center.removeObserver(collector)
        var observations = errorSummary(error)
        observations["helper_bundle_id"] = helperBundleID
        observations["service_status"] = statusName(currentService.status)
        emitResponse(ok: false, status: "error", observations: observations)
        return
    }

    let currentStatus = statusName(currentService.status)
    if currentStatus == "requires_approval" || currentStatus == "not_found" {
        center.removeObserver(collector)
        emitResponse(
            ok: false,
            status: currentStatus,
            promptRequested: currentStatus == "requires_approval",
            observations: [
                "helper_bundle_id": helperBundleID,
                "service_status": currentStatus
            ],
            warnings: statusWarnings(currentStatus)
        )
        return
    }

    waitForHeartbeat(seconds: min(seconds, 8), collector: collector)
    postJSONNotification(
        name: recorderStartNotification,
        payload: [
            "source": probeName,
            "seconds": Double(seconds),
            "raw_content_allowed": false
        ]
    )
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    let fixture = writeLowSensitiveRecorderFixture()

    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while collector.recorderEvents.isEmpty && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    let cleanup = bestEffortStopAndUnregister()
    center.removeObserver(collector)
    let event = collector.recorderEvents.first ?? [:]
    let text = event["text"] as? JSONObject ?? [:]
    let hashMatches = (text["sha256_12"] as? String) == (fixture["sha256_12"] as? String)
    let ok = !collector.heartbeats.isEmpty && !collector.recorderEvents.isEmpty && hashMatches
    emitResponse(
        ok: ok,
        status: ok ? "recorder_roundtrip_observed" : "recorder_roundtrip_not_observed",
        observations: [
            "helper_bundle_id": helperBundleID,
            "service_status_before_cleanup": currentStatus,
            "heartbeat_count": collector.heartbeats.count,
            "recorder_event_count": collector.recorderEvents.count,
            "first_heartbeat": collector.heartbeats.first ?? [:],
            "first_recorder_event": event,
            "fixture": fixture,
            "hash_matches_fixture": hashMatches,
            "cleanup": cleanup,
            "timeout_seconds": seconds
        ],
        warnings: [
            "The command overwrites the current pasteboard with a low-sensitive fixture.",
            "Helper emits only redacted pasteboard metadata and short hashes."
        ]
    )
}

@available(macOS 13.0, *)
func restartPolicyCheck() {
    _ = bestEffortStopAndUnregister()
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.0))
    let collector = HeartbeatCollector()
    let center = DistributedNotificationCenter.default()
    center.addObserver(
        collector,
        selector: #selector(HeartbeatCollector.receive(_:)),
        name: heartbeatNotification,
        object: nil
    )

    let currentService = service()
    do {
        try currentService.register()
    } catch {
        center.removeObserver(collector)
        var observations = errorSummary(error)
        observations["helper_bundle_id"] = helperBundleID
        observations["service_status"] = statusName(currentService.status)
        emitResponse(ok: false, status: "error", observations: observations)
        return
    }

    waitForHeartbeat(seconds: 8, collector: collector)
    let firstPID = collector.heartbeats.first?["pid"] as? NSNumber
    postJSONNotification(
        name: controlNotification,
        payload: ["source": probeName, "mode": "exit_nonzero"]
    )

    let startedCount = collector.heartbeats.count
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        if collector.heartbeats.count > startedCount {
            let latestPID = collector.heartbeats.last?["pid"] as? NSNumber
            if latestPID != firstPID {
                break
            }
        }
    }

    let cleanup = bestEffortStopAndUnregister()
    center.removeObserver(collector)
    let latestPID = collector.heartbeats.last?["pid"] as? NSNumber
    let restartObserved = firstPID != nil && latestPID != nil && latestPID != firstPID
    let heartbeatObserved = !collector.heartbeats.isEmpty
    emitResponse(
        ok: heartbeatObserved,
        status: heartbeatObserved ? "restart_policy_checked" : "restart_policy_not_observed",
        observations: [
            "helper_bundle_id": helperBundleID,
            "heartbeat_count": collector.heartbeats.count,
            "first_heartbeat": collector.heartbeats.first ?? [:],
            "last_heartbeat": collector.heartbeats.last ?? [:],
            "nonzero_exit_requested": true,
            "restart_observed": restartObserved,
            "service_status_after_cleanup": statusName(currentService.status),
            "cleanup": cleanup
        ],
        warnings: restartObserved ? [] : [
            "No restart heartbeat was observed in the short window; this records launchd behavior on the current machine only."
        ]
    )
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "blocks-login-helper" else {
    usage()
    Foundation.exit(0)
}

if #available(macOS 13.0, *) {
    if args.contains("--status") {
        emitStatus()
    } else if args.contains("--approval-status") {
        emitStatus()
    } else if args.contains("--register") {
        registerHelper()
    } else if args.contains("--roundtrip") {
        roundtrip(seconds: secondsArgument(from: args))
    } else if args.contains("--recorder-roundtrip") {
        recorderRoundtrip(seconds: secondsArgument(from: args))
    } else if args.contains("--restart-policy-check") {
        restartPolicyCheck()
    } else if args.contains("--unregister") {
        unregisterHelper()
    } else {
        usage()
    }
} else {
    emitResponse(
        ok: false,
        status: "not_supported",
        observations: [
            "minimum_macos": "13.0",
            "current_os": ProcessInfo.processInfo.operatingSystemVersionString
        ]
    )
}
