import AppKit
import CryptoKit
import Foundation

let heartbeatNotification = Notification.Name("app.blocks.spikes.loginitem.helper.heartbeat")
let stopNotification = Notification.Name("app.blocks.spikes.loginitem.helper.stop")
let recorderStartNotification = Notification.Name("app.blocks.spikes.loginitem.helper.recorder.start")
let recorderEventNotification = Notification.Name("app.blocks.spikes.loginitem.helper.recorder.event")
let controlNotification = Notification.Name("app.blocks.spikes.loginitem.helper.control")
let helperBundleID = Bundle.main.bundleIdentifier ?? "app.blocks.spikes.loginitem.helper"
let maxLifetimeSeconds: TimeInterval = 30

typealias JSONObject = [String: Any]

func sha256Prefix(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
}

func jsonObject(from notification: Notification) -> JSONObject {
    guard let object = notification.object as? String,
          let data = object.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
        return [:]
    }
    return parsed
}

func postJSON(name: Notification.Name, payload: JSONObject) {
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let text = data.flatMap { String(data: $0, encoding: .utf8) }
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: text,
        userInfo: nil,
        deliverImmediately: true
    )
}

func pasteboardRedactedEvent(changeCount: Int) -> JSONObject {
    let pasteboard = NSPasteboard.general
    let item = pasteboard.pasteboardItems?.first
    var event: JSONObject = [
        "bundle_id": helperBundleID,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "change_count": changeCount,
        "item_count": pasteboard.pasteboardItems?.count ?? 0,
        "types": (pasteboard.types ?? []).map { $0.rawValue }.sorted(),
        "timestamp": Date().timeIntervalSince1970
    ]
    if let text = item?.string(forType: .string) {
        event["text"] = [
            "characters": text.count,
            "sha256_12": sha256Prefix(text)
        ]
    }
    event["raw_content_emitted"] = false
    return event
}

final class HelperState: NSObject {
    var shouldStop = false
    var recorderActiveUntil: Date?
    var recorderLastChangeCount = NSPasteboard.general.changeCount
    var requestedNonzeroExit = false

    @objc func stop(_ notification: Notification) {
        shouldStop = true
    }

    @objc func startRecorder(_ notification: Notification) {
        let payload = jsonObject(from: notification)
        let seconds = min(max(payload["seconds"] as? Double ?? 8, 1), 30)
        recorderLastChangeCount = NSPasteboard.general.changeCount
        recorderActiveUntil = Date().addingTimeInterval(seconds)
    }

    @objc func control(_ notification: Notification) {
        let payload = jsonObject(from: notification)
        if payload["mode"] as? String == "exit_nonzero" {
            requestedNonzeroExit = true
        }
    }

    func recorderIsActive() -> Bool {
        guard let recorderActiveUntil else {
            return false
        }
        if Date() < recorderActiveUntil {
            return true
        }
        self.recorderActiveUntil = nil
        return false
    }
}

let helperState = HelperState()
let center = DistributedNotificationCenter.default()
center.addObserver(
    helperState,
    selector: #selector(HelperState.stop(_:)),
    name: stopNotification,
    object: nil
)
center.addObserver(
    helperState,
    selector: #selector(HelperState.startRecorder(_:)),
    name: recorderStartNotification,
    object: nil
)
center.addObserver(
    helperState,
    selector: #selector(HelperState.control(_:)),
    name: controlNotification,
    object: nil
)

let deadline = Date().addingTimeInterval(maxLifetimeSeconds)
var sequence = 0

while !helperState.shouldStop && Date() < deadline {
    if helperState.requestedNonzeroExit {
        exit(2)
    }

    sequence += 1
    let heartbeat: [String: Any] = [
        "bundle_id": helperBundleID,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "sequence": sequence,
        "timestamp": Date().timeIntervalSince1970
    ]
    postJSON(name: heartbeatNotification, payload: heartbeat)

    if helperState.recorderIsActive() {
        let changeCount = NSPasteboard.general.changeCount
        if changeCount != helperState.recorderLastChangeCount {
            postJSON(name: recorderEventNotification, payload: pasteboardRedactedEvent(changeCount: changeCount))
            helperState.recorderLastChangeCount = changeCount
        }
    }

    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
}

center.removeObserver(helperState)
