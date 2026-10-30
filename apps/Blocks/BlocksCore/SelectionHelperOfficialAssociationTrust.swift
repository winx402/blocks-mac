import Darwin
import Foundation
import Security

#if !BLOCKS_LOCAL_DEVELOPMENT
/// Official association never uses the development peer registry. A context
/// pins both installed executables and the running self before accepting IPC.
/// Any later replacement invalidates the context instead of rebinding trust.
final class SelectionHelperOfficialAssociationTrust: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let identifier: String
        let team: String
        let path: String
        let cdHash: String
    }

    let app: Identity
    let helper: Identity
    private let own: Identity
    private let ownCode: SecCode

    private init(app: Identity, helper: Identity, own: Identity, ownCode: SecCode) {
        self.app = app
        self.helper = helper
        self.own = own
        self.ownCode = ownCode
    }

    static func make() -> SelectionHelperOfficialAssociationTrust? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let own = runningIdentity(code), validTeam(own.team) else { return nil }
        let executable = URL(fileURLWithPath: own.path)
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host: URL
        switch own.identifier {
        case "app.blocks.app": host = bundle
        case "app.blocks.selection-helper":
            guard bundle.lastPathComponent == "blocksHelper.app" else { return nil }
            host = bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        default: return nil
        }
        let appPath = host.appendingPathComponent("Contents/MacOS/Blocks").path
        let helperPath = host.appendingPathComponent("Contents/Helpers/blocksHelper.app/Contents/MacOS/blocksHelper").path
        guard let app = diskIdentity(path: appPath, identifier: "app.blocks.app", team: own.team),
              let helper = diskIdentity(path: helperPath, identifier: "app.blocks.selection-helper", team: own.team),
              own == (own.identifier == app.identifier ? app : helper),
              check(code, expected: own) else { return nil }
        return .init(app: app, helper: helper, own: own, ownCode: code)
    }

    func snapshotIsCurrent() -> Bool {
        Self.check(ownCode, expected: own)
            && Self.diskIdentity(path: app.path, identifier: app.identifier, team: app.team) == app
            && Self.diskIdentity(path: helper.path, identifier: helper.identifier, team: helper.team) == helper
    }

    func authenticate(auditToken: Data, role: String) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size, snapshotIsCurrent() else { return false }
        let expected: Identity
        switch role {
        case "app": expected = app
        case "helper": expected = helper
        default: return false
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary,
                                             [], &code) == errSecSuccess,
              let code, Self.check(code, expected: expected),
              let observed = Self.runningIdentity(code),
              Self.matches(observed, expected: expected), snapshotIsCurrent() else { return false }
        return true
    }

    // Pure policy seam; runtime observations always come from Security and
    // LOCAL_PEERTOKEN, never from paths, PIDs, or identities in a wire request.
    static func matches(_ observed: Identity, expected: Identity) -> Bool {
        validTeam(observed.team)
            && ["app.blocks.app", "app.blocks.selection-helper"].contains(observed.identifier)
            && observed == expected
            && URL(fileURLWithPath: observed.path).resolvingSymlinksInPath().path == expected.path
    }

    private static func validTeam(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func requirement(identifier: String, team: String, hash: String? = nil) -> SecRequirement? {
        guard ["app.blocks.app", "app.blocks.selection-helper"].contains(identifier), validTeam(team),
              hash == nil || hash!.range(of: "^[0-9a-f]{40}(?:[0-9a-f]{24})?$", options: .regularExpression) != nil else { return nil }
        var text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        if let hash { text += " and cdhash H\"\(hash)\"" }
        var value: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &value) == errSecSuccess else { return nil }
        return value
    }

    private static func check(_ code: SecCode, expected: Identity) -> Bool {
        guard let requirement = requirement(identifier: expected.identifier, team: expected.team, hash: expected.cdHash) else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private static func diskIdentity(path: String, identifier: String, team: String) -> Identity? {
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
              let requirement = requirement(identifier: identifier, team: team) else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              let identity = information(code), identity.identifier == identifier,
              identity.team == team, identity.path == path else { return nil }
        return identity
    }

    private static func runningIdentity(_ code: SecCode) -> Identity? {
        var value: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &value) == errSecSuccess, let value else { return nil }
        return information(value)
    }

    private static func information(_ code: SecStaticCode) -> Identity? {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [CFString: Any],
              let identifier = info[kSecCodeInfoIdentifier] as? String,
              let team = info[kSecCodeInfoTeamIdentifier] as? String,
              let path = info[kSecCodeInfoMainExecutable] as? URL,
              let hash = info[kSecCodeInfoUnique] as? Data else { return nil }
        return .init(identifier: identifier, team: team, path: path.standardizedFileURL.path,
                     cdHash: hash.map { String(format: "%02x", $0) }.joined())
    }
}
#endif
