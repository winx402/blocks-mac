import BlocksCore
import Foundation

enum BlocksBuiltInPluginCategory: String, Codable, CaseIterable, Sendable {
    case clipboard
    case screenshot
    case translation
    case productivity
}

struct BlocksBuiltInPluginLocalization: Codable, Equatable, Sendable {
    let name: String
    let summary: String
}

struct BlocksBuiltInPluginCatalogEntry:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    let id: String
    let version: String
    let category: BlocksBuiltInPluginCategory
    let symbolName: String
    let packageDirectory: String
    let packageSHA256: String
    let localizations: [String: BlocksBuiltInPluginLocalization]

    private enum CodingKeys: String, CodingKey {
        case id, version, category, localizations
        case symbolName = "symbol_name"
        case packageDirectory = "package_directory"
        case packageSHA256 = "package_sha256"
    }

    func localized(locale: Locale = .current) -> BlocksBuiltInPluginLocalization {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if let exact = localizations[identifier] { return exact }
        if let language = locale.language.languageCode?.identifier,
           let match = localizations.first(where: {
               $0.key == language || $0.key.hasPrefix("\(language)-")
           })?.value {
            return match
        }
        return localizations["en"]
            ?? localizations.values.first
            ?? .init(name: id, summary: "")
    }
}

struct BlocksBuiltInPluginCatalogDocument: Codable, Equatable, Sendable {
    let catalogVersion: String
    let entries: [BlocksBuiltInPluginCatalogEntry]

    private enum CodingKeys: String, CodingKey {
        case catalogVersion = "catalog_version"
        case entries
    }
}

enum BlocksBuiltInPluginCatalogError: Error, LocalizedError {
    case resourceMissing
    case entryUnavailable(String)
    case packageMissing(String)
    case identifierMismatch(expected: String, actual: String)
    case versionMismatch(expected: String, actual: String)
    case hashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "The built-in plugin catalog is unavailable in this app build."
        case let .entryUnavailable(id):
            "The built-in plugin catalog entry is unavailable: \(id)."
        case let .packageMissing(path):
            "The built-in plugin package is missing: \(path)."
        case let .identifierMismatch(expected, actual):
            "The built-in catalog expected \(expected), but the package declares \(actual)."
        case let .versionMismatch(expected, actual):
            "The built-in catalog expected version \(expected), but the package declares \(actual)."
        case let .hashMismatch(expected, actual):
            "The built-in plugin hash changed (expected \(expected), found \(actual))."
        }
    }
}

struct BlocksBuiltInPluginCatalog: Sendable {
    let document: BlocksBuiltInPluginCatalogDocument
    let resourceRoot: URL

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let resourceRoot = bundle.url(
            forResource: "BuiltInPlugins",
            withExtension: nil
        ) else {
            throw BlocksBuiltInPluginCatalogError.resourceMissing
        }
        let catalogURL = resourceRoot.appendingPathComponent("catalog.json")
        let data = try Data(contentsOf: catalogURL, options: .mappedIfSafe)
        let document = try JSONDecoder().decode(
            BlocksBuiltInPluginCatalogDocument.self,
            from: data
        )
        return .init(document: document, resourceRoot: resourceRoot)
    }

    func packageURL(for entry: BlocksBuiltInPluginCatalogEntry) -> URL {
        resourceRoot.appendingPathComponent(
            entry.packageDirectory,
            isDirectory: true
        )
    }

    func validatedPackage(
        for entry: BlocksBuiltInPluginCatalogEntry
    ) throws -> BlocksNativePluginValidatedPackage {
        let url = packageURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BlocksBuiltInPluginCatalogError.packageMissing(
                entry.packageDirectory
            )
        }
        let package = try BlocksNativePluginPackageValidator().validate(
            directory: url
        )
        guard package.manifest.id == entry.id else {
            throw BlocksBuiltInPluginCatalogError.identifierMismatch(
                expected: entry.id,
                actual: package.manifest.id
            )
        }
        guard package.manifest.version == entry.version else {
            throw BlocksBuiltInPluginCatalogError.versionMismatch(
                expected: entry.version,
                actual: package.manifest.version
            )
        }
        guard !entry.packageSHA256.isEmpty,
              package.packageSHA256 == entry.packageSHA256 else {
            throw BlocksBuiltInPluginCatalogError.hashMismatch(
                expected: entry.packageSHA256,
                actual: package.packageSHA256
            )
        }
        return package
    }
}

/// Loads the richer, localized presentation bundled inside built-in plugin
/// packages away from the main actor. Package validation computes hashes and
/// performs file IO, so it must never be reached from a SwiftUI `body`.
actor BlocksBuiltInPluginPresentationLoader {
    func load(
        catalog: BlocksBuiltInPluginCatalog,
        localeIdentifier: String
    ) -> [String: BlocksNativePluginPresentationLocalization] {
        let locale = Locale(identifier: localeIdentifier)
        var presentations: [
            String: BlocksNativePluginPresentationLocalization
        ] = [:]
        for entry in catalog.document.entries {
            guard !Task.isCancelled else { break }
            guard let package = try? catalog.validatedPackage(for: entry),
                  let presentation = package.manifest.presentation?.localized(
                    fallbackName: entry.localized(locale: locale).name,
                    locale: locale
                  ) else {
                continue
            }
            presentations[entry.id] = presentation
        }
        return presentations
    }
}

extension BlocksNativePluginManager {
    /// Applies catalog revisions only when the reviewed permission contract is
    /// byte-for-byte equivalent. Permission expansion always remains pending
    /// for an explicit user review in the plugin center.
    func applyCompatibleBuiltInUpdates(
        catalog: BlocksBuiltInPluginCatalog,
        validationCheckpoint: (@Sendable () async -> Void)? = nil
    ) async {
        for entry in catalog.document.entries {
            guard operation == .idle,
                  let installed = plugins.first(where: { $0.id == entry.id }),
                  installed.installationOrigin == .builtIn else { continue }
            let package: BlocksNativePluginValidatedPackage
            do {
                package = try await Task.detached(priority: .utility) {
                    try catalog.validatedPackage(for: entry)
                }.value
            } catch {
                continue
            }
            await validationCheckpoint?()
            guard package.packageSHA256 != installed.packageHash else {
                continue
            }
            let approvedPermissions = Set(installed.approvedPermissions)
            let replacementPermissions = Set(
                package.manifest.declaredPermissionTokens
            )
            let approvedDomains = Set(
                installed.approvedDomains.map { $0.lowercased() }
            )
            let replacementDomains = Set(
                (package.manifest.permissions.network?.domains ?? [])
                    .map { $0.lowercased() }
            )
            guard approvedPermissions == replacementPermissions,
                  approvedDomains == replacementDomains else {
                continue
            }
            let wasEnabled = installed.isEnabled
            var ownedPendingID: UUID?
            do {
                let pending = try await prepareBuiltInInstallation(
                    entryID: entry.id,
                    catalog: catalog
                )
                ownedPendingID = pending.id
                let updated = try await confirmAndInstall(pendingID: pending.id)
                if wasEnabled {
                    _ = try await setEnabled(true, pluginID: updated.id)
                }
            } catch {
                if let ownedPendingID {
                    cancelPendingInstallation(id: ownedPendingID)
                }
            }
        }
    }
}
