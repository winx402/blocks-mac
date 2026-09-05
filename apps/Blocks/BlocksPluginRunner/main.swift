import BlocksCore
import AppKit
import Darwin
import Foundation
import JavaScriptCore
import OSLog

private final class BlocksPluginRunnerListenerDelegate:
    NSObject,
    NSXPCListenerDelegate
{
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard BlocksPluginRunnerPeerValidator.isHostApp(connection) else {
            connection.invalidate()
            return false
        }

        let service = BlocksNativePluginRunnerXPCService()
        connection.exportedInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerXPCProtocol.self
        )
        connection.exportedObject = service
        connection.interruptionHandler = { [weak service] in
            service?.cancelAll()
        }
        connection.invalidationHandler = { [weak service] in
            service?.cancelAll()
        }
        connection.resume()
        return true
    }
}

private enum BlocksPluginRunnerPeerValidator {
    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "PluginRunnerPeer"
    )

    static func isHostApp(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else {
            logger.error("reject reason=user_mismatch")
            return false
        }
        guard connection.processIdentifier > 0 else {
            logger.error("reject reason=missing_pid")
            return false
        }
        guard let expectedExecutable = embeddedHostAppExecutableURL() else {
            logger.error(
                "reject reason=missing_embedded_host bundle=\(Bundle.main.bundleURL.path, privacy: .public)"
            )
            return false
        }
        guard let peerExecutable = executableURL(
            processID: connection.processIdentifier
        ) else {
            logger.error(
                "reject reason=missing_peer_path pid=\(connection.processIdentifier, privacy: .public)"
            )
            return false
        }
        guard peerExecutable.resolvingSymlinksInPath()
            == expectedExecutable.resolvingSymlinksInPath() else {
            logger.error(
                "reject reason=path_mismatch pid=\(connection.processIdentifier, privacy: .public) expected=\(expectedExecutable.path, privacy: .public) actual=\(peerExecutable.path, privacy: .public)"
            )
            return false
        }

        // An app-embedded XPC service is launchd-scoped to its containing app.
        // App Sandbox intentionally denies SecCodeCopyGuestWithAttributes for
        // the host process, so attempting an additional dynamic signing query
        // makes every legitimate connection fail. The exact executable path
        // above binds the peer to this service's own containing app; the UID
        // and running-application identifier checks keep that boundary explicit.
        let peerBundleIdentifier = NSRunningApplication(
            processIdentifier: connection.processIdentifier
        )?.bundleIdentifier
        guard peerBundleIdentifier
            == BlocksNativePluginXPC.hostAppBundleIdentifier else {
            logger.error(
                "reject reason=unexpected_peer_application pid=\(connection.processIdentifier, privacy: .public) bundle=\(peerBundleIdentifier ?? "missing", privacy: .public)"
            )
            return false
        }
        return true
    }

    private static func embeddedHostAppExecutableURL() -> URL? {
        let serviceBundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard serviceBundleURL.pathExtension.lowercased() == "xpc" else {
            return nil
        }
        let appURL = serviceBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        guard appURL.pathExtension.lowercased() == "app" else {
            return nil
        }
        return appURL.appendingPathComponent(
            "Contents/MacOS/Blocks",
            isDirectory: false
        )
    }

    private static func executableURL(processID: pid_t) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
            .standardizedFileURL
    }
}

// JavaScriptCore binds a VM to the run loop of the thread that initializes it.
// Touch the framework once on the XPC service's main thread before plugin work
// is dispatched to the private serial execution queue. Each invocation still
// creates and owns its own context on that queue; this bootstrap context is
// never shared with plugin execution.
private let javaScriptCoreBootstrapContext = JSContext()
_ = javaScriptCoreBootstrapContext
private let delegate = BlocksPluginRunnerListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
