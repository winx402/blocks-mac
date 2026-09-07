import Foundation
import Security

public enum BlocksKeychainNamespace {
    /// Local development uses the system login keychain and its normal access
    /// prompts, not a fabricated provisioning group or a plaintext fallback.
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
