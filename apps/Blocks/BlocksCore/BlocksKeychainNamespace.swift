import Foundation
import Security
import OSLog

public enum BlocksKeychainNamespace {
    /// Local development uses the login keychain, not a fabricated provisioning
    /// group or a plaintext fallback. Helper access is coordinated below.
    public static func queryForCurrentBuild(_ query: [String: Any]) -> [String: Any] {
        #if BLOCKS_LOCAL_DEVELOPMENT
        var local = query
        local.removeValue(forKey: kSecAttrAccessGroup as String)
        local.removeValue(forKey: kSecAttrAccessible as String)
        local[kSecUseDataProtectionKeychain as String] = false
        return local
        #else
        return query
        #endif
    }

    public static func helperQuery(service: String, account: String, accessGroup: String?) -> [String: Any]? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        #if BLOCKS_LOCAL_DEVELOPMENT
        return queryForCurrentBuild(base)
        #else
        guard let accessGroup, !accessGroup.isEmpty else { return nil }
        return base.merging([
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]) { _, replacement in replacement }
        #endif
    }
}

/// All Blocks-owned Keychain calls share this lock because the legacy Keychain
/// interaction switch is process-wide, not a per-query option. Never hold this
/// scope across await, IPC, or user interaction. Other credential stores retain
/// their normal policy, but cannot race a Helper's temporary no-UI operation.
public enum BlocksKeychainAccess {
    private static let lock = NSRecursiveLock()
    private static let logger = Logger(subsystem: "app.blocks.keychain", category: "InteractionPolicy")

    public static func perform(helper: Bool = false, _ operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        #if BLOCKS_LOCAL_DEVELOPMENT
        if helper {
            var previouslyAllowed: DarwinBoolean = false
            let readStatus = SecKeychainGetUserInteractionAllowed(&previouslyAllowed)
            guard readStatus == errSecSuccess else { return readStatus }
            let disableStatus = SecKeychainSetUserInteractionAllowed(false)
            guard disableStatus == errSecSuccess else { return disableStatus }
            let result = operation()
            let restoreStatus = SecKeychainSetUserInteractionAllowed(previouslyAllowed.boolValue)
            if restoreStatus != errSecSuccess {
                logger.error("Unable to restore Keychain interaction policy: \(restoreStatus, privacy: .public)")
            }
            // A failed restoration must never be reported as a successful call.
            return restoreStatus == errSecSuccess ? result : restoreStatus
        }
        #endif
        return operation()
    }

    public static func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform { SecItemCopyMatching(query, result) }
    }
    public static func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform { SecItemAdd(query, result) }
    }
    public static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        perform { SecItemUpdate(query, attributes) }
    }
    public static func delete(_ query: CFDictionary) -> OSStatus {
        perform { SecItemDelete(query) }
    }

    public static func helperCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform(helper: true) { SecItemCopyMatching(query, result) }
    }
    public static func helperUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        perform(helper: true) { SecItemUpdate(query, attributes) }
    }
    public static func helperDelete(_ query: CFDictionary) -> OSStatus {
        perform(helper: true) { SecItemDelete(query) }
    }
    public static func helperAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform(helper: true) {
            #if BLOCKS_LOCAL_DEVELOPMENT
            guard let access = BlocksLocalBuildTrust.withKeychainPeerExecutables({ makeHelperAccess(trustedExecutables: $0) }),
                  var item = query as? [String: Any] else { return errSecAuthFailed }
            item[kSecAttrAccess as String] = access
            return SecItemAdd(item as CFDictionary, result)
            #else
            return SecItemAdd(query, result)
            #endif
        }
    }

    // Internal seam for isolated, synthetic two-process Keychain tests. Runtime
    // callers cannot supply paths: helperAdd always uses the validated manifest.
    static func makeHelperAccess(trustedExecutables: [URL]) -> SecAccess? {
        guard trustedExecutables.count == 2, Set(trustedExecutables).count == 2 else { return nil }
        var trusted = [SecTrustedApplication]()
        for executable in trustedExecutables {
            var application: SecTrustedApplication?
            // SecTrustedApplication requires the bundle root for bundled apps.
            let path = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
            guard SecTrustedApplicationCreateFromPath(path, &application) == errSecSuccess,
                  let application else { return nil }
            trusted.append(application)
        }
        var access: SecAccess?
        guard SecAccessCreate("Blocks Helper pairing" as CFString, trusted as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
