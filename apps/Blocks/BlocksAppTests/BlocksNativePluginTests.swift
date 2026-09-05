import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Blocks
import BlocksCore
import BlocksScreenshotCore

final class BlocksNativePluginPackageValidatorTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksNativePluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    func testScopedResourceAuthorizationRevocationDoesNotAffectNewOrUnscopedLeases() throws {
        let featureGate = BlocksPluginFeatureAdmissionGate()
        let broker = BlocksPluginResourceBroker(featureAdmissionGate: featureGate)
        let resource = broker.register(
            data: Data("scoped".utf8),
            kind: .screenshot,
            mediaType: "image/png"
        )
        let oldToken = featureGate.capture(module: .screenshot)
        let oldLease = broker.authorizeScoped(
            pluginID: "com.example.scoped",
            resourceIDs: [resource.id],
            featureAdmission: oldToken
        )
        XCTAssertNoThrow(try broker.read(
            pluginID: "com.example.scoped",
            id: resource.id,
            offset: 0,
            length: 32
        ))

        featureGate.invalidate(module: .screenshot)
        XCTAssertThrowsError(try broker.read(
            pluginID: "com.example.scoped",
            id: resource.id,
            offset: 0,
            length: 32
        ))

        let newToken = featureGate.capture(module: .screenshot)
        let newLease = broker.authorizeScoped(
            pluginID: "com.example.scoped",
            resourceIDs: [resource.id],
            featureAdmission: newToken
        )
        XCTAssertNoThrow(try broker.read(
            pluginID: "com.example.scoped",
            id: resource.id,
            offset: 0,
            length: 32
        ))
        broker.revokeScoped(oldLease, resourceIDs: [resource.id])
        XCTAssertNoThrow(try broker.read(
            pluginID: "com.example.scoped",
            id: resource.id,
            offset: 0,
            length: 32
        ))

        broker.authorize(pluginID: "com.example.ui", resourceIDs: [resource.id])
        broker.revokeScoped(newLease, resourceIDs: [resource.id])
        XCTAssertNoThrow(try broker.read(
            pluginID: "com.example.ui",
            id: resource.id,
            offset: 0,
            length: 32
        ))
    }

    func testFeatureAdmissionGenerationSaturatesFailClosedAtMaximum() {
        let gate = BlocksPluginFeatureAdmissionGate(
            testingInitialGenerations: [.screenshot: UInt64.max - 1]
        )
        let penultimateToken = gate.capture(module: .screenshot)
        XCTAssertTrue(gate.isCurrent(penultimateToken))

        gate.invalidate(module: .screenshot)
        XCTAssertFalse(gate.isCurrent(penultimateToken))
        let maximumToken = gate.capture(module: .screenshot)
        XCTAssertTrue(gate.isCurrent(maximumToken))

        gate.invalidate(module: .screenshot)
        XCTAssertFalse(gate.isCurrent(maximumToken))
        let exhaustedToken = gate.capture(module: .screenshot)
        XCTAssertFalse(gate.isCurrent(exhaustedToken))

        gate.invalidate(module: .screenshot)
        XCTAssertFalse(gate.isCurrent(exhaustedToken))

        let ordinaryGate = BlocksPluginFeatureAdmissionGate()
        let oldOrdinaryToken = ordinaryGate.capture(module: .screenshot)
        ordinaryGate.invalidate(module: .screenshot)
        XCTAssertFalse(ordinaryGate.isCurrent(oldOrdinaryToken))
        XCTAssertTrue(
            ordinaryGate.isCurrent(
                ordinaryGate.capture(module: .screenshot)
            )
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testValidUnsignedPackageProducesBoundedConfirmationSummary() throws {
        let package = try makePackage(
            manifest: manifest(
                permissions: .init(
                    network: .init(
                        domains: ["api.example.com"],
                        methods: [.post],
                        maximumRequestBytes: 4_096
                    ),
                    secrets: [
                        .init(id: "api_key", displayName: "API Key"),
                    ]
                )
            )
        )

        let result = try BlocksNativePluginPackageValidator().validate(directory: package)

        XCTAssertEqual(result.manifest.id, "com.example.fixture")
        XCTAssertEqual(result.packageSHA256.count, 64)
        XCTAssertFalse(result.installationConfirmation.isSigned)
        XCTAssertTrue(result.installationConfirmation.requiresRiskConfirmation)
        XCTAssertEqual(result.installationConfirmation.networkDomains, ["api.example.com"])
        XCTAssertEqual(
            result.installationConfirmation.networkMaximumRequestBytes,
            4_096
        )
        XCTAssertEqual(result.installationConfirmation.secretIDs, ["api_key"])
        XCTAssertEqual(
            Set(result.relativeFilePaths),
            Set(["manifest.json", "plugin.js"])
        )
    }

    func testManifestRejectsUserIndistinguishableSecretDisplayNames()
        throws
    {
        func manifest(
            secrets: [BlocksNativePluginSecretDeclaration]
        ) -> BlocksNativePluginManifest {
            BlocksNativePluginManifest(
                schemaVersion: 2,
                id: "com.example.secret-display-names",
                displayName: "Secret Display Names",
                version: "1.0.0",
                entryPoint: "plugin.js",
                capabilities: [.translation],
                permissions: .init(secrets: secrets),
                configurationFields: secrets.map {
                    .init(
                        id: $0.id,
                        type: .secret,
                        title: $0.displayName,
                        required: $0.required
                    )
                }
            )
        }

        let validator = BlocksNativePluginPackageValidator()
        for (secrets, duplicateDisplayName) in [
            (
                [
                    BlocksNativePluginSecretDeclaration(
                        id: "api_key",
                        displayName: "API Key"
                    ),
                    BlocksNativePluginSecretDeclaration(
                        id: "service_key",
                        displayName: "API Key"
                    ),
                ],
                "API Key"
            ),
            (
                [
                    BlocksNativePluginSecretDeclaration(
                        id: "api_key",
                        displayName: "API Key"
                    ),
                    BlocksNativePluginSecretDeclaration(
                        id: "service_key",
                        displayName: "api key"
                    ),
                ],
                "api key"
            ),
            (
                [
                    BlocksNativePluginSecretDeclaration(
                        id: "cafe_key",
                        displayName: "Caf\u{00E9}"
                    ),
                    BlocksNativePluginSecretDeclaration(
                        id: "service_key",
                        displayName: "Cafe\u{0301}"
                    ),
                ],
                "Cafe\u{0301}"
            ),
        ] {
            XCTAssertThrowsError(try validator.validate(manifest: manifest(secrets: secrets))) {
                error in
                XCTAssertEqual(
                    error as? BlocksNativePluginValidationError,
                    .duplicateSecretDisplayName(duplicateDisplayName)
                )
            }
        }

        XCTAssertNoThrow(
            try validator.validate(
                manifest: manifest(secrets: [
                    .init(id: "api_key", displayName: "API Key"),
                    .init(id: "service_key", displayName: "Service Token"),
                ])
            )
        )
    }

    func testPackageHashIsDeterministicAndChangesWithEntrySource() throws {
        let first = try makePackage(
            name: "First.blocksplugin",
            manifest: manifest(),
            entrySource: "function translate() { return 'A'; }"
        )
        let second = try makePackage(
            name: "Second.blocksplugin",
            manifest: manifest(),
            entrySource: "function translate() { return 'A'; }"
        )
        let third = try makePackage(
            name: "Third.blocksplugin",
            manifest: manifest(),
            entrySource: "function translate() { return 'B'; }"
        )
        let validator = BlocksNativePluginPackageValidator()

        XCTAssertEqual(
            try validator.validate(directory: first).packageSHA256,
            try validator.validate(directory: second).packageSHA256
        )
        XCTAssertNotEqual(
            try validator.validate(directory: first).packageSHA256,
            try validator.validate(directory: third).packageSHA256
        )
    }

    func testContextDisclosureChangeChangesPackageHashAndConfirmation()
        throws
    {
        let firstManifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.context-change",
            displayName: "Context Change",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text],
                contextFields: [.inputSource]
            )
        )
        let secondManifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: firstManifest.id,
            displayName: firstManifest.displayName,
            version: firstManifest.version,
            entryPoint: firstManifest.entryPoint,
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text],
                contextFields: [
                    .inputSource,
                    .sourceApplicationBundleID,
                ]
            )
        )
        let first = try makePackage(
            name: "Context-First.blocksplugin",
            manifest: firstManifest
        )
        let second = try makePackage(
            name: "Context-Second.blocksplugin",
            manifest: secondManifest
        )
        let validator = BlocksNativePluginPackageValidator()
        let firstPackage = try validator.validate(directory: first)
        let secondPackage = try validator.validate(directory: second)

        XCTAssertNotEqual(
            firstPackage.packageSHA256,
            secondPackage.packageSHA256
        )
        XCTAssertEqual(
            firstPackage.installationConfirmation
                .translationContextFields,
            [.inputSource]
        )
        XCTAssertEqual(
            secondPackage.installationConfirmation
                .translationContextFields,
            [.inputSource, .sourceApplicationBundleID]
        )
    }

    func testValidatorDisclosesPlatformUIStorageAndExecutionScopes()
        throws
    {
        let package = try makePackage(
            manifest: BlocksNativePluginManifest(
                schemaVersion: 4,
                id: "com.example.platform-disclosure",
                displayName: "Platform Disclosure",
                version: "1.0.0",
                entryPoint: "plugin.js",
                capabilities: [.translation, .hooks, .ui],
                translation: .init(
                    acceptedInputs: [.text],
                    contextFields: [
                        .inputSource,
                        .sourceApplicationBundleID,
                    ]
                ),
                platform: .init(
                    hooks: [
                        .init(
                            id: "background-hook",
                            event: .appLaunched,
                            runsInBackground: true
                        ),
                    ],
                    ui: [
                        .init(
                            id: "settings-status",
                            slot: .settingsStatusCard,
                            root: .init(id: "status", kind: .status)
                        ),
                    ],
                    storage: .init(kinds: [.keyValue]),
                    schedules: [
                        .init(
                            id: "refresh",
                            kind: .interval,
                            configuration: [:]
                        ),
                    ]
                )
            )
        )

        let confirmation = try BlocksNativePluginPackageValidator()
            .validate(directory: package)
            .installationConfirmation

        XCTAssertEqual(
            confirmation.translationContextFields,
            [.inputSource, .sourceApplicationBundleID]
        )
        XCTAssertEqual(confirmation.hookEventNames, [.appLaunched])
        XCTAssertEqual(confirmation.uiSlots, [.settingsStatusCard])
        XCTAssertTrue(confirmation.includesBackgroundExecution)
        XCTAssertTrue(confirmation.includesBackgroundHookExecution)
        XCTAssertTrue(confirmation.includesScheduledExecution)
        XCTAssertTrue(confirmation.usesPrivateStorage)
        XCTAssertTrue(confirmation.requiresRiskConfirmation)
    }

    func testValidatorRejectsFailClosedTerminationHookButAllowsOtherWillHook()
        throws
    {
        let validator = BlocksNativePluginPackageValidator()
        let terminationManifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.termination-fail-closed",
            displayName: "Termination Fail Closed",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(
                        id: "block-termination",
                        event: .appWillTerminate,
                        failurePolicy: .failClosed
                    ),
                ]
            )
        )

        XCTAssertThrowsError(try validator.validate(manifest: terminationManifest)) {
            error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .invalidPlatformDeclaration(
                    "app.will_terminate may not use fail_closed."
                )
            )
        }

        let ordinaryWillManifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.ordinary-will-fail-closed",
            displayName: "Ordinary Will Fail Closed",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(
                        id: "block-paste",
                        event: .clipboardWillWritePasteboard,
                        failurePolicy: .failClosed
                    ),
                ]
            )
        )
        XCTAssertNoThrow(try validator.validate(manifest: ordinaryWillManifest))
    }

    func testValidatorRestrictsForegroundOnlyHooksToNonTerminationWillPreflight()
        throws
    {
        let validator = BlocksNativePluginPackageValidator()
        func manifest(
            _ event: BlocksPluginEventName,
            runsInBackground: Bool
        ) -> BlocksNativePluginManifest {
            .init(
                schemaVersion: 4,
                id: "com.example.foreground-only-\(event.rawValue.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-"))",
                displayName: "Foreground-only Hook",
                version: "1.0.0",
                entryPoint: "plugin.js",
                capabilities: [.hooks],
                platform: .init(hooks: [
                    .init(
                        id: "hook",
                        event: event,
                        runsInBackground: runsInBackground
                    ),
                ])
            )
        }

        for event in [
            BlocksPluginEventName.clipboardWillPersistCapture,
            .clipboardWillWritePasteboard,
            .translationWillRunSession,
            .translationWillCommitResult,
            .providerWillSendRequest,
            .screenshotWillFinalizeOutput,
            .automationWillExecuteShortcut,
        ] {
            XCTAssertNoThrow(
                try validator.validate(manifest: manifest(event, runsInBackground: false))
            )
            XCTAssertNoThrow(
                try validator.validate(manifest: manifest(event, runsInBackground: true))
            )
        }
        for event in [
            BlocksPluginEventName.clipboardDidPersistCapture,
            .clipboardCaptureFailed,
            .automationManualTrigger,
            .automationScheduledTrigger,
            .appWillTerminate,
        ] {
            XCTAssertThrowsError(
                try validator.validate(manifest: manifest(event, runsInBackground: false))
            ) { error in
                XCTAssertEqual(
                    error as? BlocksNativePluginValidationError,
                    .invalidPlatformDeclaration(
                        "runs_in_background=false is only allowed for non-termination will.* preflight hooks."
                    )
                )
            }
            XCTAssertNoThrow(
                try validator.validate(manifest: manifest(event, runsInBackground: true))
            )
        }
    }

    func testPackageRejectsSecureFieldRegardlessOfSecretDeclaration()
        throws
    {
        func manifest(
            id: String,
            secrets: [BlocksNativePluginSecretDeclaration]
        ) -> BlocksNativePluginManifest {
            BlocksNativePluginManifest(
                schemaVersion: 4,
                id: id,
                displayName: "Secure Field Fixture",
                version: "1.0.0",
                entryPoint: "plugin.js",
                capabilities: [.actions, .ui],
                permissions: .init(
                    network: .init(
                        domains: ["api.example.com"],
                        methods: [.post]
                    ),
                    secrets: secrets
                ),
                configurationFields: secrets.map {
                    .init(
                        id: $0.id,
                        type: .secret,
                        title: $0.displayName,
                        required: $0.required
                    )
                },
                platform: .init(
                    actions: [
                        .init(id: "submit", displayName: "Submit"),
                    ],
                    ui: [
                        .init(
                            id: "settings",
                            slot: .pluginPage,
                            root: .init(
                                id: "page",
                                kind: .page,
                                children: [
                                    .init(
                                        id: "api-token",
                                        kind: .secureField,
                                        actionID: "submit"
                                    ),
                                ]
                            )
                        ),
                    ]
                )
            )
        }

        for (name, fixture) in [
            (
                "WithoutSecrets.blocksplugin",
                manifest(
                    id: "com.example.secure-field-without-secret",
                    secrets: []
                )
            ),
            (
                "WithDeclaredSecret.blocksplugin",
                manifest(
                    id: "com.example.secure-field-with-secret",
                    secrets: [
                        .init(id: "api_token", displayName: "API Token"),
                    ]
                )
            ),
        ] {
            let package = try makePackage(name: name, manifest: fixture)

            XCTAssertThrowsError(
                try BlocksNativePluginPackageValidator().validate(
                    directory: package
                )
            ) { error in
                XCTAssertEqual(
                    error as? BlocksNativePluginValidationError,
                    .secureFieldNotSupported("api-token")
                )
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "Secret/Keychain configuration field"
                    )
                )
            }
        }
    }

    func testInstallationConfirmationRoundTripsNewRiskDisclosures()
        throws
    {
        let confirmation = BlocksNativePluginInstallationConfirmation(
            pluginID: "com.example.round-trip",
            displayName: "Round Trip",
            version: "1.0.0",
            packageSHA256: "fixture",
            isSigned: true,
            capabilities: [.translation, .hooks, .ui],
            networkDomains: [],
            networkMethods: [],
            networkMaximumRequestBytes: 12_345,
            secretIDs: [],
            translationContextFields: [.ocrSummary],
            hookEventNames: [.appLaunched],
            uiSlots: [.settingsStatusCard],
            includesBackgroundExecution: true,
            includesBackgroundHookExecution: true,
            includesScheduledExecution: true,
            usesPrivateStorage: true
        )

        let decoded = try JSONDecoder().decode(
            BlocksNativePluginInstallationConfirmation.self,
            from: JSONEncoder().encode(confirmation)
        )

        XCTAssertEqual(decoded, confirmation)
        XCTAssertEqual(decoded.networkMaximumRequestBytes, 12_345)
        XCTAssertTrue(decoded.requiresRiskConfirmation)
    }

    func testSymbolicLinkInsidePackageIsRejected() throws {
        let package = try makePackage(manifest: manifest())
        let externalFile = temporaryRoot.appendingPathComponent("external.js")
        try Data("external".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("linked.js"),
            withDestinationURL: externalFile
        )

        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(directory: package)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .symbolicLinkNotAllowed("linked.js")
            )
        }
    }

    func testTraversalEntryPointIsRejectedBeforeFileLookup() throws {
        let package = try makePackage(
            manifest: manifest(entryPoint: "../outside.js")
        )

        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(directory: package)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .invalidEntryPoint
            )
        }
    }

    func testOversizedPackageIsRejectedWithoutReadingEntry() throws {
        let package = try makePackage(
            manifest: manifest(),
            entrySource: String(repeating: "x", count: 2_048)
        )
        let validator = BlocksNativePluginPackageValidator(
            limits: .init(
                maximumFileCount: 10,
                maximumTotalBytes: 1_024,
                maximumManifestBytes: 1_024,
                maximumEntryPointBytes: 4_096
            )
        )

        XCTAssertThrowsError(try validator.validate(directory: package)) { error in
            guard case .totalSizeExceeded = error as? BlocksNativePluginValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInvalidPermissionsAreRejected() throws {
        let duplicateDomains = manifest(
            permissions: .init(
                network: .init(domains: ["api.example.com", "API.EXAMPLE.COM"])
            )
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(manifest: duplicateDomains)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .duplicateNetworkDomain("API.EXAMPLE.COM")
            )
        }

        let localDomain = manifest(
            permissions: .init(network: .init(domains: ["localhost"]))
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(manifest: localDomain)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .invalidNetworkDomain("localhost")
            )
        }
    }

    func testManifestV1WithoutConfigurationFieldsRemainsCompatible()
        throws
    {
        let data = Data(
            """
            {
              "schema_version": 1,
              "id": "com.example.legacy",
              "display_name": "Legacy",
              "version": "1.0.0",
              "entry_point": "plugin.js",
              "capabilities": ["translation"],
              "permissions": {}
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: data
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.configurationFields.isEmpty)
        XCTAssertEqual(
            decoded.effectiveTranslationAcceptedInputs,
            [.text]
        )
        XCTAssertEqual(
            decoded.effectiveTranslationContextFields,
            [.inputSource]
        )
        XCTAssertFalse(decoded.translationSupportsStatus)
        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: decoded
            )
        )
    }

    func testManifestV2ValidatesDeclarativeConfigurationAndSessionDomains()
        throws
    {
        let valid = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.configured",
            displayName: "Configured",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(
                    domains: ["api.example.com"],
                    methods: [.post]
                ),
                secrets: [
                    .init(
                        id: "session_cookie",
                        displayName: "Session Cookie"
                    ),
                ]
            ),
            configurationFields: [
                .init(
                    id: "base_url",
                    type: .url,
                    title: "Base URL",
                    required: true,
                    defaultValue: .string("https://api.example.com")
                ),
                .init(
                    id: "mode",
                    type: .choice,
                    title: "Mode",
                    defaultValue: .string("fast"),
                    choices: [
                        .init(value: "fast", title: "Fast"),
                        .init(value: "quality", title: "Quality"),
                    ]
                ),
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Signed-in Session",
                    required: true,
                    allowedDomains: ["api.example.com"]
                ),
            ]
        )

        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: valid
            )
        )
        XCTAssertEqual(
            valid.effectiveTranslationAcceptedInputs,
            [.text]
        )
        XCTAssertEqual(
            valid.effectiveTranslationContextFields,
            [.inputSource]
        )
        XCTAssertFalse(valid.translationSupportsStatus)

        let invalidV1 = BlocksNativePluginManifest(
            schemaVersion: 1,
            id: "com.example.invalid",
            displayName: "Invalid",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            configurationFields: [
                .init(
                    id: "mode",
                    type: .text,
                    title: "Mode"
                ),
            ]
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: invalidV1
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .configurationFieldsRequireSchemaV2
            )
        }

        let mismatchedRequirement = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.mismatch",
            displayName: "Mismatch",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                secrets: [
                    .init(
                        id: "api_key",
                        displayName: "API Key",
                        required: true
                    ),
                ]
            ),
            configurationFields: [
                .init(
                    id: "api_key",
                    type: .secret,
                    title: "API Key",
                    required: false
                ),
            ]
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: mismatchedRequirement
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .sensitiveConfigurationRequiredMismatch("api_key")
            )
        }

        let reservedField = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.reserved",
            displayName: "Reserved",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            configurationFields: [
                .init(
                    id: "connection_test",
                    type: .boolean,
                    title: "Connection Test",
                    defaultValue: .bool(false)
                ),
            ]
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: reservedField
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .reservedConfigurationFieldID("connection_test")
            )
        }
    }

    func testManifestV3ValidatesTranslationContractAndScreenshotPermission()
        throws
    {
        let valid = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.image-translation",
            displayName: "Image Translation",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text, .screenshotImage],
                contextFields: [
                    .inputSource,
                    .sourceApplicationBundleID,
                ],
                supportsStatus: true
            ),
            permissions: .init(data: [.screenshotImage])
        )

        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: valid
            )
        )
        XCTAssertEqual(
            valid.effectiveTranslationAcceptedInputs,
            [.text, .screenshotImage]
        )
        XCTAssertTrue(valid.translationSupportsStatus)

        let missingPermission = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.missing-image-permission",
            displayName: "Missing Permission",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.screenshotImage]
            )
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: missingPermission
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .screenshotInputPermissionMismatch
            )
        }

        let legacyExpansion = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.legacy-expansion",
            displayName: "Legacy Expansion",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.screenshotImage],
                supportsStatus: true
            )
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: legacyExpansion
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .translationContractRequiresSchemaV3
            )
        }

        let missingAcceptedInputs = try JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: Data(
                """
                {
                  "schema_version": 3,
                  "id": "com.example.missing-input-contract",
                  "display_name": "Missing Input Contract",
                  "version": "1.0.0",
                  "entry_point": "plugin.js",
                  "capabilities": ["translation"],
                  "translation": {},
                  "permissions": {}
                }
                """.utf8
            )
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: missingAcceptedInputs
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .translationAcceptedInputsMissing
            )
        }
    }

    func testLegacyInstallationConfirmationDecodesNewDisclosureFieldsAsEmpty()
        throws
    {
        let data = Data(
            """
            {
              "pluginID": "com.example.legacy",
              "displayName": "Legacy",
              "version": "1.0.0",
              "packageSHA256": "fixture",
              "isSigned": false,
              "capabilities": ["translation"],
              "networkDomains": [],
              "networkMethods": [],
              "secretIDs": []
            }
            """.utf8
        )

        let confirmation = try JSONDecoder().decode(
            BlocksNativePluginInstallationConfirmation.self,
            from: data
        )

        XCTAssertTrue(confirmation.dataPermissions.isEmpty)
        XCTAssertTrue(
            confirmation.translationAcceptedInputs.isEmpty
        )
        XCTAssertTrue(
            confirmation.translationContextFields.isEmpty
        )
        XCTAssertTrue(confirmation.hookEventNames.isEmpty)
        XCTAssertTrue(confirmation.uiSlots.isEmpty)
        XCTAssertFalse(confirmation.includesBackgroundExecution)
        XCTAssertFalse(confirmation.includesBackgroundHookExecution)
        XCTAssertFalse(confirmation.includesScheduledExecution)
        XCTAssertFalse(confirmation.usesPrivateStorage)
        XCTAssertEqual(
            confirmation.networkMaximumRequestBytes,
            BlocksNativePluginNetworkPermission.defaultMaximumRequestBytes
        )
        XCTAssertTrue(confirmation.requiresRiskConfirmation)
    }

    func testManifestV2RequiresEverySecretDeclarationToHaveOneSensitiveField()
        throws
    {
        let orphanedV2Secret = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.orphaned-secret",
            displayName: "Orphaned Secret",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                secrets: [
                    .init(id: "api_key", displayName: "API Key"),
                ]
            )
        )

        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: orphanedV2Secret
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .secretDeclarationMissingSensitiveConfigurationField(
                    "api_key"
                )
            )
        }

        let compatibleV1Secret = BlocksNativePluginManifest(
            schemaVersion: 1,
            id: "com.example.legacy-secret",
            displayName: "Legacy Secret",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                secrets: [
                    .init(id: "api_key", displayName: "API Key"),
                ]
            )
        )

        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: compatibleV1Secret
            )
        )
    }

    func testConnectionTestConfigurationCannotBeOverriddenByPersistedState() {
        let configuration = BlocksNativePluginHostConfiguration
            .connectionTest(
                persisted: [
                    "connection_test": .bool(false),
                    "mode": .string("fixture"),
                ]
            )

        XCTAssertEqual(configuration["connection_test"], .bool(true))
        XCTAssertEqual(configuration["mode"], .string("fixture"))
    }

    func testOptionalChoiceCanRemoveItsPersistedOverride() {
        let field = BlocksNativePluginConfigurationField(
            id: "tone",
            type: .choice,
            title: "Tone",
            choices: [
                .init(value: "formal", title: "Formal"),
                .init(value: "casual", title: "Casual"),
            ]
        )
        var configuration: [String: JSONValue] = [
            field.id: .string("formal"),
        ]

        XCTAssertTrue(
            TranslationPluginConfigurationChoicePolicy
                .allowsUnset(field)
        )
        TranslationPluginConfigurationChoicePolicy.apply(
            TranslationPluginConfigurationChoicePolicy.unsetValue,
            field: field,
            to: &configuration
        )

        XCTAssertNil(configuration[field.id])
    }

    func testRequiredOrDefaultedChoiceDoesNotExposeUnset() {
        let required = BlocksNativePluginConfigurationField(
            id: "required-tone",
            type: .choice,
            title: "Tone",
            required: true,
            choices: [.init(value: "formal", title: "Formal")]
        )
        let defaulted = BlocksNativePluginConfigurationField(
            id: "default-tone",
            type: .choice,
            title: "Tone",
            defaultValue: .string("formal"),
            choices: [.init(value: "formal", title: "Formal")]
        )

        XCTAssertFalse(
            TranslationPluginConfigurationChoicePolicy
                .allowsUnset(required)
        )
        XCTAssertFalse(
            TranslationPluginConfigurationChoicePolicy
                .allowsUnset(defaulted)
        )
    }

    func testRequiredTextURLAndChoiceConfigurationRejectEmptyNormalizedValues()
        throws
    {
        let suiteName = "BlocksPluginConfiguration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BlocksNativePluginConfigurationStore(defaults: defaults)
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.required-fields",
            displayName: "Required Fields",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            configurationFields: [
                .init(
                    id: "label",
                    type: .text,
                    title: "Label",
                    required: true
                ),
                .init(
                    id: "endpoint",
                    type: .url,
                    title: "Endpoint",
                    required: true
                ),
                .init(
                    id: "mode",
                    type: .choice,
                    title: "Mode",
                    required: true,
                    choices: [
                        .init(value: "", title: "Empty"),
                        .init(value: "normal", title: "Normal"),
                    ]
                ),
            ]
        )

        XCTAssertThrowsError(
            try store.save(
                [
                    "label": .string("   \n"),
                    "endpoint": .string("https://example.com"),
                    "mode": .string("normal"),
                ],
                pluginID: manifest.id,
                manifest: manifest
            )
        )
        XCTAssertThrowsError(
            try store.save(
                [
                    "label": .string("Fixture"),
                    "endpoint": .string("   "),
                    "mode": .string("normal"),
                ],
                pluginID: manifest.id,
                manifest: manifest
            )
        )
        XCTAssertThrowsError(
            try store.save(
                [
                    "label": .string("Fixture"),
                    "endpoint": .string("https://example.com"),
                    "mode": .string(""),
                ],
                pluginID: manifest.id,
                manifest: manifest
            )
        )
    }

    func testConfigurationReadDropsFieldsNotDeclaredByCurrentManifest()
        throws
    {
        let suiteName = "BlocksPluginConfiguration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pluginID = "com.example.configuration-upgrade"
        let key = "translation.plugin.configuration.\(pluginID)"
        defaults.set(
            try JSONEncoder().encode(
                [
                    "legacy_mode": JSONValue.string("stale"),
                    "current": JSONValue.string("kept"),
                ]
            ),
            forKey: key
        )
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: pluginID,
            displayName: "Configuration Upgrade",
            version: "2.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            configurationFields: [
                .init(
                    id: "current",
                    type: .text,
                    title: "Current"
                ),
            ]
        )
        let store = BlocksNativePluginConfigurationStore(defaults: defaults)

        XCTAssertEqual(
            try store.configuration(
                pluginID: pluginID,
                manifest: manifest
            ),
            ["current": .string("kept")]
        )
        XCTAssertThrowsError(
            try store.save(
                ["legacy_mode": .string("must-not-save")],
                pluginID: pluginID,
                manifest: manifest
            )
        )
    }

    func testPluginSecretRejectsValuesOver64KiBBeforeKeychainAccess() {
        let store = BlocksNativePluginSecretStore(
            service: "app.blocks.tests.\(UUID().uuidString)"
        )
        let oversized = String(
            repeating: "x",
            count: BlocksNativePluginSecretStore.maximumValueBytes + 1
        )

        XCTAssertThrowsError(
            try store.save(
                oversized,
                pluginID: "com.example.fixture",
                secretID: "session_cookie"
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginSecretStoreError,
                .valueTooLarge(oversized.utf8.count)
            )
        }
    }

    func testInstallationDisclosureIncludesRequestBodyLimitWithoutSecretValue() {
        let disclosure = PluginInstallationDisclosurePresentation(
            manifest: manifest(
                permissions: .init(
                    network: .init(
                        domains: ["api.example.com"],
                        maximumRequestBytes: 12_345
                    ),
                    secrets: [
                        .init(id: "api_token", displayName: "API Token"),
                    ]
                )
            )
        )

        XCTAssertEqual(disclosure.networkMaximumRequestBytes, 12_345)
        XCTAssertEqual(disclosure.secrets.map(\.displayName), ["API Token"])
        XCTAssertFalse(String(reflecting: disclosure).contains("secret-value"))
    }

    func testNetworkMaximumRequestBytesAcceptsAbsoluteBoundaryOnly() throws {
        let maximum = BlocksNativePluginNetworkPermission
            .absoluteMaximumRequestBytes
        let validator = BlocksNativePluginPackageValidator()

        try validator.validate(
            manifest: manifest(
                permissions: .init(
                    network: .init(
                        domains: ["api.example.com"],
                        maximumRequestBytes: maximum
                    )
                )
            )
        )

        XCTAssertThrowsError(
            try validator.validate(
                manifest: manifest(
                    permissions: .init(
                        network: .init(
                            domains: ["api.example.com"],
                            maximumRequestBytes: maximum + 1
                        )
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginValidationError,
                .invalidMaximumRequestBytes(maximum + 1)
            )
        }
    }

    func testInstallationDisclosureMapsSessionCredentialToItsExactDomains() {
        let disclosure = PluginInstallationDisclosurePresentation(
            manifest: BlocksNativePluginManifest(
                id: "com.example.session-disclosure",
                displayName: "Session Disclosure",
                version: "1.0.0",
                entryPoint: "plugin.js",
                capabilities: [.translation],
                permissions: .init(
                    network: .init(
                        domains: ["api.example.com", "AUTH.EXAMPLE.COM"]
                    ),
                    secrets: [
                        .init(
                            id: "session_cookie",
                            displayName: "Session Cookie"
                        ),
                    ]
                ),
                configurationFields: [
                    .init(
                        id: "session_cookie",
                        type: .sessionCredential,
                        title: "Session Cookie",
                        required: true,
                        allowedDomains: ["AUTH.EXAMPLE.COM"]
                    ),
                ]
            )
        )

        XCTAssertEqual(
            disclosure.secrets,
            [
                .init(
                    id: "session_cookie",
                    displayName: "Session Cookie",
                    required: true,
                    isSessionCredential: true,
                    allowedDomains: ["auth.example.com"]
                ),
            ]
        )
        let visibleDisclosure = disclosure.secrets[0].localizedDisclosureText
        XCTAssertTrue(visibleDisclosure.contains("auth.example.com"))
        XCTAssertFalse(visibleDisclosure.contains("api.example.com"))
        XCTAssertFalse(visibleDisclosure.contains("secret-value"))
    }

    private func makePackage(
        name: String = "Fixture.blocksplugin",
        manifest: BlocksNativePluginManifest,
        entrySource: String = "function translate(input) { return input.text; }"
    ) throws -> URL {
        let package = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: package.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data(entrySource.utf8).write(
            to: package.appendingPathComponent("plugin.js"),
            options: .atomic
        )
        return package
    }

    private func manifest(
        entryPoint: String = "plugin.js",
        permissions: BlocksNativePluginPermissions = .init()
    ) -> BlocksNativePluginManifest {
        BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.2.3",
            entryPoint: entryPoint,
            capabilities: [.translation],
            permissions: permissions,
            configurationFields: permissions.secrets.map {
                .init(
                    id: $0.id,
                    type: .secret,
                    title: $0.displayName,
                    required: $0.required
                )
            }
        )
    }
}

final class BlocksNativePluginNetworkPolicyTests: XCTestCase {
    func testExactAndWildcardDomainsAreValidatedWithoutLeakingSecrets() throws {
        let manifest = makeManifest(
            domains: ["api.example.com", "*.service.example.org"],
            secretIDs: ["api_key"]
        )
        let request = BlocksNativePluginNetworkRequest(
            url: "https://v1.service.example.org/translate",
            method: .post,
            headers: ["Authorization": "Bearer {{secret:api_key}}"],
            body: Data(#"{"text":"hello"}"#.utf8)
        )

        let validated = try BlocksNativePluginNetworkPolicy().validate(
            request,
            manifest: manifest
        )

        XCTAssertEqual(validated.url.host, "v1.service.example.org")
        XCTAssertEqual(validated.referencedSecretIDs, ["api_key"])
        XCTAssertEqual(
            request.headers["Authorization"],
            "Bearer {{secret:api_key}}"
        )
    }

    func testUndeclaredSecretAndMalformedSecretAreRejected() {
        let manifest = makeManifest(domains: ["api.example.com"], secretIDs: ["api_key"])
        let undeclared = BlocksNativePluginNetworkRequest(
            url: "https://api.example.com/translate",
            method: .post,
            headers: ["Authorization": "Bearer {{secret:other}}"]
        )
        XCTAssertThrowsError(
            try BlocksNativePluginNetworkPolicy().validate(undeclared, manifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginNetworkPolicyError,
                .secretNotDeclared("other")
            )
        }

        let malformed = BlocksNativePluginNetworkRequest(
            url: "https://api.example.com/translate",
            method: .post,
            headers: ["Authorization": "{{secret:api_key"]
        )
        XCTAssertThrowsError(
            try BlocksNativePluginNetworkPolicy().validate(malformed, manifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginNetworkPolicyError,
                .malformedSecretReference
            )
        }
    }

    func testNetworkURLBytesAreBoundedBeforeBridgeEnvelope() throws {
        let manifest = makeManifest(domains: ["api.example.com"])
        let maximum = BlocksNativePluginNetworkPolicy.maximumURLBytes
        let prefix = "https://api.example.com/"
        let exactURL = prefix + String(
            repeating: "a",
            count: maximum - prefix.utf8.count
        )

        XCTAssertNoThrow(
            try BlocksNativePluginNetworkPolicy().validate(
                .init(url: exactURL, method: .post),
                manifest: manifest
            )
        )

        let oversizedURL = exactURL + "a"
        XCTAssertThrowsError(
            try BlocksNativePluginNetworkPolicy().validate(
                .init(url: oversizedURL, method: .post),
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginNetworkPolicyError,
                .urlTooLarge(maximum + 1)
            )
        }
    }

    func testHTTPPrivateTargetsMethodsAndRestrictedHeadersAreRejected() {
        let manifest = makeManifest(domains: ["api.example.com"])
        let policy = BlocksNativePluginNetworkPolicy()
        let requests: [(BlocksNativePluginNetworkRequest, BlocksNativePluginNetworkPolicyError)] = [
            (
                .init(url: "http://api.example.com", method: .post),
                .insecureScheme
            ),
            (
                .init(url: "https://127.0.0.1", method: .post),
                .privateOrLocalHost
            ),
            (
                .init(url: "https://api.example.com", method: .delete),
                .methodNotAllowed("DELETE")
            ),
            (
                .init(
                    url: "https://api.example.com",
                    method: .post,
                    headers: ["Host": "attacker.example"]
                ),
                .restrictedHeader("Host")
            ),
        ]

        for (request, expectedError) in requests {
            XCTAssertThrowsError(try policy.validate(request, manifest: manifest)) { error in
                XCTAssertEqual(error as? BlocksNativePluginNetworkPolicyError, expectedError)
            }
        }
    }

    func testSessionCredentialCanOnlyReachItsExactDeclaredDomains()
        throws
    {
        let manifest = BlocksNativePluginManifest(
            id: "com.example.session",
            displayName: "Session",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(
                    domains: [
                        "api.example.com",
                        "other.example.com",
                    ],
                    methods: [.post]
                ),
                secrets: [
                    .init(
                        id: "session_cookie",
                        displayName: "Session Cookie"
                    ),
                ]
            ),
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Signed-in Session",
                    required: true,
                    allowedDomains: ["api.example.com"]
                ),
            ]
        )
        try BlocksNativePluginPackageValidator().validate(
            manifest: manifest
        )
        let request = BlocksNativePluginNetworkRequest(
            url: "https://other.example.com/translate",
            method: .post,
            headers: [
                "Cookie": "{{secret:session_cookie}}",
            ]
        )

        XCTAssertThrowsError(
            try BlocksNativePluginNetworkPolicy().validate(
                request,
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginNetworkPolicyError,
                .sessionCredentialDomainNotAllowed(
                    credentialID: "session_cookie",
                    domain: "other.example.com"
                )
            )
        }
    }

    private func makeManifest(
        domains: [String],
        secretIDs: [String] = []
    ) -> BlocksNativePluginManifest {
        BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(domains: domains, methods: [.post]),
                secrets: secretIDs.map {
                    .init(id: $0, displayName: $0)
                }
            )
        )
    }
}

final class BlocksNativePluginMetadataRepositoryTests: XCTestCase {
    func testPendingPluginCannotEnableUntilExactPackageIsApproved() throws {
        let fixture = try makeRepository()
        defer { fixture.database.close() }
        let package = try makeValidatedPackage(hash: String(repeating: "a", count: 64))

        let pending = try fixture.repository.installPending(
            package: package,
            installedRelativePath: "com.example.fixture/1.0.0"
        )
        XCTAssertEqual(pending.approvalStatus, .pending)
        XCTAssertFalse(pending.isEnabled)
        XCTAssertThrowsError(
            try fixture.repository.setEnabled(true, pluginID: pending.id)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginMetadataRepositoryError,
                .approvalRequired
            )
        }

        let approved = try fixture.repository.approve(
            pluginID: pending.id,
            expectedPackageHash: pending.packageHash,
            permissions: ["network", "secret:api_key"],
            domains: ["API.EXAMPLE.COM"]
        )
        let enabled = try fixture.repository.setEnabled(true, pluginID: pending.id)

        XCTAssertEqual(approved.approvalStatus, .approved)
        XCTAssertEqual(approved.approvedDomains, ["api.example.com"])
        XCTAssertTrue(enabled.isEnabled)
    }

    func testPackageHashChangeRevokesApprovalAndDisablesPlugin() throws {
        let fixture = try makeRepository()
        defer { fixture.database.close() }
        let original = try makeValidatedPackage(hash: String(repeating: "a", count: 64))
        _ = try fixture.repository.installPending(
            package: original,
            installedRelativePath: "com.example.fixture/1.0.0"
        )
        _ = try fixture.repository.approve(
            pluginID: original.manifest.id,
            expectedPackageHash: original.packageSHA256,
            permissions: ["network"],
            domains: ["api.example.com"]
        )
        _ = try fixture.repository.setEnabled(
            true,
            pluginID: original.manifest.id
        )

        let changed = try makeValidatedPackage(hash: String(repeating: "b", count: 64))
        let reinstalled = try fixture.repository.installPending(
            package: changed,
            installedRelativePath: "com.example.fixture/1.0.1"
        )

        XCTAssertEqual(reinstalled.approvalStatus, .pending)
        XCTAssertFalse(reinstalled.isEnabled)
        XCTAssertTrue(reinstalled.approvedPermissions.isEmpty)
        XCTAssertTrue(reinstalled.approvedDomains.isEmpty)
    }

    func testApprovalCannotGrantPermissionsOutsideValidatedManifest() throws {
        let fixture = try makeRepository()
        defer { fixture.database.close() }
        let package = try makeValidatedPackage(hash: String(repeating: "a", count: 64))
        _ = try fixture.repository.installPending(
            package: package,
            installedRelativePath: "com.example.fixture/1.0.0"
        )

        XCTAssertThrowsError(
            try fixture.repository.approve(
                pluginID: package.manifest.id,
                expectedPackageHash: package.packageSHA256,
                permissions: ["network", "secret:not_declared"],
                domains: ["api.example.com"]
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginMetadataRepositoryError,
                .approvalExceedsManifest
            )
        }
        XCTAssertThrowsError(
            try fixture.repository.approve(
                pluginID: package.manifest.id,
                expectedPackageHash: package.packageSHA256,
                permissions: ["network"],
                domains: ["evil.example"]
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginMetadataRepositoryError,
                .approvalExceedsManifest
            )
        }
    }

    func testInstallApprovedRollsBackMetadataWhenApprovalFails() throws {
        let fixture = try makeRepository()
        defer { fixture.database.close() }
        let package = try makeValidatedPackage(hash: String(repeating: "c", count: 64))

        XCTAssertThrowsError(
            try fixture.repository.installApproved(
                package: package,
                installedRelativePath: "fixture/\(package.packageSHA256)",
                permissions: ["secret:not_declared"],
                domains: [],
                now: Date(timeIntervalSince1970: 10)
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginMetadataRepositoryError,
                .approvalExceedsManifest
            )
        }
        XCTAssertThrowsError(
            try fixture.repository.metadata(id: package.manifest.id)
        ) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginMetadataRepositoryError,
                .pluginNotFound(package.manifest.id)
            )
        }
    }

    private func makeRepository() throws -> (
        database: AppDatabase,
        repository: BlocksNativePluginMetadataRepository
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksPluginMetadata-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        return (database, BlocksNativePluginMetadataRepository(database: database))
    }

    private func makeValidatedPackage(
        hash: String
    ) throws -> BlocksNativePluginValidatedPackage {
        let manifest = BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: hash.first == "a" ? "1.0.0" : "1.0.1",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(domains: ["api.example.com"]),
                secrets: [.init(id: "api_key", displayName: "API Key")]
            ),
            configurationFields: [
                .init(
                    id: "api_key",
                    type: .secret,
                    title: "API Key",
                    required: true
                ),
            ]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        return BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: manifestData,
            entrySource: "function translate(input) { return input.text; }",
            packageSHA256: hash,
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: hash,
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: ["api.example.com"],
                networkMethods: [.post],
                secretIDs: ["api_key"]
            )
        )
    }
}

final class BlocksPluginPlatformContractTests: XCTestCase {
    private let safeModePreferenceKey = "blocks.plugins.safeMode"
    private var previousSafeModePreference: Any?

    override func setUp() async throws {
        try await super.setUp()
        previousSafeModePreference = UserDefaults.standard.object(
            forKey: safeModePreferenceKey
        )
        UserDefaults.standard.set(false, forKey: safeModePreferenceKey)
    }

    override func tearDown() async throws {
        if let previousSafeModePreference {
            UserDefaults.standard.set(
                previousSafeModePreference,
                forKey: safeModePreferenceKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: safeModePreferenceKey)
        }
        previousSafeModePreference = nil
        try await super.tearDown()
    }

    func testPluginUIActionSnapshotIncludesDefaultsRuntimeAndLocalValues() {
        let root = BlocksPluginUIComponent(
            id: "page",
            kind: .page,
            children: [
                .init(
                    id: "name",
                    kind: .textField,
                    properties: ["value": .string("default")]
                ),
                .init(
                    id: "enabled",
                    kind: .toggle,
                    properties: ["value": .bool(false)]
                ),
            ]
        )
        let snapshot = BlocksPluginUIStateSnapshot.make(
            root: root,
            runtimeState: [
                "enabled": ["value": .bool(true)],
            ],
            localState: [
                "name": ["value": .string("edited")],
            ]
        )

        guard case let .object(name)? = snapshot["name"],
              case let .object(enabled)? = snapshot["enabled"] else {
            return XCTFail("Expected complete component snapshots")
        }
        XCTAssertEqual(name["value"], .string("edited"))
        XCTAssertEqual(enabled["value"], .bool(true))
        XCTAssertNotNil(snapshot["page"])
    }

    func testManifestV4SeparatesHostExportedAndImportedActions() throws {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.platform",
            displayName: "Platform",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks, .actions],
            permissions: .init(data: [.clipboardContent]),
            platform: .init(
                hooks: [
                    .init(
                        id: "tag-paste",
                        event: .clipboardWillWritePasteboard,
                        entryFunction: "handleHook"
                    ),
                ],
                hostActions: ["clipboard.tag.ensure_and_attach"],
                actions: [
                    .init(
                        id: "normalize",
                        displayName: "Normalize",
                        entryFunction: "normalize"
                    ),
                ],
                importedActions: [
                    .init(
                        pluginID: "com.example.producer",
                        actionID: "lookup"
                    ),
                ],
                storage: .init(kinds: [.keyValue]),
                sharedState: [
                    .init(id: "legacy-shared-data", access: .read),
                ]
            )
        )

        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: manifest
            )
        )
        let decoded = try JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        XCTAssertEqual(
            decoded.platform?.hostActions,
            ["clipboard.tag.ensure_and_attach"]
        )
        XCTAssertEqual(decoded.platform?.actions.map(\.id), ["normalize"])
        XCTAssertEqual(
            decoded.platform?.importedActions,
            [.init(pluginID: "com.example.producer", actionID: "lookup")]
        )
        XCTAssertNil(decoded.platform?.sharedState.first?.displayName)
    }

    func testSharedNamespaceDisplayNameIsOptionalAndPresentationOnly() throws {
        let oldJSON = Data(
            #"{"id":"old-scope","access":"read"}"#.utf8
        )
        let oldDeclaration = try JSONDecoder().decode(
            BlocksPluginSharedNamespaceDeclaration.self,
            from: oldJSON
        )
        XCTAssertNil(oldDeclaration.displayName)

        let named = BlocksPluginSharedNamespaceDeclaration(
            id: "recent-items",
            displayName: "Recent items",
            ownerPluginID: "com.example.owner",
            access: .read
        )
        let decoded = try JSONDecoder().decode(
            BlocksPluginSharedNamespaceDeclaration.self,
            from: JSONEncoder().encode(named)
        )
        XCTAssertEqual(decoded.displayName, "Recent items")
        XCTAssertEqual(decoded.id, "recent-items")
        XCTAssertEqual(decoded.ownerPluginID, "com.example.owner")
    }

    func testSharedNamespaceDisplayNameRejectsUnsafeOrInvalidPresentationText() {
        let validator = BlocksNativePluginPackageValidator()
        for displayName in ["   ", String(repeating: "a", count: 81), "bad\u{202E}name"] {
            let manifest = BlocksNativePluginManifest(
                schemaVersion: 4,
                id: "com.example.shared-display-name",
                displayName: "Shared display name",
                version: "1.0.0",
                entryPoint: "plugin.js",
                capabilities: [.actions],
                platform: .init(sharedState: [
                    .init(
                        id: "shared-data",
                        displayName: displayName,
                        access: .read
                    ),
                ])
            )
            XCTAssertThrowsError(try validator.validate(manifest: manifest))
        }
    }

    func testManifestV4RejectsHostActionsOutsideVersionedRegistry() {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.unknown-host-action",
            displayName: "Unknown Host Action",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init(hostActions: ["system.arbitrary_shell"])
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: manifest
            )
        )
    }

    func testManifestV5NegotiatesHostAPIV2AndRejectsFutureAPI() throws {
        let supported = BlocksNativePluginManifest(
            schemaVersion: 5,
            minimumHostAPIVersion: 2,
            id: "com.example.color-sample",
            displayName: "Color Sample",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["screenshot.color_sample.begin"]
            )
        )
        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: supported
            )
        )

        let future = BlocksNativePluginManifest(
            schemaVersion: 5,
            minimumHostAPIVersion: 3,
            id: "com.example.future-host",
            displayName: "Future Host",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init()
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: future
            )
        )
    }

    func testManifestV6RequiresUserPresentationAndAcceptsTypedDefaults()
        throws
    {
        let presentation = BlocksNativePluginPresentation(
            summary: "Keeps the setting understandable.",
            purpose: "Explains the user benefit without implementation terms.",
            trigger: "Runs when the selected event occurs.",
            examples: ["A short user-facing example."],
            dataUsage: "Uses only the approved event data.",
            localizations: [
                "zh-Hans": .init(
                    name: "示例插件",
                    summary: "用普通用户能理解的方式说明插件。",
                    purpose: "解释用户收益。",
                    trigger: "在已选择的事件发生时运行。",
                    examples: ["展示一个简短示例。"],
                    dataUsage: "只使用已授权的事件数据。"
                ),
            ]
        )
        let valid = BlocksNativePluginManifest(
            schemaVersion: 6,
            minimumHostAPIVersion: 2,
            id: "com.example.presentation",
            displayName: "Presentation",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            configurationFields: [
                .init(
                    id: "hour",
                    type: .number,
                    title: "Hour",
                    defaultValue: .int(9)
                ),
                .init(
                    id: "modes",
                    type: .multipleChoice,
                    title: "Modes",
                    defaultValue: .array([.string("first")]),
                    choices: [
                        .init(value: "first", title: "First"),
                        .init(value: "second", title: "Second"),
                    ]
                ),
            ],
            presentation: presentation,
            platform: .init()
        )
        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(manifest: valid)
        )
        XCTAssertEqual(
            presentation.localized(
                fallbackName: "Presentation",
                locale: Locale(identifier: "zh_CN")
            ).name,
            "示例插件"
        )
        let localizedComponent = BlocksPluginUIComponent(
            id: "status",
            kind: .status,
            title: "Status",
            properties: ["value": .string("Waiting")],
            localizations: [
                "zh-Hans": .init(
                    title: "状态",
                    text: "等待处理"
                ),
            ]
        )
        XCTAssertEqual(
            localizedComponent.localized(
                locale: Locale(identifier: "zh_CN")
            ).title,
            "状态"
        )
        XCTAssertEqual(
            localizedComponent.localized(
                locale: Locale(identifier: "zh_CN")
            ).text,
            "等待处理"
        )

        let missingPresentation = BlocksNativePluginManifest(
            schemaVersion: 6,
            id: "com.example.missing-presentation",
            displayName: "Missing Presentation",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init()
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: missingPresentation
            )
        )
    }

    func testBuiltInCatalogContainsEightIndependentValidatedPackages() throws {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        let document = catalog.document

        XCTAssertEqual(document.entries.count, 8)
        XCTAssertEqual(Set(document.entries.map(\.id)).count, 8)
        for entry in document.entries {
            XCTAssertTrue(entry.id.hasPrefix("com.blocks.builtin."))
            XCTAssertFalse(entry.packageSHA256.isEmpty)
            let package = try catalog.validatedPackage(for: entry)
            XCTAssertEqual(package.manifest.id, entry.id)
            XCTAssertEqual(package.manifest.version, entry.version)
            XCTAssertEqual(package.packageSHA256, entry.packageSHA256)
            XCTAssertNil(package.manifest.permissions.network)
            XCTAssertTrue(package.manifest.permissions.secrets.isEmpty)
        }
    }

    func testBuiltInCatalogRejectsEntryWithMissingPackageHash() throws {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        let entry = try XCTUnwrap(catalog.document.entries.first)
        let missingHashEntry = BlocksBuiltInPluginCatalogEntry(
            id: entry.id,
            version: entry.version,
            category: entry.category,
            symbolName: entry.symbolName,
            packageDirectory: entry.packageDirectory,
            packageSHA256: "",
            localizations: entry.localizations
        )

        XCTAssertThrowsError(
            try catalog.validatedPackage(for: missingHashEntry)
        ) { error in
            guard case let .hashMismatch(expected, _) =
                error as? BlocksBuiltInPluginCatalogError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "")
        }
        XCTAssertNoThrow(try catalog.validatedPackage(for: entry))
    }

    func testRealClipboardCaptureContractFeedsOfficialPluginRuntime()
        async throws
    {
        let record = ClipboardRecorderRecord(
            id: "capture-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .url,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.url"],
                textLength: 42,
                urlCount: 1
            ),
            sourceApp: .init(
                bundleIdentifier: "com.example.source",
                localizedName: "Fixture"
            ),
            signatureSHA256_12: "0123456789ab",
            fixtureOwned: true,
            restorable: true,
            summary: "Example URL"
        )
        let sourcePayload = ClipboardRecorderPayload(
            recordID: record.id,
            kind: .url,
            urlString: "https://example.com/?utm_source=fixture"
        )
        let contract = await ClipboardPluginEventContract.contentInput(
            record: record,
            payload: sourcePayload,
            stageTextResource: { text, kind, mediaType, metadata in
                BlocksPluginResourceReference(
                    id: "content-resource",
                    kind: kind,
                    mediaType: mediaType,
                    byteCount: Int64(text.utf8.count),
                    metadata: metadata
                )
            }
        )
        XCTAssertEqual(contract.payload["kind"], .string("url"))
        XCTAssertEqual(
            contract.payload["text"],
            .string("https://example.com/?utm_source=fixture")
        )
        XCTAssertEqual(contract.resources.map(\.id), ["content-resource"])

        let catalog = try BlocksBuiltInPluginCatalog.load()
        let entry = try XCTUnwrap(
            catalog.document.entries.first {
                $0.id == "com.blocks.builtin.smart-tagger"
            }
        )
        let package = try catalog.validatedPackage(for: entry)
        let response = BlocksNativePluginJavaScriptRunner(
            networkBroker: { request in
                .init(
                    requestID: request.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data()
                )
            }
        ).executePlatform(.init(
            manifest: package.manifest,
            entrySource: package.entrySource,
            invocation: .init(
                pluginID: package.manifest.id,
                kind: .hook,
                entryFunction: "classifyCapture",
                event: .init(
                    name: .clipboardDidPersistCapture,
                    sessionID: record.id,
                    payload: contract.payload,
                    resources: contract.resources
                )
            ),
            executionTimeLimitSeconds: 1
        ))
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(
            response.result?.hook?.actions.first?.actionID,
            "clipboard.tag.ensure_and_attach"
        )
    }

    func testOfficialBuiltInsExecuteRepresentativeFlowsThroughGenericRuntime()
        throws
    {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        let document = catalog.document
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { request in
                BlocksNativePluginNetworkResponse(
                    requestID: request.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data()
                )
            },
            hostOperationBroker: { request in
                let value: JSONValue
                switch request.operation {
                case "storage.get", "storage.queue.dequeue":
                    value = .null
                case "storage.put", "storage.queue.enqueue":
                    value = .object([
                        "value": request.input["value"] ?? .null,
                        "revision": .int(1),
                    ])
                default:
                    return .init(
                        requestID: request.requestID,
                        ok: false,
                        errorCode: "unexpected_operation",
                        errorMessage: request.operation
                    )
                }
                return .init(
                    requestID: request.requestID,
                    ok: true,
                    value: value
                )
            }
        )

        func package(_ id: String) throws -> BlocksNativePluginValidatedPackage {
            let entry = try XCTUnwrap(
                document.entries.first { $0.id == id }
            )
            return try catalog.validatedPackage(for: entry)
        }

        func runHook(
            _ id: String,
            function: String,
            event: BlocksPluginEventEnvelope,
            configuration: [String: JSONValue] = [:]
        ) throws -> BlocksPluginHookResult {
            let validated = try package(id)
            let response = runner.executePlatform(
                BlocksPluginRunnerRequest(
                    manifest: validated.manifest,
                    entrySource: validated.entrySource,
                    invocation: .init(
                        pluginID: id,
                        kind: .hook,
                        entryFunction: function,
                        event: event,
                        configuration: configuration
                    ),
                    executionTimeLimitSeconds: 1
                )
            )
            XCTAssertEqual(
                response.status,
                .completed,
                response.errorMessage ?? "Unexpected plugin runtime status"
            )
            return try XCTUnwrap(response.result?.hook)
        }

        let clipboardCapture = BlocksPluginEventEnvelope(
            name: .clipboardDidPersistCapture,
            payload: [
                "record_id": .string("record-1"),
                "text": .string("https://example.com/?utm_source=test"),
            ]
        )
        let smartTagger = try runHook(
            "com.blocks.builtin.smart-tagger",
            function: "classifyCapture",
            event: clipboardCapture
        )
        XCTAssertEqual(
            smartTagger.actions.first?.actionID,
            "clipboard.tag.ensure_and_attach"
        )

        let cleaner = try runHook(
            "com.blocks.builtin.paste-cleaner",
            function: "cleanPaste",
            event: .init(
                name: .clipboardWillWritePasteboard,
                payload: ["text": .string("  first\r\n\r\n\r\nsecond  ")]
            ),
            configuration: [
                "trim_outer_whitespace": .bool(true),
                "normalize_line_breaks": .bool(true),
                "collapse_blank_lines": .bool(true),
            ]
        )
        XCTAssertEqual(cleaner.mutations.first?.value, .string("first\n\nsecond"))

        let imageCleaner = try runHook(
            "com.blocks.builtin.paste-cleaner",
            function: "cleanPaste",
            event: .init(
                name: .clipboardWillWritePasteboard,
                payload: ["kind": .string("image")]
            ),
            configuration: [
                "trim_outer_whitespace": .bool(true),
                "normalize_line_breaks": .bool(true),
            ]
        )
        XCTAssertTrue(imageCleaner.mutations.isEmpty)

        let organizer = try runHook(
            "com.blocks.builtin.link-organizer",
            function: "organizeLink",
            event: .init(
                name: .clipboardWillWritePasteboard,
                payload: [
                    "text": .string(
                        "https://example.com/path?utm_source=test&keep=1#part"
                    ),
                ]
            )
        )
        XCTAssertEqual(
            organizer.mutations.first?.value,
            .string("https://example.com/path?keep=1#part")
        )

        let radar = try runHook(
            "com.blocks.builtin.content-radar",
            function: "inspectCapture",
            event: .init(
                name: .clipboardDidPersistCapture,
                payload: ["text": .string("550e8400-e29b-41d4-a716-446655440000")]
            )
        )
        XCTAssertEqual(radar.uiStatePatches.first?.value, .string("UUID"))

        let screenshotOCR = try runHook(
            "com.blocks.builtin.screenshot-ocr",
            function: "afterScreenshot",
            event: .init(
                name: .screenshotOutputFinished,
                resources: [
                    .init(
                        id: "screenshot-1",
                        kind: .screenshot,
                        mediaType: "image/png",
                        byteCount: 128
                    ),
                ]
            )
        )
        XCTAssertEqual(screenshotOCR.actions.first?.actionID, "screenshot.ocr")

        let terminology = try runHook(
            "com.blocks.builtin.terminology-guard",
            function: "enforceTerms",
            event: .init(
                name: .translationWillCommitResult,
                payload: ["translated_text": .string("Use Blocks every day")]
            ),
            configuration: [
                "glossary": .string("Blocks=积木工具"),
                "case_sensitive": .bool(false),
            ]
        )
        XCTAssertEqual(
            terminology.mutations.first?.value,
            .string("Use 积木工具 every day")
        )

        let cards = try runHook(
            "com.blocks.builtin.word-cards",
            function: "captureFavorite",
            event: .init(
                name: .translationFavoriteChanged,
                payload: [
                    "favorite_id": .string("favorite-1"),
                    "is_favorite": .bool(true),
                ]
            )
        )
        XCTAssertEqual(cards.uiStatePatches.count, 2)

        let colors = try runHook(
            "com.blocks.builtin.color-collector",
            function: "collectColor",
            event: .init(
                name: .clipboardDidPersistCapture,
                payload: ["text": .string("#FF00AA")]
            )
        )
        XCTAssertEqual(colors.uiStatePatches.first?.value, .string("#FF00AA"))
    }

    func testManifestV4AcceptsControlledProviderRequestAndRejectsLegacyMock()
        throws
    {
        let controlled = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.provider-request",
            displayName: "Provider Request",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init(hostActions: ["provider.request"])
        )
        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: controlled
            )
        )

        let legacyMock = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.provider-mock",
            displayName: "Provider Mock",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init(hostActions: ["provider.request.mock"])
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: legacyMock
            )
        )
    }

    @MainActor
    func testProviderRequestRejectsScheduledInvocationOrigin() async {
        let model = AppModel()

        do {
            _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(
                    actionID: "provider.request",
                    input: ["operation": .string("connection_test")]
                ),
                context: .init(
                    requestingPluginID: "com.example.scheduled-provider",
                    causationID: UUID(),
                    origin: .scheduled
                )
            )
            XCTFail("Scheduled plugin work must not be treated as user initiated.")
        } catch let error as BlocksPluginRuntimeError {
            guard case let .invalidHostOperation(reason) = error else {
                return XCTFail("Unexpected runtime error: \(error)")
            }
            XCTAssertEqual(
                reason,
                "provider.request.requires_user_initiated"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testClipboardPasteRecordRejectsScheduledAndBackgroundOriginsBeforePaste()
        async
    {
        let model = AppModel()

        for origin in [
            BlocksPluginHostInvocationOrigin.scheduled,
            .background,
        ] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(
                        actionID: "clipboard.paste_record",
                        input: ["record_id": .string("missing-record")]
                    ),
                    context: .init(
                        requestingPluginID: "com.example.noninteractive-paste",
                        causationID: UUID(),
                        origin: origin
                    )
                )
                XCTFail("Non-user plugin work must not start a paste.")
            } catch let error as BlocksPluginRuntimeError {
                guard case let .invalidHostOperation(reason) = error else {
                    return XCTFail("Unexpected runtime error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "clipboard.paste_record.requires_user_initiated"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNil(model.clipboardCoordinator.pasteTask)
        XCTAssertNil(model.clipboardCoordinator.pendingPasteRequest)
    }

    @MainActor
    func testClipboardCopyTextRejectsScheduledAndBackgroundOriginsBeforeCopy()
        async
    {
        let model = AppModel(
            clipboardStore: ClipboardStore(repository: nil)
        )

        for origin in [
            BlocksPluginHostInvocationOrigin.scheduled,
            .background,
        ] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(
                        actionID: "clipboard.copy_text",
                        input: ["text": .string("must not be copied")]
                    ),
                    context: .init(
                        requestingPluginID: "com.example.noninteractive-copy",
                        causationID: UUID(),
                        origin: origin
                    )
                )
                XCTFail("Non-user plugin work must not copy text.")
            } catch let error as BlocksPluginRuntimeError {
                guard case let .invalidHostOperation(reason) = error else {
                    return XCTFail("Unexpected runtime error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "clipboard.copy_text.requires_user_initiated"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(model.clipboardStore.records.isEmpty)
        XCTAssertNil(model.clipboardCoordinator.pasteTask)
        XCTAssertNil(model.clipboardCoordinator.pendingPasteRequest)
    }

    @MainActor
    func testClipboardRecordDeleteRequiresDestructiveConfirmationAndRevision()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginRecordDeleteOrigin-\(UUID().uuidString)",
            isDirectory: true
        )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-delete-origin-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "deleteorigin",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )
        let model = AppModel(
            clipboardStore: ClipboardStore(repository: repository)
        )

        for origin in [
            BlocksPluginHostInvocationOrigin.background,
            .scheduled,
            .explicitUser,
            .hostConfirmedExplicitUser,
            .commandLine(destructiveActionConfirmed: false),
            .commandLine(destructiveActionConfirmed: true),
        ] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(
                        actionID: "clipboard.record.delete",
                        input: [
                            "record_id": .string(record.id),
                            "confirmed": .bool(true),
                        ]
                    ),
                    context: .init(
                        requestingPluginID: "com.example.noninteractive-delete",
                        causationID: UUID(),
                        origin: origin
                    )
                )
                XCTFail("Non-user plugin work must not delete clipboard history.")
            } catch let error as BlocksPluginRuntimeError {
                guard case let .invalidHostOperation(reason) = error else {
                    return XCTFail("Unexpected runtime error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "destructive_host_action_capability_required"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertNotNil(try repository.loadRecord(recordID: record.id))
            XCTAssertNotNil(try repository.readPayload(recordID: record.id))
        }

        for expectedRevision in [nil, 0, -1, 1, 2] as [Int64?] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(
                        actionID: "clipboard.record.delete",
                        input: ["record_id": .string(record.id)],
                        expectedRevision: expectedRevision
                    ),
                    context: .init(
                        requestingPluginID: "com.example.invalid-revision-delete",
                        causationID: UUID(),
                        origin: .hostConfirmedExplicitUser
                    )
                )
                XCTFail("Invalid or stale revisions must not delete a record.")
            } catch {
                guard case let .invalidHostOperation(reason) =
                    error as? BlocksPluginRuntimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(reason, "destructive_host_action_capability_required")
            }
            XCTAssertNotNil(try repository.loadRecord(recordID: record.id))
            XCTAssertNotNil(try repository.readPayload(recordID: record.id))
            XCTAssertEqual(
                try repository.search("original", limit: 10).map(\.id),
                [record.id]
            )
        }

        XCTAssertNotNil(try repository.loadRecord(recordID: record.id))
        XCTAssertNotNil(try repository.readPayload(recordID: record.id))
        XCTAssertEqual(try repository.search("original", limit: 10).map(\.id), [record.id])
    }

    @MainActor
    func testSystemShortcutExecuteRejectsScheduledAndBackgroundOriginsBeforeExecution()
        async
    {
        let model = AppModel()

        for origin in [
            BlocksPluginHostInvocationOrigin.scheduled,
            .background,
        ] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(
                        actionID: "system.shortcut.execute",
                        input: [
                            "command": .string(
                                ShortcutCommand.screenshotSmart.rawValue
                            ),
                        ]
                    ),
                    context: .init(
                        requestingPluginID: "com.example.noninteractive-shortcut",
                        causationID: UUID(),
                        origin: origin
                    )
                )
                XCTFail("Non-user plugin work must not execute a shortcut.")
            } catch let error as BlocksPluginRuntimeError {
                guard case let .invalidHostOperation(reason) = error else {
                    return XCTFail("Unexpected runtime error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "system.shortcut.execute.requires_user_initiated"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testScreenshotCaptureStartRejectsScheduledAndBackgroundOriginsBeforeCapture()
        async
    {
        let captureService = ScreenshotCaptureStartProbe()
        let screenshotStore = ScreenshotStore(
            captureService: captureService,
            permissionRefresher: {},
            permissionSnapshotProvider: {
                fatalError("A non-user plugin invocation must not reach capture preflight.")
            }
        )
        let model = AppModel(screenshotStore: screenshotStore)

        for origin in [
            BlocksPluginHostInvocationOrigin.scheduled,
            .background,
        ] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(actionID: "screenshot.capture.start"),
                    context: .init(
                        requestingPluginID: "com.example.noninteractive-capture",
                        causationID: UUID(),
                        origin: origin
                    )
                )
                XCTFail("Non-user plugin work must not start screenshot capture.")
            } catch let error as BlocksPluginRuntimeError {
                guard case let .invalidHostOperation(reason) = error else {
                    return XCTFail("Unexpected runtime error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "screenshot.capture.start.requires_user_initiated"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(captureService.captureCount, 0)
    }

    @MainActor
    func testScreenshotColorSampleRejectsScheduledAndBackgroundOriginsBeforeSamplerStart()
        async
    {
        let samplerProbe = ScreenshotColorSampleStartProbe()
        let coordinator = ScreenshotColorSampleCoordinator(
            startSampler: { completion in samplerProbe.start(completion: completion) }
        )
        let model = AppModel(colorSampleCoordinator: coordinator)

        for origin in [
            BlocksPluginHostInvocationOrigin.scheduled,
            .background,
        ] {
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(actionID: "screenshot.color_sample.begin"),
                    context: .init(
                        requestingPluginID: "com.example.noninteractive-color-sample",
                        causationID: UUID(),
                        origin: origin
                    )
                )
                XCTFail("Non-user plugin work must not start color sampling.")
            } catch let error as BlocksPluginRuntimeError {
                guard case let .invalidHostOperation(reason) = error else {
                    return XCTFail("Unexpected runtime error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "screenshot.color_sample.begin.requires_user_initiated"
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(samplerProbe.startCount, 0)
    }

    @MainActor
    func testScreenshotColorSampleCancellationReturnsWithoutLateCompletion()
        async
    {
        let samplerProbe = ScreenshotColorSampleStartProbe()
        let coordinator = ScreenshotColorSampleCoordinator(
            startSampler: { completion in samplerProbe.start(completion: completion) }
        )
        let model = AppModel(colorSampleCoordinator: coordinator)
        let finished = expectation(description: "Cancelled sample returns")
        var receivedSuccessfulResult = false
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            do {
                _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                    .init(actionID: "screenshot.color_sample.begin"),
                    context: .init(
                        requestingPluginID: "com.example.explicit-user-color-sample",
                        causationID: UUID(),
                        origin: .explicitUser
                    )
                )
                receivedSuccessfulResult = true
            } catch is CancellationError {
                // Expected: cancellation releases the host operation promptly.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        await Task.yield()
        XCTAssertEqual(samplerProbe.startCount, 1)
        task.cancel()
        await fulfillment(of: [finished], timeout: 0.5)

        samplerProbe.complete(.systemRed)
        samplerProbe.complete(.systemBlue)
        await Task.yield()
        XCTAssertFalse(receivedSuccessfulResult)
    }

    @MainActor
    func testScreenshotColorSampleSuccessMatchesDeclaredOutputSchemaExactly()
        async throws
    {
        let samplerProbe = ScreenshotColorSampleStartProbe()
        let coordinator = ScreenshotColorSampleCoordinator(
            startSampler: { completion in samplerProbe.start(completion: completion) }
        )
        let model = AppModel(colorSampleCoordinator: coordinator)
        let task = Task { @MainActor in
            try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(actionID: "screenshot.color_sample.begin"),
                context: .init(
                    requestingPluginID: "com.example.explicit-user-color-sample",
                    causationID: UUID(),
                    origin: .explicitUser
                )
            )
        }

        await Task.yield()
        XCTAssertEqual(samplerProbe.startCount, 1)
        samplerProbe.complete(.systemRed)
        let result = try await task.value
        guard case let .object(output) = result else {
            return XCTFail("Color sampler must return an object.")
        }

        XCTAssertEqual(
            Set(output.keys),
            Set([
                "color_space",
                "red",
                "green",
                "blue",
                "alpha",
                "hex",
                "normalized_x",
                "normalized_y",
            ])
        )
        XCTAssertNil(output["screen_x"])
        XCTAssertNil(output["screen_y"])
    }

    func testClipboardRecordUpdateRequiresClipboardContentPermission() {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.clipboard-update",
            displayName: "Clipboard Update",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["clipboard.record.update"]
            )
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: manifest
            )
        )
    }

    @MainActor
    func testPluginRecordUpdatePersistsEditableTextAndCustomTitle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginRecordUpdate-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-editable-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "0123456789ab",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )
        let store = ClipboardStore(repository: repository)

        let result = try await store.updateRecordFromPlugin(
            recordID: record.id,
            customTitle: "Plugin title",
            text: "plugin updated text",
            expectedContentRevision: 1
        )

        XCTAssertEqual(result.newContentRevision, 2)
        XCTAssertTrue(result.changedFields.contains(.payload))
        XCTAssertTrue(result.changedFields.contains(.customTitle))
        XCTAssertTrue(result.changedFields.contains(.fts))
        XCTAssertEqual(
            try repository.readDetailEditablePayload(
                recordID: record.id,
                purpose: "detailEditRead"
            )?.text,
            "plugin updated text"
        )
        let updated = try repository.loadDetailReadModel(recordID: record.id)
        XCTAssertEqual(updated.contentRevision, 2)
        XCTAssertEqual(updated.title, "Plugin title")
        XCTAssertEqual(updated.boundedPreview.body, "plugin updated text")
    }

    @MainActor
    func testPluginRecordUpdateRejectsStaleRevisionAfterUserTitleOnlySave()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginRecordUpdateStale-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-stale-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "stale1234567",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )
        let actionRevision = try repository.loadDetailReadModel(
            recordID: record.id
        ).contentRevision
        let userSave = try repository.saveDetailEdit(
            command: ClipboardDetailEditCommand(
                recordID: record.id,
                expectedContentRevision: actionRevision,
                editableKind: .plainText,
                draft: .init(text: "ignored for a title-only save"),
                customTitle: "User title",
                updatesPayload: false,
                updatesCustomTitle: true,
                purpose: ClipboardDetailEditSavePurpose.detailEditSave.rawValue
            )
        )
        XCTAssertEqual(userSave.newContentRevision, actionRevision + 1)
        XCTAssertEqual(
            userSave.updatedDetailReadModel.contentRevision,
            userSave.newContentRevision
        )
        XCTAssertTrue(userSave.changedFields.contains(.customTitle))
        XCTAssertTrue(userSave.changedFields.contains(.contentRevision))
        let store = ClipboardStore(repository: repository)

        do {
            _ = try await store.updateRecordFromPlugin(
                recordID: record.id,
                customTitle: "Plugin title",
                text: nil,
                expectedContentRevision: actionRevision
            )
            XCTFail("A stale plugin action must not overwrite a user save.")
        } catch {
            XCTAssertEqual(error as? ClipboardDetailSaveFailure, .revisionConflict)
        }

        let preserved = try repository.loadDetailReadModel(recordID: record.id)
        XCTAssertEqual(preserved.contentRevision, actionRevision + 1)
        XCTAssertEqual(preserved.title, "User title")
        XCTAssertEqual(
            try repository.readDetailEditablePayload(
                recordID: record.id,
                purpose: "detailEditRead"
            )?.text,
            "original"
        )

        let currentRevisionResult = try await store.updateRecordFromPlugin(
            recordID: record.id,
            customTitle: "Plugin title",
            text: nil,
            expectedContentRevision: preserved.contentRevision
        )
        XCTAssertEqual(
            currentRevisionResult.newContentRevision,
            preserved.contentRevision + 1
        )
        XCTAssertEqual(
            currentRevisionResult.updatedDetailReadModel.contentRevision,
            currentRevisionResult.newContentRevision
        )
        XCTAssertEqual(
            try repository.loadDetailReadModel(recordID: record.id).title,
            "Plugin title"
        )
    }

    @MainActor
    func testPluginRecordUpdateRejectsMissingExpectedRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginRecordUpdateMissingRevision-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-missing-revision-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "missing12345",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )
        let store = ClipboardStore(repository: repository)

        do {
            _ = try await store.updateRecordFromPlugin(
                recordID: record.id,
                customTitle: "Plugin title",
                text: "plugin text",
                expectedContentRevision: nil
            )
            XCTFail("A plugin update without a revision must be rejected.")
        } catch {
            XCTAssertEqual(error as? ClipboardDetailSaveFailure, .revisionConflict)
        }

        let preserved = try repository.loadDetailReadModel(recordID: record.id)
        XCTAssertEqual(preserved.contentRevision, 1)
        XCTAssertEqual(preserved.title, record.kind.rawValue)
        XCTAssertEqual(
            try repository.readDetailEditablePayload(
                recordID: record.id,
                purpose: "detailEditRead"
            )?.text,
            "original"
        )
    }

    @MainActor
    func testClipboardRecordUpdateHostActionEnforcesRuntimeApprovalAndRevisionEndToEnd()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginRecordUpdateHostAction-\(UUID().uuidString)",
            isDirectory: true
        )
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-host-action-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "hostaction12",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )

        let pluginID = "com.example.clipboard-host-action"
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Clipboard Host Action",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions, .hooks],
            permissions: .init(data: [.clipboardContent]),
            platform: .init(
                hooks: [
                    .init(
                        id: "observe-update",
                        event: .clipboardRecordUpdated,
                        entryFunction: "observeUpdate"
                    ),
                ],
                hostActions: ["clipboard.record.update"],
                actions: [
                    .init(
                        id: "update-record",
                        displayName: "Update record",
                        entryFunction: "updateRecord"
                    ),
                ]
            )
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let sourceURL = root.appendingPathComponent(
            "ClipboardHostAction.blocksplugin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try manifestData.write(
            to: sourceURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data("function updateRecord() {}".utf8).write(
            to: sourceURL.appendingPathComponent("plugin.js"),
            options: .atomic
        )
        let package = try BlocksNativePluginPackageValidator().validate(
            directory: sourceURL
        )
        let metadataRepository = BlocksNativePluginMetadataRepository(
            database: database
        )
        let executor = ClipboardRecordUpdateHostActionExecutor()
        let manager = BlocksNativePluginManager(
            repository: metadataRepository,
            managedRoot: root.appendingPathComponent("Managed", isDirectory: true),
            executor: executor,
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let pending = try await manager.prepareInstallation(
            validatedPackage: package,
            sourceDisplayName: "Clipboard Host Action.blocksplugin"
        )
        _ = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: pluginID)
        let model = AppModel(
            clipboardStore: ClipboardStore(repository: repository),
            translationPluginManager: manager
        )

        func assertRecordUnchanged() throws {
            let detail = try repository.loadDetailReadModel(recordID: record.id)
            XCTAssertEqual(detail.contentRevision, 1)
            XCTAssertEqual(detail.title, record.kind.rawValue)
            XCTAssertEqual(
                try repository.readDetailEditablePayload(
                    recordID: record.id,
                    purpose: "detailEditRead"
                )?.text,
                "original"
            )
        }
        func invoke(
            expectedRevision: Int64?,
            origin: BlocksPluginHostInvocationOrigin = .explicitUser
        ) async throws {
            executor.nextAction = .init(
                actionID: "clipboard.record.update",
                input: [
                    "record_id": .string(record.id),
                    "custom_title": .string("Plugin title"),
                    "text": .string("plugin updated text"),
                ],
                expectedRevision: expectedRevision
            )
            _ = try await model.pluginRuntimeCoordinator.performPluginAction(
                pluginID: pluginID,
                actionID: "update-record",
                origin: origin
            )
        }

        _ = try metadataRepository.approve(
            pluginID: pluginID,
            expectedPackageHash: package.packageSHA256,
            permissions: ["action:update-record", "data:clipboard_content"],
            domains: []
        )
        await manager.reload()
        do {
            try await invoke(expectedRevision: 1)
            XCTFail("An unapproved host action must not reach the AppModel handler.")
        } catch {
            guard let runtimeError = error as? BlocksPluginRuntimeError,
                  case let .invalidHostOperation(reason) = runtimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "unapproved:clipboard.record.update")
        }
        try assertRecordUnchanged()

        _ = try metadataRepository.approve(
            pluginID: pluginID,
            expectedPackageHash: package.packageSHA256,
            permissions: [
                "action:update-record",
                "host_action:clipboard.record.update",
            ],
            domains: []
        )
        await manager.reload()
        do {
            try await invoke(expectedRevision: 1)
            XCTFail("Revoking clipboard content after host-action approval must block the update.")
        } catch {
            guard let runtimeError = error as? BlocksPluginRuntimeError,
                  case let .invalidHostOperation(reason) = runtimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "unapproved:data:clipboard_content")
        }
        try assertRecordUnchanged()

        _ = try metadataRepository.approve(
            pluginID: pluginID,
            expectedPackageHash: package.packageSHA256,
            permissions: [
                "action:update-record",
                "host_action:clipboard.record.update",
                "data:clipboard_content",
            ],
            domains: []
        )
        await manager.reload()
        do {
            try await invoke(expectedRevision: nil)
            XCTFail("A host action without an expected revision must be rejected.")
        } catch {
            XCTAssertEqual(error as? ClipboardDetailSaveFailure, .revisionConflict)
        }
        try assertRecordUnchanged()

        XCTAssertTrue(
            manager.plugins.first(where: { $0.id == pluginID })?.safetyDisabled
                == true
        )
        XCTAssertEqual(executor.cancelCount, 1)
        do {
            try await invoke(expectedRevision: 1)
            XCTFail("A safety-disabled plugin must not execute another action.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginExecutionError,
                .pluginDisabled
            )
        }
        try assertRecordUnchanged()
        try await manager.clearSafetyDisable(pluginID: pluginID)

        for origin in [
            BlocksPluginHostInvocationOrigin.background,
            .scheduled,
        ] {
            do {
                try await invoke(expectedRevision: 1, origin: origin)
                XCTFail("A non-user plugin invocation must not update a record.")
            } catch {
                guard let runtimeError = error as? BlocksPluginRuntimeError,
                      case let .invalidHostOperation(reason) = runtimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "clipboard.record.update.requires_user_initiated"
                )
            }
            try assertRecordUnchanged()
        }

        try await invoke(expectedRevision: 1, origin: .explicitUser)
        let updated = try repository.loadDetailReadModel(recordID: record.id)
        XCTAssertEqual(updated.contentRevision, 2)
        XCTAssertEqual(updated.title, "Plugin title")
        XCTAssertEqual(
            try repository.readDetailEditablePayload(
                recordID: record.id,
                purpose: "detailEditRead"
            )?.text,
            "plugin updated text"
        )
        XCTAssertEqual(
            try repository.search("plugin updated text", limit: 10).map(\.id),
            [record.id]
        )
        for _ in 0..<200 where executor.observedClipboardRecordUpdatedPayload == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            executor.observedClipboardRecordUpdatedPayload?["operation"],
            .string("content_updated")
        )
        XCTAssertEqual(
            executor.observedClipboardRecordUpdatedPayload?["content_revision"],
            .int(2)
        )
    }

    @MainActor
    func testClipboardRecordBringToFrontHostActionRequiresUserInitiationAndPersists()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginBringToFrontHostAction-\(UUID().uuidString)",
            isDirectory: true
        )
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let target = ClipboardRecorderRecord(
            id: "plugin-bring-to-front-target",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 45,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 6
            ),
            sourceApp: nil,
            signatureSHA256_12: "bringfront01",
            fixtureOwned: true,
            restorable: true,
            summary: "target"
        )
        let front = ClipboardRecorderRecord(
            id: "plugin-bring-to-front-existing",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            changeCount: 46,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 5
            ),
            sourceApp: nil,
            signatureSHA256_12: "bringfront02",
            fixtureOwned: true,
            restorable: true,
            summary: "front"
        )
        _ = try repository.insert(
            record: target,
            payload: .init(recordID: target.id, kind: .text, text: "target")
        )
        _ = try repository.insert(
            record: front,
            payload: .init(recordID: front.id, kind: .text, text: "front")
        )

        let clipboardStore = ClipboardStore(repository: repository)
        let seeded = await clipboardStore.commitCopyEvent(
            recordID: front.id,
            source: .plugin,
            at: Date(timeIntervalSince1970: 1_700_001_000),
            shouldPublishPluginEvent: { false }
        )
        XCTAssertTrue(seeded.persisted)
        XCTAssertEqual(clipboardStore.records.map(\.id), [front.id, target.id])

        let model = AppModel(clipboardStore: clipboardStore)
        let eventProbe = PluginHostActionInvocationProbe()
        clipboardStore.configurePluginEventDispatcher { envelope in
            await eventProbe.recordInvocation()
            return .allowed(envelope)
        }
        let originalLastCopiedAt = try XCTUnwrap(
            repository.loadRecord(recordID: target.id)
        ).lastCopiedAt
        let originalOrder = clipboardStore.records.map(\.id)

        func invoke(_ origin: BlocksPluginHostInvocationOrigin) async throws -> JSONValue {
            try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(
                    actionID: "clipboard.record.bring_to_front",
                    input: ["record_id": .string(target.id)]
                ),
                context: .init(
                    requestingPluginID: "com.example.bring-to-front",
                    causationID: UUID(),
                    origin: origin
                )
            )
        }
        func assertUnchanged() async throws {
            XCTAssertEqual(
                try XCTUnwrap(repository.loadRecord(recordID: target.id))
                    .lastCopiedAt,
                originalLastCopiedAt
            )
            XCTAssertEqual(clipboardStore.records.map(\.id), originalOrder)
            let eventCount = await eventProbe.invocationCount
            XCTAssertEqual(eventCount, 0)
        }

        for origin in [
            BlocksPluginHostInvocationOrigin.background,
            .scheduled,
        ] {
            do {
                _ = try await invoke(origin)
                XCTFail("A non-user plugin invocation must not promote a record.")
            } catch {
                guard let runtimeError = error as? BlocksPluginRuntimeError,
                      case let .invalidHostOperation(reason) = runtimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "clipboard.record.bring_to_front.requires_user_initiated"
                )
            }
            try await assertUnchanged()
        }

        let promoted = try await invoke(.explicitUser)
        XCTAssertEqual(promoted, .bool(true))
        let persisted = try XCTUnwrap(repository.loadRecord(recordID: target.id))
        XCTAssertGreaterThan(persisted.lastCopiedAt, originalLastCopiedAt)
        XCTAssertEqual(clipboardStore.records.first?.id, target.id)
        let eventCount = await eventProbe.invocationCount
        XCTAssertEqual(eventCount, 1)
    }

    @MainActor
    func testSystemOpenPluginPageHostActionRequiresUserInitiation() async throws {
        let model = AppModel()
        var openerCount = 0
        model.configureMainWindowOpener { openerCount += 1 }
        let initialSection = model.selectedSection
        let initialNavigationGeneration = model.mainWindowNavigationGeneration

        func invoke(_ origin: BlocksPluginHostInvocationOrigin) async throws -> JSONValue {
            try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(actionID: "system.open_plugin_page"),
                context: .init(
                    requestingPluginID: "com.example.open-plugin-page",
                    causationID: UUID(),
                    origin: origin
                )
            )
        }

        for origin in [
            BlocksPluginHostInvocationOrigin.background,
            .scheduled,
        ] {
            do {
                _ = try await invoke(origin)
                XCTFail("A non-user plugin invocation must not open the plugin page.")
            } catch {
                guard let runtimeError = error as? BlocksPluginRuntimeError,
                      case let .invalidHostOperation(reason) = runtimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "system.open_plugin_page.requires_user_initiated"
                )
            }
            XCTAssertEqual(openerCount, 0)
            XCTAssertEqual(
                model.selectedSection.rawValue,
                initialSection.rawValue
            )
            XCTAssertEqual(
                model.mainWindowNavigationGeneration,
                initialNavigationGeneration
            )
        }

        let opened = try await invoke(.explicitUser)
        XCTAssertEqual(opened, .bool(true))
        XCTAssertEqual(openerCount, 1)
        XCTAssertEqual(model.selectedSection.rawValue, AppSection.hooks.rawValue)
        XCTAssertEqual(
            model.mainWindowNavigationGeneration,
            initialNavigationGeneration + 1
        )
    }

    @MainActor
    func testClipboardTagDeleteHostActionRequiresDestructiveConfirmation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginTagDeleteHostAction-\(UUID().uuidString)",
            isDirectory: true
        )
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-tag-delete-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 43,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "tagdelete123",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )

        let clipboardStore = ClipboardStore(repository: repository)
        guard let tagID = await clipboardStore.tagStore.createFilterTag(
            displayName: "Plugin tag"
        ) else {
            return XCTFail("Expected the persistent fixture tag to be created.")
        }
        let attached = await clipboardStore.tagStore.addTag(
            recordID: record.id,
            tagID: tagID
        )
        XCTAssertTrue(attached)
        let tagRepository = ClipboardTagRepository(repository: repository)

        func assertTagAndAssociationRemain() throws {
            XCTAssertTrue(
                try tagRepository.loadTags().contains(where: { $0.id == tagID })
            )
            XCTAssertEqual(
                try tagRepository.loadRecordTags(recordIDs: [record.id])[record.id]?
                    .map(\.id),
                [tagID]
            )
        }

        let model = AppModel(clipboardStore: clipboardStore)
        let expectedRevision = try XCTUnwrap(
            try tagRepository.loadTags().first(where: { $0.id == tagID })?.contentRevision
        )
        func invoke(
            _ origin: BlocksPluginHostInvocationOrigin,
            expectedRevision: Int64? = nil
        ) async throws {
            _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(
                    actionID: "clipboard.tag.delete",
                    input: ["tag_id": .string(tagID)]
                ),
                context: .init(
                    requestingPluginID: "com.example.tag-delete",
                    causationID: UUID(),
                    expectedRevision: expectedRevision,
                    origin: origin
                )
            )
        }

        for origin in [
            BlocksPluginHostInvocationOrigin.background,
            .scheduled,
            .explicitUser,
            .hostConfirmedExplicitUser,
            .commandLine(destructiveActionConfirmed: false),
            .commandLine(destructiveActionConfirmed: true),
        ] {
            do {
                try await invoke(origin)
                XCTFail("A non-user plugin invocation must not delete a tag.")
            } catch {
                guard let runtimeError = error as? BlocksPluginRuntimeError,
                      case let .invalidHostOperation(reason) = runtimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "destructive_host_action_capability_required"
                )
            }
            try assertTagAndAssociationRemain()
        }

        for revision in [Int64?.none, .some(expectedRevision)] {
            do {
                try await invoke(.hostConfirmedExplicitUser, expectedRevision: revision)
                XCTFail("A naked host-confirmed origin must not delete a tag.")
            } catch {
                guard case let .invalidHostOperation(reason) =
                    error as? BlocksPluginRuntimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(reason, "destructive_host_action_capability_required")
            }
            try assertTagAndAssociationRemain()
        }
    }

    @MainActor
    func testClipboardTagAndFavoriteHostActionsRequireUserInitiationAndPersist()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginTagAndFavoriteHostActions-\(UUID().uuidString)",
            isDirectory: true
        )
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-tag-and-favorite-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 44,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "tagfavorite1",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )

        let tagRepository = ClipboardTagRepository(repository: repository)
        let created = try tagRepository.createTag(displayName: "Original tag")
        let tagID = try XCTUnwrap(created.changedTagIDs.first)
        _ = try tagRepository.addTag(recordID: record.id, tagID: tagID)
        let clipboardStore = ClipboardStore(repository: repository)
        func reloadTagSnapshot() throws {
            clipboardStore.tagStore.applyReadSnapshot(
                tags: try tagRepository.loadTags(),
                recordTags: try tagRepository.loadRecordTags(recordIDs: [record.id]),
                recordIDs: [record.id],
                replacesRecordTags: true
            )
        }
        try reloadTagSnapshot()
        let model = AppModel(clipboardStore: clipboardStore)

        func recordTagIDs() throws -> Set<String> {
            Set(
                try tagRepository.loadRecordTags(recordIDs: [record.id])[record.id,
                    default: []].map(\.id)
            )
        }
        func tagName() throws -> String? {
            try tagRepository.loadTags().first(where: { $0.id == tagID })?
                .displayName
        }
        func tagRevision(_ id: String) throws -> Int64 {
            try XCTUnwrap(
                try tagRepository.loadTags().first(where: { $0.id == id })
            ).contentRevision
        }
        func invoke(
            actionID: String,
            input: [String: JSONValue],
            origin: BlocksPluginHostInvocationOrigin,
            expectedRevision: Int64? = nil
        ) async throws -> JSONValue {
            try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(
                    actionID: actionID,
                    input: input,
                    expectedRevision: expectedRevision
                ),
                context: .init(
                    requestingPluginID: "com.example.tag-and-favorite",
                    causationID: UUID(),
                    origin: origin
                )
            )
        }
        func assertRejectedForNonUserOrigins(
            actionID: String,
            input: [String: JSONValue],
            reason: String,
            assertUnchanged: () throws -> Void
        ) async throws {
            for origin in [
                BlocksPluginHostInvocationOrigin.background,
                .scheduled,
            ] {
                do {
                    _ = try await invoke(
                        actionID: actionID,
                        input: input,
                        origin: origin
                    )
                    XCTFail("A non-user plugin invocation must not mutate clipboard data.")
                } catch {
                    guard let runtimeError = error as? BlocksPluginRuntimeError,
                          case let .invalidHostOperation(actualReason) = runtimeError else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(actualReason, reason)
                }
                try assertUnchanged()
            }
        }

        try await assertRejectedForNonUserOrigins(
            actionID: "clipboard.tag.detach",
            input: [
                "record_id": .string(record.id),
                "tag_id": .string(tagID),
            ],
            reason: "clipboard.tag.detach.requires_user_initiated"
        ) {
            XCTAssertEqual(try tagName(), "Original tag")
            XCTAssertTrue(try recordTagIDs().contains(tagID))
            XCTAssertFalse(
                try recordTagIDs().contains(ClipboardTagRepository.favoriteTagID)
            )
        }
        let detached = try await invoke(
            actionID: "clipboard.tag.detach",
            input: [
                "record_id": .string(record.id),
                "tag_id": .string(tagID),
            ],
            origin: .explicitUser,
            expectedRevision: try tagRevision(tagID)
        )
        XCTAssertEqual(detached, .bool(true))
        XCTAssertFalse(try recordTagIDs().contains(tagID))
        try reloadTagSnapshot()

        try await assertRejectedForNonUserOrigins(
            actionID: "clipboard.tag.rename",
            input: [
                "tag_id": .string(tagID),
                "name": .string("Renamed tag"),
            ],
            reason: "clipboard.tag.rename.requires_user_initiated"
        ) {
            XCTAssertEqual(try tagName(), "Original tag")
            XCTAssertFalse(try recordTagIDs().contains(tagID))
            XCTAssertFalse(
                try recordTagIDs().contains(ClipboardTagRepository.favoriteTagID)
            )
        }
        let renamed = try await invoke(
            actionID: "clipboard.tag.rename",
            input: [
                "tag_id": .string(tagID),
                "name": .string("Renamed tag"),
            ],
            origin: .explicitUser,
            expectedRevision: try tagRevision(tagID)
        )
        XCTAssertEqual(renamed, .bool(true))
        XCTAssertEqual(try tagName(), "Renamed tag")
        try reloadTagSnapshot()

        try await assertRejectedForNonUserOrigins(
            actionID: "clipboard.record.favorite",
            input: [
                "record_id": .string(record.id),
                "is_favorite": .bool(true),
            ],
            reason: "clipboard.record.favorite.requires_user_initiated"
        ) {
            XCTAssertEqual(try tagName(), "Renamed tag")
            XCTAssertFalse(try recordTagIDs().contains(tagID))
            XCTAssertFalse(
                try recordTagIDs().contains(ClipboardTagRepository.favoriteTagID)
            )
        }
        let favorited = try await invoke(
            actionID: "clipboard.record.favorite",
            input: [
                "record_id": .string(record.id),
                "is_favorite": .bool(true),
            ],
            origin: .explicitUser,
            expectedRevision: try tagRevision(
                ClipboardTagRepository.favoriteTagID
            )
        )
        XCTAssertEqual(favorited, .bool(true))
        XCTAssertTrue(
            try recordTagIDs().contains(ClipboardTagRepository.favoriteTagID)
        )

        // A direct intervening mutation leaves the MainActor snapshot stale.
        // The plugin action must compare the durable tag revision rather than
        // toggling from that stale snapshot and reversing the newer truth.
        let staleFavoriteRevision = try tagRevision(
            ClipboardTagRepository.favoriteTagID
        )
        _ = try tagRepository.setFavorite(
            recordID: record.id,
            isFavorite: false,
            expectedContentRevision: staleFavoriteRevision
        )
        XCTAssertFalse(
            try recordTagIDs().contains(ClipboardTagRepository.favoriteTagID)
        )
        do {
            _ = try await invoke(
                actionID: "clipboard.record.favorite",
                input: [
                    "record_id": .string(record.id),
                    "is_favorite": .bool(false),
                ],
                origin: .explicitUser,
                expectedRevision: staleFavoriteRevision
            )
            XCTFail("A stale favorite mutation must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardTagMutationError,
                .revisionConflict
            )
        }
        XCTAssertFalse(
            try recordTagIDs().contains(ClipboardTagRepository.favoriteTagID)
        )
        let currentFavoriteRevision = try tagRevision(
            ClipboardTagRepository.favoriteTagID
        )
        let idempotentUnfavorite = try await invoke(
            actionID: "clipboard.record.favorite",
            input: [
                "record_id": .string(record.id),
                "is_favorite": .bool(false),
            ],
            origin: .explicitUser,
            expectedRevision: currentFavoriteRevision
        )
        XCTAssertEqual(idempotentUnfavorite, .bool(false))
        XCTAssertEqual(
            try tagRevision(ClipboardTagRepository.favoriteTagID),
            currentFavoriteRevision
        )
        let refavorited = try await invoke(
            actionID: "clipboard.record.favorite",
            input: [
                "record_id": .string(record.id),
                "is_favorite": .bool(true),
            ],
            origin: .explicitUser,
            expectedRevision: currentFavoriteRevision
        )
        XCTAssertEqual(refavorited, .bool(true))
        XCTAssertEqual(
            try tagRevision(ClipboardTagRepository.favoriteTagID),
            currentFavoriteRevision + 1
        )
    }

    @MainActor
    func testSystemScheduleSetEnabledRequiresUserInitiationOnlyForEnabling()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginScheduleSetEnabledHostAction-\(UUID().uuidString)",
            isDirectory: true
        )
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: root.appendingPathComponent("Managed", isDirectory: true),
            executor: RecordingPluginExecutor(),
            platformRepository: platformRepository
        )
        let pluginID = "com.example.schedule-set-enabled"
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Schedule Set Enabled",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["system.schedule.set_enabled"],
                schedules: [
                    .init(
                        id: "interval",
                        kind: .interval,
                        configuration: ["seconds": .int(3_600)]
                    ),
                ]
            )
        )
        let source = root.appendingPathComponent(
            "ScheduleSetEnabled.blocksplugin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(
            to: source.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data("function noop() {}".utf8).write(
            to: source.appendingPathComponent("plugin.js"),
            options: .atomic
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        XCTAssertEqual(installed.id, pluginID)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let model = AppModel(translationPluginManager: manager)

        func binding() throws -> BlocksPluginScheduleBinding {
            try XCTUnwrap(
                platformRepository.scheduleBindings(
                    pluginID: installed.id,
                    runnableOnly: false
                ).first
            )
        }
        func invoke(
            enabled: Bool,
            origin: BlocksPluginHostInvocationOrigin
        ) async throws {
            _ = try await model.pluginRuntimeCoordinator.actionRegistry.perform(
                .init(
                    actionID: "system.schedule.set_enabled",
                    input: [
                        "schedule_id": .string("interval"),
                        "enabled": .bool(enabled),
                    ]
                ),
                context: .init(
                    requestingPluginID: installed.id,
                    causationID: UUID(),
                    origin: origin
                )
            )
        }

        XCTAssertFalse(try binding().isEnabled)
        for origin in [
            BlocksPluginHostInvocationOrigin.background,
            .scheduled,
        ] {
            do {
                try await invoke(enabled: true, origin: origin)
                XCTFail("A non-user plugin invocation must not enable a schedule.")
            } catch {
                guard let runtimeError = error as? BlocksPluginRuntimeError,
                      case let .invalidHostOperation(reason) = runtimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "system.schedule.set_enabled.requires_user_initiated"
                )
            }
            XCTAssertFalse(try binding().isEnabled)
            XCTAssertNil(try binding().nextFireAt)
            XCTAssertTrue(
                try platformRepository.scheduleBindings(pluginID: installed.id).isEmpty
            )
        }

        try await invoke(enabled: true, origin: .explicitUser)
        XCTAssertTrue(try binding().isEnabled)
        let enabledScheduleIDs = await manager.scheduleBindings(
            pluginID: installed.id
        ).map(\.scheduleID)
        XCTAssertEqual(
            enabledScheduleIDs,
            ["interval"]
        )

        try await invoke(enabled: false, origin: .background)
        XCTAssertFalse(try binding().isEnabled)
        XCTAssertNil(try binding().nextFireAt)
        XCTAssertTrue(
            try platformRepository.scheduleBindings(pluginID: installed.id).isEmpty
        )
    }

    @MainActor
    func testHostActionRegistryForwardsInvocationExpectedRevision() async throws {
        let registry = BlocksPluginHostActionRegistry()
        registry.register(
            BlocksPluginHostCapabilityDescriptor(
                id: "fixture",
                risk: .ordinary
            )
        ) { context, _ in
            .object([
                "expected_revision": .int(Int(context.expectedRevision ?? -1)),
                "user_initiated": .bool(context.origin.userInitiated),
            ])
        }

        let output = try await registry.perform(
            .init(actionID: "fixture", expectedRevision: 42),
            context: .init(
                requestingPluginID: "com.example.fixture",
                causationID: UUID(),
                expectedRevision: nil,
                origin: .commandLine()
            )
        )

        XCTAssertEqual(
            output,
            .object([
                "expected_revision": .int(42),
                "user_initiated": .bool(true),
            ])
        )
    }

    func testHostInvocationOriginMappingFailsClosedForBackgroundWork() {
        XCTAssertTrue(BlocksPluginHostInvocationOrigin.explicitUser.userInitiated)
        XCTAssertTrue(BlocksPluginHostInvocationOrigin.commandLine().userInitiated)
        XCTAssertFalse(
            BlocksPluginHostInvocationOrigin.commandLine()
                .destructiveActionConfirmed
        )
        XCTAssertFalse(
            BlocksPluginHostInvocationOrigin.commandLine(
                destructiveActionConfirmed: true
            ).destructiveActionConfirmed
        )
        XCTAssertFalse(
            BlocksPluginHostInvocationOrigin.explicitUser
                .destructiveActionConfirmed
        )
        XCTAssertFalse(
            BlocksPluginHostInvocationOrigin.hostConfirmedExplicitUser
                .destructiveActionConfirmed
        )
        XCTAssertFalse(BlocksPluginHostInvocationOrigin.scheduled.userInitiated)
        XCTAssertFalse(BlocksPluginHostInvocationOrigin.background.userInitiated)
    }

    @MainActor
    func testDestructiveConfirmationPresenterFailsClosedAndRecoversAfterCancellation()
        async
    {
        let request = BlocksPluginDestructiveActionConfirmationRequest(
            requestID: UUID(),
            pluginID: "com.example.fixture",
            actionID: "clipboard.record.delete",
            targetID: "record-1",
            causationID: UUID(),
            expectedRevision: 4
        )
        let noWindowPresenter = BlocksPluginDestructiveActionConfirmationPresenter(
            windowProvider: { nil },
            sheetPresenter: { _, _, _ in
                XCTFail("A missing host window must not attempt to present a sheet.")
            }
        )
        let noWindowResult = await noWindowPresenter.present(
            request,
            pluginDisplayName: "Fixture",
            targetDisplayName: "Record"
        )
        XCTAssertFalse(noWindowResult)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        var windowIsClosed = false
        let closeWindow = {
            guard !windowIsClosed else { return }
            windowIsClosed = true
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        defer {
            closeWindow()
        }
        let firstStarted = expectation(description: "first confirmation sheet starts")
        let secondStarted = expectation(description: "second confirmation sheet starts")
        var presentationCount = 0
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        var capturedAlerts: [NSAlert] = []
        var dismissalCount = 0
        let presenter = BlocksPluginDestructiveActionConfirmationPresenter(
            windowProvider: { window },
            sheetPresenter: { alert, presentedWindow, completion in
                XCTAssertTrue(presentedWindow === window)
                presentationCount += 1
                capturedAlerts.append(alert)
                completions.append(completion)
                switch presentationCount {
                case 1: firstStarted.fulfill()
                case 2: secondStarted.fulfill()
                default: XCTFail("Unexpected extra confirmation sheet.")
                }
            },
            sheetDismisser: { _, dismissedWindow in
                XCTAssertTrue(dismissedWindow === window)
                dismissalCount += 1
            }
        )

        let cancelled = Task { @MainActor in
            await presenter.present(
                request,
                pluginDisplayName: "Fixture",
                targetDisplayName: "Record"
            )
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let overlappingResult = await presenter.present(
            request,
            pluginDisplayName: "Fixture",
            targetDisplayName: "Record"
        )
        XCTAssertFalse(overlappingResult)
        completions[0](.alertFirstButtonReturn)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(dismissalCount, 1)

        let approved = Task { @MainActor in
            await presenter.present(
                request,
                pluginDisplayName: "Fixture",
                targetDisplayName: "Record"
            )
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        completions[0](.alertFirstButtonReturn)
        await Task.yield()
        XCTAssertEqual(dismissalCount, 1)
        completions[1](.alertFirstButtonReturn)
        let approvedResult = await approved.value
        XCTAssertTrue(approvedResult)
        completions[1](.alertSecondButtonReturn)
        await Task.yield()

        XCTAssertEqual(presentationCount, 2)
        let alertStyles = capturedAlerts.map { $0.alertStyle }
        let firstAlertButtonTitles = capturedAlerts.first?.buttons.map {
            $0.title
        }
        XCTAssertEqual(alertStyles, [.critical, .critical])
        XCTAssertEqual(
            firstAlertButtonTitles,
            [
                L10n.string("plugin.runtime.destructiveConfirmation.delete"),
                L10n.string("common.cancel"),
            ]
        )
        completions.removeAll()
        capturedAlerts.removeAll()
        closeWindow()
        let windowTeardownSettled = expectation(
            description: "destructive confirmation window teardown settles"
        )
        DispatchQueue.main.async {
            windowTeardownSettled.fulfill()
        }
        await fulfillment(of: [windowTeardownSettled], timeout: 1)
    }

    func testPluginInvokeArgumentsParseConfirmationOnlyFromTheCommandEnvelope()
        throws
    {
        XCTAssertEqual(
            try PluginDevelopmentInvokeArguments.parse([
                "com.example.fixture", "run",
            ]),
            .init(
                pluginID: "com.example.fixture",
                actionID: "run",
                inputSource: .none,
                confirmed: false
            )
        )
        XCTAssertEqual(
            try PluginDevelopmentInvokeArguments.parse([
                "com.example.fixture", "run", "--stdin", "--confirm",
            ]),
            .init(
                pluginID: "com.example.fixture",
                actionID: "run",
                inputSource: .standardInput,
                confirmed: true
            )
        )
        XCTAssertEqual(
            try PluginDevelopmentInvokeArguments.parse([
                "com.example.fixture", "run", "--confirm", "--file",
                "/tmp/action.json",
            ]),
            .init(
                pluginID: "com.example.fixture",
                actionID: "run",
                inputSource: .file("/tmp/action.json"),
                confirmed: true
            )
        )

        let invalidArguments: [[String]] = [
            [],
            ["com.example.fixture"],
            ["--confirm", "run"],
            ["com.example.fixture", "--confirm"],
            ["com.example.fixture", "run", "--unknown"],
            ["com.example.fixture", "run", "--confirm", "--confirm"],
            ["com.example.fixture", "run", "--stdin", "--stdin"],
            ["com.example.fixture", "run", "--file"],
            ["com.example.fixture", "run", "--file", "--confirm"],
            [
                "com.example.fixture", "run", "--file", "/tmp/action.json",
                "--stdin",
            ],
            [
                "com.example.fixture", "run", "--stdin", "--file",
                "/tmp/action.json",
            ],
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try PluginDevelopmentInvokeArguments.parse(arguments),
                "Expected invalid arguments to fail: \(arguments)"
            ) { error in
                XCTAssertEqual(
                    error as? PluginDevelopmentInvokeArgumentsError,
                    .invalidArguments
                )
            }
        }
    }

    @MainActor
    func testDestructiveConfirmationWindowCloseFailsPendingPresentationAndRecovers()
        async
    {
        let request = BlocksPluginDestructiveActionConfirmationRequest(
            requestID: UUID(), pluginID: "com.example.fixture",
            actionID: "clipboard.record.delete", targetID: "record-1",
            causationID: UUID(), expectedRevision: 1
        )
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        for window in [firstWindow, secondWindow] {
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
        }
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
            firstWindow.close()
            secondWindow.close()
        }
        var currentWindow: NSWindow? = firstWindow
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let firstStarted = expectation(description: "pending sheet starts")
        let secondStarted = expectation(description: "recovered sheet starts")
        var presentationCount = 0
        let presenter = BlocksPluginDestructiveActionConfirmationPresenter(
            windowProvider: { currentWindow },
            sheetPresenter: { _, _, completion in
                completions.append(completion)
                presentationCount += 1
                if presentationCount == 1 { firstStarted.fulfill() }
                else if presentationCount == 2 { secondStarted.fulfill() }
                else { XCTFail("Unexpected additional confirmation sheet.") }
            },
            sheetDismisser: { _, _ in }
        )

        let pending = Task { @MainActor in
            await presenter.present(request, pluginDisplayName: "Fixture", targetDisplayName: "Record")
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        firstWindow.close()
        let pendingResult = await pending.value
        XCTAssertFalse(pendingResult)

        currentWindow = secondWindow
        let recovered = Task { @MainActor in
            await presenter.present(request, pluginDisplayName: "Fixture", targetDisplayName: "Record")
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        completions[1](.alertFirstButtonReturn)
        let recoveredResult = await recovered.value
        XCTAssertTrue(recoveredResult)
        secondWindow.close()
        await Task.yield()
    }

    @MainActor
    func testPendingPasteRequestPreservesPluginLifecycleAcrossAccessibilityRetry() {
        let defaultsSuite = "BlocksPluginPasteLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: ClipboardStore(repository: nil),
            privacyStore: PrivacyStore(repository: nil),
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults)
        )
        let runtime = BlocksPluginRuntimeCoordinator(
            manager: AppModel.makeTranslationPluginManager()
        )
        let token = runtime.captureHostActionLifecycleToken()
        let request = coordinator.makePendingPasteRequest(
            recordID: "fixture",
            targetContext: nil,
            promptForAccessibility: true,
            invocationOrigin: .explicitUser,
            pluginLifecycleToken: token,
            pluginLifecycleLeaseProvider: { nil },
            pluginLifecycleIsCurrent: { [weak runtime] token in
                runtime?.isHostActionLifecycleCurrent(token) == true
            }
        )
        let retry = request
            .waitingForAccessibilityRetry(
                lease: ClipboardPasteboardWriteLease(changeCount: 11),
                historySyncPending: false
            )
            .retryingAfterAccessibilityGrant()

        XCTAssertTrue(coordinator.pastePluginLifecycleIsCurrent(retry))
        runtime.forceShutdownForApplicationTermination()
        XCTAssertFalse(coordinator.pastePluginLifecycleIsCurrent(request))
        XCTAssertFalse(coordinator.pastePluginLifecycleIsCurrent(retry))
    }

    func testDeferredPluginPasteLeaseBlocksLifecycleDrainUntilRequestEnds()
        async throws
    {
        let gate = BlocksPluginHostOperationAdmissionGate()
        let pluginID = "com.example.deferred-paste"
        let lease = try gate.acquire(pluginID: pluginID)
        let requestHolder = DeferredPluginPasteLeaseHolder(lease: lease)
        let revoked = expectation(description: "plugin lifecycle gate revoked")
        let drain = Task.detached {
            gate.revoke(pluginID: pluginID)
            revoked.fulfill()
            gate.drain(pluginID: pluginID)
        }

        await fulfillment(of: [revoked], timeout: 1)
        XCTAssertTrue(gate.isRevoked(pluginID: pluginID))
        await requestHolder.release()
        await drain.value

        XCTAssertThrowsError(try gate.acquire(pluginID: pluginID))
    }

    @MainActor
    func testPendingPluginPasteDoesNotAcquireLifecycleLeaseUntilExecution() {
        let defaultsSuite = "BlocksPluginPasteDeferredLease.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: ClipboardStore(repository: nil),
            privacyStore: PrivacyStore(repository: nil),
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults)
        )
        let gate = BlocksPluginHostOperationAdmissionGate()
        var acquisitionCount = 0
        let request = coordinator.makePendingPasteRequest(
            recordID: "fixture",
            targetContext: nil,
            promptForAccessibility: true,
            invocationOrigin: .explicitUser,
            pluginLifecycleToken: nil,
            pluginLifecycleLeaseProvider: {
                acquisitionCount += 1
                return try? gate.acquire(pluginID: "com.example.fixture")
            }
        )
        coordinator.pendingPasteRequest = request

        XCTAssertEqual(acquisitionCount, 0)
        gate.revokeAllAndDrain()
        XCTAssertEqual(acquisitionCount, 0)
        coordinator.pendingPasteRequest = nil
    }

    func testManifestV4UserFileUIRequiresOneCanonicalPermission() throws {
        let contribution = BlocksPluginUIContribution(
            id: "files",
            slot: .pluginPage,
            root: .init(
                id: "page",
                kind: .page,
                children: [
                    .init(
                        id: "choose",
                        kind: .fileAuthorization,
                        title: "Choose",
                        actionID: "read-file"
                    ),
                ]
            )
        )
        let platform = BlocksPluginPlatformConfiguration(
            actions: [
                .init(
                    id: "read-file",
                    displayName: "Read file"
                ),
            ],
            ui: [contribution],
            storage: .init(userGrantedFiles: true)
        )
        let missingPermission = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.user-files-missing",
            displayName: "Files Missing",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions, .ui],
            platform: platform
        )
        XCTAssertThrowsError(
            try BlocksNativePluginPackageValidator().validate(
                manifest: missingPermission
            )
        )

        let approved = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.user-files",
            displayName: "Files",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions, .ui],
            permissions: .init(data: [.userGrantedFiles]),
            platform: platform
        )
        XCTAssertNoThrow(
            try BlocksNativePluginPackageValidator().validate(
                manifest: approved
            )
        )
        XCTAssertTrue(
            approved.declaredPermissionTokens.contains(
                BlocksPluginPermissionToken.userGrantedFiles
            )
        )
        XCTAssertFalse(
            approved.declaredPermissionTokens.contains(
                "files:user_granted"
            )
        )
    }

    func testPlatformHookRunnerReturnsTypedMutationsActionsAndUIState()
        throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.platform-runner",
            displayName: "Platform Runner",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(
                        id: "paste",
                        event: .clipboardWillWritePasteboard,
                        entryFunction: "handleHook"
                    ),
                ]
            )
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { request in
                BlocksNativePluginNetworkResponse(
                    requestID: request.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data()
                )
            }
        )
        let event = BlocksPluginEventEnvelope(
            name: .clipboardWillWritePasteboard,
            payload: ["text": .string("before")]
        )
        let response = runner.executePlatform(
            BlocksPluginRunnerRequest(
                manifest: manifest,
                entrySource: """
                function handleHook(event) {
                  return {
                    disposition: "allow",
                    mutations: [{ field: "text", value: "after" }],
                    ui_state_patches: [{
                      component_id: "status",
                      property: "value",
                      operation: "replace",
                      value: "ready"
                    }]
                  };
                }
                """,
                invocation: BlocksPluginRuntimeInvocation(
                    pluginID: manifest.id,
                    kind: .hook,
                    entryFunction: "handleHook",
                    event: event
                ),
                executionTimeLimitSeconds: 1
            )
        )

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(
            response.result?.hook?.mutations,
            [.init(field: "text", value: .string("after"))]
        )
        XCTAssertEqual(
            response.result?.uiStatePatches.first?.componentID,
            "status"
        )
    }

    func testPlatformHookRunnerRoundTripsPrivateAndSharedStorageBridge()
        throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.platform-storage",
            displayName: "Platform Storage",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(
                        id: "launch",
                        event: .appLaunched,
                        entryFunction: "observeLaunch"
                    ),
                ],
                storage: .init(kinds: [.keyValue]),
                sharedState: [
                    .init(
                        id: "public-counter",
                        schemaVersion: 1,
                        schema: ["value": .string("integer")],
                        access: .readWrite
                    ),
                ]
            )
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { request in
                BlocksNativePluginNetworkResponse(
                    requestID: request.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data()
                )
            },
            hostOperationBroker: { request in
                let value: JSONValue
                switch request.operation {
                case "storage.get":
                    value = .null
                case "storage.put", "shared.put":
                    value = .object([
                        "value": request.input["value"] ?? .null,
                        "revision": .int(1),
                        "updated_at": .double(1_785_527_083.0),
                    ])
                default:
                    return BlocksPluginHostOperationResponse(
                        requestID: request.requestID,
                        ok: false,
                        errorCode: "unexpected_operation",
                        errorMessage: request.operation
                    )
                }
                return BlocksPluginHostOperationResponse(
                    requestID: request.requestID,
                    ok: true,
                    value: value
                )
            }
        )
        let response = runner.executePlatform(
            BlocksPluginRunnerRequest(
                manifest: manifest,
                entrySource: """
                function observeLaunch() {
                  const stored = blocks.storage.get("default", "launch_count");
                  const count = stored && stored.value ? stored.value : 0;
                  blocks.storage.put("default", "launch_count", count + 1);
                  blocks.sharedState.put(
                    "com.example.platform-storage",
                    "public-counter",
                    "launch_count",
                    1,
                    count + 1
                  );
                  return { disposition: "allow" };
                }
                """,
                invocation: BlocksPluginRuntimeInvocation(
                    pluginID: manifest.id,
                    kind: .hook,
                    entryFunction: "observeLaunch",
                    event: BlocksPluginEventEnvelope(name: .appLaunched)
                ),
                executionTimeLimitSeconds: 1
            )
        )

        XCTAssertEqual(
            response.status,
            .completed,
            response.errorMessage ?? "The platform runner did not report an error."
        )
        XCTAssertEqual(response.result?.hook?.disposition, .allow)
    }

    func testResourceBrokerRequiresPerInvocationAuthorizationAndStreamsAllBytes()
        throws
    {
        let broker = BlocksPluginResourceBroker()
        let source = Data((0..<2_500_000).map { UInt8($0 % 251) })
        let reference = broker.register(
            data: source,
            kind: .screenshot,
            mediaType: "image/png"
        )
        XCTAssertThrowsError(
            try broker.read(
                pluginID: "com.example.consumer",
                id: reference.id,
                offset: 0,
                length: 1_048_576
            )
        )
        broker.authorize(
            pluginID: "com.example.consumer",
            resourceIDs: [reference.id]
        )
        var restored = Data()
        var offset = 0
        repeat {
            let chunk = try broker.read(
                pluginID: "com.example.consumer",
                id: reference.id,
                offset: offset,
                length: 1_048_576
            )
            guard case let .string(base64)? = chunk["data_base64"],
                  let data = Data(base64Encoded: base64),
                  case let .int(next)? = chunk["next_offset"],
                  case let .bool(eof)? = chunk["eof"] else {
                return XCTFail("Invalid resource chunk")
            }
            restored.append(data)
            offset = next
            if eof { break }
        } while true
        XCTAssertEqual(restored, source)
        broker.revoke(
            pluginID: "com.example.consumer",
            resourceIDs: [reference.id]
        )
        XCTAssertThrowsError(
            try broker.read(
                pluginID: "com.example.consumer",
                id: reference.id,
                offset: 0,
                length: 1
            )
        )
    }

    func testResourceRemovalWaitsForAsynchronousHostLease() throws {
        let broker = BlocksPluginResourceBroker()
        let reference = broker.register(
            data: Data("still available".utf8),
            kind: .text,
            mediaType: "text/plain"
        )
        broker.retainHostLease(ids: [reference.id])
        broker.authorize(
            pluginID: "com.example.async-hook",
            resourceIDs: [reference.id]
        )
        broker.remove(ids: [reference.id])

        XCTAssertNoThrow(try broker.read(
            pluginID: "com.example.async-hook",
            id: reference.id,
            offset: 0,
            length: 1024
        ))

        broker.releaseHostLease(ids: [reference.id])
        XCTAssertThrowsError(try broker.read(
            pluginID: "com.example.async-hook",
            id: reference.id,
            offset: 0,
            length: 1
        ))
    }

    func testShutdownDefersStagedSessionRemovalUntilExistingHostLeaseEnds()
        async throws
    {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginShutdownLeaseTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let broker = BlocksPluginResourceBroker(
            stagingBaseDirectory: stagingRoot
        )
        let stagedReference = await broker.stageTextResource(
            "leased staged resource",
            kind: .text,
            mediaType: "text/plain"
        )
        let reference = try XCTUnwrap(stagedReference)
        let sessionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        let pluginID = "com.example.shutdown-lease"
        broker.authorize(pluginID: pluginID, resourceIDs: [reference.id])
        broker.retainHostLease(ids: [reference.id])

        broker.shutdown()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sessionDirectory.path)
        )
        XCTAssertNoThrow(try broker.read(
            pluginID: pluginID,
            id: reference.id,
            offset: 0,
            length: 1_024
        ))

        broker.releaseHostLease(ids: [reference.id])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.path)
        )
        XCTAssertThrowsError(try broker.read(
            pluginID: pluginID,
            id: reference.id,
            offset: 0,
            length: 1
        ))
        broker.shutdown()
    }

    @MainActor
    func testTerminationTimeoutForceFinalizesLeasedStagingBeforeReply()
        async throws
    {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginTerminationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let broker = BlocksPluginResourceBroker(
            stagingBaseDirectory: stagingRoot
        )
        let stagedReference = await broker.stageTextResource(
            "termination staging resource",
            kind: .text,
            mediaType: "text/plain"
        )
        let reference = try XCTUnwrap(stagedReference)
        let sessionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        let pluginID = "com.example.termination-lease"
        broker.authorize(pluginID: pluginID, resourceIDs: [reference.id])
        broker.retainHostLease(ids: [reference.id])
        var cleanupStarted = false
        var leaseRemainedReadable = false
        var replyCount = 0
        let replyReceived = expectation(description: "termination reply")
        let coordinator = AppTerminationCoordinator(
            dispatcher: {
                broker.shutdown()
                leaseRemainedReadable = (try? broker.read(
                    pluginID: pluginID,
                    id: reference.id,
                    offset: 0,
                    length: 1_024
                )) != nil
                cleanupStarted = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            },
            finalizer: {
                broker.forceShutdown()
            },
            timeoutSleeper: { _ in
                while !cleanupStarted {
                    await Task.yield()
                }
            },
            replyHandler: { _ in
                replyCount += 1
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: sessionDirectory.path
                    )
                )
                replyReceived.fulfill()
            }
        )

        XCTAssertEqual(coordinator.requestTermination(), .terminateLater)
        await fulfillment(of: [replyReceived], timeout: 1)
        XCTAssertEqual(replyCount, 1)
        XCTAssertTrue(leaseRemainedReadable)
        XCTAssertThrowsError(try broker.read(
            pluginID: pluginID,
            id: reference.id,
            offset: 0,
            length: 1
        ))
    }

    func testStagedTextResourceStreamsFourMiBAndSurvivesHostLease()
        async throws
    {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginStagingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let broker = BlocksPluginResourceBroker(
            stagingBaseDirectory: stagingRoot
        )
        let text = String(repeating: "x", count: 4 * 1_024 * 1_024)
        let source = Data(text.utf8)
        let stagedReference = await broker.stageTextResource(
            text,
            kind: .text,
            mediaType: "text/plain; charset=utf-8"
        )
        let reference = try XCTUnwrap(stagedReference)
        let expectedDigest = SHA256.hash(data: source)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(reference.byteCount, Int64(source.count))
        XCTAssertEqual(reference.sha256, expectedDigest)
        let sessionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        let stagedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ).first
        )
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: sessionDirectory.path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: stagedFile.path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(filePermissions, 0o600)

        let pluginID = "com.example.staged-text"
        broker.authorize(pluginID: pluginID, resourceIDs: [reference.id])
        broker.retainHostLease(ids: [reference.id])
        broker.remove(ids: [reference.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))

        var restored = Data()
        var offset = 0
        while true {
            let response = try broker.read(
                pluginID: pluginID,
                id: reference.id,
                offset: offset,
                length: 262_144
            )
            guard case let .string(base64)? = response["data_base64"],
                  let chunk = Data(base64Encoded: base64),
                  case let .int(nextOffset)? = response["next_offset"],
                  case let .bool(eof)? = response["eof"] else {
                return XCTFail("Invalid staged text resource chunk")
            }
            restored.append(chunk)
            offset = nextOffset
            if eof { break }
        }
        XCTAssertEqual(restored, source)

        broker.releaseHostLease(ids: [reference.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
        XCTAssertThrowsError(try broker.read(
            pluginID: pluginID,
            id: reference.id,
            offset: 0,
            length: 1
        ))
        broker.shutdown()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.path)
        )
    }

    func testCancelledTextStagingRemovesTemporaryFile() async throws {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginCancellationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let enteredChunk = expectation(description: "staging reached first chunk")
        let releaseChunk = DispatchSemaphore(value: 0)
        let broker = BlocksPluginResourceBroker(
            stagingBaseDirectory: stagingRoot,
            stagingChunkHook: {
                enteredChunk.fulfill()
                releaseChunk.wait()
            }
        )
        let task = Task {
            await broker.stageTextResource(
                String(repeating: "x", count: 4 * 1_024 * 1_024),
                kind: .text,
                mediaType: "text/plain; charset=utf-8"
            )
        }

        await fulfillment(of: [enteredChunk], timeout: 1)
        task.cancel()
        releaseChunk.signal()
        let cancelledResult = await task.value
        XCTAssertNil(cancelledResult)

        let sessionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        broker.shutdown()
    }

    func testTextStagingCleansDeadProcessSessionsAndOldLegacyFiles()
        throws
    {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginRecoveryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let staleSession = stagingRoot.appendingPathComponent(
            "2147483647-stale",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staleSession,
            withIntermediateDirectories: false
        )
        try Data("secret".utf8).write(
            to: staleSession.appendingPathComponent("payload")
        )
        let legacyFile = stagingRoot.appendingPathComponent("legacy-payload")
        try Data("legacy-secret".utf8).write(to: legacyFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7_200)],
            ofItemAtPath: legacyFile.path
        )

        let broker = BlocksPluginResourceBroker(
            stagingBaseDirectory: stagingRoot
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleSession.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyFile.path)
        )
        broker.shutdown()
    }

    func testTextStagingRejectsSymbolicLinkBaseDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginSymlinkTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        let broker = BlocksPluginResourceBroker(
            stagingBaseDirectory: link
        )

        let stagedReference = await broker.stageTextResource(
            "secret",
            kind: .text,
            mediaType: "text/plain"
        )
        XCTAssertNil(stagedReference)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @MainActor
    func testTextStagingFailureDoesNotBlockCoreClipboardPaste() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginPasteFailOpen-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let defaultsSuite = "BlocksPluginPasteFailOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-staging-paste",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            changeCount: 7,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 21,
                byteCount: 21
            ),
            sourceApp: nil,
            signatureSHA256_12: "pastefail001",
            fixtureOwned: true,
            restorable: true,
            summary: "paste survives staging"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(
                recordID: record.id,
                kind: .text,
                text: "paste survives staging"
            )
        )
        let pasteboard = ClipboardPluginFailOpenPasteboard(changeCount: 40)
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: ClipboardStore(repository: repository),
            privacyStore: PrivacyStore(repository: nil),
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults),
            autoPasteCoordinator: ClipboardAutoPasteCoordinator(
                pasteboard: pasteboard,
                changeSuppressor: ClipboardPasteboardChangeSuppressor()
            )
        )
        var dispatchedEvents: [BlocksPluginEventName] = []
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeTranslationPanel: {},
            translateRecord: { _ in },
            refreshPermissionState: {},
            dispatchPluginEvent: {
                dispatchedEvents.append($0.name)
                return .allowed($0)
            },
            stagePluginTextResource: { _, _, _, _ in nil },
            removePluginResources: { _ in },
            accessibilityGranted: { true },
            presentAccessibilityAssist: { _ in }
        )

        let request = coordinator.makePendingPasteRequest(
            recordID: record.id,
            targetContext: nil,
            promptForAccessibility: false
        )
        coordinator.startPaste(request)
        let pasteTask = try XCTUnwrap(coordinator.pasteTask)
        await pasteTask.value

        XCTAssertEqual(pasteboard.writeCallCount, 1)
        guard case let .string(value)? = pasteboard.items.first?
            .representations[.string] else {
            return XCTFail("Core paste must retain its plain-text representation.")
        }
        XCTAssertEqual(value, "paste survives staging")
        XCTAssertFalse(
            dispatchedEvents.contains(.clipboardWillWritePasteboard),
            "A failed resource stage must skip only the plugin pre-hook."
        )
    }

    @MainActor
    func testClipboardPasteHookCannotDowngradeFileURLRepresentation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginFileURLPaste-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let defaultsSuite = "BlocksPluginFileURLPaste.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let fileURL = root.appendingPathComponent("plugin-source.txt")
        try Data("fixture".utf8).write(to: fileURL)
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-file-url-paste",
            createdAt: Date(timeIntervalSince1970: 1_700_000_150),
            changeCount: 9,
            kind: .fileURL,
            formatSummary: .init(
                itemCount: 1,
                types: [NSPasteboard.PasteboardType.fileURL.rawValue],
                textLength: fileURL.path.count,
                byteCount: fileURL.absoluteString.utf8.count
            ),
            sourceApp: nil,
            signatureSHA256_12: "fileurlhook1",
            fixtureOwned: true,
            restorable: true,
            summary: fileURL.lastPathComponent
        )
        _ = try repository.insert(
            record: record,
            payload: .init(
                recordID: record.id,
                kind: .fileURL,
                text: fileURL.path,
                urlString: fileURL.absoluteString
            )
        )
        let pasteboard = ClipboardPluginFailOpenPasteboard(changeCount: 50)
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: ClipboardStore(repository: repository),
            privacyStore: PrivacyStore(repository: nil),
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults),
            autoPasteCoordinator: ClipboardAutoPasteCoordinator(
                pasteboard: pasteboard,
                changeSuppressor: ClipboardPasteboardChangeSuppressor()
            )
        )
        var observedWillAuthorization: BlocksPluginAuthorizationContext?
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeTranslationPanel: {},
            translateRecord: { _ in },
            refreshPermissionState: {},
            dispatchPluginEvent: { envelope in
                guard envelope.name == .clipboardWillWritePasteboard else {
                    return .allowed(envelope)
                }
                observedWillAuthorization = envelope.authorization
                var mutatedPayload = envelope.payload
                mutatedPayload["text"] = .string("downgraded by plugin")
                mutatedPayload["plain_text"] = .string("downgraded by plugin")
                let mutated = BlocksPluginEventEnvelope(
                    eventID: envelope.eventID,
                    name: envelope.name,
                    occurredAt: envelope.occurredAt,
                    sessionID: envelope.sessionID,
                    requestID: envelope.requestID,
                    revision: envelope.revision,
                    causationID: envelope.causationID,
                    source: envelope.source,
                    authorization: envelope.authorization,
                    payload: mutatedPayload,
                    resources: envelope.resources
                )
                return .allowed(mutated)
            },
            stagePluginTextResource: { text, kind, mediaType, _ in
                BlocksPluginResourceReference(
                    id: "file-url-resource",
                    kind: kind,
                    mediaType: mediaType,
                    byteCount: Int64(text.utf8.count),
                    sha256: "fixture"
                )
            },
            removePluginResources: { _ in },
            accessibilityGranted: { true },
            presentAccessibilityAssist: { _ in }
        )

        coordinator.startPaste(coordinator.makePendingPasteRequest(
            recordID: record.id,
            targetContext: nil,
            promptForAccessibility: false
        ))
        let pasteTask = try XCTUnwrap(coordinator.pasteTask)
        await pasteTask.value

        XCTAssertEqual(pasteboard.writeCallCount, 1)
        XCTAssertEqual(pasteboard.items.count, 1)
        let writtenItem = try XCTUnwrap(pasteboard.items.first)
        XCTAssertEqual(writtenItem.semanticFileURL, fileURL)
        XCTAssertTrue(writtenItem.representations.isEmpty)
        XCTAssertEqual(observedWillAuthorization?.userInitiated, true)
    }

    @MainActor
    func testInMemoryLiveClipboardCaptureDoesNotDispatchDidPersistCapture()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginInMemoryCapture-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let defaultsSuite = "BlocksPluginInMemoryCapture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let privacyStore = PrivacyStore(
            repository: PrivacyPolicyRepository(database: database)
        )
        for _ in 0..<100 where !privacyStore.canCaptureClipboard {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(privacyStore.canCaptureClipboard)

        let clipboardStore = ClipboardStore(repository: nil)
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: clipboardStore,
            privacyStore: privacyStore,
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults)
        )
        var didPersistCaptureCount = 0
        let captureFinished = expectation(
            description: "in-memory capture task finishes"
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeTranslationPanel: {},
            translateRecord: { _ in },
            refreshPermissionState: {},
            dispatchPluginEvent: { envelope in
                if envelope.name == .clipboardDidPersistCapture {
                    didPersistCaptureCount += 1
                }
                return .allowed(envelope)
            },
            stagePluginTextResource: { text, kind, mediaType, _ in
                BlocksPluginResourceReference(
                    id: "in-memory-capture-resource",
                    kind: kind,
                    mediaType: mediaType,
                    byteCount: Int64(text.utf8.count),
                    sha256: "fixture"
                )
            },
            removePluginResources: { _ in
                captureFinished.fulfill()
            },
            accessibilityGranted: { true },
            presentAccessibilityAssist: { _ in }
        )
        let record = ClipboardRecorderRecord(
            id: "in-memory-capture",
            createdAt: Date(),
            changeCount: 9,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 17,
                byteCount: 17
            ),
            sourceApp: nil,
            signatureSHA256_12: "inmemorycap",
            fixtureOwned: true,
            restorable: true,
            summary: "memory capture text"
        )
        coordinator.ingestLiveCapture(
            ClipboardLiveCaptureSnapshot(
                record: record,
                payload: .init(
                    recordID: record.id,
                    kind: .text,
                    text: "memory capture text"
                )
            )
        )

        await fulfillment(of: [captureFinished], timeout: 2)
        XCTAssertEqual(clipboardStore.records.map(\.id), [record.id])
        XCTAssertTrue(clipboardStore.repositoryUnavailable)
        XCTAssertEqual(didPersistCaptureCount, 0)
    }

    @MainActor
    func testTextStagingFailureDoesNotDiscardClipboardCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginCaptureFailOpen-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let defaultsSuite = "BlocksPluginCaptureFailOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let privacyStore = PrivacyStore(
            repository: PrivacyPolicyRepository(database: database)
        )
        for _ in 0..<100 where !privacyStore.canCaptureClipboard {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(privacyStore.canCaptureClipboard)
        let clipboardStore = ClipboardStore(repository: repository)
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: clipboardStore,
            privacyStore: privacyStore,
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults)
        )
        var dispatchedEvents: [BlocksPluginEventName] = []
        let didPersistCapture = expectation(
            description: "core capture persists after plugin staging fails"
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeTranslationPanel: {},
            translateRecord: { _ in },
            refreshPermissionState: {},
            dispatchPluginEvent: {
                dispatchedEvents.append($0.name)
                if $0.name == .clipboardDidPersistCapture {
                    didPersistCapture.fulfill()
                }
                return .allowed($0)
            },
            stagePluginTextResource: { _, _, _, _ in nil },
            removePluginResources: { _ in },
            accessibilityGranted: { true },
            presentAccessibilityAssist: { _ in }
        )
        let record = ClipboardRecorderRecord(
            id: "plugin-staging-capture",
            createdAt: Date(),
            changeCount: 8,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 23,
                byteCount: 23
            ),
            sourceApp: nil,
            signatureSHA256_12: "capturefail1",
            fixtureOwned: true,
            restorable: true,
            summary: "capture survives staging"
        )
        coordinator.ingestLiveCapture(
            ClipboardLiveCaptureSnapshot(
                record: record,
                payload: .init(
                    recordID: record.id,
                    kind: .text,
                    text: "capture survives staging"
                )
            )
        )

        await fulfillment(of: [didPersistCapture], timeout: 2)
        let persistedPayload = try repository.readPayload(recordID: record.id)
        XCTAssertEqual(persistedPayload?.text, "capture survives staging")
        XCTAssertFalse(
            dispatchedEvents.contains(.clipboardWillPersistCapture),
            "A failed resource stage must not expose an incomplete pre-hook event."
        )
        XCTAssertTrue(
            dispatchedEvents.contains(.clipboardDidPersistCapture),
            "The post-event should still report the completed core capture."
        )
        XCTAssertEqual(
            dispatchedEvents.filter { $0 == .clipboardDidPersistCapture }.count,
            1,
            "A repository-backed capture should dispatch exactly one post-event."
        )
    }

    func testDebugLogAlwaysRedactsSecretsEvenInDebugMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginLog-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlocksPluginDebugLogStore(
            environment: StorageEnvironment(rootDirectory: root)
        )
        try store.append(
            pluginID: "com.example.debug",
            entry: [
                "input": .object([
                    "text": .string("visible"),
                    "authorization": .string("Bearer should-not-leak"),
                    "nested": .object([
                        "api_key": .string("should-not-leak"),
                    ]),
                ]),
            ]
        )
        let file = try XCTUnwrap(store.logFiles(
            pluginID: "com.example.debug"
        ).first)
        let log = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(log.contains("visible"))
        XCTAssertFalse(log.contains("should-not-leak"))
        XCTAssertTrue(log.contains("<redacted>"))
    }

    func testPluginLogStructuralSummaryRetainsOnlyTypeAndCounts() throws {
        let stringSentinel = "PLUGIN_STRING_SENTINEL_4B4C"
        let objectKeySentinel = "PLUGIN_OBJECT_KEY_SENTINEL_4B4C"
        let deepSentinel = "PLUGIN_DEEP_SENTINEL_4B4C"
        let hashSentinel = "a6a90c7efc0641d08c771f0b0123456789abcdef"
        let otp = 761_293

        XCTAssertEqual(
            BlocksPluginLogRedactor.structuralSummary(.string(stringSentinel)),
            .object([
                "type": .string("string"),
                "utf8_bytes": .int(stringSentinel.utf8.count),
            ])
        )
        let arraySummary = BlocksPluginLogRedactor.structuralSummary(.array([
            .object([objectKeySentinel: .string(deepSentinel)]),
        ]))
        XCTAssertEqual(
            arraySummary,
            .object(["type": .string("array"), "count": .int(1)])
        )
        XCTAssertEqual(
            BlocksPluginLogRedactor.structuralSummary(.int(otp)),
            .object(["type": .string("number")])
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStructuralLog-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlocksPluginDebugLogStore(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let summary = BlocksPluginLogRedactor.structuralSummary(.object([
            objectKeySentinel: .array([
                .object(["deep": .string(deepSentinel)]),
            ]),
            "otp": .int(otp),
            "hash": .string(hashSentinel),
        ]))
        try store.append(
            pluginID: "com.example.structural-log",
            entry: [
                "string_summary": BlocksPluginLogRedactor.structuralSummary(
                    .string(stringSentinel)
                ),
                "array_summary": arraySummary,
                "input_summary": summary,
            ]
        )
        let file = try XCTUnwrap(store.logFiles(
            pluginID: "com.example.structural-log"
        ).first)
        let persisted = try String(contentsOf: file, encoding: .utf8)

        for forbidden in [
            stringSentinel, objectKeySentinel, deepSentinel, hashSentinel,
            String(otp),
        ] {
            XCTAssertFalse(persisted.contains(forbidden))
        }
        XCTAssertTrue(persisted.contains("input_summary"))
        XCTAssertTrue(persisted.contains("field_count"))
        XCTAssertTrue(persisted.contains("\"type\":\"object\""))
    }

    func testPluginErrorLogSummaryRedactsRawBodiesAndSecretsForAuditAndDebug() throws {
        let bodyMarker = "plugin-error-body-6E8D77"
        let bearerToken = "Bearer token-6E8D77"
        let apiKeyQuery = "https://example.invalid/fail?api_key=query-6E8D77"
        let error = BlocksNativePluginExecutionError.executionFailed(
            code: "fixture_failure",
            message: "\(bodyMarker) \(bearerToken) \(apiKeyQuery)"
        )
        let summary = BlocksPluginLogRedactor.errorSummary(
            error,
            category: "plugin_execution",
            code: "execution_failed"
        )
        let auditMetadata = BlocksPluginLogRedactor.sanitize([
            "error": .string(error.localizedDescription),
            "stack": .string("frame \(bearerToken) \(apiKeyQuery)"),
        ].merging(summary, uniquingKeysWith: { _, new in new }))
        let auditData = try JSONEncoder().encode(auditMetadata)
        let auditLog = String(decoding: auditData, as: UTF8.self)
        XCTAssertFalse(auditLog.contains(bodyMarker))
        XCTAssertFalse(auditLog.contains("error_message_sha256"))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginLogSummary-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlocksPluginDebugLogStore(
            environment: StorageEnvironment(rootDirectory: root)
        )
        try store.append(
            pluginID: "com.example.error-debug",
            entry: [
                "error_detail": .string(error.localizedDescription),
                "stack": .string("frame \(bearerToken) \(apiKeyQuery)"),
            ].merging(summary, uniquingKeysWith: { _, new in new })
        )
        let file = try XCTUnwrap(store.logFiles(
            pluginID: "com.example.error-debug"
        ).first)
        let log = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(log.contains(bodyMarker))
        XCTAssertTrue(log.contains("<redacted_error_text>"))
        for forbidden in ["token-6E8D77", "query-6E8D77"] {
            XCTAssertFalse(log.contains(forbidden))
            XCTAssertFalse(auditLog.contains(forbidden))
        }
        XCTAssertTrue(log.contains("execution_failed"))
        XCTAssertFalse(log.contains("error_message_sha256"))
        XCTAssertTrue(auditLog.contains("execution_failed"))
    }

    func testRedirectErrorDetailNeverPersistsPrivatePathInDebugOrNonDebugLogs()
        async throws
    {
        let sentinel = "LEAK_SENTINEL"
        let privateURL = "https://private.example/private/\(sentinel)"
        let broker = BlocksNativePluginNetworkBroker(
            secretResolver: { _, _ in "" },
            addressResolver: { _ in [.ipv4("93.184.216.34")] },
            pinnedTransport: { _ in
                .init(
                    statusCode: 302,
                    headers: ["Location": privateURL],
                    body: Data()
                )
            }
        )
        let manifest = BlocksNativePluginManifest(
            id: "com.example.redirect-log",
            displayName: "Redirect Log",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(domains: ["api.example.com"], methods: [.get])
            )
        )
        let error: Error
        do {
            _ = try await broker.perform(
                request: .init(url: "https://api.example.com/start", method: .get),
                manifest: manifest,
                approvedDomains: ["api.example.com"],
                approvedMethods: [.get],
                approvedSecretIDs: []
            )
            return XCTFail("Expected the unapproved 302 redirect to be denied.")
        } catch let caughtError {
            error = caughtError
        }

        let summary = BlocksPluginLogRedactor.errorSummary(
            error,
            category: "network",
            code: "redirect_denied"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginRedirectLog-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlocksPluginDebugLogStore(
            environment: StorageEnvironment(rootDirectory: root)
        )
        try store.append(
            pluginID: "com.example.debug-on",
            entry: [
                "error_detail": .string(error.localizedDescription),
                "errorDetail": .string(error.localizedDescription),
                "error-detail": .string(error.localizedDescription),
                "pluginErrorMessage": .string(error.localizedDescription),
                "error_text": .string(error.localizedDescription),
                "error-text": .string(error.localizedDescription),
                "pluginErrorText": .string(error.localizedDescription),
            ]
                .merging(summary, uniquingKeysWith: { _, new in new })
        )
        try store.append(
            pluginID: "com.example.debug-off",
            entry: summary
        )

        for pluginID in ["com.example.debug-on", "com.example.debug-off"] {
            let file = try XCTUnwrap(store.logFiles(pluginID: pluginID).first)
            let persisted = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(persisted.contains(sentinel))
            XCTAssertFalse(persisted.contains(privateURL))
            XCTAssertTrue(persisted.contains("network"))
            XCTAssertTrue(persisted.contains("redirect_denied"))
            XCTAssertTrue(persisted.contains("error_message_length"))
        }
    }

    func testPluginLogRedactorRejectsSecretsInsideEncodedStringsAndHeaderKeys()
        throws
    {
        let sanitized = BlocksPluginLogRedactor.sanitize([
            "headers": .object([
                "X-API-Key": .string("HEADER_SECRET"),
                "Set-Cookie": .string("session=COOKIE_SECRET"),
            ]),
            "detail": .string(
                #"{"Cookie":"STRING_COOKIE","api_key":"STRING_KEY"}"#
            ),
            "fragment": .string(
                "https://example.invalid/#access_token=FRAGMENT_SECRET"
            ),
        ])
        let data = try JSONEncoder().encode(sanitized)
        let output = String(decoding: data, as: UTF8.self)

        for forbidden in [
            "HEADER_SECRET", "COOKIE_SECRET", "STRING_COOKIE",
            "STRING_KEY", "FRAGMENT_SECRET",
        ] {
            XCTAssertFalse(output.contains(forbidden))
        }
        XCTAssertTrue(output.contains("<redacted>"))
    }

    func testUserAuthorizedFileResourceStreamsWithoutLoadingInline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksPluginFile-\(UUID().uuidString)")
        let content = Data(String(repeating: "resource", count: 200_000).utf8)
        try content.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let broker = BlocksPluginResourceBroker()
        let reference = try broker.registerUserAuthorizedFile(
            url: url,
            mediaType: "application/octet-stream"
        )
        XCTAssertEqual(reference.byteCount, Int64(content.count))
        broker.authorize(pluginID: "com.example.file", resourceIDs: [reference.id])
        var restored = Data()
        var offset = 0
        while true {
            let response = try broker.read(
                pluginID: "com.example.file",
                id: reference.id,
                offset: offset,
                length: 65_537
            )
            guard case let .string(base64)? = response["data_base64"],
                  let data = Data(base64Encoded: base64),
                  case let .int(next)? = response["next_offset"],
                  case let .bool(eof)? = response["eof"] else {
                return XCTFail("Invalid file resource chunk")
            }
            restored.append(data)
            offset = next
            if eof { break }
        }
        XCTAssertEqual(restored, content)
        broker.remove(ids: [reference.id])
        XCTAssertThrowsError(try broker.read(
            pluginID: "com.example.file",
            id: reference.id,
            offset: 0,
            length: 1
        ))
    }

    @MainActor
    func testPluginNetworkAuditPersistsOnlyWhitelistedMetadata() async throws {
        let sessionSentinel = "SESSION_SENTINEL"
        let imageSentinel = "IMAGE_BASE64_SENTINEL"
        let oneTimePasscode = "482193"
        let pathSentinel = "RAW_PATH_SECRET"
        let encodedPathSentinel = "%50%41%54%48%5F%53%45%43%52%45%54"
        let requestHeaderSentinel = "X-Trace-REQUEST_HEADER_SECRET"
        let responseHeaderSentinel = "X-Trace-RESPONSE_HEADER_SECRET"
        let requestBody = Data(
            #"{"session":"SESSION_SENTINEL","otp":"482193","image":"IMAGE_BASE64_SENTINEL"}"#
                .utf8
        )
        let responseBody = Data(
            #"{"session":"SESSION_SENTINEL","otp":"482193","image":"IMAGE_BASE64_SENTINEL"}"#
                .utf8
        )
        let bodySHA256 = SHA256.hash(data: requestBody)
            .map { String(format: "%02x", $0) }
            .joined()
        let request = BlocksNativePluginNetworkRequest(
            requestID: UUID(),
            url: "https://user:password@example.invalid/reset/\(pathSentinel)/\(encodedPathSentinel)?session=SESSION_SENTINEL#IMAGE_BASE64_SENTINEL",
            method: .post,
            headers: [
                "Content-Type": "application/json",
                requestHeaderSentinel: sessionSentinel,
            ],
            body: requestBody,
            timeoutSeconds: 30
        )
        let response = BlocksNativePluginNetworkResponse(
            requestID: request.requestID,
            statusCode: 201,
            headers: [
                "Cache-Control": "no-store",
                responseHeaderSentinel: sessionSentinel,
            ],
            body: responseBody
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksPluginNetworkAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BlocksPluginDebugLogStore(
            environment: StorageEnvironment(rootDirectory: root)
        )
        for entry in [
            BlocksNativePluginXPCExecutionClient.networkRequestEntry(request),
            BlocksNativePluginXPCExecutionClient.networkResponseEntry(response),
        ] {
            try store.append(pluginID: "com.example.network-audit", entry: entry)
        }

        let file = try XCTUnwrap(store.logFiles(
            pluginID: "com.example.network-audit"
        ).first)
        let persisted = try String(contentsOf: file, encoding: .utf8)
        let manager = BlocksNativePluginManager(
            repository: RecordingPluginMetadataStore(),
            managedRoot: root.appendingPathComponent("Managed", isDirectory: true),
            executor: CancelledFailClosedHookExecutor(),
            secretStore: RecordingPluginSecretStore(),
            debugLogStore: store
        )
        let service = PluginDevelopmentService(
            pluginManager: manager,
            runtime: BlocksPluginRuntimeCoordinator(manager: manager)
        )
        let result = try await service.execute(
            .init(
                operation: .showLogs,
                pluginID: "com.example.network-audit"
            ),
            requestID: .make()
        )
        let exported = try XCTUnwrap(result.logs)

        for forbidden in [
            sessionSentinel,
            imageSentinel,
            oneTimePasscode,
            bodySHA256,
            pathSentinel,
            encodedPathSentinel,
            "PATH_SECRET",
            requestHeaderSentinel,
            responseHeaderSentinel,
            "user:password",
            "?session=",
            "/reset/",
        ] {
            XCTAssertFalse(persisted.contains(forbidden))
            XCTAssertFalse(exported.contains(forbidden))
        }
        XCTAssertTrue(persisted.contains("content-type"))
        XCTAssertTrue(persisted.contains("cache-control"))
        XCTAssertTrue(persisted.contains("custom_header_count"))
        XCTAssertTrue(persisted.contains("example.invalid"))
        XCTAssertTrue(persisted.contains("path_present"))
        XCTAssertTrue(persisted.contains("path_segment_count"))
        XCTAssertTrue(persisted.contains("status_code"))
        XCTAssertTrue(persisted.contains("byte_count"))
        XCTAssertTrue(exported.contains("byte_count"))
        XCTAssertFalse(persisted.contains("\"sha256\""))
        XCTAssertFalse(exported.contains("\"sha256\""))
    }

    func testPrivateValueConcurrentCASAcrossRepositoriesAllowsExactlyOneWrite()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginPrivateCAS-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let firstDatabase = try AppDatabase.open(environment: environment)
        let secondDatabase = try AppDatabase.open(environment: environment)
        defer {
            firstDatabase.close()
            secondDatabase.close()
        }

        let pluginID = "com.example.private-cas"
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Private CAS",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(storage: .init(kinds: [.keyValue]))
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function run() {}",
            packageSHA256: "private-cas-fixture",
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: pluginID,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "private-cas-fixture",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try BlocksNativePluginMetadataRepository(database: firstDatabase)
            .installApproved(
                package: package,
                installedRelativePath: pluginID,
                permissions: manifest.declaredPermissionTokens,
                domains: []
            )

        let firstRepository = BlocksPluginPlatformRepository(database: firstDatabase)
        let secondRepository = BlocksPluginPlatformRepository(database: secondDatabase)
        let createdWithZeroRevision = try firstRepository.putPrivateValue(
            pluginID: pluginID,
            key: "created-with-cas",
            value: .string("created"),
            expectedRevision: 0
        )
        XCTAssertEqual(createdWithZeroRevision.revision, 1)
        XCTAssertThrowsError(try secondRepository.putPrivateValue(
            pluginID: pluginID,
            key: "created-with-cas",
            value: .string("must-conflict"),
            expectedRevision: 0
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .revisionConflict(expected: 0, actual: 1)
            )
        }
        let initial = try firstRepository.putPrivateValue(
            pluginID: pluginID,
            key: "counter",
            value: .int(0)
        )
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Result<BlocksPluginStoredValue, Error>] = []
        for (repository, value) in [
            (firstRepository, JSONValue.int(1)),
            (secondRepository, JSONValue.int(2)),
        ] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try repository.putPrivateValue(
                        pluginID: pluginID,
                        key: "counter",
                        value: value,
                        expectedRevision: initial.revision
                    )
                }
                lock.withLock { results.append(result) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(
            results.filter {
                if case let .failure(error as BlocksPluginPlatformRepositoryError) = $0 {
                    return error == .revisionConflict(expected: 1, actual: 2)
                }
                return false
            }.count,
            1
        )
        let final = try XCTUnwrap(
            firstRepository.privateValue(pluginID: pluginID, key: "counter")
        )
        XCTAssertEqual(final.revision, initial.revision + 1)
        XCTAssertTrue([JSONValue.int(1), .int(2)].contains(final.value))
    }

    func testSharedValueConcurrentCASAcrossRepositoriesAllowsExactlyOneWrite()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSharedCAS-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let firstDatabase = try AppDatabase.open(environment: environment)
        let secondDatabase = try AppDatabase.open(environment: environment)
        defer {
            firstDatabase.close()
            secondDatabase.close()
        }

        let pluginID = "com.example.shared-cas"
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Shared CAS",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(
                sharedState: [
                    .init(
                        id: "counter",
                        schemaVersion: 1,
                        schema: [:],
                        access: .readWrite
                    ),
                ]
            )
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function run() {}",
            packageSHA256: "shared-cas-fixture",
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: pluginID,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "shared-cas-fixture",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try BlocksNativePluginMetadataRepository(database: firstDatabase)
            .installApproved(
                package: package,
                installedRelativePath: pluginID,
                permissions: manifest.declaredPermissionTokens,
                domains: []
            )

        let firstRepository = BlocksPluginPlatformRepository(database: firstDatabase)
        let secondRepository = BlocksPluginPlatformRepository(database: secondDatabase)
        let createdWithZeroRevision = try firstRepository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "counter",
            key: "created-with-cas",
            schemaVersion: 1,
            value: .string("created"),
            expectedRevision: 0
        )
        XCTAssertEqual(createdWithZeroRevision.revision, 1)
        XCTAssertThrowsError(try secondRepository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "counter",
            key: "created-with-cas",
            schemaVersion: 1,
            value: .string("must-conflict"),
            expectedRevision: 0
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .revisionConflict(expected: 0, actual: 1)
            )
        }
        let initial = try firstRepository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "counter",
            key: "value",
            schemaVersion: 1,
            value: .int(0)
        )
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Result<BlocksPluginStoredValue, Error>] = []
        for (repository, value) in [
            (firstRepository, JSONValue.int(1)),
            (secondRepository, JSONValue.int(2)),
        ] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try repository.putSharedValue(
                        actorPluginID: pluginID,
                        ownerPluginID: pluginID,
                        namespace: "counter",
                        key: "value",
                        schemaVersion: 1,
                        value: value,
                        expectedRevision: initial.revision
                    )
                }
                lock.withLock { results.append(result) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(
            results.filter {
                if case let .failure(error as BlocksPluginPlatformRepositoryError) = $0 {
                    return error == .revisionConflict(expected: 1, actual: 2)
                }
                return false
            }.count,
            1
        )
        let final = try XCTUnwrap(
            firstRepository.sharedValue(
                actorPluginID: pluginID,
                ownerPluginID: pluginID,
                namespace: "counter",
                key: "value"
            )
        )
        XCTAssertEqual(final.revision, initial.revision + 1)
        XCTAssertTrue([JSONValue.int(1), .int(2)].contains(final.value))
    }

    func testSharedStorageQuotaRejectsGrowthAndPreservesValueAndRevision()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSharedQuota-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.shared-quota"
        let repository = try installSharedStoragePlugin(
            database: database,
            pluginID: pluginID,
            namespace: "quota"
        )
        let exactValue = String(repeating: "v", count: 1_048_574)
        let stored = try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota",
            key: "value",
            schemaVersion: 1,
            value: .string(exactValue)
        )

        XCTAssertThrowsError(try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota",
            key: "value",
            schemaVersion: 1,
            value: .string(exactValue + "v"),
            expectedRevision: stored.revision
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        let unchanged = try XCTUnwrap(repository.sharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota",
            key: "value"
        ))
        XCTAssertEqual(unchanged.value, stored.value)
        XCTAssertEqual(unchanged.revision, stored.revision)
    }

    func testSharedStorageAggregateQuotaAllowsReplacementShrink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSharedQuotaAggregate-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.shared-quota-aggregate"
        let repository = try installSharedStoragePlugin(
            database: database,
            pluginID: pluginID,
            namespace: "quota"
        )
        let payload = String(repeating: "a", count: 1_047_998)
        for index in 0..<8 {
            _ = try repository.putSharedValue(
                actorPluginID: pluginID,
                ownerPluginID: pluginID,
                namespace: "quota",
                key: "k\(index)",
                schemaVersion: 1,
                value: .string(payload)
            )
        }

        XCTAssertThrowsError(try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota",
            key: "overflow",
            schemaVersion: 1,
            value: .string(String(repeating: "b", count: 5_000))
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        _ = try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota",
            key: "k0",
            schemaVersion: 1,
            value: .string("s")
        )
        XCTAssertNoThrow(try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota",
            key: "overflow",
            schemaVersion: 1,
            value: .string(String(repeating: "b", count: 5_000))
        ))
    }

    func testSharedStorageEntryQuotaCountsOwnerEntriesAcrossNamespaces()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSharedEntryQuota-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        let pluginID = "com.example.shared-entry-quota"
        _ = try installSharedStoragePlugin(
            database: database,
            pluginID: pluginID,
            namespace: "quota-a"
        )
        database.close()
        try seedSharedStorageEntries(
            environment: environment,
            ownerPluginID: pluginID,
            count: 4_096
        )

        let reopened = try AppDatabase.open(environment: environment)
        defer { reopened.close() }
        let repository = BlocksPluginPlatformRepository(database: reopened)
        XCTAssertThrowsError(try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-b",
            key: "overflow",
            schemaVersion: 1,
            value: .null
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        XCTAssertNil(try repository.sharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-b",
            key: "overflow"
        ))

        let replaced = try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-a",
            key: "key-0",
            schemaVersion: 1,
            value: .bool(true),
            expectedRevision: 1
        )
        XCTAssertEqual(replaced.revision, 2)
        XCTAssertEqual(replaced.value, .bool(true))
    }

    func testSharedStorageOverEntryQuotaRejectsGrowthWithoutMutation()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSharedLegacyEntryQuota-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        let pluginID = "com.example.shared-legacy-entry-quota"
        _ = try installSharedStoragePlugin(
            database: database,
            pluginID: pluginID,
            namespace: "quota-a"
        )
        database.close()
        try seedSharedStorageEntries(
            environment: environment,
            ownerPluginID: pluginID,
            count: 4_097
        )

        let reopened = try AppDatabase.open(environment: environment)
        defer { reopened.close() }
        let repository = BlocksPluginPlatformRepository(database: reopened)
        let original = try XCTUnwrap(repository.sharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-a",
            key: "key-0"
        ))
        XCTAssertThrowsError(try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-b",
            key: "overflow",
            schemaVersion: 1,
            value: .null
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        XCTAssertThrowsError(try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-a",
            key: "key-0",
            schemaVersion: 1,
            value: .string("growth"),
            expectedRevision: original.revision
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        let unchanged = try XCTUnwrap(repository.sharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-a",
            key: "key-0"
        ))
        XCTAssertEqual(unchanged, original)

        let replaced = try repository.putSharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-a",
            key: "key-0",
            schemaVersion: 1,
            value: .bool(true),
            expectedRevision: original.revision
        )
        XCTAssertEqual(replaced.revision, original.revision + 1)
        XCTAssertEqual(replaced.value, .bool(true))
        XCTAssertNil(try repository.sharedValue(
            actorPluginID: pluginID,
            ownerPluginID: pluginID,
            namespace: "quota-b",
            key: "overflow"
        ))
    }

    func testPrivateQueueZeroRevisionCASIsAtomicAcrossRepositories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginQueueCAS-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let firstDatabase = try AppDatabase.open(environment: environment)
        let secondDatabase = try AppDatabase.open(environment: environment)
        defer {
            firstDatabase.close()
            secondDatabase.close()
        }

        let pluginID = "com.example.queue-cas"
        _ = try installPrivateStoragePlugin(
            database: firstDatabase,
            pluginID: pluginID
        )
        let firstRepository = BlocksPluginPlatformRepository(database: firstDatabase)
        let secondRepository = BlocksPluginPlatformRepository(database: secondDatabase)
        let empty = try firstRepository.dequeuePrivateValue(
            pluginID: pluginID,
            key: "jobs",
            expectedRevision: 0
        )
        XCTAssertEqual(empty, .init(value: nil, remainingCount: 0, revision: 0))
        XCTAssertNil(try firstRepository.privateValue(pluginID: pluginID, key: "jobs"))
        XCTAssertThrowsError(try firstRepository.dequeuePrivateValue(
            pluginID: pluginID,
            key: "jobs",
            expectedRevision: 1
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .revisionConflict(expected: 1, actual: 0)
            )
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Result<BlocksPluginQueueResult, Error>] = []
        for (repository, value) in [
            (firstRepository, JSONValue.string("first")),
            (secondRepository, JSONValue.string("second")),
        ] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try repository.enqueuePrivateValue(
                        pluginID: pluginID,
                        key: "jobs",
                        value: value,
                        expectedRevision: 0
                    )
                }
                lock.withLock { results.append(result) }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(
            results.filter { if case .success = $0 { true } else { false } }.count,
            1
        )
        XCTAssertEqual(
            results.filter {
                if case let .failure(error as BlocksPluginPlatformRepositoryError) = $0 {
                    return error == .revisionConflict(expected: 0, actual: 1)
                }
                return false
            }.count,
            1
        )
        let final = try XCTUnwrap(
            firstRepository.privateValue(pluginID: pluginID, key: "jobs")
        )
        XCTAssertEqual(final.revision, 1)
        guard case let .array(items) = final.value else {
            return XCTFail("Expected queue storage to contain an array.")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue([JSONValue.string("first"), .string("second")].contains(items[0]))
    }

    func testPrivateQueuePreservesFIFOAndCASRevisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginQueue-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }

        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.queue",
            displayName: "Queue",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: .init(
                actions: [
                    .init(id: "run", displayName: "Run")
                ],
                storage: .init(kinds: [.queue])
            )
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let packageHash = "queue-fixture"
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: manifestData,
            entrySource: "function performAction() { return {}; }",
            packageSHA256: packageHash,
            relativeFilePaths: ["main.js", "manifest.json"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: packageHash,
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try BlocksNativePluginMetadataRepository(database: database)
            .installApproved(
                package: package,
                installedRelativePath: "com.example.queue",
                permissions: ["storage:private"],
                domains: []
            )

        let repository = BlocksPluginPlatformRepository(database: database)
        let first = try repository.enqueuePrivateValue(
            pluginID: manifest.id,
            key: "jobs",
            value: .string("first")
        )
        let second = try repository.enqueuePrivateValue(
            pluginID: manifest.id,
            key: "jobs",
            value: .string("second"),
            expectedRevision: first.revision
        )
        XCTAssertEqual(second.remainingCount, 2)

        let dequeuedFirst = try repository.dequeuePrivateValue(
            pluginID: manifest.id,
            key: "jobs",
            expectedRevision: second.revision
        )
        XCTAssertEqual(dequeuedFirst.value, .string("first"))
        XCTAssertEqual(dequeuedFirst.remainingCount, 1)
        let dequeuedSecond = try repository.dequeuePrivateValue(
            pluginID: manifest.id,
            key: "jobs",
            expectedRevision: dequeuedFirst.revision
        )
        XCTAssertEqual(dequeuedSecond.value, .string("second"))
        XCTAssertEqual(dequeuedSecond.remainingCount, 0)
        XCTAssertThrowsError(
            try repository.enqueuePrivateValue(
                pluginID: manifest.id,
                key: "jobs",
                value: .string("stale"),
                expectedRevision: second.revision
            )
        )
    }

    func testManifestRefreshPreservesEnabledScheduleState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginSchedule-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let metadataRepository = BlocksNativePluginMetadataRepository(
            database: database
        )
        let platformRepository = BlocksPluginPlatformRepository(
            database: database
        )
        let firstPlatform = BlocksPluginPlatformConfiguration(
            schedules: [
                .init(
                    id: "daily",
                    kind: .calendar,
                    configuration: ["hour": .int(9)]
                ),
            ]
        )
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.schedule",
            displayName: "Schedule",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.actions],
            platform: firstPlatform
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function handleSchedule() { return {}; }",
            packageSHA256: "schedule-fixture",
            relativeFilePaths: ["main.js", "manifest.json"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "schedule-fixture",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try metadataRepository.installApproved(
            package: package,
            installedRelativePath: "com.example.schedule",
            permissions: manifest.declaredPermissionTokens,
            domains: []
        )
        try platformRepository.synchronizeManifest(
            pluginID: manifest.id,
            platform: firstPlatform
        )
        try platformRepository.setScheduleEnabled(
            true,
            pluginID: manifest.id,
            scheduleID: "daily"
        )

        let updatedPlatform = BlocksPluginPlatformConfiguration(
            schedules: [
                .init(
                    id: "daily",
                    kind: .calendar,
                    configuration: ["hour": .int(10)]
                ),
            ]
        )
        try platformRepository.synchronizeManifest(
            pluginID: manifest.id,
            platform: updatedPlatform
        )
        let binding = try XCTUnwrap(
            platformRepository.scheduleBindings(
                pluginID: manifest.id,
                runnableOnly: false
            ).first
        )
        XCTAssertTrue(binding.isEnabled)
        XCTAssertEqual(binding.configuration["hour"], .int(10))
    }

    func testRepeatedHookFailureDisablesOnlyThatHook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginHookSafety-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let metadataRepository = BlocksNativePluginMetadataRepository(
            database: database
        )
        let platformRepository = BlocksPluginPlatformRepository(
            database: database
        )
        let platform = BlocksPluginPlatformConfiguration(
            hooks: [
                .init(
                    id: "unstable",
                    event: .clipboardWillWritePasteboard
                ),
                .init(
                    id: "healthy",
                    event: .clipboardWillWritePasteboard
                ),
            ]
        )
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.hook-safety",
            displayName: "Hook Safety",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.hooks],
            platform: platform
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function handleHook() { return {}; }",
            packageSHA256: "hook-safety-fixture",
            relativeFilePaths: ["main.js", "manifest.json"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "hook-safety-fixture",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try metadataRepository.installApproved(
            package: package,
            installedRelativePath: manifest.id,
            permissions: manifest.declaredPermissionTokens,
            domains: []
        )
        _ = try metadataRepository.setEnabled(
            true,
            pluginID: manifest.id
        )
        try platformRepository.synchronizeManifest(
            pluginID: manifest.id,
            platform: platform
        )

        XCTAssertFalse(try platformRepository.recordHookExecutionOutcome(
            pluginID: manifest.id,
            hookID: "unstable",
            succeeded: false
        ))
        XCTAssertFalse(try platformRepository.recordHookExecutionOutcome(
            pluginID: manifest.id,
            hookID: "unstable",
            succeeded: false
        ))
        XCTAssertTrue(try platformRepository.recordHookExecutionOutcome(
            pluginID: manifest.id,
            hookID: "unstable",
            succeeded: false
        ))

        let all = try platformRepository.hookBindings(pluginID: manifest.id)
        let unstable = try XCTUnwrap(all.first { $0.hookID == "unstable" })
        let healthy = try XCTUnwrap(all.first { $0.hookID == "healthy" })
        XCTAssertTrue(unstable.safetyDisabled)
        XCTAssertFalse(unstable.isEnabled)
        XCTAssertEqual(unstable.consecutiveFailureCount, 3)
        XCTAssertFalse(healthy.safetyDisabled)
        XCTAssertTrue(healthy.isEnabled)
        XCTAssertEqual(
            try platformRepository.hookBindings(
                for: .clipboardWillWritePasteboard
            ).map(\.hookID),
            ["healthy"]
        )
        XCTAssertFalse(
            try metadataRepository.metadata(id: manifest.id).safetyDisabled
        )

        try platformRepository.setHookEnabled(
            true,
            pluginID: manifest.id,
            hookID: "unstable"
        )
        let restored = try XCTUnwrap(
            try platformRepository.hookBindings(pluginID: manifest.id)
                .first { $0.hookID == "unstable" }
        )
        XCTAssertTrue(restored.isEnabled)
        XCTAssertFalse(restored.safetyDisabled)
        XCTAssertEqual(restored.consecutiveFailureCount, 0)
    }

    func testVersionFifteenRepairsEarlyDevelopmentHookSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginV15Repair-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let initial = try AppDatabase.open(environment: environment)
        initial.close()

        var legacyHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                environment.databaseURL.path,
                &legacyHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let legacySQL =
            """
            DROP TABLE plugin_hook_bindings;
            CREATE TABLE plugin_hook_bindings (
                plugin_id TEXT NOT NULL,
                hook_id TEXT NOT NULL,
                event_name TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                timeout_ms INTEGER NOT NULL DEFAULT 500,
                failure_policy TEXT NOT NULL DEFAULT 'fail_open',
                last_failure_at REAL,
                PRIMARY KEY(plugin_id, hook_id)
            );
            """
        var legacyError: UnsafeMutablePointer<CChar>?
        let legacyResult = sqlite3_exec(
            legacyHandle,
            legacySQL,
            nil,
            nil,
            &legacyError
        )
        let legacyMessage = legacyError.map { String(cString: $0) }
        if let legacyError {
            sqlite3_free(legacyError)
        }
        sqlite3_close(legacyHandle)
        XCTAssertEqual(legacyResult, SQLITE_OK, legacyMessage ?? "")

        let repaired = try AppDatabase.open(environment: environment)
        defer { repaired.close() }
        repaired.close()

        var verificationHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                environment.databaseURL.path,
                &verificationHandle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                verificationHandle,
                "PRAGMA table_info(plugin_hook_bindings)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        sqlite3_finalize(statement)
        sqlite3_close(verificationHandle)
        XCTAssertTrue(columns.contains("safety_disabled"))
        XCTAssertTrue(columns.contains("consecutive_failure_count"))
    }

    func testVersionSixteenMigratesExistingPluginsAsExternal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginV16Migration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let initial = try AppDatabase.open(environment: environment)
        let repository = BlocksNativePluginMetadataRepository(database: initial)
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.pre-v16",
            displayName: "Pre-v16",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init()
        )
        let data = try JSONEncoder().encode(manifest)
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: data,
            entrySource: "function run() { return {}; }",
            packageSHA256: String(repeating: "f", count: 64),
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: String(repeating: "f", count: 64),
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try repository.installPending(
            package: package,
            installedRelativePath: "com.example.pre-v16/1.0.0"
        )
        initial.close()

        var legacyHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                environment.databaseURL.path,
                &legacyHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        var legacyError: UnsafeMutablePointer<CChar>?
        let legacyResult = sqlite3_exec(
            legacyHandle,
            """
            ALTER TABLE plugin_metadata DROP COLUMN built_in_catalog_version;
            ALTER TABLE plugin_metadata DROP COLUMN installation_origin;
            PRAGMA user_version = 15;
            """,
            nil,
            nil,
            &legacyError
        )
        let legacyMessage = legacyError.map { String(cString: $0) }
        if let legacyError {
            sqlite3_free(legacyError)
        }
        sqlite3_close(legacyHandle)
        XCTAssertEqual(legacyResult, SQLITE_OK, legacyMessage ?? "")

        let migrated = try AppDatabase.open(environment: environment)
        defer { migrated.close() }
        XCTAssertEqual(try migrated.userVersion(), 17)
        let metadata = try BlocksNativePluginMetadataRepository(
            database: migrated
        ).metadata(id: manifest.id)
        XCTAssertEqual(metadata.installationOrigin, .external)
        XCTAssertNil(metadata.builtInCatalogVersion)
    }

    func testHostCapabilityRegistryDoesNotContainBuiltInPluginIdentifiers()
        throws
    {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        for pluginID in catalog.document.entries.map(\.id) {
            XCTAssertFalse(
                BlocksPluginHostAPIV2.actionIDs.contains(pluginID),
                "Host capabilities must remain generic rather than plugin-specific"
            )
        }
    }

    func testEveryPublicHostActionHasAnExplicitKnownRiskClassification() {
        let publicActionIDs = BlocksPluginHostActionRegistryV1.actionIDs
            .union(BlocksPluginHostAPIV2.actionIDs)

        for actionID in publicActionIDs {
            XCTAssertNotEqual(
                BlocksPluginHostActionRegistryV1.risk(for: actionID),
                .unknown,
                "Public host action \(actionID) must have an explicit risk classification."
            )
        }

        XCTAssertEqual(
            BlocksPluginHostActionRegistryV1.risk(
                for: "host.action.unknown.future"
            ),
            .unknown
        )
    }

    func testPrivateStorageValueNamespaceAndKeyUTF8Quotas() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageQuota-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.storage-quota-dimensions"
        let repository = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )

        let exactValue = String(
            repeating: "v",
            count: 1_048_574
        )
        XCTAssertEqual(
            try repository.putPrivateValue(
                pluginID: pluginID,
                key: "value-exact",
                value: .string(exactValue)
            ).value,
            .string(exactValue)
        )
        XCTAssertThrowsError(
            try repository.putPrivateValue(
                pluginID: pluginID,
                key: "value-over",
                value: .string(exactValue + "v")
            )
        ) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }

        let exactNamespace = String(
            repeating: "n",
            count: 128
        )
        XCTAssertNoThrow(try repository.putPrivateValue(
            pluginID: pluginID,
            namespace: exactNamespace,
            key: "namespace-exact",
            value: .null
        ))
        XCTAssertThrowsError(try repository.putPrivateValue(
            pluginID: pluginID,
            namespace: exactNamespace + "n",
            key: "namespace-over",
            value: .null
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }

        let exactKey = String(
            repeating: "k",
            count: 256
        )
        XCTAssertNoThrow(try repository.putPrivateValue(
            pluginID: pluginID,
            key: exactKey,
            value: .null
        ))
        XCTAssertThrowsError(try repository.putPrivateValue(
            pluginID: pluginID,
            key: exactKey + "k",
            value: .null
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
    }

    func testPrivateStorageAggregateQuotaAllowsReplacementShrink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageQuotaAggregate-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.storage-quota-aggregate"
        let repository = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )
        let payload = String(repeating: "a", count: 1_047_998)
        for index in 0..<8 {
            _ = try repository.putPrivateValue(
                pluginID: pluginID,
                key: "k\(index)",
                value: .string(payload)
            )
        }

        XCTAssertThrowsError(try repository.putPrivateValue(
            pluginID: pluginID,
            key: "overflow",
            value: .string(String(repeating: "b", count: 5_000))
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        _ = try repository.putPrivateValue(
            pluginID: pluginID,
            key: "k0",
            value: .string("s")
        )
        XCTAssertNoThrow(try repository.putPrivateValue(
            pluginID: pluginID,
            key: "overflow",
            value: .string(String(repeating: "b", count: 5_000))
        ))
    }

    func testPrivateQueueQuotasPreserveRevisionAndFIFO() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageQuotaQueue-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.storage-quota-queue"
        let repository = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )
        let exactItem = String(
            repeating: "q",
            count: 65_534
        )
        let first = try repository.enqueuePrivateValue(
            pluginID: pluginID,
            key: "items",
            value: .string(exactItem)
        )
        XCTAssertThrowsError(try repository.enqueuePrivateValue(
            pluginID: pluginID,
            key: "items",
            value: .string(exactItem + "q"),
            expectedRevision: first.revision
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        XCTAssertEqual(
            try repository.privateValue(pluginID: pluginID, key: "items")?.revision,
            first.revision
        )
        XCTAssertEqual(
            try repository.dequeuePrivateValue(
                pluginID: pluginID,
                key: "items",
                expectedRevision: first.revision
            ).value,
            .string(exactItem)
        )

        var revision: Int64?
        for index in 0..<256 {
            let result = try repository.enqueuePrivateValue(
                pluginID: pluginID,
                key: "counted-items",
                value: .int(index),
                expectedRevision: revision
            )
            revision = result.revision
        }
        XCTAssertThrowsError(try repository.enqueuePrivateValue(
            pluginID: pluginID,
            key: "counted-items",
            value: .int(256),
            expectedRevision: revision
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        let dequeued = try repository.dequeuePrivateValue(
            pluginID: pluginID,
            key: "counted-items",
            expectedRevision: revision
        )
        XCTAssertEqual(dequeued.value, .int(0))
        XCTAssertEqual(
            dequeued.remainingCount,
            255
        )
    }

    func testPrivateQueueRejectsOversizedArraySeededThroughKeyValue()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageQueueSeed-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.storage-queue-seed"
        let repository = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )
        let seeded = try repository.putPrivateValue(
            pluginID: pluginID,
            key: "items",
            value: .array(Array(repeating: .null, count: 257))
        )

        XCTAssertThrowsError(try repository.dequeuePrivateValue(
            pluginID: pluginID,
            key: "items",
            expectedRevision: seeded.revision
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        let unchanged = try XCTUnwrap(repository.privateValue(
            pluginID: pluginID,
            key: "items"
        ))
        XCTAssertEqual(unchanged.revision, seeded.revision)
        XCTAssertEqual(unchanged.value, seeded.value)
    }

    func testPrivateQueueDequeueRejectsOversizedSeededItemWithoutMutation()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageQueueOversizedSeed-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer { database.close() }
        let pluginID = "com.example.storage-queue-oversized-seed"
        let repository = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )
        let oversizedItem = JSONValue.string(String(
            repeating: "q",
            count: 65_536
        ))
        XCTAssertGreaterThan(
            try JSONEncoder().encode(oversizedItem).count,
            65_536
        )
        let seeded = try repository.putPrivateValue(
            pluginID: pluginID,
            key: "items",
            value: .array([oversizedItem])
        )

        XCTAssertThrowsError(try repository.dequeuePrivateValue(
            pluginID: pluginID,
            key: "items",
            expectedRevision: seeded.revision
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        let unchanged = try XCTUnwrap(repository.privateValue(
            pluginID: pluginID,
            key: "items"
        ))
        XCTAssertEqual(unchanged.revision, seeded.revision)
        XCTAssertEqual(unchanged.value, seeded.value)
    }

    func testPrivateStorageEntryQuotaRejectsNewKeyButAllowsReplacement()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageEntryQuota-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        let pluginID = "com.example.storage-entry-quota"
        _ = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )
        database.close()

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                environment.databaseURL.path,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        var errorMessage: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                """
                WITH RECURSIVE indices(value) AS (
                    SELECT 0
                    UNION ALL
                    SELECT value + 1 FROM indices WHERE value < 4095
                )
                INSERT INTO plugin_storage (
                    plugin_id, namespace, key, value_json, revision, updated_at
                )
                SELECT
                    '\(pluginID)', 'default', 'key-' || value, 'null', 1, 0
                FROM indices;
                """,
                nil,
                nil,
                &errorMessage
            ),
            SQLITE_OK,
            errorMessage.map { String(cString: $0) } ?? ""
        )
        if let errorMessage { sqlite3_free(errorMessage) }
        sqlite3_close(handle)

        let reopened = try AppDatabase.open(environment: environment)
        defer { reopened.close() }
        let reopenedRepository = BlocksPluginPlatformRepository(
            database: reopened
        )
        XCTAssertThrowsError(try reopenedRepository.putPrivateValue(
            pluginID: pluginID,
            key: "overflow",
            value: .null
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .storageQuotaExceeded
            )
        }
        let updated = try reopenedRepository.putPrivateValue(
            pluginID: pluginID,
            key: "key-0",
            value: .bool(true),
            expectedRevision: 1
        )
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.value, .bool(true))
        XCTAssertNil(try reopenedRepository.privateValue(
            pluginID: pluginID,
            key: "overflow"
        ))
    }

    func testPrivateStorageStaleCASBeatsQuotaAndLegacyRowsCanShrink()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginStorageQuotaLegacy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(rootDirectory: root)
        let database = try AppDatabase.open(environment: environment)
        let pluginID = "com.example.storage-quota-legacy"
        let repository = try installPrivateStoragePlugin(
            database: database,
            pluginID: pluginID
        )
        let initial = try repository.putPrivateValue(
            pluginID: pluginID,
            key: "cas",
            value: .int(1)
        )
        XCTAssertThrowsError(try repository.putPrivateValue(
            pluginID: pluginID,
            key: "cas",
            value: .string(String(
                repeating: "x",
                count: 1_048_576
            )),
            expectedRevision: initial.revision - 1
        )) { error in
            XCTAssertEqual(
                error as? BlocksPluginPlatformRepositoryError,
                .revisionConflict(expected: 0, actual: initial.revision)
            )
        }
        XCTAssertEqual(
            try repository.privateValue(pluginID: pluginID, key: "cas")?.revision,
            initial.revision
        )
        database.close()

        let legacyNamespace = String(
            repeating: "n",
            count: 129
        )
        var legacyHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                environment.databaseURL.path,
                &legacyHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        var legacyError: UnsafeMutablePointer<CChar>?
        let legacyResult = sqlite3_exec(
            legacyHandle,
            """
            INSERT INTO plugin_storage (
                plugin_id, namespace, key, value_json, revision, updated_at
            ) VALUES ('\(pluginID)', '\(legacyNamespace)', 'legacy', '"legacy"', 1, 0);
            """,
            nil,
            nil,
            &legacyError
        )
        let legacyMessage = legacyError.map { String(cString: $0) }
        if let legacyError {
            sqlite3_free(legacyError)
        }
        sqlite3_close(legacyHandle)
        XCTAssertEqual(legacyResult, SQLITE_OK, legacyMessage ?? "")

        let reopened = try AppDatabase.open(environment: environment)
        defer { reopened.close() }
        let reopenedRepository = BlocksPluginPlatformRepository(database: reopened)
        let legacy = try XCTUnwrap(reopenedRepository.privateValue(
            pluginID: pluginID,
            namespace: legacyNamespace,
            key: "legacy"
        ))
        XCTAssertEqual(legacy.value, .string("legacy"))
        let shrunk = try reopenedRepository.putPrivateValue(
            pluginID: pluginID,
            namespace: legacyNamespace,
            key: "legacy",
            value: .string("x"),
            expectedRevision: legacy.revision
        )
        XCTAssertEqual(shrunk.revision, legacy.revision + 1)
        XCTAssertEqual(shrunk.value, .string("x"))
    }

    private func installPrivateStoragePlugin(
        database: AppDatabase,
        pluginID: String
    ) throws -> BlocksPluginPlatformRepository {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Storage quota fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(storage: .init(kinds: [.keyValue, .queue]))
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function run() {}",
            packageSHA256: "storage-quota-fixture-\(pluginID)",
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: pluginID,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "storage-quota-fixture-\(pluginID)",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try BlocksNativePluginMetadataRepository(database: database)
            .installApproved(
                package: package,
                installedRelativePath: pluginID,
                permissions: manifest.declaredPermissionTokens,
                domains: []
            )
        return BlocksPluginPlatformRepository(database: database)
    }

    private func installSharedStoragePlugin(
        database: AppDatabase,
        pluginID: String,
        namespace: String
    ) throws -> BlocksPluginPlatformRepository {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Shared storage quota fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(sharedState: [
                .init(
                    id: namespace,
                    schemaVersion: 1,
                    schema: [:],
                    access: .readWrite
                )
            ])
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function run() {}",
            packageSHA256: "shared-quota-fixture-\(pluginID)",
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: pluginID,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "shared-quota-fixture-\(pluginID)",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        _ = try BlocksNativePluginMetadataRepository(database: database)
            .installApproved(
                package: package,
                installedRelativePath: pluginID,
                permissions: manifest.declaredPermissionTokens,
                domains: []
        )
        return BlocksPluginPlatformRepository(database: database)
    }

    private func seedSharedStorageEntries(
        environment: StorageEnvironment,
        ownerPluginID: String,
        count: Int
    ) throws {
        precondition(count > 0)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            environment.databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw NSError(
                domain: "BlocksNativePluginTests",
                code: Int(SQLITE_CANTOPEN),
                userInfo: [NSLocalizedDescriptionKey: "Could not open fixture database."]
            )
        }
        defer { sqlite3_close(handle) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            handle,
            """
            WITH RECURSIVE indices(value) AS (
                SELECT 0
                UNION ALL
                SELECT value + 1 FROM indices WHERE value < \(count - 1)
            )
            INSERT INTO plugin_shared_state (
                owner_plugin_id, namespace, key, schema_version,
                value_json, revision, updated_at
            )
            SELECT
                '\(ownerPluginID)',
                CASE WHEN value % 2 = 0 THEN 'quota-a' ELSE 'quota-b' END,
                'key-' || value,
                1,
                'null',
                1,
                0
            FROM indices;
            """,
            nil,
            nil,
            &errorMessage
        )
        let message = errorMessage.map { String(cString: $0) }
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "BlocksNativePluginTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message ?? "Fixture seed failed."]
            )
        }
    }
}

final class BlocksNativePluginJavaScriptRunnerTests: XCTestCase {
    func testInputEchoExampleReturnsCompleteSemanticInvocationWithoutImageBytes()
        throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.blocks.examples.input-echo",
            displayName: "Blocks Input Echo",
            version: "1.0.0",
            entryPoint: "main.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text, .screenshotImage],
                contextFields: [
                    .inputSource,
                    .sourceApplicationBundleID,
                    .ocrSummary,
                ],
                supportsStatus: true
            ),
            permissions: .init(data: [.screenshotImage])
        )
        let source = """
        function translate(input, context) {
          blocks.progress({
            kind: "status",
            code: "echo_preparing",
            text: "Preparing the invocation echo."
          });
          const attachments = Array.isArray(input.attachments)
            ? input.attachments.map((attachment) => ({
                id: attachment.id ?? null,
                kind: attachment.kind ?? null,
                media_type: attachment.media_type ?? null,
                pixel_width: attachment.pixel_width ?? null,
                pixel_height: attachment.pixel_height ?? null,
                byte_count: attachment.byte_count ?? null,
                sha256: attachment.sha256 ?? null
              }))
            : [];
          const text = JSON.stringify({
            input: {
              text: input.text ?? null,
              source_language: input.source_language ?? null,
              target_language: input.target_language ?? null,
              input_source: input.context?.input_source ?? null,
              source_application_bundle_id:
                input.context?.source_application_bundle_id ?? null,
              ocr_summary: input.context?.ocr_summary ?? null,
              attachments
            },
            context: {
              request_id: context.requestID,
              session_id: context.configuration?.session_id ?? null,
              capability: context.capability,
              configuration: context.configuration ?? {}
            }
          }, null, 2);
          if (text.length > 256 * 1024) {
            return {
              status: "failed",
              text: "",
              error_code: "echo_output_too_large",
              error_message: "The complete invocation echo exceeds 512 KB.",
              is_retryable: false
            };
          }
          blocks.progress({
            kind: "status",
            code: "echo_completed",
            text: "Invocation echo is ready."
          });
          return {
            status: "completed",
            text,
            metadata: { echo: true, attachment_count: attachments.length }
          };
        }
        """
        let events = LockedProgressEvents()
        let invocation = BlocksNativePluginInvocation(
            requestID: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!,
            pluginID: manifest.id,
            kind: .translation,
            input: [
                "text": .string("Echo me"),
                "source_language": .string("en"),
                "target_language": .string("ja"),
                "context": .object([
                    "input_source": .string("screenshot_ocr"),
                    "source_application_bundle_id":
                        .string("com.example.fixture"),
                    "ocr_summary": .object([
                        "line_count": .int(2),
                    ]),
                ]),
                "attachments": .array([
                    .object([
                        "id": .string("attachment-1"),
                        "kind": .string("screenshot_image"),
                        "media_type": .string("image/jpeg"),
                        "pixel_width": .int(640),
                        "pixel_height": .int(480),
                        "byte_count": .int(12),
                        "sha256": .string("fixture-sha256"),
                        "data_base64": .string("c2VjcmV0LWJ5dGVz"),
                    ]),
                ]),
            ],
            configuration: [
                "session_id": .string("session-fixture"),
            ]
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in
                XCTFail("The echo source must not use the network")
                throw TestError.unexpectedNetwork
            },
            progressSink: { events.append($0) }
        )

        let response = runner.execute(
            BlocksNativePluginRunnerRequest(
                manifest: manifest,
                entrySource: source,
                invocation: invocation
            )
        )

        XCTAssertEqual(response.status, .completed)
        let text = try XCTUnwrap(response.output?.text)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        )
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        let attachments = try XCTUnwrap(
            input["attachments"] as? [[String: Any]]
        )
        XCTAssertEqual(input["text"] as? String, "Echo me")
        XCTAssertEqual(input["source_language"] as? String, "en")
        XCTAssertEqual(input["target_language"] as? String, "ja")
        XCTAssertEqual(
            context["request_id"] as? String,
            invocation.requestID.uuidString
        )
        XCTAssertEqual(context["session_id"] as? String, "session-fixture")
        XCTAssertEqual(attachments.first?["sha256"] as? String, "fixture-sha256")
        XCTAssertNil(attachments.first?["data_base64"])
        XCTAssertFalse(text.contains("c2VjcmV0LWJ5dGVz"))
        XCTAssertEqual(
            events.values.compactMap(\.code),
            ["echo_preparing", "echo_completed"]
        )

        let oversizedInvocation = BlocksNativePluginInvocation(
            requestID: UUID(),
            pluginID: manifest.id,
            kind: .translation,
            input: invocation.input,
            configuration: [
                "fixture_payload": .string(
                    String(repeating: "x", count: 270_000)
                ),
            ]
        )
        let oversizedResponse = runner.execute(
            BlocksNativePluginRunnerRequest(
                manifest: manifest,
                entrySource: source,
                invocation: oversizedInvocation
            )
        )
        XCTAssertEqual(oversizedResponse.status, .completed)
        XCTAssertEqual(
            oversizedResponse.output?.status,
            .failed
        )
        XCTAssertEqual(
            oversizedResponse.output?.errorCode,
            "echo_output_too_large"
        )
        XCTAssertEqual(
            oversizedResponse.output?.isRetryable,
            false
        )
    }

    func testTranslationPluginReturnsNormalizedText() {
        let request = makeRequest(
            source: """
            function translate(input, context) {
              return { text: input.text.toUpperCase(), metadata: { provider: "fixture" } };
            }
            """
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in
                XCTFail("Network must not be called")
                throw TestError.unexpectedNetwork
            }
        )

        let response = runner.execute(request)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.text, "HELLO")
        XCTAssertEqual(response.output?.metadata["provider"], .string("fixture"))
    }

    func testPluginHasNoDirectNetworkOrRuntimeGlobals() {
        let request = makeRequest(
            source: """
            function translate() {
              const blocked = [
                typeof fetch,
                typeof XMLHttpRequest,
                typeof WebSocket,
                typeof require,
                typeof process
              ];
              return blocked.join(",");
            }
            """
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(request)

        XCTAssertEqual(
            response.output?.text,
            "undefined,undefined,undefined,undefined,undefined"
        )
    }

    func testDeclaredNetworkRequestIsBrokeredAndSecretRemainsAPlaceholder() {
        let manifest = BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(domains: ["api.example.com"], methods: [.post]),
                secrets: [.init(id: "api_key", displayName: "API Key")]
            ),
            configurationFields: [
                .init(
                    id: "api_key",
                    type: .secret,
                    title: "API Key",
                    required: true
                ),
            ]
        )
        let request = makeRequest(
            manifest: manifest,
            source: """
            function translate(input) {
              const response = blocks.request({
                url: "https://api.example.com/translate",
                method: "POST",
                headers: { Authorization: "Bearer {{secret:api_key}}" },
                body: JSON.stringify({ text: input.text })
              });
              return JSON.parse(response.body).translation;
            }
            """
        )
        let capturedHeader = LockedStringBox()
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { networkRequest in
                capturedHeader.set(networkRequest.headers["Authorization"])
                return BlocksNativePluginNetworkResponse(
                    requestID: networkRequest.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"translation":"你好"}"#.utf8)
                )
            }
        )

        let response = runner.execute(request)

        XCTAssertEqual(capturedHeader.value, "Bearer {{secret:api_key}}")
        XCTAssertEqual(response.output?.text, "你好")
    }

    func testNetworkBridgeHonorsExactFourMiBRawRequestBoundary() {
        let maximum = BlocksNativePluginNetworkPermission
            .absoluteMaximumRequestBytes
        let manifest = BlocksNativePluginManifest(
            id: "com.example.network-boundary",
            displayName: "Network Boundary",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(
                    domains: ["api.example.com"],
                    methods: [.post],
                    maximumRequestBytes: maximum
                )
            )
        )
        let exactBodyCount = LockedStringBox()
        let exactRunner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { request in
                exactBodyCount.set(String(request.body?.count ?? -1))
                return BlocksNativePluginNetworkResponse(
                    requestID: request.requestID,
                    statusCode: 204,
                    headers: [:],
                    body: Data()
                )
            }
        )
        let exactResponse = exactRunner.execute(
            makeRequest(
                manifest: manifest,
                source: """
                function translate() {
                  const byteCount = \(maximum);
                  const encodedCount = Math.ceil(byteCount / 3) * 4;
                  const response = blocks.request({
                    url: "https://api.example.com/upload",
                    method: "POST",
                    bodyBase64: "A".repeat(encodedCount - 2) + "=="
                  });
                  return "accepted:" + response.statusCode;
                }
                """
            )
        )

        XCTAssertEqual(exactResponse.status, .completed)
        XCTAssertEqual(exactResponse.output?.text, "accepted:204")
        XCTAssertEqual(exactBodyCount.value, String(maximum))

        let encodedXPCRequest = try? JSONEncoder().encode(
            BlocksNativePluginNetworkRequest(
                url: "https://api.example.com/upload",
                method: .post,
                body: Data(repeating: 0, count: maximum)
            )
        )
        XCTAssertGreaterThan(encodedXPCRequest?.count ?? 0, 5 * 1_048_576)
        XCTAssertEqual(
            encodedXPCRequest.flatMap {
                BlocksNativePluginXPCExecutionClient
                    .decodeNetworkBridgeRequest($0)?.body?.count
            },
            maximum
        )

        let oversizedBrokerCalled = LockedFlag()
        let oversizedRunner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { request in
                oversizedBrokerCalled.set()
                return BlocksNativePluginNetworkResponse(
                    requestID: request.requestID,
                    statusCode: 500,
                    headers: [:],
                    body: Data()
                )
            }
        )
        let oversizedResponse = oversizedRunner.execute(
            makeRequest(
                manifest: manifest,
                source: """
                function translate() {
                  const byteCount = \(maximum + 1);
                  const encodedCount = Math.ceil(byteCount / 3) * 4;
                  try {
                    blocks.request({
                      url: "https://api.example.com/upload",
                      method: "POST",
                      bodyBase64: "A".repeat(encodedCount - 1) + "="
                    });
                    return "unexpected_accept";
                  } catch (error) {
                    return error.message.includes("too large")
                      ? "policy_rejected"
                      : "bridge_rejected";
                  }
                }
                """
            )
        )

        XCTAssertEqual(oversizedResponse.status, .completed)
        XCTAssertEqual(oversizedResponse.output?.text, "policy_rejected")
        XCTAssertFalse(oversizedBrokerCalled.value)
    }

    func testTextNetworkResponseUsesOnlyUTF8BridgeRepresentation() {
        let manifest = BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(
                    domains: ["api.example.com"],
                    methods: [.get]
                )
            )
        )
        let request = makeRequest(
            manifest: manifest,
            source: """
            function translate() {
              const response = blocks.request({
                url: "https://api.example.com/translate",
                method: "GET"
              });
              return [
                response.body,
                String(response.bodyBase64 === null),
                response.bodyEncoding
              ].join("|");
            }
            """
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { networkRequest in
                BlocksNativePluginNetworkResponse(
                    requestID: networkRequest.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data("hello".utf8)
                )
            }
        )

        let response = runner.execute(request)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.text, "hello|true|utf8")
    }

    func testBinaryNetworkResponseUsesOnlyBase64BridgeRepresentation() {
        let manifest = BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            permissions: .init(
                network: .init(
                    domains: ["api.example.com"],
                    methods: [.get]
                )
            )
        )
        let request = makeRequest(
            manifest: manifest,
            source: """
            function translate() {
              const response = blocks.request({
                url: "https://api.example.com/binary",
                method: "GET"
              });
              return [
                String(response.body === null),
                response.bodyBase64,
                response.bodyEncoding
              ].join("|");
            }
            """
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { networkRequest in
                BlocksNativePluginNetworkResponse(
                    requestID: networkRequest.requestID,
                    statusCode: 200,
                    headers: [:],
                    body: Data([0x00, 0xff, 0x80])
                )
            }
        )

        let response = runner.execute(request)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.text, "true|AP+A|base64")
    }

    func testCapabilityMismatchFailsBeforeJavaScriptExecutes() {
        let manifest = BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.ocr]
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(makeRequest(manifest: manifest))

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, "invalid_plugin")
    }

    func testProgressFloodFailsEvenWhenPluginCatchesBridgeError() {
        let request = makeRequest(
            source: """
            function translate() {
              for (let index = 0; index < 200; index += 1) {
                try {
                  blocks.progress({
                    kind: "partial_text",
                    text: "partial-" + index
                  });
                } catch (_) {
                  // A plugin must not bypass a host budget with try/catch.
                }
              }
              return "must-not-complete";
            }
            """
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(request)

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, "progress_budget_exceeded")
        XCTAssertNil(response.output)
    }

    func testSchemaV3TranslationReportsStatusThenOneCompletedTerminal()
    {
        let events = LockedProgressEvents()
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.v3-status",
            displayName: "V3 Status",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text],
                supportsStatus: true
            )
        )
        let request = makeRequest(
            manifest: manifest,
            source: """
            function translate(input) {
              blocks.progress({
                kind: "status",
                code: "processing",
                text: "Processing",
                fraction: 0.5
              });
              return { status: "completed", text: input.text + ":done" };
            }
            """
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork },
            progressSink: { events.append($0) }
        )

        let response = runner.execute(request)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.status, .completed)
        XCTAssertEqual(response.output?.text, "hello:done")
        XCTAssertEqual(events.values.map(\.kind), [.status])
        XCTAssertEqual(events.values.first?.code, "processing")
    }

    func testSchemaV3TranslationRejectsLegacyPartialStreaming()
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.v3-no-stream",
            displayName: "V3 No Stream",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(
                acceptedInputs: [.text],
                supportsStatus: true
            )
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(
            makeRequest(
                manifest: manifest,
                source: """
                function translate() {
                  blocks.progress({
                    kind: "partial_text",
                    text: "not allowed"
                  });
                  return { status: "completed", text: "too late" };
                }
                """
            )
        )

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, "script_exception")
        XCTAssertNil(response.output)
    }

    func testSchemaV3TranslationPreservesFailedTerminalContract()
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.v3-failure",
            displayName: "V3 Failure",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(acceptedInputs: [.text])
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(
            makeRequest(
                manifest: manifest,
                source: """
                function translate() {
                  return {
                    status: "failed",
                    error_code: "fixture_rejected",
                    error_message: "Fixture rejected the request.",
                    is_retryable: false
                  };
                }
                """
            )
        )

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.status, .failed)
        XCTAssertEqual(response.output?.errorCode, "fixture_rejected")
        XCTAssertEqual(response.output?.isRetryable, false)
        XCTAssertTrue(response.output?.text.isEmpty == true)
    }

    func testSchemaV3TranslationRejectsBareStringTerminal()
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.v3-bare-terminal",
            displayName: "V3 Bare Terminal",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(acceptedInputs: [.text])
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(
            makeRequest(
                manifest: manifest,
                source: #"function translate() { return "ambiguous"; }"#
            )
        )

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, "invalid_output")
        XCTAssertNil(response.output)
    }

    func testSchemaV3TranslationRejectsObjectWithoutExplicitStatus()
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.v3-missing-status",
            displayName: "V3 Missing Status",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(acceptedInputs: [.text])
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(
            makeRequest(
                manifest: manifest,
                source: #"function translate() { return { text: "ambiguous" }; }"#
            )
        )

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.errorCode, "invalid_output")
        XCTAssertNil(response.output)
    }

    func testSchemaV2OutputIgnoresSchemaV3TerminalFieldNames()
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.v2-status-field",
            displayName: "V2 Status Field",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation]
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in throw TestError.unexpectedNetwork }
        )

        let response = runner.execute(
            makeRequest(
                manifest: manifest,
                source: """
                function translate() {
                  return {
                    text: "legacy-success",
                    status: "failed",
                    error_code: "legacy-debug-field",
                    error_message: "ignored by v2"
                  };
                }
                """
            )
        )

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.status, .completed)
        XCTAssertEqual(response.output?.text, "legacy-success")
        XCTAssertNil(response.output?.errorCode)
    }

    func testDoctorStyleIsolatedRunnerProbeExecutesAndFailsClosed()
        throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.blocks.plugin-doctor-probe-test",
            displayName: "Doctor Probe Test",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(acceptedInputs: [.text])
        )
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in
                XCTFail("The doctor probe must not use the network.")
                throw TestError.unexpectedNetwork
            }
        )

        let ready = runner.execute(makeRequest(
            manifest: manifest,
            source: """
            function translate() {
              return { status: "completed", text: "blocks-plugin-doctor-ready" };
            }
            """
        ))
        XCTAssertEqual(ready.status, .completed)
        XCTAssertEqual(ready.output?.status, .completed)
        XCTAssertEqual(ready.output?.text, "blocks-plugin-doctor-ready")

        let failed = runner.execute(makeRequest(
            manifest: manifest,
            source: "function translate() { throw new Error('probe failure'); }"
        ))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errorCode, "script_exception")
        XCTAssertNil(failed.output)
    }

    private func makeRequest(
        manifest: BlocksNativePluginManifest? = nil,
        source: String = "function translate(input) { return input.text; }"
    ) -> BlocksNativePluginRunnerRequest {
        let resolvedManifest = manifest ?? BlocksNativePluginManifest(
            schemaVersion: 2,
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation]
        )
        return BlocksNativePluginRunnerRequest(
            manifest: resolvedManifest,
            entrySource: source,
            invocation: BlocksNativePluginInvocation(
                pluginID: resolvedManifest.id,
                kind: .translation,
                input: ["text": .string("hello")]
            )
        )
    }

    private enum TestError: Error {
        case unexpectedNetwork
    }
}

final class TranslationSourcePackageWorkerTests: XCTestCase {
    func testValidateMaterializesValidatedSnapshotWithoutCrashing()
        async throws
    {
        let manifest = """
        {
          "schema_version": 3,
          "id": "com.blocks.tests.package-worker",
          "display_name": "Package Worker Fixture",
          "version": "1.0.0",
          "entry_point": "main.js",
          "capabilities": ["translation"],
          "translation": {
            "accepted_inputs": ["text"],
            "context_fields": [],
            "requires_explicit_source_language": false,
            "supports_status": true
          },
          "permissions": {},
          "configuration_fields": []
        }
        """
        let snapshot = try TranslationSourcePackageSnapshot(files: [
            "manifest.json": Data(manifest.utf8),
            "main.js": Data(
                "function translate(input) { return input.text; }".utf8
            ),
        ])

        let package = try await TranslationSourcePackageWorker().validate(
            snapshot
        )

        XCTAssertEqual(package.manifest.id, "com.blocks.tests.package-worker")
        XCTAssertEqual(
            Set(package.files.keys),
            Set(["manifest.json", "main.js"])
        )
    }
}

final class BlocksNativePluginProgressBudgetTests: XCTestCase {
    func testFrequencyBudgetRejectsMoreThan120EventsInOneSecond() throws {
        let clock = LockedTimeBox()
        let budget = LockedPluginProgressBudget(timeProvider: { clock.value })

        for _ in 0..<BlocksNativePluginProgressBudgetLimits.maximumEventsPerSecond {
            try budget.consume(bytes: 1)
        }

        XCTAssertThrowsError(try budget.consume(bytes: 1)) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginRunnerError,
                .progressBudgetExceeded
            )
        }
    }

    func testLifetimeEventBudgetIsIndependentFromFrequencyWindow() throws {
        let clock = LockedTimeBox()
        let budget = LockedPluginProgressBudget(timeProvider: { clock.value })

        for _ in 0..<BlocksNativePluginProgressBudgetLimits.maximumEventCount {
            try budget.consume(bytes: 1)
            clock.advance(by: 0.02)
        }

        XCTAssertThrowsError(try budget.consume(bytes: 1)) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginRunnerError,
                .progressBudgetExceeded
            )
        }
    }

    func testRateBudgetUsesRollingWindowAcrossSecondBoundary() throws {
        let clock = LockedTimeBox(initialValue: 0.9)
        let budget = LockedPluginProgressBudget(timeProvider: { clock.value })

        for _ in 0..<BlocksNativePluginProgressBudgetLimits.maximumEventsPerSecond {
            try budget.consume(bytes: 1)
        }
        clock.advance(by: 0.11)

        XCTAssertThrowsError(try budget.consume(bytes: 1)) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginRunnerError,
                .progressBudgetExceeded
            )
        }
    }

    func testAggregateByteBudgetRejectsAdditionalPayload() throws {
        let clock = LockedTimeBox()
        let budget = LockedPluginProgressBudget(timeProvider: { clock.value })
        let eventBytes = 64 * 1_024

        for _ in 0..<16 {
            try budget.consume(bytes: eventBytes)
            clock.advance(by: 0.02)
        }

        XCTAssertThrowsError(try budget.consume(bytes: 1)) { error in
            XCTAssertEqual(
                error as? BlocksNativePluginRunnerError,
                .progressBudgetExceeded
            )
        }
    }
}

final class BlocksNativePluginProgressCoalescerTests: XCTestCase {
    func testPartialTextFloodDeliversFirstAndLatestWithoutExceedingThirtyHertz() {
        let received = LockedProgressEvents()
        let requestID = UUID()
        let coalescer = BlocksNativePluginProgressCoalescer {
            received.append($0)
        }

        for index in 0..<1_000 {
            coalescer.submit(
                BlocksNativePluginProgress(
                    requestID: requestID,
                    kind: .partialText,
                    text: "partial-\(index)"
                )
            )
        }
        coalescer.finish(flushPending: true)

        XCTAssertLessThanOrEqual(received.values.count, 2)
        XCTAssertEqual(received.values.last?.text, "partial-999")
    }
}

final class BlocksNativePluginNetworkTaskStartGateTests: XCTestCase {
    func testOpeningBeforeWaitReturnsImmediately() async {
        let gate = PluginNetworkTaskStartGate()

        gate.open()
        await gate.wait()
    }

    func testWaitDoesNotResumeUntilGateOpens() async {
        let gate = PluginNetworkTaskStartGate()
        let waiterStarted = expectation(description: "waiter started")
        let prematureFinish = expectation(description: "waiter must remain suspended")
        prematureFinish.isInverted = true
        let waiterFinished = expectation(description: "waiter finished after open")

        let task = Task {
            waiterStarted.fulfill()
            await gate.wait()
            prematureFinish.fulfill()
            waiterFinished.fulfill()
        }

        await fulfillment(of: [waiterStarted], timeout: 1)
        await fulfillment(of: [prematureFinish], timeout: 0.05)

        gate.open()
        await fulfillment(of: [waiterFinished], timeout: 1)
        _ = await task.value
    }
}

final class BlocksNativePluginXPCRoundTripTests: XCTestCase {
    func testEmbeddedRunnerExecutesTranslationOutsideHostProcess() throws {
        let host = PluginRunnerTestHost()
        host.start()
        defer { host.shutdown() }

        let connection = NSXPCConnection(
            serviceName: BlocksNativePluginXPC.serviceName
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerXPCProtocol.self
        )
        connection.resume()
        defer { connection.invalidate() }

        let manifest = BlocksNativePluginManifest(
            id: "com.example.fixture",
            displayName: "Fixture",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation]
        )
        let request = BlocksNativePluginRunnerRequest(
            manifest: manifest,
            entrySource: """
            function translate(input) {
              return { text: input.text.toUpperCase() };
            }
            """,
            invocation: BlocksNativePluginInvocation(
                pluginID: manifest.id,
                kind: .translation,
                input: ["text": .string("xpc round trip")]
            ),
            executionTimeLimitSeconds: 5
        )
        let requestData = try JSONEncoder().encode(request)
        let completed = expectation(description: "XPC runner response")
        var receivedResponse: BlocksNativePluginRunnerResponse?
        var receivedError: Error?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            receivedError = error
            completed.fulfill()
        } as? BlocksNativePluginRunnerXPCProtocol
        XCTAssertNotNil(proxy)

        proxy?.execute(
            requestData,
            hostEndpoint: host.endpoint
        ) { responseData in
            do {
                receivedResponse = try JSONDecoder().decode(
                    BlocksNativePluginRunnerResponse.self,
                    from: responseData
                )
            } catch {
                receivedError = error
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 8)

        XCTAssertNil(receivedError)
        XCTAssertEqual(
            receivedResponse?.status,
            .completed,
            receivedResponse.map {
                "code=\($0.errorCode ?? "nil") message=\($0.errorMessage ?? "nil")"
            } ?? "missing response"
        )
        XCTAssertEqual(
            receivedResponse?.output?.text,
            "XPC ROUND TRIP",
            receivedResponse.map {
                "code=\($0.errorCode ?? "nil") message=\($0.errorMessage ?? "nil")"
            } ?? "missing response"
        )
    }
}

final class BlocksNativePluginRunnerWatchdogTests: XCTestCase {
    func testFiniteBlockedScriptTriggersFatalWatchdogWithoutLeakingWork() throws {
        let host = PluginRunnerTestHost()
        host.start()
        defer { host.shutdown() }

        let fatalTriggered = expectation(description: "fatal watchdog")
        let replyReceived = expectation(description: "finite script reply")
        let service = BlocksNativePluginRunnerXPCService {
            fatalTriggered.fulfill()
        }
        let manifest = BlocksNativePluginManifest(
            id: "com.example.watchdog",
            displayName: "Watchdog",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation]
        )
        let request = BlocksNativePluginRunnerRequest(
            manifest: manifest,
            entrySource: """
            function translate() {
              const deadline = Date.now() + 1800;
              while (Date.now() < deadline) {}
              return { text: "finite" };
            }
            """,
            invocation: BlocksNativePluginInvocation(
                pluginID: manifest.id,
                kind: .translation,
                input: [:]
            ),
            executionTimeLimitSeconds: 1
        )
        let requestData = try JSONEncoder().encode(request)
        var response: BlocksNativePluginRunnerResponse?

        service.execute(requestData, hostEndpoint: host.endpoint) { data in
            response = try? JSONDecoder().decode(
                BlocksNativePluginRunnerResponse.self,
                from: data
            )
            replyReceived.fulfill()
        }

        wait(for: [fatalTriggered, replyReceived], timeout: 3)
        XCTAssertEqual(response?.status, .completed)
        XCTAssertEqual(response?.output?.text, "finite")
    }
}

final class BlocksNativePluginXPCExecutionClientIntegrationTests: XCTestCase {
    func testApprovedDisabledPluginCanOnlyRunExplicitConnectionTest()
        async throws
    {
        let fixture = try makeRuntimeFixture(
            id: "com.example.disabled-connection-test",
            capability: .translation,
            entrySource: """
            function translate(input) {
              return { text: "tested:" + input.text };
            }
            """
        )
        let disabledMetadata = pluginMetadata(
            fixture.metadata,
            isEnabled: false
        )
        let client = makeClient(
            metadata: [disabledMetadata.id: disabledMetadata],
            timeoutSeconds: 5
        )
        let invocation = BlocksNativePluginInvocation(
            pluginID: disabledMetadata.id,
            kind: .translation,
            input: [
                "text": .string("fixture"),
                "source_language": .string("en"),
                "target_language": .string("zh-Hans"),
            ],
            configuration: ["connection_test": .bool(true)]
        )

        let output = try await client.executeConnectionTest(
            package: fixture.package,
            metadata: disabledMetadata,
            invocation: invocation,
            progress: { _ in }
        )
        XCTAssertEqual(output.text, "tested:fixture")

        do {
            _ = try await client.execute(
                package: fixture.package,
                metadata: disabledMetadata,
                invocation: invocation,
                progress: { _ in }
            )
            XCTFail("Normal execution must still reject disabled plugins.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginExecutionError,
                .pluginDisabled
            )
        }

        let invalidInvocation = BlocksNativePluginInvocation(
            pluginID: disabledMetadata.id,
            kind: .translation,
            input: ["text": .string("fixture")]
        )
        do {
            _ = try await client.executeConnectionTest(
                package: fixture.package,
                metadata: disabledMetadata,
                invocation: invalidInvocation,
                progress: { _ in }
            )
            XCTFail("The disabled execution exception must be connection-test only.")
        } catch {
            guard case .executionFailed(
                code: "invalid_connection_test",
                message: _
            ) = error as? BlocksNativePluginExecutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSafetyDisabledPluginCannotRunExplicitConnectionTest()
        async throws
    {
        let fixture = try makeRuntimeFixture(
            id: "com.example.safety-disabled-connection-test",
            capability: .translation,
            entrySource: """
            function translate(input) {
              return { text: "must-not-run:" + input.text };
            }
            """
        )
        let safetyDisabledMetadata = pluginMetadata(
            fixture.metadata,
            isEnabled: false,
            safetyDisabled: true
        )
        let client = makeClient(
            metadata: [
                safetyDisabledMetadata.id: safetyDisabledMetadata,
            ],
            timeoutSeconds: 5
        )
        let invocation = BlocksNativePluginInvocation(
            pluginID: safetyDisabledMetadata.id,
            kind: .translation,
            input: ["text": .string("fixture")],
            configuration: ["connection_test": .bool(true)]
        )

        do {
            _ = try await client.executeConnectionTest(
                package: fixture.package,
                metadata: safetyDisabledMetadata,
                invocation: invocation,
                progress: { _ in }
            )
            XCTFail("Safety-disabled plugins must not use the disabled connection-test exception.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginExecutionError,
                .pluginDisabled
            )
        }
    }

    func testCancellationAfterPrepareBeforeAuthoritativeMetadataSkipsExecute()
        async throws
    {
        let fixture = try makeRuntimeFixture(
            id: "com.example.cancel-before-execute",
            capability: .translation,
            entrySource: """
            function translate(input) {
              return { text: "must-not-run:" + input.text };
            }
            """
        )
        let resolver = PausablePluginMetadataResolver(
            metadata: fixture.metadata
        )
        let connectionFactory = RecordingPluginXPCConnectionFactory()
        let executeStarted = LockedFlag()
        let client = BlocksNativePluginXPCExecutionClient(
            timeoutSeconds: 3,
            metadataResolver: { pluginID in
                try await resolver.resolve(pluginID: pluginID)
            },
            secretResolver: { _, _ in
                throw PluginXPCIntegrationTestError.unexpectedSecretRequest
            },
            connectionFactory: { connectionFactory.makeConnection() },
            preExecuteProbe: { executeStarted.set() }
        )
        let execution = Task {
            try await client.execute(
                package: fixture.package,
                metadata: fixture.metadata,
                invocation: BlocksNativePluginInvocation(
                    pluginID: fixture.metadata.id,
                    kind: .translation,
                    input: ["text": .string("cancelled")]
                ),
                progress: { _ in }
            )
        }

        await resolver.waitUntilSecondReadStarts()
        execution.cancel()
        await resolver.resumeSecondRead(with: fixture.metadata)

        do {
            _ = try await execution.value
            XCTFail("Cancellation after runner preparation must prevent execution.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(executeStarted.value)
        XCTAssertEqual(connectionFactory.connectionCount, 1)
    }

    func testPlatformCancellationAfterPrepareBeforeAuthoritativeMetadataSkipsExecute()
        async throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: "com.example.platform-cancel-before-execute",
            displayName: "Platform Cancel Before Execute",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "launch",
                    event: .appLaunched,
                    entryFunction: "handleLaunch"
                ),
            ])
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let packageHash = "platform-cancel-before-execute-hash"
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: manifestData,
            entrySource: "function handleLaunch() { return {}; }",
            packageSHA256: packageHash,
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: packageHash,
                isSigned: false,
                capabilities: [.hooks],
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        let metadata = BlocksNativePluginMetadata(
            id: manifest.id,
            displayName: manifest.displayName,
            packageVersion: manifest.version,
            packageHash: packageHash,
            manifestJSON: String(decoding: manifestData, as: UTF8.self),
            capabilities: [.hooks],
            installedRelativePath: "\(manifest.id)/\(packageHash)",
            isEnabled: true,
            approvalStatus: .approved,
            approvedPermissions: [],
            approvedDomains: [],
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let resolver = PausablePluginMetadataResolver(metadata: metadata)
        let connectionFactory = RecordingPluginXPCConnectionFactory()
        let executeStarted = LockedFlag()
        let client = BlocksNativePluginXPCExecutionClient(
            timeoutSeconds: 3,
            metadataResolver: { pluginID in
                try await resolver.resolve(pluginID: pluginID)
            },
            secretResolver: { _, _ in
                throw PluginXPCIntegrationTestError.unexpectedSecretRequest
            },
            connectionFactory: { connectionFactory.makeConnection() },
            preExecuteProbe: { executeStarted.set() }
        )
        let execution = Task {
            try await client.executePlatform(
                package: package,
                metadata: metadata,
                invocation: BlocksPluginRuntimeInvocation(
                    pluginID: metadata.id,
                    kind: .hook,
                    entryFunction: "handleLaunch",
                    event: .init(name: .appLaunched)
                ),
                timeoutSeconds: 3,
                progress: { _ in }
            )
        }

        await resolver.waitUntilSecondReadStarts()
        execution.cancel()
        await resolver.resumeSecondRead(with: metadata)

        do {
            _ = try await execution.value
            XCTFail("Cancellation after runner preparation must prevent platform execution.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(executeStarted.value)
        XCTAssertEqual(connectionFactory.connectionCount, 1)
    }

    func testAuthoritativeMetadataIsRecheckedAfterRegistrationBeforeExecution() async throws {
        let fixture = try makeRuntimeFixture(
            id: "com.example.authorization-race",
            capability: .translation,
            entrySource: """
            function translate(input) {
              return { text: "must-not-run:" + input.text };
            }
            """
        )
        let resolver = PausablePluginMetadataResolver(
            metadata: fixture.metadata
        )
        let client = BlocksNativePluginXPCExecutionClient(
            timeoutSeconds: 3,
            metadataResolver: { pluginID in
                try await resolver.resolve(pluginID: pluginID)
            },
            secretResolver: { _, _ in
                throw PluginXPCIntegrationTestError.unexpectedSecretRequest
            }
        )
        let execution = Task {
            try await client.execute(
                package: fixture.package,
                metadata: fixture.metadata,
                invocation: BlocksNativePluginInvocation(
                    pluginID: fixture.metadata.id,
                    kind: .translation,
                    input: ["text": .string("blocked")]
                ),
                progress: { _ in }
            )
        }

        await resolver.waitUntilSecondReadStarts()
        await resolver.resumeSecondRead(
            with: pluginMetadata(
                fixture.metadata,
                isEnabled: false
            )
        )

        do {
            _ = try await execution.value
            XCTFail("A plugin disabled after XPC registration must not run.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginExecutionError,
                .pluginDisabled
            )
        }
        let readCount = await resolver.readCount
        XCTAssertEqual(readCount, 2)
    }

    func testAuthoritativeScreenshotPermissionRevocationStopsExecution()
        async throws
    {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.example.permission-race",
            displayName: "Permission Race",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.ocr],
            permissions: .init(data: [.screenshotImage])
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let hash = "permission-race-hash"
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: manifestData,
            entrySource:
                "function ocr() { return { text: 'must-not-run' }; }",
            packageSHA256: hash,
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: hash,
                isSigned: false,
                capabilities: [.ocr],
                networkDomains: [],
                networkMethods: [],
                secretIDs: [],
                dataPermissions: [.screenshotImage]
            )
        )
        let now = Date(timeIntervalSince1970: 1)
        let approved = BlocksNativePluginMetadata(
            id: manifest.id,
            displayName: manifest.displayName,
            packageVersion: manifest.version,
            packageHash: hash,
            manifestJSON: String(
                decoding: manifestData,
                as: UTF8.self
            ),
            capabilities: [.ocr],
            installedRelativePath: "\(manifest.id)/\(hash)",
            isEnabled: true,
            approvalStatus: .approved,
            approvedPermissions: ["data:screenshot_image"],
            approvedDomains: [],
            installedAt: now,
            updatedAt: now
        )
        let revoked = BlocksNativePluginMetadata(
            id: approved.id,
            displayName: approved.displayName,
            packageVersion: approved.packageVersion,
            packageHash: approved.packageHash,
            manifestJSON: approved.manifestJSON,
            capabilities: approved.capabilities,
            installedRelativePath: approved.installedRelativePath,
            isEnabled: true,
            approvalStatus: .approved,
            approvedPermissions: [],
            approvedDomains: [],
            installedAt: approved.installedAt,
            updatedAt: Date()
        )
        let resolver = PausablePluginMetadataResolver(
            metadata: approved
        )
        let client = BlocksNativePluginXPCExecutionClient(
            metadataResolver: { pluginID in
                try await resolver.resolve(pluginID: pluginID)
            },
            secretResolver: { _, _ in
                throw PluginXPCIntegrationTestError
                    .unexpectedSecretRequest
            }
        )
        let execution = Task {
            try await client.execute(
                package: package,
                metadata: approved,
                invocation: BlocksNativePluginInvocation(
                    pluginID: approved.id,
                    kind: .ocr,
                    input: [
                        "image_base64": .string("ZmFrZQ=="),
                        "media_type": .string("image/jpeg"),
                    ]
                ),
                progress: { _ in }
            )
        }

        await resolver.waitUntilSecondReadStarts()
        await resolver.resumeSecondRead(with: revoked)

        do {
            _ = try await execution.value
            XCTFail("Revoked screenshot permission must stop execution.")
        } catch let error as BlocksNativePluginExecutionError {
            guard case let .executionFailed(code, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, "plugin_data_permission_missing")
        }
    }

    func testSuccessfulOCRPluginRunsEndToEndThroughEmbeddedRunner() async throws {
        let fixture = try makeRuntimeFixture(
            id: "com.example.ocr-e2e",
            capability: .ocr,
            entrySource: """
            function ocr(input) {
              if (input.media_type !== "image/jpeg"
                  || input.pixel_width !== 3
                  || input.pixel_height !== 2
                  || typeof input.image_base64 !== "string"
                  || input.image_base64.length < 16) {
                throw new Error("OCR fixture received invalid image input.");
              }
              return {
                text: "FIRST LINE\\nSECOND LINE",
                metadata: {
                  line_count: 2,
                  mean_confidence: 0.875
                }
              };
            }
            """
        )
        let client = makeClient(
            metadata: [fixture.metadata.id: fixture.metadata],
            timeoutSeconds: 5
        )
        let adapter = PluginOCRServiceAdapter(
            package: fixture.package,
            metadata: fixture.metadata,
            executor: client
        )

        let snapshot = try await adapter.recognizeText(
            in: try makeCapture(width: 3, height: 2),
            requestToken: LocalVisionOCRRequestToken()
        )

        XCTAssertEqual(snapshot.text, "FIRST LINE\nSECOND LINE")
        XCTAssertEqual(snapshot.lineCount, 2)
        XCTAssertEqual(snapshot.meanConfidence, 0.875, accuracy: 0.000_1)
    }

    func testInvalidatedInvocationDoesNotPoisonNextRealRunnerConnection() async throws {
        let interrupted = try makeRuntimeFixture(
            id: "com.example.invalidated",
            capability: .translation,
            entrySource: """
            function translate() {
              blocks.progress({ kind: "progress", fraction: 0.1 });
              const deadline = Date.now() + 300;
              while (Date.now() < deadline) {}
              return { text: "too late" };
            }
            """
        )
        let recovered = try makeRuntimeFixture(
            id: "com.example.after-invalidation",
            capability: .translation,
            entrySource: """
            function translate(input) {
              return { text: "recovered:" + input.text };
            }
            """
        )
        let connectionFactory = RecordingPluginXPCConnectionFactory()
        let client = makeClient(
            metadata: [
                interrupted.metadata.id: interrupted.metadata,
                recovered.metadata.id: recovered.metadata,
            ],
            timeoutSeconds: 3,
            connectionFactory: connectionFactory
        )
        let interruptedTask = Task {
            try await client.execute(
                package: interrupted.package,
                metadata: interrupted.metadata,
                invocation: BlocksNativePluginInvocation(
                    pluginID: interrupted.metadata.id,
                    kind: .translation,
                    input: ["text": .string("first")]
                ),
                progress: { _ in }
            )
        }
        try await waitUntil {
            connectionFactory.connectionCount == 1
        }
        let firstConnection = try XCTUnwrap(connectionFactory.connection(at: 0))
        try await Task.sleep(for: .milliseconds(100))

        firstConnection.invalidate()

        do {
            _ = try await interruptedTask.value
            XCTFail("The invalidated invocation unexpectedly completed.")
        } catch let error as BlocksNativePluginExecutionError {
            guard case let .executionFailed(code, _) = error else {
                return XCTFail("Unexpected plugin error: \(error)")
            }
            XCTAssertEqual(code, "runner_invalidated")
        }

        let output = try await client.execute(
            package: recovered.package,
            metadata: recovered.metadata,
            invocation: BlocksNativePluginInvocation(
                pluginID: recovered.metadata.id,
                kind: .translation,
                input: ["text": .string("second")]
            ),
            progress: { _ in }
        )

        XCTAssertEqual(output.text, "recovered:second")
        XCTAssertEqual(connectionFactory.connectionCount, 2)
    }

    func testFiniteTimeoutDoesNotPoisonNextRealRunnerConnection() async throws {
        let timedOut = try makeRuntimeFixture(
            id: "com.example.runner-timeout",
            capability: .translation,
            entrySource: """
            function translate() {
              blocks.progress({ kind: "progress", fraction: 0.1 });
              const deadline = Date.now() + 1200;
              while (Date.now() < deadline) {}
              return { text: "too late" };
            }
            """
        )
        let recovered = try makeRuntimeFixture(
            id: "com.example.after-timeout",
            capability: .translation,
            entrySource: """
            function translate(input) {
              blocks.progress({ kind: "progress", fraction: 1 });
              return { text: "fresh:" + input.text };
            }
            """
        )
        let connectionFactory = RecordingPluginXPCConnectionFactory()
        let client = makeClient(
            metadata: [
                timedOut.metadata.id: timedOut.metadata,
                recovered.metadata.id: recovered.metadata,
            ],
            timeoutSeconds: 1,
            connectionFactory: connectionFactory
        )
        do {
            _ = try await client.execute(
                package: timedOut.package,
                metadata: timedOut.metadata,
                invocation: BlocksNativePluginInvocation(
                    pluginID: timedOut.metadata.id,
                    kind: .translation,
                    input: ["text": .string("slow")]
                ),
                progress: { _ in }
            )
            XCTFail("The finite over-budget plugin unexpectedly completed.")
        } catch let error as BlocksNativePluginExecutionError {
            guard case let .executionFailed(code, _) = error else {
                return XCTFail("Unexpected plugin error: \(error)")
            }
            XCTAssertEqual(code, "runner_timeout")
        }

        let output = try await client.execute(
            package: recovered.package,
            metadata: recovered.metadata,
            invocation: BlocksNativePluginInvocation(
                pluginID: recovered.metadata.id,
                kind: .translation,
                input: ["text": .string("ready")]
            ),
            progress: { _ in }
        )

        XCTAssertEqual(output.text, "fresh:ready")
        XCTAssertEqual(connectionFactory.connectionCount, 2)
    }

    private struct RuntimeFixture {
        let package: BlocksNativePluginValidatedPackage
        let metadata: BlocksNativePluginMetadata
    }

    private func makeRuntimeFixture(
        id: String,
        capability: BlocksNativePluginCapability,
        entrySource: String
    ) throws -> RuntimeFixture {
        let manifest = BlocksNativePluginManifest(
            id: id,
            displayName: id,
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [capability]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let packageHash = Data(id.utf8).base64EncodedString()
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: manifestData,
            entrySource: entrySource,
            packageSHA256: packageHash,
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: id,
                displayName: id,
                version: manifest.version,
                packageSHA256: packageHash,
                isSigned: false,
                capabilities: [capability],
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        let now = Date(timeIntervalSince1970: 1)
        let metadata = BlocksNativePluginMetadata(
            id: id,
            displayName: id,
            packageVersion: manifest.version,
            packageHash: packageHash,
            manifestJSON: String(decoding: manifestData, as: UTF8.self),
            capabilities: [capability],
            installedRelativePath: "\(id)/\(packageHash)",
            isEnabled: true,
            approvalStatus: .approved,
            approvedPermissions: [],
            approvedDomains: [],
            installedAt: now,
            updatedAt: now
        )
        return RuntimeFixture(package: package, metadata: metadata)
    }

    private func pluginMetadata(
        _ metadata: BlocksNativePluginMetadata,
        isEnabled: Bool,
        safetyDisabled: Bool = false
    ) -> BlocksNativePluginMetadata {
        BlocksNativePluginMetadata(
            id: metadata.id,
            displayName: metadata.displayName,
            packageVersion: metadata.packageVersion,
            packageHash: metadata.packageHash,
            manifestJSON: metadata.manifestJSON,
            capabilities: metadata.capabilities,
            installedRelativePath: metadata.installedRelativePath,
            isEnabled: isEnabled,
            approvalStatus: metadata.approvalStatus,
            approvedPermissions: metadata.approvedPermissions,
            approvedDomains: metadata.approvedDomains,
            debugEnabled: metadata.debugEnabled,
            safetyDisabled: safetyDisabled,
            consecutiveFailureCount: safetyDisabled ? 3 : 0,
            installedAt: metadata.installedAt,
            updatedAt: Date()
        )
    }

    private func makeClient(
        metadata: [String: BlocksNativePluginMetadata],
        timeoutSeconds: Double,
        connectionFactory: RecordingPluginXPCConnectionFactory? = nil
    ) -> BlocksNativePluginXPCExecutionClient {
        BlocksNativePluginXPCExecutionClient(
            timeoutSeconds: timeoutSeconds,
            metadataResolver: { pluginID in
                guard let value = metadata[pluginID] else {
                    throw PluginXPCIntegrationTestError.metadataMissing
                }
                return value
            },
            secretResolver: { _, _ in
                throw PluginXPCIntegrationTestError.unexpectedSecretRequest
            },
            connectionFactory: {
                connectionFactory?.makeConnection()
                    ?? NSXPCConnection(
                        serviceName: BlocksNativePluginXPC.serviceName
                    )
            }
        )
    }

    private func makeCapture(
        width: Int,
        height: Int
    ) throws -> TranslationScreenshotCapture {
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.sRGB)
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                red: 0.2,
                green: 0.4,
                blue: 0.8,
                alpha: 1
            )
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return TranslationScreenshotCapture(
            image: NSImage(
                cgImage: image,
                size: CGSize(width: width, height: height)
            ),
            cgImage: image,
            logicalRect: CGRect(x: 0, y: 0, width: width, height: height),
            pixelSize: CGSize(width: width, height: height),
            screen: nil
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started
                >= timeoutNanoseconds {
                throw PluginXPCIntegrationTestError.conditionTimedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class BlocksNativePluginManagerTests: XCTestCase {
    private let safeModePreferenceKey = "blocks.plugins.safeMode"
    private var previousSafeModePreference: Any?

    override func setUp() async throws {
        try await super.setUp()
        previousSafeModePreference = UserDefaults.standard.object(
            forKey: safeModePreferenceKey
        )
        UserDefaults.standard.set(false, forKey: safeModePreferenceKey)
    }

    override func tearDown() async throws {
        if let previousSafeModePreference {
            UserDefaults.standard.set(
                previousSafeModePreference,
                forKey: safeModePreferenceKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: safeModePreferenceKey)
        }
        previousSafeModePreference = nil
        try await super.tearDown()
    }

    func testRuntimeDebugLogNeverPersistsPluginPayloadsThroughShowLogs()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginRuntimeDebugSummary-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        let debugLogStore = BlocksPluginDebugLogStore(environment: environment)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platformRepository,
            debugLogStore: debugLogStore
        )
        let source = try makePackage(
            at: root,
            capabilities: [.actions, .hooks],
            platform: .init(
                hooks: [
                    .init(id: "launch", event: .appLaunched),
                ],
                actions: [
                    .init(
                        id: "launder",
                        displayName: "Launder",
                        entryFunction: "run"
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setDebugEnabled(true, pluginID: installed.id)

        let inputSentinel = "ACTION_INPUT_SENTINEL_4B4C"
        let outputSentinel = "ACTION_OUTPUT_SENTINEL_4B4C"
        let diagnosticSentinel = "DIAGNOSTIC_SENTINEL_4B4C"
        let metadataKeySentinel = "DIAGNOSTIC_KEY_SENTINEL_4B4C"
        let otp = 761_293
        executor.nextPlatformResult = .init(
            output: [
                "note": .string(outputSentinel),
                "nested": .array([
                    .object([metadataKeySentinel: .string(diagnosticSentinel)]),
                ]),
                "otp": .int(otp),
            ],
            diagnostics: [
                .init(
                    level: .warning,
                    code: "plugin-controlled-code",
                    message: diagnosticSentinel,
                    metadata: [metadataKeySentinel: .string(diagnosticSentinel)]
                ),
            ]
        )
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "launder",
            input: [
                "note": .string(inputSentinel),
                metadataKeySentinel: .array([.int(otp)]),
            ]
        )

        let debugActionSentinel = "UNAPPROVED_ACTION_DEBUG_SENTINEL_4B4C"
        executor.nextPlatformResult = .init(hook: .init(actions: [
            .init(actionID: debugActionSentinel),
        ]))
        _ = await runtime.dispatch(.init(name: .appLaunched))

        try await manager.setDebugEnabled(false, pluginID: installed.id)
        let nonDebugActionSentinel =
            "UNAPPROVED_ACTION_NONDEBUG_SENTINEL_4B4C"
        executor.nextPlatformResult = .init(hook: .init(actions: [
            .init(actionID: nonDebugActionSentinel),
        ]))
        _ = await runtime.dispatch(.init(name: .appLaunched))

        let file = try XCTUnwrap(debugLogStore.logFiles(
            pluginID: installed.id
        ).first)
        let persisted = try String(contentsOf: file, encoding: .utf8)
        let service = PluginDevelopmentService(
            pluginManager: manager,
            runtime: runtime
        )
        let shown = try await service.execute(
            .init(operation: .showLogs, pluginID: installed.id),
            requestID: .make()
        )
        let exported = try XCTUnwrap(shown.logs)
        var auditDatabase: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                environment.databaseURL.path,
                &auditDatabase,
                SQLITE_OPEN_READONLY,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_close(auditDatabase) }
        var auditStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                auditDatabase,
                "SELECT GROUP_CONCAT(metadata_json, '\n') FROM plugin_audit_events",
                -1,
                &auditStatement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(auditStatement) }
        let auditMetadata: String
        if sqlite3_step(auditStatement) == SQLITE_ROW,
           let text = sqlite3_column_text(auditStatement, 0) {
            auditMetadata = String(
                cString: UnsafeRawPointer(text)
                    .assumingMemoryBound(to: CChar.self)
            )
        } else {
            auditMetadata = ""
        }

        for forbidden in [
            inputSentinel, outputSentinel, diagnosticSentinel,
            metadataKeySentinel, String(otp), debugActionSentinel,
            nonDebugActionSentinel,
        ] {
            XCTAssertFalse(persisted.contains(forbidden))
            XCTAssertFalse(exported.contains(forbidden))
            XCTAssertFalse(auditMetadata.contains(forbidden))
        }
        for required in [
            "\"category\":\"action\"",
            "\"action\":\"launder\"",
            "\"outcome\":\"completed\"",
            "input_summary",
            "output_summary",
            "diagnostic_count",
            "diagnostic_levels",
        ] {
            XCTAssertTrue(persisted.contains(required))
            XCTAssertTrue(exported.contains(required))
        }
        XCTAssertTrue(persisted.contains("unapproved_or_unknown"))
        XCTAssertTrue(exported.contains("unapproved_or_unknown"))
        XCTAssertTrue(auditMetadata.contains("unapproved_or_unknown"))
    }

    func testAutomaticSafetyDisableRevokesRuntimeReadsUntilExplicitClear()
        async throws
    {
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defaults.set(false, forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSafetyHostReads-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platformRepository
        )
        let source = try makePackage(
            at: root,
            capabilities: [.actions],
            platform: .init(
                actions: [
                    .init(id: "fail", displayName: "Fail", entryFunction: "fail"),
                ],
                storage: .init(kinds: [.keyValue]),
                sharedState: [
                    .init(
                        id: "safety-shared",
                        schemaVersion: 1,
                        schema: [:],
                        access: .readWrite
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)

        func request(
            _ operation: String,
            _ input: [String: JSONValue]
        ) -> BlocksPluginHostOperationResponse {
            manager.hostOperationRouter.perform(.init(
                pluginID: installed.id,
                operation: operation,
                input: input
            ))
        }

        XCTAssertTrue(request("storage.put", [
            "key": .string("private"),
            "value": .string("private-value"),
        ]).ok)
        XCTAssertTrue(request("shared.put", [
            "owner_plugin_id": .string(installed.id),
            "namespace": .string("safety-shared"),
            "key": .string("shared"),
            "schema_version": .int(1),
            "value": .string("shared-value"),
        ]).ok)

        for _ in 0 ..< 3 {
            executor.failNextExecution()
            do {
                _ = try await runtime.performPluginAction(
                    pluginID: installed.id,
                    actionID: "fail"
                )
                XCTFail("Expected the fixture action to fail.")
            } catch {
                // The third recorded failure is the automatic safety cutoff.
            }
        }

        XCTAssertTrue(
            manager.plugins.first(where: { $0.id == installed.id })?
                .safetyDisabled == true
        )
        XCTAssertFalse(request("storage.get", [
            "key": .string("private"),
        ]).ok)
        XCTAssertFalse(request("shared.get", [
            "owner_plugin_id": .string(installed.id),
            "namespace": .string("safety-shared"),
            "key": .string("shared"),
        ]).ok)

        try await manager.clearSafetyDisable(pluginID: installed.id)
        XCTAssertTrue(request("storage.get", [
            "key": .string("private"),
        ]).ok)
        XCTAssertTrue(request("shared.get", [
            "owner_plugin_id": .string(installed.id),
            "namespace": .string("safety-shared"),
            "key": .string("shared"),
        ]).ok)
    }

    func testBindingFilteringFailsClosedForAppStoreExternalPlugins() {
        let external = pluginMetadata(
            id: "com.example.external",
            isEnabled: true,
            approvalStatus: .approved,
            capabilities: [.hooks]
        )
        let hook = BlocksPluginHookBinding(
            pluginID: external.id,
            hookID: "fail-closed",
            event: .appLaunched,
            sortOrder: 0,
            isEnabled: true,
            timeoutMilliseconds: 100,
            failurePolicy: .failClosed
        )
        let schedule = BlocksPluginScheduleBinding(
            pluginID: external.id,
            scheduleID: "rebuild-host",
            kind: .interval,
            configuration: [:],
            isEnabled: true
        )

        XCTAssertTrue(
            BlocksNativePluginManager.filterBindingsForDistribution(
                [hook],
                pluginID: \.pluginID,
                pluginSnapshot: [external],
                distributionChannel: .appStoreBeta
            ).isEmpty
        )
        XCTAssertTrue(
            BlocksNativePluginManager.filterBindingsForDistribution(
                [schedule],
                pluginID: \.pluginID,
                pluginSnapshot: [external],
                distributionChannel: .appStoreBeta
            ).isEmpty
        )
        XCTAssertEqual(
            BlocksNativePluginManager.filterBindingsForDistribution(
                [hook],
                pluginID: \.pluginID,
                pluginSnapshot: [external],
                distributionChannel: .directBeta
            ),
            [hook]
        )
        XCTAssertEqual(
            BlocksNativePluginManager.filterBindingsForDistribution(
                [schedule],
                pluginID: \.pluginID,
                pluginSnapshot: [external],
                distributionChannel: .directBeta
            ),
            [schedule]
        )
    }

    func testAppStoreRuntimeSkipsExternalFailClosedHookWithoutRecordingFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginAppStoreRuntime-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platformRepository = BlocksPluginPlatformRepository(
            database: database
        )
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platformRepository
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(
                        id: "block-host-write",
                        event: .clipboardWillWritePasteboard,
                        failurePolicy: .failClosed
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)

        let appStoreRuntime = BlocksPluginRuntimeCoordinator(
            manager: manager,
            distributionChannel: .appStoreBeta
        )
        let appStoreResult = await appStoreRuntime.dispatch(
            .init(name: .clipboardWillWritePasteboard)
        )

        XCTAssertTrue(appStoreResult.allowed)
        XCTAssertNil(appStoreResult.blockedByPluginID)
        XCTAssertEqual(executor.invocationCount, 0)

        let afterAppStoreDispatch = try XCTUnwrap(
            platformRepository.hookBindings(pluginID: installed.id).first
        )
        XCTAssertEqual(afterAppStoreDispatch.consecutiveFailureCount, 0)

        let directRuntime = BlocksPluginRuntimeCoordinator(
            manager: manager,
            distributionChannel: .directBeta
        )
        let directResult = await directRuntime.dispatch(
            .init(name: .clipboardWillWritePasteboard)
        )

        XCTAssertTrue(directResult.allowed)
        XCTAssertEqual(executor.invocationCount, 1)
        let afterDirectDispatch = try XCTUnwrap(
            platformRepository.hookBindings(pluginID: installed.id).first
        )
        XCTAssertEqual(afterDirectDispatch.consecutiveFailureCount, 0)

        executor.failNextExecution()
        let failedDirectResult = await directRuntime.dispatch(
            .init(name: .clipboardWillWritePasteboard)
        )
        XCTAssertFalse(failedDirectResult.allowed)
        XCTAssertEqual(failedDirectResult.blockedByPluginID, installed.id)
        XCTAssertEqual(
            try platformRepository.hookBindings(pluginID: installed.id)
                .first?.consecutiveFailureCount,
            1
        )
    }

    func testRuntimeSkipsForegroundHookWhenPersistedBindingEventDrifts()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginBindingDrift-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platformRepository
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "foreground-preflight",
                    event: .clipboardWillWritePasteboard,
                    failurePolicy: .failClosed,
                    runsInBackground: false
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)

        let validResult = await runtime.dispatch(
            .init(name: .clipboardWillWritePasteboard)
        )
        XCTAssertTrue(validResult.allowed)
        XCTAssertEqual(executor.invocationCount, 1)

        // Simulate a historical/corrupt persisted binding without changing
        // the validated manifest snapshot held by the manager.
        try platformRepository.synchronizeManifest(
            pluginID: installed.id,
            platform: .init(hooks: [
                .init(
                    id: "foreground-preflight",
                    event: .automationScheduledTrigger,
                    failurePolicy: .failClosed,
                    runsInBackground: false
                ),
            ])
        )

        let staleResult = await runtime.dispatch(
            .init(name: .automationScheduledTrigger)
        )
        XCTAssertTrue(staleResult.allowed)
        XCTAssertNil(staleResult.blockedByPluginID)
        XCTAssertEqual(executor.invocationCount, 1)
        let binding = try XCTUnwrap(
            platformRepository.hookBindings(pluginID: installed.id).first
        )
        XCTAssertEqual(binding.consecutiveFailureCount, 0)
    }

    @MainActor
    func testAsyncPostEventsAreFIFOWithinModuleWithoutBlockingOtherModules()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginAsyncFIFO-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = AsyncModuleFIFOPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(id: "screenshot-finished", event: .screenshotOutputFinished),
                    .init(id: "screenshot-failed", event: .screenshotOutputFailed),
                    .init(id: "screenshot-finalize", event: .screenshotWillFinalizeOutput),
                    .init(id: "clipboard-saved", event: .clipboardDidPersistCapture),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let resource = runtime.resources.register(
            data: Data("lease".utf8),
            kind: .screenshot,
            mediaType: "image/png"
        )
        runtime.resources.authorize(
            pluginID: installed.id,
            resourceIDs: [resource.id]
        )

        runtime.dispatchAsync(.init(
            name: .screenshotOutputFinished,
            payload: ["sequence": .string("A")],
            resources: [resource]
        ))
        await executor.waitForMarker("screenshot.output_finished:A")

        XCTAssertNoThrow(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))
        runtime.resources.remove(ids: [resource.id])
        XCTAssertNoThrow(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))

        runtime.dispatchAsync(.init(
            name: .screenshotOutputFailed,
            payload: ["sequence": .string("B")]
        ))
        runtime.dispatchAsync(.init(
            name: .clipboardDidPersistCapture,
            payload: ["sequence": .string("C")]
        ))
        await executor.waitForMarker("clipboard.did_persist_capture:C")
        let markersBeforeScreenshotRelease = await executor.markers()
        XCTAssertEqual(
            markersBeforeScreenshotRelease,
            ["screenshot.output_finished:A", "clipboard.did_persist_capture:C"]
        )

        let willDispatch = Task { @MainActor in
            await runtime.dispatchFromFeature(.init(
                name: .screenshotWillFinalizeOutput,
                payload: ["sequence": .string("will")]
            ))
        }
        await Task.yield()
        let markersWhileScreenshotIsBlocked = await executor.markers()
        XCTAssertEqual(
            markersWhileScreenshotIsBlocked,
            markersBeforeScreenshotRelease
        )

        await executor.releaseFirstScreenshot()
        await executor.waitForMarker("screenshot.output_failed:B")
        _ = await willDispatch.value
        await executor.waitForMarker("screenshot.will_finalize_output:will")
        let markersAfterScreenshotRelease = await executor.markers()
        XCTAssertEqual(
            markersAfterScreenshotRelease,
            [
                "screenshot.output_finished:A",
                "clipboard.did_persist_capture:C",
                "screenshot.output_failed:B",
                "screenshot.will_finalize_output:will",
            ]
        )
        XCTAssertThrowsError(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))
    }

    @MainActor
    func testAwaitedPostEventReturnsOnlyAfterRuntimeHookCompletes()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginAwaitedPost-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = AsyncModuleFIFOPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "screenshot-finished",
                    event: .screenshotOutputFinished
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let completion = PluginAsyncCompletionProbe()

        let dispatch = Task { @MainActor in
            let result = await runtime.dispatchFromFeatureAwaitingCompletion(
                .init(
                    name: .screenshotOutputFinished,
                    payload: ["sequence": .string("A")]
                )
            )
            await completion.markFinished()
            return result
        }
        await executor.waitForMarker("screenshot.output_finished:A")

        let finishedWhileHookIsSuspended = await completion.isFinished
        XCTAssertFalse(finishedWhileHookIsSuspended)

        await executor.releaseFirstScreenshot()
        let result = await dispatch.value
        XCTAssertTrue(result.allowed)
        let finishedAfterHookCompletion = await completion.isFinished
        XCTAssertTrue(finishedAfterHookCompletion)
    }

    @MainActor
    func testAwaitedTerminalPostRevokedAfterFIFOEnqueueDoesNotReachExecutor()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginAwaitedPostAdmission-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        let firstStarted = expectation(description: "first terminal started")
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = AsyncModuleFIFOPluginExecutor(
            effectsMarker: "screenshot.will_finalize_output:revoked",
            onMarker: { marker in
            if marker == "screenshot.output_finished:A" {
                firstStarted.fulfill()
            }
            }
        )
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(id: "screenshot-finished", event: .screenshotOutputFinished),
                .init(id: "screenshot-failed", event: .screenshotOutputFailed),
                .init(id: "screenshot-will-finalize", event: .screenshotWillFinalizeOutput),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let secondEnqueued = expectation(description: "second terminal enqueued")
        runtime.asyncDispatchEnqueuedHook = { envelope in
            if envelope.name == .screenshotOutputFailed,
               envelope.payload["sequence"] == .string("B") {
                secondEnqueued.fulfill()
            }
        }

        runtime.dispatchAsync(.init(
            name: .screenshotOutputFinished,
            payload: ["sequence": .string("A")]
        ))
        await fulfillment(of: [firstStarted], timeout: 1)

        var isCurrent = true
        let secondFinished = expectation(description: "second terminal completed")
        let second = Task { @MainActor in
            defer { secondFinished.fulfill() }
            return await runtime.dispatchFromFeatureAwaitingCompletion(
                .init(
                    name: .screenshotOutputFailed,
                    payload: ["sequence": .string("B")]
                ),
                admissionIsCurrent: { isCurrent }
            )
        }
        await fulfillment(of: [secondEnqueued], timeout: 1)
        isCurrent = false
        await executor.releaseFirstScreenshot()
        await fulfillment(of: [secondFinished], timeout: 1)
        let result = await second.value

        XCTAssertTrue(result.allowed)
        let markers = await executor.markers()
        XCTAssertEqual(markers, ["screenshot.output_finished:A"])

        let revokedWillResource = runtime.resources.register(
            data: Data("revoked-will".utf8),
            kind: .screenshot,
            mediaType: "image/png"
        )
        let revokedWillResult = await runtime.dispatchFromFeatureAwaitingCompletion(
            .init(
                name: .screenshotWillFinalizeOutput,
                payload: ["sequence": .string("revoked")],
                resources: [revokedWillResource]
            ),
            admissionIsCurrent: { false }
        )
        XCTAssertTrue(revokedWillResult.allowed)
        let markersAfterRevokedWill = await executor.markers()
        XCTAssertEqual(markersAfterRevokedWill, ["screenshot.output_finished:A"])
        let revokedWillEffects = await executor.effectsInvocationCount()
        XCTAssertEqual(revokedWillEffects, 0)
    }

    @MainActor
    func testClipboardCoordinatorDisableRevokesRunningWillHookResourceAndLateEffects()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginClipboardFeatureAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsSuite =
            "BlocksPluginClipboardFeatureAdmission-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let safeModeKey = "blocks.plugins.safeMode"
        let previousSafeMode = UserDefaults.standard.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                UserDefaults.standard.set(previousSafeMode, forKey: safeModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: safeModeKey)
            }
        }
        UserDefaults.standard.set(false, forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let willStarted = expectation(description: "clipboard will hook started")
        let executor = FeatureAdmissionSuspendedHookExecutor(
            onWillStarted: { willStarted.fulfill() },
            suspendedWillEvent: .clipboardWillPersistCapture
        )
        defer { executor.release() }
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "Managed",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            pluginID: "com.example.clipboard-feature-admission",
            capabilities: [.hooks, .actions, .ui],
            dataPermissions: [.clipboardContent],
            platform: .init(
                hooks: [
                    .init(
                        id: "will-persist",
                        event: .clipboardWillPersistCapture
                    ),
                    .init(
                        id: "persisted",
                        event: .clipboardDidPersistCapture
                    ),
                    .init(
                        id: "failed",
                        event: .clipboardCaptureFailed
                    ),
                ],
                hostActions: ["system.notification"],
                ui: [
                    .init(
                        id: "runtime-status",
                        slot: .clipboardRecordBadge,
                        root: .init(id: "runtime-status", kind: .status)
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let hostActionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await hostActionProbe.recordInvocation()
            return .null
        }
        let coordinator = ClipboardFeatureCoordinator(
            clipboardStore: ClipboardStore(repository: nil),
            privacyStore: PrivacyStore(repository: nil),
            featureAvailabilityStore: FeatureAvailabilityStore(defaults: defaults)
        )
        coordinator.configure(
            statusRecorder: { _ in },
            sectionSelector: { _ in },
            closeTranslationPanel: {},
            translateRecord: { _ in },
            refreshPermissionState: {},
            pluginManager: manager,
            pluginRuntime: runtime,
            dispatchPluginEvent: { envelope in
                await runtime.dispatchFromFeature(envelope)
            },
            stagePluginTextResource: { _, _, _, _ in nil },
            removePluginResources: { _ in },
            accessibilityGranted: { true },
            presentAccessibilityAssist: { _ in }
        )
        let resource = runtime.resources.register(
            data: Data("clipboard-sensitive".utf8),
            kind: .text,
            mediaType: "text/plain"
        )
        let readRequest = BlocksPluginHostOperationRequest(
            pluginID: installed.id,
            operation: "resource.read",
            input: [
                "resource_id": .string(resource.id),
                "offset": .int(0),
                "length": .int(128),
            ]
        )
        let dispatch = Task { @MainActor in
            await runtime.dispatchFromFeatureAwaitingCompletion(.init(
                name: .clipboardWillPersistCapture,
                resources: [resource]
            ))
        }
        await fulfillment(of: [willStarted], timeout: 1)
        XCTAssertTrue(manager.hostOperationRouter.perform(readRequest).ok)

        coordinator.disableRuntime()
        XCTAssertFalse(manager.hostOperationRouter.perform(readRequest).ok)

        executor.release()
        _ = await dispatch.value
        let hostActionInvocationCount = await hostActionProbe.invocationCount
        XCTAssertEqual(hostActionInvocationCount, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
        XCTAssertEqual(
            executor.invocationCount(for: .clipboardDidPersistCapture),
            0
        )
        XCTAssertEqual(
            executor.invocationCount(for: .clipboardCaptureFailed),
            0
        )
    }

    @MainActor
    func testScreenshotStoreDisableRevokesRunningWillHookResourceAndLateEffects()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginScreenshotFeatureAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsSuite = "BlocksPluginScreenshotFeatureAdmission-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }

        let willStarted = expectation(description: "screenshot will hook started")
        let executor = FeatureAdmissionSuspendedHookExecutor(
            onWillStarted: { willStarted.fulfill() }
        )
        defer { executor.release() }
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "Managed",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let source = try makePackage(
            at: root,
            pluginID: "com.example.screenshot-feature-admission",
            capabilities: [.hooks, .actions, .ui],
            dataPermissions: [.screenshotImage, .screenshotDocument],
            platform: .init(
                hooks: [
                    .init(
                        id: "will-finalize",
                        event: .screenshotWillFinalizeOutput
                    ),
                    .init(
                        id: "finished",
                        event: .screenshotOutputFinished
                    ),
                    .init(
                        id: "failed",
                        event: .screenshotOutputFailed
                    ),
                ],
                hostActions: ["system.notification", "screenshot.ocr"],
                ui: [
                    .init(
                        id: "runtime-status",
                        slot: .screenshotStatusItem,
                        root: .init(id: "runtime-status", kind: .status)
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let auditCountBeforeDisable = try pluginAuditEventCount(
            databaseURL: environment.databaseURL,
            pluginID: installed.id
        )
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let hostActionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await hostActionProbe.recordInvocation()
            return .null
        }

        let image = try featureAdmissionScreenshotImage()
        let capture = ScreenshotCapture(
            id: "feature-admission-capture",
            image: image,
            pixelSize: CGSize(width: 2, height: 2),
            sourceRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            kind: .region,
            displayScope: nil,
            sourceSummary: "feature admission fixture"
        )
        let captureService = FeatureAdmissionCaptureService(capture: capture)
        let pasteboard = FeatureAdmissionPasteboardWriter()
        let archive = FeatureAdmissionArchiveWriter()
        let editor = FeatureAdmissionEditorPresenter()
        let resources = FeatureAdmissionResourceTracker()
        let runtimeResources = runtime.resources
        var screenshotEnabled = true
        let store = ScreenshotStore(
            captureService: captureService,
            editorPresenter: editor,
            preferencesStore: ScreenshotPreferencesStore(userDefaults: defaults),
            pasteboardWriter: pasteboard,
            archiveWriter: archive,
            featureEnabled: { screenshotEnabled },
            permissionRefresher: {},
            permissionSnapshotProvider: {
                fatalError("No-editor action does not read GUI permissions.")
            }
        )
        store.configureCoordinator(
            statusRecorder: { _ in },
            retakeHandler: { _ in },
            dispatchPluginEvent: { [weak runtime] envelope in
                guard let runtime else { return .allowed(envelope) }
                return await runtime.dispatchFromFeature(envelope)
            },
            registerPluginResource: { [weak runtime, resources, runtimeResources] data, kind, mediaType, metadata in
                guard runtime != nil else { return nil }
                let resource = runtimeResources.register(
                    data: data,
                    kind: kind,
                    mediaType: mediaType,
                    metadata: metadata
                )
                resources.recordRegistered(resource.id)
                return resource
            },
            removePluginResources: { [resources, runtimeResources] ids in
                resources.recordRemoved(ids)
                runtimeResources.remove(ids: ids)
            },
            pluginManager: manager,
            pluginRuntime: runtime
        )
        let input = try ScreenshotCaptureActionInput(
            kind: .region,
            interaction: .noEditor,
            copy: true,
            watermark: .none
        )
        let oldActionFinished = expectation(description: "disabled screenshot action finished")
        let oldActionSucceeded = LockedFlag()
        let oldAction = Task { @MainActor in
            defer { oldActionFinished.fulfill() }
            do {
                _ = try await store.executeAction(input, outputFile: nil)
                oldActionSucceeded.set()
            } catch {
                return
            }
        }
        defer { oldAction.cancel() }
        await fulfillment(of: [willStarted], timeout: 1)
        let resourceID = try XCTUnwrap(executor.resourceID())
        func resourceRead() -> BlocksPluginHostOperationResponse {
            manager.hostOperationRouter.perform(.init(
                pluginID: installed.id,
                operation: "resource.read",
                input: [
                    "resource_id": .string(resourceID),
                    "offset": .int(0),
                    "length": .int(16),
                ]
            ))
        }
        XCTAssertTrue(resourceRead().ok)

        screenshotEnabled = false
        store.disableRuntime()
        XCTAssertFalse(resourceRead().ok)
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertEqual(archive.archiveCount, 0)
        let hostActionsAtDisable = await hostActionProbe.invocationCount
        XCTAssertEqual(hostActionsAtDisable, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)

        executor.release()
        await fulfillment(of: [oldActionFinished], timeout: 1)
        XCTAssertFalse(oldActionSucceeded.value)
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertEqual(archive.archiveCount, 0)
        let hostActionsAfterRelease = await hostActionProbe.invocationCount
        XCTAssertEqual(hostActionsAfterRelease, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
        XCTAssertEqual(executor.terminalInvocationCount(), 0)
        XCTAssertEqual(
            try pluginAuditEventCount(
                databaseURL: environment.databaseURL,
                pluginID: installed.id
            ),
            auditCountBeforeDisable
        )
        XCTAssertEqual(resources.registeredIDs(), [resourceID])
        XCTAssertEqual(resources.removedIDs(), [resourceID])
        XCTAssertFalse(resourceRead().ok)

        screenshotEnabled = true
        let recovered = try await store.executeAction(input, outputFile: nil)
        XCTAssertEqual(recovered.pasteboard, .succeeded)
        XCTAssertEqual(recovered.history, .succeeded)
        XCTAssertEqual(pasteboard.writeCount, 1)
        XCTAssertEqual(archive.archiveCount, 1)
        let hostActionsAfterRecovery = await hostActionProbe.invocationCount
        XCTAssertEqual(hostActionsAfterRecovery, 1)
        XCTAssertEqual(executor.terminalInvocationCount(), 1)
        XCTAssertEqual(
            runtime.uiStateByPluginID[installed.id]?["runtime-status"]?["value"],
            .string("ran")
        )
    }

    @MainActor
    func testScreenshotStoreDisableCutsOffAlreadyAdmittedScopedResourceRead()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginScreenshotReadAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsSuite = "BlocksPluginScreenshotReadAdmission-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let safeModeKey = "blocks.plugins.safeMode"
        let previousSafeMode = UserDefaults.standard.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                UserDefaults.standard.set(previousSafeMode, forKey: safeModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: safeModeKey)
            }
        }
        UserDefaults.standard.set(false, forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let firstWillStarted = expectation(description: "first screenshot will hook started")
        let secondWillStarted = expectation(description: "second screenshot will hook started")
        let executor = FeatureAdmissionSuspendedHookExecutor(
            onWillStarted: { firstWillStarted.fulfill() },
            onWillInvocation: { invocationCount in
                if invocationCount == 2 { secondWillStarted.fulfill() }
            }
        )
        defer { executor.release() }
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "Managed",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            pluginID: "com.example.screenshot-read-admission",
            capabilities: [.hooks, .actions, .ui],
            dataPermissions: [.screenshotImage, .screenshotDocument],
            platform: .init(
                hooks: [
                    .init(
                        id: "will-finalize",
                        event: .screenshotWillFinalizeOutput
                    ),
                ],
                hostActions: ["system.notification", "screenshot.ocr"],
                ui: [
                    .init(
                        id: "runtime-status",
                        slot: .screenshotStatusItem,
                        root: .init(id: "runtime-status", kind: .status)
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)

        let readCheckpointReached = expectation(
            description: "scoped resource read reached checkpoint"
        )
        let readCheckpointRelease = DispatchSemaphore(value: 0)
        let readCheckpointClaim = LockedFlag()
        let runtime = BlocksPluginRuntimeCoordinator(
            manager: manager,
            resourceReadCheckpoint: {
                guard readCheckpointClaim.claim() else { return }
                readCheckpointReached.fulfill()
                _ = readCheckpointRelease.wait(timeout: .now() + 1)
            }
        )
        defer { readCheckpointRelease.signal() }

        var screenshotEnabled = true
        let image = try featureAdmissionScreenshotImage()
        let capture = ScreenshotCapture(
            id: "read-admission-capture",
            image: image,
            pixelSize: CGSize(width: 2, height: 2),
            sourceRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            kind: .region,
            displayScope: nil,
            sourceSummary: "resource read admission fixture"
        )
        let store = ScreenshotStore(
            captureService: FeatureAdmissionCaptureService(capture: capture),
            editorPresenter: FeatureAdmissionEditorPresenter(),
            preferencesStore: ScreenshotPreferencesStore(userDefaults: defaults),
            pasteboardWriter: FeatureAdmissionPasteboardWriter(),
            archiveWriter: FeatureAdmissionArchiveWriter(),
            featureEnabled: { screenshotEnabled },
            permissionRefresher: {},
            permissionSnapshotProvider: {
                fatalError("Resource-read fixture must not request GUI permissions.")
            }
        )
        store.configureCoordinator(
            statusRecorder: { _ in },
            retakeHandler: { _ in },
            pluginRuntime: runtime
        )

        let resource = runtime.resources.register(
            data: Data("sensitive screenshot bytes".utf8),
            kind: .screenshot,
            mediaType: "image/png"
        )
        let router = manager.hostOperationRouter
        let readRequest = BlocksPluginHostOperationRequest(
            pluginID: installed.id,
            operation: "resource.read",
            input: [
                "resource_id": .string(resource.id),
                "offset": .int(0),
                "length": .int(128),
            ]
        )

        let firstDispatch = Task { @MainActor in
            await runtime.dispatchFromFeature(.init(
                name: .screenshotWillFinalizeOutput,
                resources: [resource]
            ))
        }
        await fulfillment(of: [firstWillStarted], timeout: 1)

        let read = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: router.perform(readRequest))
                }
            }
        }
        await fulfillment(of: [readCheckpointReached], timeout: 1)
        screenshotEnabled = false
        store.disableRuntime()
        readCheckpointRelease.signal()
        let revokedResponse = await read.value
        XCTAssertFalse(revokedResponse.ok)
        XCTAssertNil(revokedResponse.value)

        executor.releaseCurrentWillAndRearm()
        _ = await firstDispatch.value

        screenshotEnabled = true
        let secondDispatch = Task { @MainActor in
            await runtime.dispatchFromFeature(.init(
                name: .screenshotWillFinalizeOutput,
                resources: [resource]
            ))
        }
        await fulfillment(of: [secondWillStarted], timeout: 1)
        let recoveredResponse = router.perform(readRequest)
        XCTAssertTrue(recoveredResponse.ok)
        guard case let .object(recoveredValue)? = recoveredResponse.value else {
            return XCTFail("Expected a resource.read object after re-enable.")
        }
        XCTAssertEqual(
            recoveredValue.string("data_base64"),
            Data("sensitive screenshot bytes".utf8).base64EncodedString()
        )
        executor.release()
        _ = await secondDispatch.value
    }

    @MainActor
    func testFeatureAdmissionRevokedAfterPermissionSkipsHostActionAndTerminalEffects()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginFeatureActionAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = FeatureAdmissionActionExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "Managed",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let source = try makePackage(
            at: root,
            pluginID: "com.example.feature-action-admission",
            capabilities: [.hooks, .actions],
            platform: .init(
                hooks: [
                    .init(
                        id: "screenshot-finished",
                        event: .screenshotOutputFinished
                    ),
                    .init(
                        id: "host-action-completed",
                        event: .pluginHostActionCompleted
                    ),
                    .init(
                        id: "host-action-failed",
                        event: .pluginHostActionFailed
                    ),
                ],
                hostActions: ["system.notification"]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let auditCountBeforeDispatch = try pluginAuditEventCount(
            databaseURL: environment.databaseURL,
            pluginID: installed.id
        )
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let hostActionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await hostActionProbe.recordInvocation()
            return .null
        }
        let permissionReached = expectation(description: "host action permission approved")
        let permissionPause = FeatureAdmissionPermissionPause()
        defer { permissionPause.release() }
        runtime.hostActionPermissionApprovedHook = {
            permissionReached.fulfill()
            await permissionPause.wait()
        }

        let dispatchFinished = expectation(description: "feature dispatch finished")
        let dispatchAllowed = LockedFlag()
        let dispatch = Task { @MainActor in
            defer { dispatchFinished.fulfill() }
            let result = await runtime.dispatchFromFeatureAwaitingCompletion(
                .init(name: .screenshotOutputFinished)
            )
            if result.allowed { dispatchAllowed.set() }
        }
        defer { dispatch.cancel() }
        await fulfillment(of: [permissionReached], timeout: 1)
        runtime.invalidateFeatureAdmission(for: .screenshot)
        permissionPause.release()
        await fulfillment(of: [dispatchFinished], timeout: 1)

        XCTAssertTrue(dispatchAllowed.value)
        let hostActionInvocationCount = await hostActionProbe.invocationCount
        XCTAssertEqual(hostActionInvocationCount, 0)
        XCTAssertEqual(
            executor.invocationCount(for: .pluginHostActionCompleted),
            0
        )
        XCTAssertEqual(
            executor.invocationCount(for: .pluginHostActionFailed),
            0
        )
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
        XCTAssertEqual(
            try pluginAuditEventCount(
                databaseURL: environment.databaseURL,
                pluginID: installed.id
            ),
            auditCountBeforeDispatch
        )
    }

    @MainActor
    func testAsyncPostQueueInvalidationDropsQueuedEventsAndReleasesLeases()
        async throws
    {
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        func runScenario(termination: Bool) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "BlocksPluginAsyncInvalidation-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            let environment = StorageEnvironment(
                rootDirectory: root.appendingPathComponent(
                    "Data",
                    isDirectory: true
                )
            )
            let database = try AppDatabase.open(environment: environment)
            defer { database.close() }
            let executor = AsyncModuleFIFOPluginExecutor()
            let manager = BlocksNativePluginManager(
                repository: BlocksNativePluginMetadataRepository(database: database),
                managedRoot: environment.rootDirectory.appendingPathComponent(
                    "TranslationPlugins",
                    isDirectory: true
                ),
                executor: executor,
                secretStore: RecordingPluginSecretStore(),
                platformRepository: BlocksPluginPlatformRepository(database: database)
            )
            let source = try makePackage(
                at: root,
                capabilities: [.hooks],
                platform: .init(hooks: [
                    .init(id: "screenshot-finished", event: .screenshotOutputFinished),
                    .init(id: "screenshot-failed", event: .screenshotOutputFailed),
                    .init(id: "screenshot-ocr", event: .screenshotOCRCompleted),
                    .init(id: "screenshot-finalize", event: .screenshotWillFinalizeOutput),
                ])
            )
            let pending = try await manager.prepareInstallation(from: source)
            let installed = try await manager.confirmAndInstall(pendingID: pending.id)
            _ = try await manager.setEnabled(true, pluginID: installed.id)
            let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
            let resources = (0..<3).map { index in
                runtime.resources.register(
                    data: Data("lease-\(index)".utf8),
                    kind: .screenshot,
                    mediaType: "image/png"
                )
            }
            runtime.resources.authorize(
                pluginID: installed.id,
                resourceIDs: resources.dropFirst().map(\.id)
            )

            runtime.dispatchAsync(.init(
                name: .screenshotOutputFinished,
                payload: ["sequence": .string("A")],
                resources: [resources[0]]
            ))
            await executor.waitForMarker("screenshot.output_finished:A")
            runtime.dispatchAsync(.init(
                name: .screenshotOutputFailed,
                payload: ["sequence": .string("B")],
                resources: [resources[1]]
            ))
            runtime.dispatchAsync(.init(
                name: .screenshotOCRCompleted,
                payload: ["sequence": .string("C")],
                resources: [resources[2]]
            ))
            let waitingWillDispatch = Task { @MainActor in
                await runtime.dispatchFromFeature(.init(
                    name: .screenshotWillFinalizeOutput,
                    payload: ["sequence": .string("will")]
                ))
            }
            await Task.yield()
            runtime.resources.remove(ids: resources.map(\.id))
            XCTAssertNoThrow(try runtime.resources.read(
                pluginID: installed.id,
                id: resources[1].id,
                offset: 0,
                length: 1
            ))

            if termination {
                await runtime.dispatchAppWillTerminate()
            } else {
                await runtime.setSafeModeEnabled(true)
                await runtime.setSafeModeEnabled(false)
            }
            await executor.releaseFirstScreenshot()
            _ = await waitingWillDispatch.value
            await waitForMainActorCondition {
                resources.dropFirst().allSatisfy { resource in
                    (try? runtime.resources.read(
                        pluginID: installed.id,
                        id: resource.id,
                        offset: 0,
                        length: 1
                    )) == nil
                }
            }
            let markersAfterInvalidation = await executor.markers()
            XCTAssertEqual(
                markersAfterInvalidation,
                ["screenshot.output_finished:A"]
            )
        }

        try await runScenario(termination: false)
        try await runScenario(termination: true)
    }

    @MainActor
    func testClipboardPostAdmissionRejectsBeforeResourceLeaseOrRunner()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginClipboardPostAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "clipboard-saved",
                    event: .clipboardDidPersistCapture
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let resource = runtime.resources.register(
            data: Data("privacy-sensitive".utf8),
            kind: .text,
            mediaType: "text/plain"
        )
        XCTAssertThrowsError(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))

        let result = await runtime.dispatchFromFeature(
            .init(
                name: .clipboardDidPersistCapture,
                resources: [resource]
            ),
            admissionIsCurrent: { false }
        )

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(executor.invocationCount, 0)
        XCTAssertThrowsError(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))
        runtime.resources.remove(ids: [resource.id])
        XCTAssertThrowsError(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))
    }

    @MainActor
    func testClipboardPostAdmissionRechecksAfterFIFOAndReleasesLease()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginClipboardPostFIFOAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = AsyncModuleFIFOPluginExecutor(
            blockingMarker: "clipboard.did_persist_capture:A",
            effectsMarker: "clipboard.did_persist_capture:B"
        )
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks, .actions],
            platform: .init(
                hooks: [.init(
                    id: "clipboard-saved",
                    event: .clipboardDidPersistCapture
                )],
                hostActions: ["system.notification"]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }
        var admissionIsCurrent = true
        let resource = runtime.resources.register(
            data: Data("queued privacy-sensitive".utf8),
            kind: .text,
            mediaType: "text/plain"
        )

        _ = await runtime.dispatchFromFeature(.init(
            name: .clipboardDidPersistCapture,
            payload: ["sequence": .string("A")]
        ))
        await executor.waitForMarker("clipboard.did_persist_capture:A")

        _ = await runtime.dispatchFromFeature(
            .init(
                name: .clipboardDidPersistCapture,
                payload: ["sequence": .string("B")],
                resources: [resource]
            ),
            admissionIsCurrent: { admissionIsCurrent }
        )
        runtime.resources.remove(ids: [resource.id])
        // A queued post retains only a host lease; the plugin itself is not
        // authorized until its runner starts. Temporarily authorize the test
        // reader so this assertion distinguishes "entry retained" from the
        // expected pre-run authorization denial.
        runtime.resources.authorize(
            pluginID: installed.id,
            resourceIDs: [resource.id]
        )
        XCTAssertNoThrow(try runtime.resources.read(
            pluginID: installed.id,
            id: resource.id,
            offset: 0,
            length: 1
        ))
        runtime.resources.revoke(
            pluginID: installed.id,
            resourceIDs: [resource.id]
        )

        admissionIsCurrent = false
        await executor.releaseBlockingMarker()
        await waitForMainActorCondition {
            runtime.resources.authorize(
                pluginID: installed.id,
                resourceIDs: [resource.id]
            )
            defer {
                runtime.resources.revoke(
                    pluginID: installed.id,
                    resourceIDs: [resource.id]
                )
            }
            return (try? runtime.resources.read(
                pluginID: installed.id,
                id: resource.id,
                offset: 0,
                length: 1
            )) == nil
        }

        let markers = await executor.markers()
        let effectsInvocationCount = await executor.effectsInvocationCount()
        let actionInvocationCount = await actionProbe.invocationCount
        XCTAssertFalse(markers.contains(
            "clipboard.did_persist_capture:B"
        ))
        XCTAssertEqual(effectsInvocationCount, 0)
        XCTAssertEqual(actionInvocationCount, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)

        _ = await runtime.dispatchFromFeature(.init(
            name: .clipboardDidPersistCapture,
            payload: ["sequence": .string("C")]
        ))
        await executor.waitForMarker("clipboard.did_persist_capture:C")
    }

    func testTerminationCancelsIntervalSchedulesBeforeTheyCanExecute()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginScheduleTermination-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(schedules: [
                .init(
                    id: "interval",
                    kind: .interval,
                    configuration: ["seconds": .int(1)]
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: "interval"
        )

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        await runtime.reloadSchedules()
        await runtime.dispatchAppWillTerminate()
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(executor.invocationCount, 0)
    }

    func testScheduledProviderRequestReachesHostActionWithNonUserOrigin()
        async throws
    {
        // `testProviderRequestRejectsScheduledInvocationOrigin` exercises the
        // production AppModel handler. This test separately proves that the
        // real schedule pipeline preserves the non-user origin up to the host
        // action registry instead of upgrading it to an interactive request.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginScheduledProvider-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.actions],
            platform: .init(
                hostActions: ["provider.request"],
                schedules: [
                    .init(
                        id: "connection-test",
                        kind: .interval,
                        configuration: ["seconds": .int(1)]
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: "connection-test"
        )
        executor.nextPlatformResult = .init(actions: [
            .init(
                actionID: "provider.request",
                input: ["operation": .string("connection_test")]
            ),
        ])

        let probe = ScheduledProviderRequestProbe()
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        runtime.actionRegistry.register("provider.request") { context, _ in
            guard context.origin.userInitiated else {
                await probe.recordScheduledRejection()
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "provider.request.requires_user_initiated"
                )
            }
            await probe.recordUnexpectedUserInitiatedInvocation()
            return .null
        }

        await runtime.reloadSchedules()
        for _ in 0 ..< 200 {
            if await probe.rejectionReason()
                == "provider.request.requires_user_initiated" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await runtime.dispatchAppWillTerminate()

        let rejectionReason = await probe.rejectionReason()
        let unexpectedUserInitiatedInvocationCount =
            await probe.unexpectedUserInitiatedInvocationCount()

        XCTAssertEqual(
            rejectionReason,
            "provider.request.requires_user_initiated"
        )
        XCTAssertEqual(unexpectedUserInitiatedInvocationCount, 0)
    }

    @MainActor
    func testUserInitiatedWillHookActionsStayBackgroundWhileUIActionsStayExplicitUser()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginHookActionOrigin-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks, .actions],
            platform: .init(
                hooks: [
                    .init(
                        id: "translation-will-run",
                        event: .translationWillRunSession
                    ),
                ],
                hostActions: ["system.shortcut.execute"],
                actions: [
                    .init(id: "run", displayName: "Run"),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let probe = HookActionOriginProbe()
        runtime.actionRegistry.register("system.shortcut.execute") { context, _ in
            await probe.recordOrigin(context.origin)
            guard context.origin.userInitiated else {
                throw BlocksPluginRuntimeError.invalidHostOperation(
                    "system.shortcut.execute.requires_user_initiated"
                )
            }
            await probe.recordSensitiveEffect()
            return .null
        }

        executor.nextPlatformResult = .init(hook: .init(actions: [
            .init(actionID: "system.shortcut.execute"),
        ]))
        let hookResult = await runtime.dispatch(.init(
            name: .translationWillRunSession,
            authorization: .init(userInitiated: true)
        ))

        XCTAssertTrue(hookResult.allowed)
        let hookOriginIsBackground = await probe.firstOriginIsBackground()
        let hookSensitiveEffectCount = await probe.sensitiveEffectCount()
        XCTAssertTrue(hookOriginIsBackground)
        XCTAssertEqual(hookSensitiveEffectCount, 0)

        executor.nextPlatformResult = .init(actions: [
            .init(actionID: "system.shortcut.execute"),
        ])
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run",
            kind: .uiAction
        )

        let actionOriginIsExplicitUser = await probe.secondOriginIsExplicitUser()
        let actionSensitiveEffectCount = await probe.sensitiveEffectCount()
        XCTAssertTrue(actionOriginIsExplicitUser)
        XCTAssertEqual(actionSensitiveEffectCount, 1)
    }

    @MainActor
    func testDestructiveDeleteConfirmationRejectsRecordUpdatedWhileAwaitingApproval()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginDeleteConfirmationCAS-\(UUID().uuidString)",
            isDirectory: true
        )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-delete-confirmation-cas-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 42,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "deletecas001",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )

        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "DeleteConfirmationCAS.blocksplugin",
            pluginID: "com.example.delete-confirmation-cas",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["clipboard.record.delete"],
                actions: [
                    .init(
                        id: "delete-record",
                        displayName: "Delete record",
                        entryFunction: "deleteRecord"
                    ),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)

        let store = ClipboardStore(repository: repository)
        let model = AppModel(
            clipboardStore: store,
            translationPluginManager: fixture.manager
        )
        let confirmationStarted = expectation(
            description: "destructive confirmation starts before content update"
        )
        let confirmationGate = DestructiveConfirmationSuspension()
        var confirmationCount = 0
        model.pluginRuntimeCoordinator
            .configureDestructiveActionConfirmationHandler { request in
                XCTAssertEqual(request.pluginID, installed.id)
                XCTAssertEqual(request.actionID, "clipboard.record.delete")
                XCTAssertEqual(request.targetID, record.id)
                XCTAssertEqual(request.expectedRevision, 1)
                confirmationCount += 1
                confirmationStarted.fulfill()
                return await confirmationGate.wait()
            }
        fixture.executor.nextPlatformResult = .init(actions: [
            .init(
                actionID: "clipboard.record.delete",
                input: ["record_id": .string(record.id)],
                expectedRevision: 1
            ),
        ])

        let deleteAction = Task { @MainActor in
            try await model.pluginRuntimeCoordinator.performPluginAction(
                pluginID: installed.id,
                actionID: "delete-record",
                origin: .explicitUser
            )
        }
        defer {
            deleteAction.cancel()
            Task { await confirmationGate.release(approved: false) }
        }

        await fulfillment(of: [confirmationStarted], timeout: 1)
        store.refreshSearchResult(query: "updated")
        let update = try await store.updateRecordFromPlugin(
            recordID: record.id,
            customTitle: nil,
            text: "updated while awaiting approval",
            expectedContentRevision: 1
        )
        XCTAssertEqual(update.newContentRevision, 2)

        await confirmationGate.release(approved: true)
        do {
            _ = try await deleteAction.value
            XCTFail("A delete confirmed with a stale revision must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardDetailSaveFailure,
                .revisionConflict
            )
        }

        XCTAssertEqual(confirmationCount, 1)
        let preserved = try XCTUnwrap(
            try repository.loadRecord(recordID: record.id)
        )
        XCTAssertEqual(
            try repository.loadDetailReadModel(recordID: record.id).contentRevision,
            2
        )
        XCTAssertEqual(preserved.id, record.id)
        XCTAssertEqual(
            try repository.readDetailEditablePayload(
                recordID: record.id,
                purpose: "detailEditRead"
            )?.text,
            "updated while awaiting approval"
        )
        XCTAssertEqual(
            try repository.search("updated", limit: 10).map(\.id),
            [record.id]
        )
        XCTAssertTrue(try repository.search("original", limit: 10).isEmpty)
        XCTAssertEqual(store.currentSearchResult.records.map(\.id), [record.id])
    }

    @MainActor
    func testTagDeleteConfirmationCASRejectsRenameThenEmitsCommittedRevision()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginTagDeleteConfirmationCAS-\(UUID().uuidString)",
            isDirectory: true
        )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-tag-delete-confirmation-cas-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 44,
            kind: .text,
            formatSummary: .init(
                itemCount: 1,
                types: ["public.utf8-plain-text"],
                textLength: 8
            ),
            sourceApp: nil,
            signatureSHA256_12: "tagdeletecas",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )
        let store = ClipboardStore(repository: repository)
        guard let tagID = await store.tagStore.createFilterTag(
            displayName: "Original tag"
        ) else {
            return XCTFail("Expected the persistent fixture tag to be created.")
        }
        let attached = await store.tagStore.addTag(recordID: record.id, tagID: tagID)
        XCTAssertTrue(attached)
        let tagRepository = ClipboardTagRepository(repository: repository)
        let revisionBeforeRename = try XCTUnwrap(
            try tagRepository.loadTags().first(where: { $0.id == tagID })
        ).contentRevision
        XCTAssertEqual(revisionBeforeRename, 2)
        let executor = ClipboardTagDeleteHostActionExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: root.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            directoryName: "TagDeleteConfirmationCAS.blocksplugin",
            pluginID: "com.example.tag-delete-confirmation-cas",
            capabilities: [.actions, .hooks],
            platform: .init(
                hooks: [.init(id: "tag-changed", event: .clipboardTagChanged)],
                hostActions: ["clipboard.tag.delete"],
                actions: [
                    .init(
                        id: "delete-tag",
                        displayName: "Delete tag",
                        entryFunction: "deleteTag"
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)

        let model = AppModel(
            clipboardStore: store,
            translationPluginManager: manager
        )
        let confirmationStarted = expectation(
            description: "tag deletion confirmation starts before rename"
        )
        let confirmationGate = DestructiveConfirmationSuspension()
        model.pluginRuntimeCoordinator
            .configureDestructiveActionConfirmationHandler { request in
                XCTAssertEqual(request.pluginID, installed.id)
                XCTAssertEqual(request.actionID, "clipboard.tag.delete")
                XCTAssertEqual(request.targetID, tagID)
                XCTAssertEqual(request.expectedRevision, revisionBeforeRename)
                confirmationStarted.fulfill()
                return await confirmationGate.wait()
            }
        executor.nextAction = .init(
            actionID: "clipboard.tag.delete",
            input: ["tag_id": .string(tagID)],
            expectedRevision: revisionBeforeRename
        )

        let deleteAction = Task { @MainActor in
            try await model.pluginRuntimeCoordinator.performPluginAction(
                pluginID: installed.id,
                actionID: "delete-tag",
                origin: .explicitUser
            )
        }
        defer {
            deleteAction.cancel()
            Task { await confirmationGate.release(approved: false) }
        }

        await fulfillment(of: [confirmationStarted], timeout: 1)
        let renamedWhileAwaitingApproval = await store.tagStore.renameFilterTag(
            tagID: tagID,
            displayName: "Renamed while awaiting approval"
        )
        XCTAssertTrue(renamedWhileAwaitingApproval)
        let renamed = try XCTUnwrap(
            try tagRepository.loadTags().first(where: { $0.id == tagID })
        )
        XCTAssertEqual(renamed.contentRevision, revisionBeforeRename + 1)

        await confirmationGate.release(approved: true)
        do {
            _ = try await deleteAction.value
            XCTFail("A tag deletion confirmed with a stale revision must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? ClipboardTagMutationError,
                .revisionConflict
            )
        }
        XCTAssertEqual(executor.invocationCount, 1)
        XCTAssertEqual(
            try tagRepository.loadTags().first(where: { $0.id == tagID })?.displayName,
            "Renamed while awaiting approval"
        )
        XCTAssertEqual(
            try tagRepository.loadRecordTags(recordIDs: [record.id])[record.id]?.map(\.id),
            [tagID]
        )

        model.pluginRuntimeCoordinator
            .configureDestructiveActionConfirmationHandler { _ in true }
        executor.nextAction = .init(
            actionID: "clipboard.tag.delete",
            input: ["tag_id": .string(tagID)],
            expectedRevision: renamed.contentRevision
        )
        do {
            _ = try await model.pluginRuntimeCoordinator.performPluginAction(
                pluginID: installed.id,
                actionID: "delete-tag",
                origin: .explicitUser
            )
        } catch {
            return XCTFail("A tag deletion with the committed revision failed: \(error)")
        }

        XCTAssertEqual(executor.invocationCount, 3)
        let deletedEventPayload = try XCTUnwrap(
            executor.observedClipboardTagChangedPayload
        )
        XCTAssertEqual(deletedEventPayload["operation"], .string("deleted"))
        XCTAssertEqual(deletedEventPayload["tag_id"], .string(tagID))
        XCTAssertEqual(
            deletedEventPayload["content_revision"],
            .int(Int(renamed.contentRevision))
        )
        XCTAssertFalse(try tagRepository.loadTags().contains(where: { $0.id == tagID }))
        XCTAssertTrue(
            try tagRepository.loadRecordTags(recordIDs: [record.id])[record.id]
                .map(\.isEmpty) ?? true
        )
    }

    @MainActor
    func testEnsureAndAttachConcurrentlyConvergesOnOneTagAndDoesNotInflateRevision()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginEnsureAtomic-\(UUID().uuidString)", isDirectory: true
        )
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let firstRecord = ClipboardRecorderRecord(
            id: "ensure-atomic-first", createdAt: Date(), changeCount: 1,
            kind: .text,
            formatSummary: .init(itemCount: 1, types: ["public.utf8-plain-text"], textLength: 5),
            sourceApp: nil, signatureSHA256_12: "ensurefirst01", fixtureOwned: true,
            restorable: true, summary: "first"
        )
        let secondRecord = ClipboardRecorderRecord(
            id: "ensure-atomic-second", createdAt: Date(), changeCount: 2,
            kind: .text,
            formatSummary: .init(itemCount: 1, types: ["public.utf8-plain-text"], textLength: 6),
            sourceApp: nil, signatureSHA256_12: "ensuresecond1", fixtureOwned: true,
            restorable: true, summary: "second"
        )
        _ = try repository.insert(record: firstRecord, payload: .init(recordID: firstRecord.id, kind: .text, text: "first"))
        _ = try repository.insert(record: secondRecord, payload: .init(recordID: secondRecord.id, kind: .text, text: "second"))

        // Separate stores model independently queued background hook actions.
        let firstStore = ClipboardStore(repository: repository)
        let secondStore = ClipboardStore(repository: repository)
        async let firstEnsure = firstStore.ensureTagAndAttachFromPlugin(
            recordID: firstRecord.id, displayName: "Concurrent ensure", requiresPersistence: true
        )
        async let secondEnsure = secondStore.ensureTagAndAttachFromPlugin(
            recordID: secondRecord.id, displayName: " concurrent  ensure ", requiresPersistence: true
        )
        let firstResult = try await firstEnsure
        let secondResult = try await secondEnsure

        XCTAssertEqual(firstResult.tagID, secondResult.tagID)
        XCTAssertEqual([firstResult.created, secondResult.created].filter { $0 }.count, 1)
        let tagRepository = ClipboardTagRepository(repository: repository)
        let tags = try tagRepository.loadTags().filter { $0.normalizedName == "concurrent ensure" }
        XCTAssertEqual(tags.count, 1)
        let tag = try XCTUnwrap(tags.first)
        let memberships = try tagRepository.loadRecordTags(recordIDs: [firstRecord.id, secondRecord.id])
        XCTAssertTrue(memberships[firstRecord.id, default: []].contains { $0.id == tag.id })
        XCTAssertTrue(memberships[secondRecord.id, default: []].contains { $0.id == tag.id })
        XCTAssertEqual(
            max(firstResult.contentRevision, secondResult.contentRevision),
            tag.contentRevision
        )
        XCTAssertEqual(
            Set([firstResult.contentRevision, secondResult.contentRevision]),
            Set([Int64(2), Int64(3)])
        )

        let beforeIdempotentEnsure = tag.contentRevision
        let idempotentResult = try await firstStore.ensureTagAndAttachFromPlugin(
            recordID: firstRecord.id, displayName: "Concurrent ensure", requiresPersistence: true
        )
        let afterIdempotentEnsure = try XCTUnwrap(
            try tagRepository.loadTags().first { $0.id == tag.id }
        )
        XCTAssertFalse(idempotentResult.created)
        XCTAssertFalse(idempotentResult.attached)
        XCTAssertEqual(idempotentResult.contentRevision, beforeIdempotentEnsure)
        XCTAssertEqual(afterIdempotentEnsure.contentRevision, beforeIdempotentEnsure)
    }

    @MainActor
    func testTagMembershipAndRenamePluginCASRejectStaleAndEmitsActualRevision()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginTagMutationCAS-\(UUID().uuidString)", isDirectory: true
        )
        let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
        defer {
            database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let repository = ClipboardRepository(database: database)
        let record = ClipboardRecorderRecord(
            id: "plugin-tag-mutation-cas-record",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            changeCount: 45,
            kind: .text,
            formatSummary: .init(itemCount: 1, types: ["public.utf8-plain-text"], textLength: 8),
            sourceApp: nil,
            signatureSHA256_12: "tagmutcas001",
            fixtureOwned: true,
            restorable: true,
            summary: "original"
        )
        _ = try repository.insert(
            record: record,
            payload: .init(recordID: record.id, kind: .text, text: "original")
        )
        let store = ClipboardStore(repository: repository)
        guard let tagID = await store.tagStore.createFilterTag(displayName: "CAS tag") else {
            return XCTFail("Expected a persistent fixture tag.")
        }
        let tagRepository = ClipboardTagRepository(repository: repository)
        let executor = ClipboardTagDeleteHostActionExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: root.appendingPathComponent("TranslationPlugins", isDirectory: true),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            directoryName: "TagMutationCAS.blocksplugin",
            pluginID: "com.example.tag-mutation-cas",
            capabilities: [.actions, .hooks],
            platform: .init(
                hooks: [.init(id: "tag-changed", event: .clipboardTagChanged)],
                hostActions: [
                    "clipboard.tag.attach",
                    "clipboard.tag.detach",
                    "clipboard.tag.rename",
                    "clipboard.tag.ensure_and_attach",
                ],
                actions: [.init(id: "mutate-tag", displayName: "Mutate tag", entryFunction: "mutateTag")]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let model = AppModel(clipboardStore: store, translationPluginManager: manager)

        func tag() throws -> ClipboardTag {
            try XCTUnwrap(try tagRepository.loadTags().first(where: { $0.id == tagID }))
        }
        func invoke(
            _ actionID: String,
            _ input: [String: JSONValue],
            _ revision: Int64?
        ) async throws {
            executor.nextAction = .init(actionID: actionID, input: input, expectedRevision: revision)
            _ = try await model.pluginRuntimeCoordinator.performPluginAction(
                pluginID: installed.id, actionID: "mutate-tag", origin: .explicitUser
            )
        }
        func assertStale(
            _ actionID: String,
            _ input: [String: JSONValue],
            _ revision: Int64
        ) async {
            let eventCount = executor.observedClipboardTagChangedPayloads.count
            do {
                try await invoke(actionID, input, revision)
                XCTFail("A stale \(actionID) must fail closed.")
            } catch {
                XCTAssertEqual(error as? ClipboardTagMutationError, .revisionConflict)
            }
            XCTAssertEqual(executor.observedClipboardTagChangedPayloads.count, eventCount)
        }

        // The bundled Smart Tagger intentionally uses ensure-and-attach
        // without a revision. Preserve both its create and existing-tag
        // idempotent paths; an explicitly supplied stale revision still owns
        // CAS semantics and must fail closed.
        try await invoke(
            "clipboard.tag.ensure_and_attach",
            [
                "record_id": .string(record.id),
                "name": .string("Plugin ensured tag"),
            ],
            nil
        )
        let ensured = try XCTUnwrap(
            try tagRepository.loadTags().first {
                $0.normalizedName == "plugin ensured tag"
            }
        )
        XCTAssertTrue(
            try tagRepository.loadRecordTags(recordIDs: [record.id])[
                record.id,
                default: []
            ].contains { $0.id == ensured.id }
        )
        XCTAssertEqual(
            executor.observedClipboardTagChangedPayloads.last?["operation"],
            .string("created_and_attached")
        )
        XCTAssertEqual(
            executor.observedClipboardTagChangedPayloads.last?["content_revision"],
            .int(Int(ensured.contentRevision))
        )
        try await invoke(
            "clipboard.tag.ensure_and_attach",
            [
                "record_id": .string(record.id),
                "name": .string("Plugin ensured tag"),
            ],
            nil
        )
        XCTAssertEqual(
            try tagRepository.loadTags().filter {
                $0.normalizedName == "plugin ensured tag"
            }.count,
            1
        )
        let ensuredCurrent = try XCTUnwrap(
            try tagRepository.loadTags().first { $0.id == ensured.id }
        )
        XCTAssertEqual(ensuredCurrent.contentRevision, ensured.contentRevision)
        await assertStale(
            "clipboard.tag.ensure_and_attach",
            [
                "record_id": .string(record.id),
                "name": .string("Plugin ensured tag"),
            ],
            ensuredCurrent.contentRevision - 1
        )
        try await invoke(
            "clipboard.tag.ensure_and_attach",
            [
                "record_id": .string(record.id),
                "name": .string("Plugin ensured tag"),
            ],
            ensuredCurrent.contentRevision
        )

        // attach: user rename advances R, stale action preserves detached state.
        let attachR = try tag().contentRevision
        await assertStale(
            "clipboard.tag.attach",
            ["record_id": .string(record.id), "tag_id": .string(tagID)],
            .max
        )
        let firstUserRename = await store.tagStore.renameFilterTag(
            tagID: tagID,
            displayName: "CAS tag user 1"
        )
        XCTAssertTrue(firstUserRename)
        await assertStale("clipboard.tag.attach", ["record_id": .string(record.id), "tag_id": .string(tagID)], attachR)
        XCTAssertFalse(try tagRepository.loadRecordTags(recordIDs: [record.id])[record.id, default: []].contains { $0.id == tagID })
        let attachCurrent = try tag().contentRevision
        try await invoke("clipboard.tag.attach", ["record_id": .string(record.id), "tag_id": .string(tagID)], attachCurrent)
        XCTAssertEqual(executor.observedClipboardTagChangedPayloads.last?["content_revision"], .int(Int(attachCurrent + 1)))

        // detach: user rename advances R, stale action preserves attached state.
        let detachR = try tag().contentRevision
        let secondUserRename = await store.tagStore.renameFilterTag(
            tagID: tagID,
            displayName: "CAS tag user 2"
        )
        XCTAssertTrue(secondUserRename)
        await assertStale("clipboard.tag.detach", ["record_id": .string(record.id), "tag_id": .string(tagID)], detachR)
        XCTAssertTrue(try tagRepository.loadRecordTags(recordIDs: [record.id])[record.id, default: []].contains { $0.id == tagID })
        let detachCurrent = try tag().contentRevision
        try await invoke("clipboard.tag.detach", ["record_id": .string(record.id), "tag_id": .string(tagID)], detachCurrent)
        XCTAssertEqual(executor.observedClipboardTagChangedPayloads.last?["content_revision"], .int(Int(detachCurrent + 1)))

        // rename: an intervening user membership write advances R and wins.
        let renameR = try tag().contentRevision
        let userAttach = await store.tagStore.addTag(
            recordID: record.id,
            tagID: tagID
        )
        XCTAssertTrue(userAttach)
        await assertStale("clipboard.tag.rename", ["tag_id": .string(tagID), "name": .string("plugin stale")], renameR)
        XCTAssertEqual(try tag().displayName, "CAS tag user 2")
        let renameCurrent = try tag().contentRevision
        try await invoke("clipboard.tag.rename", ["tag_id": .string(tagID), "name": .string("plugin current")], renameCurrent)
        XCTAssertEqual(executor.observedClipboardTagChangedPayloads.last?["content_revision"], .int(Int(renameCurrent + 1)))

        // Matching revisions make target-state operations idempotent; stale
        // revisions remain conflicts even after the target state is reached.
        let attachedR = try tag().contentRevision
        try await invoke("clipboard.tag.attach", ["record_id": .string(record.id), "tag_id": .string(tagID)], attachedR)
        XCTAssertEqual(try tag().contentRevision, attachedR)
        await assertStale("clipboard.tag.attach", ["record_id": .string(record.id), "tag_id": .string(tagID)], attachedR - 1)
        try await invoke("clipboard.tag.rename", ["tag_id": .string(tagID), "name": .string("plugin current")], attachedR)
        XCTAssertEqual(try tag().contentRevision, attachedR)
        await assertStale("clipboard.tag.rename", ["tag_id": .string(tagID), "name": .string("plugin current")], attachedR - 1)
        try await invoke("clipboard.tag.detach", ["record_id": .string(record.id), "tag_id": .string(tagID)], attachedR)
        let detachedR = try tag().contentRevision
        try await invoke("clipboard.tag.detach", ["record_id": .string(record.id), "tag_id": .string(tagID)], detachedR)
        XCTAssertEqual(try tag().contentRevision, detachedR)
        await assertStale("clipboard.tag.detach", ["record_id": .string(record.id), "tag_id": .string(tagID)], attachedR)
    }

    func testTagDeleteWithoutPositiveRevisionDoesNotPresentConfirmation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "TagDeleteRevision.blocksplugin",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["clipboard.tag.delete"],
                actions: [
                    .init(id: "run", displayName: "Run", entryFunction: "run"),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(pendingID: pending.id)
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)

        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        var confirmationCount = 0
        runtime.configureDestructiveActionConfirmationHandler { _ in
            confirmationCount += 1
            return true
        }
        runtime.actionRegistry.register("clipboard.tag.delete") { _, _ in .bool(true) }

        for expectedRevision in [Int64?.none, .some(0)] {
            fixture.executor.nextPlatformResult = .init(actions: [
                .init(
                    actionID: "clipboard.tag.delete",
                    input: ["tag_id": .string("tag.fixture")],
                    expectedRevision: expectedRevision
                ),
            ])
            do {
                _ = try await runtime.performPluginAction(
                    pluginID: installed.id,
                    actionID: "run",
                    kind: .uiAction,
                    causationID: UUID()
                )
                XCTFail("A tag delete without a positive revision must fail closed.")
            } catch {
                XCTAssertEqual(error as? ClipboardTagMutationError, .revisionConflict)
            }
        }
        XCTAssertEqual(confirmationCount, 0)
    }

    func testUIActionDestructiveHostActionRequiresFreshHostConfirmation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "DestructiveUIAction.blocksplugin",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["clipboard.record.delete"],
                actions: [
                    .init(id: "run", displayName: "Run", entryFunction: "run"),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)

        let recordID = "record-confirmation-fixture"
        let expectedRevision: Int64 = 9
        fixture.executor.nextPlatformResult = .init(actions: [
            .init(
                actionID: "clipboard.record.delete",
                input: ["record_id": .string(recordID)],
                idempotencyKey: "destructive-ui-fixture",
                expectedRevision: expectedRevision
            ),
        ])
        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        var confirmedInvocationCount = 0
        runtime.actionRegistry.register("clipboard.record.delete") { context, input in
            XCTAssertEqual(context.origin, .explicitUser)
            XCTAssertEqual(context.expectedRevision, expectedRevision)
            XCTAssertEqual(input.string("record_id"), recordID)
            confirmedInvocationCount += 1
            return .bool(true)
        }

        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run",
                kind: .uiAction,
                causationID: UUID()
            )
            XCTFail("A destructive UI action without a host presenter must fail closed.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(confirmedInvocationCount, 0)

        var decisions = [false, true, true]
        var requests: [BlocksPluginDestructiveActionConfirmationRequest] = []
        runtime.configureDestructiveActionConfirmationHandler { request in
            requests.append(request)
            return decisions.isEmpty ? false : decisions.removeFirst()
        }
        let declinedCausationID = UUID()
        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run",
                kind: .uiAction,
                causationID: declinedCausationID
            )
            XCTFail("Declining host confirmation must not run the delete action.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(confirmedInvocationCount, 0)

        let firstApprovedCausationID = UUID()
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run",
            kind: .uiAction,
            causationID: firstApprovedCausationID
        )
        let secondApprovedCausationID = UUID()
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run",
            kind: .uiAction,
            causationID: secondApprovedCausationID
        )

        XCTAssertEqual(confirmedInvocationCount, 2)
        XCTAssertEqual(requests.count, 3)
        for (request, causationID) in zip(
            requests,
            [declinedCausationID, firstApprovedCausationID, secondApprovedCausationID]
        ) {
            XCTAssertEqual(request.pluginID, installed.id)
            XCTAssertEqual(request.actionID, "clipboard.record.delete")
            XCTAssertEqual(request.targetID, recordID)
            XCTAssertEqual(request.causationID, causationID)
            XCTAssertEqual(request.expectedRevision, expectedRevision)
        }

        let lifecycleConfirmationStarted = expectation(
            description: "destructive confirmation starts before lifecycle replacement"
        )
        let lifecycleConfirmationGate = DestructiveConfirmationSuspension()
        runtime.configureDestructiveActionConfirmationHandler { _ in
            lifecycleConfirmationStarted.fulfill()
            return await lifecycleConfirmationGate.wait()
        }
        let lifecycleInvalidatedAction = Task { @MainActor in
            try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run",
                kind: .uiAction,
                causationID: UUID()
            )
        }
        defer {
            lifecycleInvalidatedAction.cancel()
            Task {
                await lifecycleConfirmationGate.release(approved: false)
            }
        }
        await fulfillment(of: [lifecycleConfirmationStarted], timeout: 1)
        _ = try await fixture.manager.setEnabled(
            false,
            pluginID: installed.id
        )
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )
        await lifecycleConfirmationGate.release(approved: true)
        let lifecycleInvalidatedResult = try await lifecycleInvalidatedAction.value
        XCTAssertEqual(lifecycleInvalidatedResult, .init())
        XCTAssertEqual(
            confirmedInvocationCount,
            2,
            "A confirmation from an invalidated execution must not delete after re-enable."
        )

        let safeModeConfirmationStarted = expectation(
            description: "destructive confirmation starts before safe mode"
        )
        let safeModeConfirmationGate = DestructiveConfirmationSuspension()
        runtime.configureDestructiveActionConfirmationHandler { _ in
            safeModeConfirmationStarted.fulfill()
            return await safeModeConfirmationGate.wait()
        }
        let safeModeInvalidatedAction = Task { @MainActor in
            try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run",
                kind: .uiAction,
                causationID: UUID()
            )
        }
        defer {
            safeModeInvalidatedAction.cancel()
            Task { await safeModeConfirmationGate.release(approved: false) }
        }
        await fulfillment(of: [safeModeConfirmationStarted], timeout: 1)
        await runtime.setSafeModeEnabled(true)
        await runtime.setSafeModeEnabled(false)
        await safeModeConfirmationGate.release(approved: true)
        do {
            _ = try await safeModeInvalidatedAction.value
            XCTFail("A lifecycle-invalidated confirmation must fail closed.")
        } catch {
            guard case let .invalidHostOperation(reason) =
                    error as? BlocksPluginRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "plugins_disabled_by_safe_mode")
        }
        XCTAssertEqual(confirmedInvocationCount, 2)

        let confirmationStarted = expectation(
            description: "destructive confirmation starts before permission revocation"
        )
        let confirmationGate = DestructiveConfirmationSuspension()
        runtime.configureDestructiveActionConfirmationHandler { _ in
            confirmationStarted.fulfill()
            return await confirmationGate.wait()
        }
        let revokedAction = Task { @MainActor in
            try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run",
                kind: .uiAction,
                causationID: UUID()
            )
        }
        defer {
            revokedAction.cancel()
            Task { await confirmationGate.release(approved: false) }
        }
        await fulfillment(of: [confirmationStarted], timeout: 1)
        fixture.metadataStore.replacePermissions(
            ["action:run"],
            for: installed.id
        )
        await confirmationGate.release(approved: true)
        do {
            _ = try await revokedAction.value
            XCTFail("Permission revocation during confirmation must block deletion.")
        } catch {
            guard case let .invalidHostOperation(reason) =
                    error as? BlocksPluginRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "unapproved:clipboard.record.delete")
        }
        XCTAssertEqual(confirmedInvocationCount, 2)
    }

    func testSafeModeInvalidationFailsOpenForCancelledFailClosedWillHook()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginSafeModeFailOpen-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)

        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = CancelledFailClosedHookExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks, .actions, .ui],
            dataPermissions: [.clipboardContent],
            platform: .init(
                hooks: [
                    .init(
                        id: "fail-closed",
                        event: .clipboardWillWritePasteboard,
                        failurePolicy: .failClosed
                    ),
                ],
                hostActions: ["system.notification"],
                ui: [
                    .init(
                        id: "settings-status",
                        slot: .settingsStatusCard,
                        root: .init(id: "status", kind: .status)
                    ),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        var hostActionCount = 0
        runtime.actionRegistry.register("system.notification") { _, _ in
            hostActionCount += 1
            return .null
        }
        let event = BlocksPluginEventEnvelope(
            name: .clipboardWillWritePasteboard,
            payload: ["text": .string("before")]
        )
        let dispatch = Task { @MainActor in
            await runtime.dispatch(event)
        }
        await executor.waitUntilStarted()

        await runtime.setSafeModeEnabled(true)
        let result = await dispatch.value

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.envelope.payload["text"], .string("before"))
        XCTAssertEqual(hostActionCount, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
    }

    @MainActor
    func testPluginShortcutsSkipDefaultActionsWhileSafeModeIsEnabled()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginShortcutSafeMode-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "shortcut-will",
                    event: .automationWillExecuteShortcut,
                    failurePolicy: .failClosed
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await manager.setEnabled(true, pluginID: installed.id)

        let model = AppModel(translationPluginManager: manager)
        await model.pluginRuntimeCoordinator.setSafeModeEnabled(true)

        var commandActionCount = 0
        let commandDidExecute = await model.executeShortcutWithPluginHooks(
            command: .screenshotSmart
        ) {
            commandActionCount += 1
        }
        var namedActionCount = 0
        let namedDidExecute = await model.executeShortcutWithPluginHooks(
            commandName: "clipboardQuickPaste1",
            payload: ["index": .int(1)]
        ) {
            namedActionCount += 1
        }

        XCTAssertFalse(commandDidExecute)
        XCTAssertFalse(namedDidExecute)
        XCTAssertEqual(commandActionCount, 0)
        XCTAssertEqual(namedActionCount, 0)
        XCTAssertEqual(executor.invocationCount, 0)

        await model.pluginRuntimeCoordinator.setSafeModeEnabled(false)
    }

    func testAppModelPluginStorageFailureStaysUnavailableWithoutTemporaryFallback() async {
        let manager = AppModel.makeTranslationPluginManager {
            throw PluginManagerInjectedError.install
        }

        XCTAssertFalse(manager.storageIsAvailable)
        XCTAssertTrue(manager.plugins.isEmpty)
        XCTAssertNotNil(manager.lastErrorMessage)

        do {
            _ = try await manager.setEnabled(
                true,
                pluginID: "com.example.fixture"
            )
            XCTFail("Unavailable storage must reject plugin mutations.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .storageUnavailable
            )
        }
        XCTAssertEqual(manager.operation, .idle)
    }

    func testOCRRuntimeSelectionRejectsDisabledUnapprovedAndNonOCRPlugins() {
        let approvedOCR = pluginMetadata(
            isEnabled: true,
            approvalStatus: .approved,
            capabilities: [.ocr]
        )

        XCTAssertEqual(
            TranslationPluginRuntimeSelection.enabledOCRPluginID(
                preferredServiceID: "plugin:\(approvedOCR.id)",
                plugins: [approvedOCR]
            ),
            approvedOCR.id
        )
        XCTAssertNil(
            TranslationPluginRuntimeSelection.enabledOCRPluginID(
                preferredServiceID: "plugin:\(approvedOCR.id)",
                plugins: [
                    pluginMetadata(
                        isEnabled: false,
                        approvalStatus: .approved,
                        capabilities: [.ocr]
                    ),
                ]
            )
        )
        XCTAssertNil(
            TranslationPluginRuntimeSelection.enabledOCRPluginID(
                preferredServiceID: "plugin:\(approvedOCR.id)",
                plugins: [
                    pluginMetadata(
                        isEnabled: true,
                        approvalStatus: .pending,
                        capabilities: [.ocr]
                    ),
                ]
            )
        )
        XCTAssertNil(
            TranslationPluginRuntimeSelection.enabledOCRPluginID(
                preferredServiceID: "plugin:\(approvedOCR.id)",
                plugins: [
                    pluginMetadata(
                        isEnabled: true,
                        approvalStatus: .approved,
                        capabilities: [.translation]
                    ),
                ]
            )
        )
    }

    func testAppModelPreservesUnavailableOCRPluginPreferenceAndPublishesFailure() async {
        let key = "translation.ocr.defaultServiceID"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set("plugin:com.example.missing-ocr", forKey: key)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginRuntimeIntent-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BlocksNativePluginManager(
            repository: RecordingPluginMetadataStore(),
            managedRoot: root,
            executor: RecordingPluginExecutor()
        )
        let model = AppModel(
            translationPluginManager: manager
        )

        model.refreshTranslationPluginRuntime()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            defaults.string(forKey: key),
            "plugin:com.example.missing-ocr"
        )
        XCTAssertEqual(
            manager.runtimeLoadFailures.first?.pluginID,
            "com.example.missing-ocr"
        )
        XCTAssertEqual(
            manager.runtimeLoadFailures.first?.capability,
            .ocr
        )
        _ = model
    }

    func testAppModelNormalizesInvalidOCRServiceToAppleVision() async {
        let key = "translation.ocr.defaultServiceID"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set("legacy-invalid-ocr", forKey: key)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginInvalidOCR-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BlocksNativePluginManager(
            repository: RecordingPluginMetadataStore(),
            managedRoot: root,
            executor: RecordingPluginExecutor()
        )
        let model = AppModel(translationPluginManager: manager)

        model.refreshTranslationPluginRuntime()
        await waitForMainActorCondition {
            defaults.string(forKey: key)
                == TranslationPluginRuntimeSelection.appleVisionOCRServiceID
        }

        XCTAssertFalse(
            manager.runtimeLoadFailures.contains {
                $0.pluginID == "legacy-invalid-ocr"
            }
        )
        _ = model
    }

    func testAppModelKeepsInstalledDisabledTranslationServiceUntilExplicitUninstall() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let pending = try await fixture.manager.prepareInstallation(from: source)
        _ = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(
            false,
            pluginID: "com.example.fixture"
        )

        let suiteName = "BlocksNativePluginRuntime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["plugin:com.example.fixture"],
            forKey: "translation.services.enabledIDs"
        )
        let translationStore = TranslationStore(defaults: defaults)
        let model = AppModel(
            translationStore: translationStore,
            translationPluginManager: fixture.manager
        )

        model.refreshTranslationPluginRuntime()
        await waitForMainActorCondition {
            translationStore.availableServices.contains {
                $0.id == "plugin:com.example.fixture"
                    && $0.availability == .disabled
            }
        }
        XCTAssertEqual(
            translationStore.enabledServiceIDs,
            ["plugin:com.example.fixture"]
        )

        try await fixture.manager.uninstall(
            pluginID: "com.example.fixture"
        )
        model.refreshTranslationPluginRuntime()
        await waitForMainActorCondition {
            !translationStore.availableServices.contains {
                $0.id == "plugin:com.example.fixture"
            }
        }
        XCTAssertFalse(
            translationStore.enabledServiceIDs.contains(
                "plugin:com.example.fixture"
            )
        )
        _ = model
    }

    func testInstallRejectsIntermediateManagedDirectorySymbolicLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginSymlink-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = try makePackage(at: root)
        let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        let outsideRoot = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: managedRoot.appendingPathComponent(
                "com.example.fixture",
                isDirectory: true
            ),
            withDestinationURL: outsideRoot
        )
        let metadataStore = RecordingPluginMetadataStore()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor()
        )
        let pending = try await manager.prepareInstallation(from: source)

        do {
            _ = try await manager.confirmAndInstall(pendingID: pending.id)
            XCTFail("An intermediate managed-directory symlink must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .installedPathEscapesRoot
            )
        }

        XCTAssertTrue(metadataStore.records.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: outsideRoot,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertEqual(manager.operation, .awaitingConfirmation)
    }

    func testInstallDoesNotWriteThroughReplacedManagedRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginRootReplacement-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = try makePackage(at: root)
        let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        let displacedRoot = root.appendingPathComponent(
            "Managed-Displaced",
            isDirectory: true
        )
        let metadataStore = RecordingPluginMetadataStore()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor(),
            installSnapshotStagingHook: {
                try FileManager.default.moveItem(
                    at: managedRoot,
                    to: displacedRoot
                )
                try FileManager.default.createDirectory(
                    at: managedRoot,
                    withIntermediateDirectories: true
                )
            }
        )
        let pending = try await manager.prepareInstallation(from: source)

        do {
            _ = try await manager.confirmAndInstall(pendingID: pending.id)
            XCTFail("Replacing the managed root must invalidate installation.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .installedPathEscapesRoot
            )
        }

        XCTAssertTrue(metadataStore.records.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: managedRoot,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertTrue(pluginSnapshots(below: displacedRoot).isEmpty)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: displacedRoot,
                includingPropertiesForKeys: nil
            ).contains {
                $0.lastPathComponent.hasPrefix(".installing-")
            }
        )
        XCTAssertEqual(manager.operation, .awaitingConfirmation)
    }

    func testUnsignedInstallRequiresDescriptorThenPersistsApprovedDisabledPlugin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksPluginManager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackage(at: root)
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let manager = BlocksNativePluginManager(
            database: database,
            storageEnvironment: environment,
            executor: RecordingPluginExecutor()
        )

        let pending = try await manager.prepareInstallation(from: source)

        XCTAssertEqual(
            pending.sourceDisplayName,
            source.lastPathComponent
        )
        XCTAssertFalse(pending.confirmation.isSigned)
        XCTAssertEqual(
            pending.installationOrigin.rawValue,
            BlocksNativePluginInstallationOrigin.external.rawValue
        )
        XCTAssertNil(pending.builtInCatalogVersion)
        XCTAssertTrue(pending.confirmation.requiresRiskConfirmation)
        XCTAssertEqual(pending.confirmation.networkDomains, ["api.example.com"])
        XCTAssertEqual(pending.confirmation.networkMethods, [.post])
        XCTAssertEqual(manager.operation, .awaitingConfirmation)

        let installed = try await manager.confirmAndInstall(pendingID: pending.id)

        XCTAssertEqual(installed.approvalStatus, .approved)
        XCTAssertFalse(installed.isEnabled)
        XCTAssertNil(manager.pendingInstallation)
        XCTAssertEqual(manager.plugins.map(\.id), ["com.example.fixture"])
    }

    func testValidatedReservedOfficialIdentifierRejectsExternalInstallationBeforeMutation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            pluginID: "com.blocks.builtin.fixture"
        )
        let package = try BlocksNativePluginPackageValidator().validate(
            directory: source
        )

        do {
            _ = try await fixture.manager.prepareInstallation(
                validatedPackage: package,
                sourceDisplayName: source.lastPathComponent
            )
            XCTFail("External installation must not claim a reserved identifier.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .reservedOfficialIdentifier("com.blocks.builtin.fixture")
            )
        }

        XCTAssertNil(fixture.manager.pendingInstallation)
        XCTAssertEqual(fixture.manager.operation, .idle)
        XCTAssertTrue(fixture.metadataStore.records.isEmpty)
        XCTAssertTrue(fixture.manager.plugins.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.managedRoot.path)
        )
    }

    func testURLReservedOfficialIdentifierRejectsExternalInstallationBeforeMutation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            pluginID: "com.blocks.builtin.fixture"
        )

        do {
            _ = try await fixture.manager.prepareInstallation(from: source)
            XCTFail("The URL entry point must reject a reserved identifier.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .reservedOfficialIdentifier("com.blocks.builtin.fixture")
            )
        }

        XCTAssertNil(fixture.manager.pendingInstallation)
        XCTAssertEqual(fixture.manager.operation, .idle)
        XCTAssertTrue(fixture.metadataStore.records.isEmpty)
        XCTAssertTrue(fixture.manager.plugins.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.managedRoot.path)
        )
    }

    func testPrepareBuiltInInstallationAcceptsHashVerifiedCatalogPackage()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            pluginID: "com.blocks.builtin.fixture"
        )
        let catalog = try catalogFixture(for: source)
        let entry = try XCTUnwrap(catalog.document.entries.first)

        let pending = try await fixture.manager.prepareBuiltInInstallation(
            entryID: entry.id,
            catalog: catalog
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )

        XCTAssertEqual(pending.sourceDisplayName, "Fixture")
        XCTAssertEqual(installed.installationOrigin, .builtIn)
        XCTAssertEqual(installed.builtInCatalogVersion, "test")
    }

    func testPrepareBuiltInInstallationRejectsCatalogHashMismatchBeforeMutation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            pluginID: "com.blocks.builtin.fixture"
        )
        let catalog = try catalogFixture(for: source)
        let entry = try XCTUnwrap(catalog.document.entries.first)
        try Data(
            "function translate(input) { return input.text + '-tampered'; }".utf8
        ).write(to: source.appendingPathComponent("plugin.js"))

        do {
            _ = try await fixture.manager.prepareBuiltInInstallation(
                entryID: entry.id,
                catalog: catalog
            )
            XCTFail("A catalog hash mismatch must fail before installation.")
        } catch {
            guard case .hashMismatch = error as? BlocksBuiltInPluginCatalogError else {
                return XCTFail("Unexpected catalog error: \(error)")
            }
        }

        XCTAssertNil(fixture.manager.pendingInstallation)
        XCTAssertEqual(fixture.manager.operation, .idle)
        XCTAssertTrue(fixture.metadataStore.records.isEmpty)
        XCTAssertTrue(fixture.manager.plugins.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.managedRoot.path)
        )
    }

    func testPrepareBuiltInInstallationRejectsUnlistedCatalogEntryBeforeMutation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listedSource = try makePackage(
            at: fixture.root,
            directoryName: "Listed.blocksplugin",
            pluginID: "com.blocks.builtin.listed"
        )
        _ = try makePackage(
            at: fixture.root,
            directoryName: "Unlisted.blocksplugin",
            pluginID: "com.blocks.builtin.unlisted"
        )
        let catalog = try catalogFixture(for: listedSource)

        do {
            _ = try await fixture.manager.prepareBuiltInInstallation(
                entryID: "com.blocks.builtin.unlisted",
                catalog: catalog
            )
            XCTFail("A package absent from the catalog must not claim built-in origin.")
        } catch {
            guard case let .entryUnavailable(id) =
                    error as? BlocksBuiltInPluginCatalogError else {
                return XCTFail("Unexpected catalog error: \(error)")
            }
            XCTAssertEqual(id, "com.blocks.builtin.unlisted")
        }

        XCTAssertNil(fixture.manager.pendingInstallation)
        XCTAssertEqual(fixture.manager.operation, .idle)
        XCTAssertTrue(fixture.metadataStore.records.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.managedRoot.path)
        )
    }

    func testCompatibleBuiltInUpdateDoesNotCancelConcurrentUserPendingInstallation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builtInSource = try makePackage(
            at: fixture.root,
            directoryName: "BuiltIn.blocksplugin",
            pluginID: "com.blocks.builtin.fixture"
        )
        let initialCatalog = try catalogFixture(for: builtInSource)
        let initialEntry = try XCTUnwrap(initialCatalog.document.entries.first)
        let initialPending = try await fixture.manager.prepareBuiltInInstallation(
            entryID: initialEntry.id,
            catalog: initialCatalog
        )
        _ = try await fixture.manager.confirmAndInstall(
            pendingID: initialPending.id
        )

        try Data(
            "function translate(input) { return input.text + '-updated'; }".utf8
        ).write(to: builtInSource.appendingPathComponent("plugin.js"))
        let updatedCatalog = try catalogFixture(for: builtInSource)
        let userSource = try makePackage(
            at: fixture.root,
            directoryName: "User.blocksplugin",
            pluginID: "com.example.user"
        )
        let validationGate = SuspendedPluginHostActionProbe()
        let validationReached = expectation(
            description: "Automatic update validation reaches its ownership checkpoint."
        )
        let automaticUpdate = Task { @MainActor in
            await fixture.manager.applyCompatibleBuiltInUpdates(
                catalog: updatedCatalog,
                validationCheckpoint: {
                    validationReached.fulfill()
                    _ = await validationGate.perform()
                }
            )
        }
        defer { Task { await validationGate.release() } }
        await fulfillment(of: [validationReached], timeout: 2)

        let userPending = try await fixture.manager.prepareInstallation(
            from: userSource
        )
        await validationGate.release()
        await automaticUpdate.value

        XCTAssertEqual(fixture.manager.operation, .awaitingConfirmation)
        XCTAssertEqual(fixture.manager.pendingInstallation?.id, userPending.id)
        XCTAssertEqual(
            fixture.manager.pendingInstallation?.manifest.id,
            "com.example.user"
        )
        XCTAssertEqual(
            fixture.manager.plugins.first(where: {
                $0.id == "com.blocks.builtin.fixture"
            })?.packageHash,
            initialPending.confirmation.packageSHA256
        )
    }

    func testCompatibleBuiltInUpdateClearsOnlyItsOwnFailedPendingInstallation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builtInSource = try makePackage(
            at: fixture.root,
            directoryName: "BuiltInFailure.blocksplugin",
            pluginID: "com.blocks.builtin.fixture"
        )
        let initialCatalog = try catalogFixture(for: builtInSource)
        let entryID = try XCTUnwrap(initialCatalog.document.entries.first?.id)
        let initialPending = try await fixture.manager.prepareBuiltInInstallation(
            entryID: entryID,
            catalog: initialCatalog
        )
        let initial = try await fixture.manager.confirmAndInstall(
            pendingID: initialPending.id
        )

        try Data(
            "function translate(input) { return input.text + '-updated'; }".utf8
        ).write(to: builtInSource.appendingPathComponent("plugin.js"))
        let updatedCatalog = try catalogFixture(for: builtInSource)
        fixture.metadataStore.failNextInstall()

        await fixture.manager.applyCompatibleBuiltInUpdates(
            catalog: updatedCatalog
        )

        XCTAssertNil(fixture.manager.pendingInstallation)
        XCTAssertEqual(fixture.manager.operation, .idle)
        XCTAssertEqual(
            fixture.manager.plugins.first(where: { $0.id == initial.id })?
                .packageHash,
            initial.packageHash
        )
        XCTAssertEqual(
            fixture.metadataStore.records.first(where: {
                $0.id == initial.id
            })?.packageHash,
            initial.packageHash
        )
    }

    func testConnectionTestValidatesDisabledPluginBeforeEnableAndUninstall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksPluginManager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackage(at: root)
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            database: database,
            storageEnvironment: environment,
            executor: executor
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)

        do {
            _ = try await manager.setEnabled(
                true,
                pluginID: installed.id
            )
            XCTFail("A plugin must not be enabled before validation.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .validationRequired
            )
        }
        let connection = await manager.connectionTest(
            pluginID: installed.id,
            capability: .translation,
            testText: "Low sensitivity fixture input"
        )
        XCTAssertTrue(connection.succeeded)
        XCTAssertNil(
            connection.outputSummary,
            "Caller-provided test input must not be reflected in the result."
        )
        XCTAssertEqual(
            executor.lastInvocation?.input["text"],
            .string("Low sensitivity fixture input")
        )
        XCTAssertEqual(executor.invocationCount, 1)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        XCTAssertTrue(manager.plugins.first?.isEnabled == true)

        try await manager.uninstall(pluginID: installed.id)
        XCTAssertTrue(manager.plugins.isEmpty)
    }

    func testGenericHookActionPluginEnablesWithoutTranslationConnectionTest()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        defaults.removeObject(forKey: safeModeKey)
        let source = try makePackage(
            at: fixture.root,
            capabilities: [.hooks, .actions],
            platform: BlocksPluginPlatformConfiguration(
                hooks: [
                    BlocksPluginHookSubscription(
                        id: "launch",
                        event: .appLaunched,
                        entryFunction: "onLaunch"
                    )
                ],
                actions: [
                    BlocksPluginActionDeclaration(
                        id: "read-state",
                        displayName: "Read state",
                        entryFunction: "readState"
                    )
                ]
            ),
            entrySource:
                "function onLaunch() { return { disposition: 'allow' }; }\n"
                + "function readState() { return { output: {} }; }"
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )

        let enabled = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        XCTAssertTrue(enabled.isEnabled)
        XCTAssertTrue(
            fixture.manager.validatedPluginIDs.contains(installed.id)
        )
        XCTAssertEqual(fixture.executor.invocationCount, 0)
    }

    func testFailedRetestDisablesPluginAndInvalidatesPriorValidation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        let firstTest = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(firstTest.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        fixture.executor.failNextExecution()
        let failedTest = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )

        XCTAssertFalse(failedTest.succeeded)
        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(
            fixture.manager.validatedPluginIDs.contains(installed.id)
        )
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: installed.id
            )
            XCTFail("A failed retest must invalidate the previous proof.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .validationRequired
            )
        }
    }

    func testFailedManagementRetestRemovesDisabledPluginFromEnabledOrder()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        let firstTest = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(firstTest.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        let suite = "BlocksNativePluginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let store = TranslationStore(defaults: defaults)
        let adapter = try await fixture.manager.makeTranslationAdapter(
            pluginID: installed.id
        )
        store.replacePluginAdapters(
            [adapter],
            snapshotIsAuthoritative: true
        )
        store.setServiceEnabled(
            true,
            serviceID: adapter.descriptor.id
        )
        XCTAssertTrue(
            store.enabledServiceIDs.contains(adapter.descriptor.id)
        )
        let service = TranslationSourceManagementService(
            pluginManager: fixture.manager,
            translationStore: store
        )

        fixture.executor.failNextExecution()
        let failedTest = await service.testSource(
            sourceID: adapter.descriptor.id
        )

        XCTAssertFalse(failedTest.succeeded)
        XCTAssertFalse(
            fixture.manager.plugins.first?.isEnabled ?? true
        )
        XCTAssertFalse(
            store.enabledServiceIDs.contains(adapter.descriptor.id)
        )
    }

    func testInvalidConfigurationSavePreservesEnabledPluginAndStoreOrder()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            configurationFields: [
                .init(
                    id: "mode",
                    type: .text,
                    title: "Mode",
                    required: true,
                    defaultValue: .string("first")
                ),
            ]
        )
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        let firstTest = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(firstTest.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        let suite = "BlocksNativePluginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let store = TranslationStore(defaults: defaults)
        let adapter = try await fixture.manager.makeTranslationAdapter(
            pluginID: installed.id
        )
        store.replacePluginAdapters(
            [adapter],
            snapshotIsAuthoritative: true
        )
        store.setServiceEnabled(
            true,
            serviceID: adapter.descriptor.id
        )
        XCTAssertTrue(
            store.enabledServiceIDs.contains(adapter.descriptor.id)
        )
        let service = TranslationSourceManagementService(
            pluginManager: fixture.manager,
            translationStore: store
        )

        do {
            try await service.savePluginConfiguration(
                ["unknown": .string("invalid")],
                pluginID: installed.id
            )
            XCTFail("An unknown configuration field must be rejected.")
        } catch {
            guard let configurationError =
                error as? BlocksNativePluginConfigurationStoreError,
                case let .unknownField(fieldID) = configurationError else {
                return XCTFail("Unexpected configuration error: \(error)")
            }
            XCTAssertEqual(fieldID, "unknown")
        }

        XCTAssertTrue(
            fixture.manager.plugins.first?.isEnabled == true
        )
        XCTAssertTrue(
            store.enabledServiceIDs.contains(adapter.descriptor.id)
        )
    }

    func testTranslationSourceActionCancellationStopsAvailabilityWaitAndRollsBackEnable()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        let connection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)

        let suite = "BlocksNativePluginCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let store = TranslationStore(defaults: defaults)
        let service = TranslationSourceManagementService(
            pluginManager: fixture.manager,
            translationStore: store
        )
        let requestID = ActionRequestID.make()
        let sourceID = "plugin:\(installed.id)"
        let task = Task { @MainActor in
            try await service.execute(
                TranslationSourceManagementActionInput(
                    operation: .enable,
                    sourceID: sourceID
                ),
                requestID: requestID
            )
        }
        await waitForMainActorCondition {
            fixture.manager.plugins.first(where: {
                $0.id == installed.id
            })?.isEnabled == true
        }

        XCTAssertTrue(
            service.cancelActionRequest(requestID.rawValue)
        )
        do {
            _ = try await task.value
            XCTFail("The cancelled Action must not wait for the timeout.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(
            fixture.manager.plugins.first(where: {
                $0.id == installed.id
            })?.isEnabled ?? true
        )
        XCTAssertFalse(store.enabledServiceIDs.contains(sourceID))
        XCTAssertFalse(
            service.cancelActionRequest(requestID.rawValue),
            "Completed requests must release their requestID ownership."
        )
    }

    func testTranslationSourceListExcludesPluginsWithoutTranslationCapability()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            capabilities: [.actions],
            platform: .init()
        )
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        XCTAssertTrue(
            fixture.manager.plugins.contains(where: {
                $0.id == installed.id
            })
        )

        let suite = "BlocksTranslationSourceList.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let store = TranslationStore(defaults: defaults)
        let service = TranslationSourceManagementService(
            pluginManager: fixture.manager,
            translationStore: store
        )

        let result = try await service.execute(
            TranslationSourceManagementActionInput(operation: .list)
        )

        XCTAssertFalse(
            result.sources.contains(where: {
                $0.sourceID == "plugin:\(installed.id)"
            })
        )
        XCTAssertTrue(
            result.sources.contains(where: {
                $0.sourceID == "apple-local"
            }),
            "Filtering ordinary plugins must preserve actual translation sources."
        )
    }

    func testTranslationSourceActionCancellationCancelsCommunityNetworkTask()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = CancellableTranslationCommunityTransport()
        let suite =
            "BlocksCommunitySourceCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let disclosureStore = TranslationCommunityWebDisclosureStore(
            defaults: defaults
        )
        disclosureStore.acknowledge(source: .googleWeb)
        let store = TranslationStore(
            communityWebTransport: transport,
            defaults: defaults
        )
        let service = TranslationSourceManagementService(
            pluginManager: fixture.manager,
            translationStore: store,
            communityDisclosureStore: disclosureStore
        )
        let requestID = ActionRequestID.make()
        let task = Task { @MainActor in
            try await service.execute(
                TranslationSourceManagementActionInput(
                    operation: .test,
                    sourceID: "community:google-web",
                    testText: "Low sensitivity cancellation fixture",
                    capability: .translation
                ),
                requestID: requestID
            )
        }
        await waitForMainActorCondition {
            transport.didStart
        }

        XCTAssertTrue(
            service.cancelActionRequest(requestID.rawValue)
        )
        do {
            _ = try await task.value
            XCTFail("Cancellation must terminate the active network test.")
        } catch is CancellationError {
            // Expected.
        }
        await waitForMainActorCondition {
            transport.didObserveCancellation
        }
        XCTAssertFalse(
            service.cancelActionRequest(requestID.rawValue),
            "The completed request must release its owned Task."
        )
    }

    func testSecretPersistenceAndSnapshotFailureRemovesStaleEnabledOrder()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["api_key"]
        )
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        try await fixture.manager.saveSecret(
            "first-key",
            pluginID: installed.id,
            secretID: "api_key"
        )
        let firstTest = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(firstTest.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        let suite = "BlocksNativePluginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let store = TranslationStore(defaults: defaults)
        let adapter = try await fixture.manager.makeTranslationAdapter(
            pluginID: installed.id
        )
        store.replacePluginAdapters(
            [adapter],
            snapshotIsAuthoritative: true
        )
        store.setServiceEnabled(
            true,
            serviceID: adapter.descriptor.id
        )
        let service = TranslationSourceManagementService(
            pluginManager: fixture.manager,
            translationStore: store
        )

        fixture.secretStore.failNextSave()
        fixture.metadataStore.failNextList()
        do {
            try await service.savePluginSecret(
                "second-key",
                pluginID: installed.id,
                secretID: "api_key"
            )
            XCTFail("The injected Keychain failure must be reported.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .secretSave
            )
        }

        XCTAssertFalse(fixture.manager.snapshotIsReady)
        XCTAssertTrue(
            fixture.manager.plugins.first?.isEnabled == true,
            "The failed refresh intentionally leaves the stale UI snapshot in memory."
        )
        XCTAssertFalse(
            store.enabledServiceIDs.contains(adapter.descriptor.id),
            "A stale plugin snapshot must fail closed in the executable service order."
        )
    }

    func testConfigurationChangeDisablesPluginUntilCurrentRevisionIsRetested()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            configurationFields: [
                .init(
                    id: "mode",
                    type: .text,
                    title: "Mode",
                    required: true,
                    defaultValue: .string("first")
                ),
            ]
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        let initialConnection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(initialConnection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        try await fixture.manager.saveConfiguration(
            ["mode": .string("second")],
            pluginID: installed.id
        )

        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(
            fixture.manager.validatedPluginIDs.contains(installed.id)
        )
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: installed.id
            )
            XCTFail("Changed configuration must require another test.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .validationRequired
            )
        }
        let updatedConnection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(updatedConnection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )
        XCTAssertTrue(fixture.manager.plugins.first?.isEnabled == true)
    }

    func testSecretChangeAndDeletionDisableAndInvalidatePlugin()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["api_key"]
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        try await fixture.manager.saveSecret(
            "first-key",
            pluginID: installed.id,
            secretID: "api_key"
        )
        let firstConnection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(firstConnection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        try await fixture.manager.saveSecret(
            "second-key",
            pluginID: installed.id,
            secretID: "api_key"
        )
        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(
            fixture.manager.validatedPluginIDs.contains(installed.id)
        )
        let secondConnection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(secondConnection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )

        try await fixture.manager.deleteSecret(
            pluginID: installed.id,
            secretID: "api_key"
        )
        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: installed.id
            )
            XCTFail("Deleting a required secret must block enablement.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .missingRequiredSecret("api_key")
            )
        }
    }

    func testSchemaV5SecretLifecycleUsesConfigurationDeclaration()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["api_key"],
            capabilities: [.actions],
            platform: .init(),
            schemaVersion: 5
        )
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )

        try await fixture.manager.saveSecret(
            "v5-key",
            pluginID: installed.id,
            secretID: "api_key"
        )

        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "api_key"
            ),
            "v5-key"
        )
    }

    func testSchemaV6SessionCredentialLifecycleUsesConfigurationDeclaration()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["session_cookie"],
            networkDomains: ["api.example.com"],
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: ["api.example.com"]
                ),
            ],
            capabilities: [.actions],
            platform: .init(),
            schemaVersion: 6,
            presentation: pluginPresentation()
        )
        let pending = try await fixture.manager.prepareInstallation(
            from: source
        )
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )

        try await fixture.manager.saveSecret(
            "v6-session",
            pluginID: installed.id,
            secretID: "session_cookie"
        )
        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "session_cookie"
            ),
            "v6-session"
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)

        try await fixture.manager.deleteSecret(
            pluginID: installed.id,
            secretID: "session_cookie"
        )
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "session_cookie"
            )
        )
        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(
            fixture.manager.validatedPluginIDs.contains(installed.id)
        )
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: installed.id
            )
            XCTFail("Deleting a required v6 session credential must block enablement.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .missingRequiredSecret("session_cookie")
            )
        }
    }

    func testSchemaV5ToV6UnchangedSecretContractPreservesValueAndInvalidatesValidation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-v5-secret.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["api_key"],
            scriptSuffix: "v5",
            schemaVersion: 5,
            translation: .init()
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        try await fixture.manager.saveSecret(
            "preserved-key",
            pluginID: first.id,
            secretID: "api_key"
        )
        let connectionTest = await fixture.manager.connectionTest(
            pluginID: first.id,
            capability: .translation
        )
        XCTAssertTrue(connectionTest.succeeded)
        _ = try await fixture.manager.setEnabled(true, pluginID: first.id)

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-v6-secret.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["api_key"],
            scriptSuffix: "v6",
            schemaVersion: 6,
            presentation: pluginPresentation(),
            translation: .init()
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        let second = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )

        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: second.id,
                secretID: "api_key"
            ),
            "preserved-key"
        )
        XCTAssertTrue(fixture.secretStore.deletedKeys.isEmpty)
        XCTAssertFalse(fixture.manager.validatedPluginIDs.contains(second.id))
        do {
            _ = try await fixture.manager.setEnabled(true, pluginID: second.id)
            XCTFail("A package upgrade must require validation for its current revision.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .validationRequired
            )
        }
    }

    func testSchemaV1SecretLifecycleUsesPermissionDeclaration()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["api_key"],
            usesLegacyV1SecretDeclarations: true
        )
        let manifestData = try Data(
            contentsOf: source.appendingPathComponent("manifest.json")
        )
        let manifest = try JSONDecoder().decode(
            BlocksNativePluginManifest.self,
            from: manifestData
        )
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertTrue(manifest.configurationFields.isEmpty)
        XCTAssertEqual(
            manifest.permissions.secrets.map(\.id),
            ["api_key"]
        )

        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )

        try await fixture.manager.saveSecret(
            "legacy-v1-key",
            pluginID: installed.id,
            secretID: "api_key"
        )
        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "api_key"
            ),
            "legacy-v1-key"
        )
        do {
            try await fixture.manager.saveSecret(
                "undeclared",
                pluginID: installed.id,
                secretID: "other_key"
            )
            XCTFail("Schema v1 must reject an undeclared secret identifier.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginSecretStoreError,
                .invalidIdentifier
            )
        }

        let connection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )
        XCTAssertTrue(fixture.manager.plugins.first?.isEnabled == true)

        try await fixture.manager.deleteSecret(
            pluginID: installed.id,
            secretID: "api_key"
        )
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "api_key"
            )
        )
        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: installed.id
            )
            XCTFail("Deleting a required v1 secret must block enablement.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .missingRequiredSecret("api_key")
            )
        }
    }

    func testSamePackageReinstallDoesNotPreserveEnablementOrValidation()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let firstPending =
            try await fixture.manager.prepareInstallation(from: source)
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        let connection = await fixture.manager.connectionTest(
            pluginID: first.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: first.id
        )

        let secondPending =
            try await fixture.manager.prepareInstallation(from: source)
        let reinstalled = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )

        XCTAssertFalse(reinstalled.isEnabled)
        XCTAssertFalse(fixture.manager.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(
            fixture.manager.validatedPluginIDs.contains(first.id)
        )
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: first.id
            )
            XCTFail("Reinstalled packages must be retested.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .validationRequired
            )
        }
    }

    func testValidationRevisionPersistsAcrossRestartAndStaleRevisionDisables()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginValidationRestart-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "BlocksPluginValidationRestart-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let metadataStore = RecordingPluginMetadataStore()
        let executor = RecordingPluginExecutor()
        let firstManager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: executor,
            configurationStore:
                BlocksNativePluginConfigurationStore(defaults: defaults),
            validationStore:
                BlocksNativePluginValidationStore(defaults: defaults)
        )
        let source = try makePackage(at: root)
        let pending = try await firstManager.prepareInstallation(from: source)
        let installed = try await firstManager.confirmAndInstall(
            pendingID: pending.id
        )
        let connection = await firstManager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)
        _ = try await firstManager.setEnabled(
            true,
            pluginID: installed.id
        )

        let restartedManager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: executor,
            configurationStore:
                BlocksNativePluginConfigurationStore(defaults: defaults),
            validationStore:
                BlocksNativePluginValidationStore(defaults: defaults)
        )
        await restartedManager.reload()
        XCTAssertTrue(restartedManager.plugins.first?.isEnabled == true)
        XCTAssertTrue(
            restartedManager.validatedPluginIDs.contains(installed.id)
        )

        try BlocksNativePluginValidationStore(defaults: defaults)
            .invalidateAndAdvanceCredentialRevision(pluginID: installed.id)
        let staleRestart = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: executor,
            configurationStore:
                BlocksNativePluginConfigurationStore(defaults: defaults),
            validationStore:
                BlocksNativePluginValidationStore(defaults: defaults)
        )
        await staleRestart.reload()
        XCTAssertFalse(staleRestart.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(
            staleRestart.validatedPluginIDs.contains(installed.id)
        )
    }

    func testDisableCancelsBeforeAndAfterPersistentStateTransition() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        let connection = await fixture.manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)
        _ = try await fixture.manager.setEnabled(
            true,
            pluginID: installed.id
        )
        _ = try await fixture.manager.setEnabled(
            false,
            pluginID: installed.id
        )

        XCTAssertEqual(fixture.executor.cancelCount, 2)
        XCTAssertFalse(fixture.metadataStore.records[0].isEnabled)
    }

    func testRequiredSecretBlocksEnableAndUninstallDeletesDeclaredSecret() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocksPluginManager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackage(
            at: root,
            requiredSecretIDs: ["api_key"]
        )
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let secretStore = RecordingPluginSecretStore()
        let manager = BlocksNativePluginManager(
            database: database,
            storageEnvironment: environment,
            executor: RecordingPluginExecutor(),
            secretStore: secretStore
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)

        do {
            _ = try await manager.setEnabled(true, pluginID: installed.id)
            XCTFail("A required secret must block enablement.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .missingRequiredSecret("api_key")
            )
        }
        XCTAssertFalse(manager.plugins.first?.isEnabled ?? true)
        XCTAssertFalse(secretStore.containsExecutedOnMainThread)

        try await manager.saveSecret(
            "fixture-api-key",
            pluginID: installed.id,
            secretID: "api_key"
        )
        let connection = await manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.uninstall(pluginID: installed.id)

        XCTAssertEqual(
            secretStore.deletedKeys,
            ["\(installed.id)::api_key"]
        )
        XCTAssertTrue(manager.plugins.isEmpty)
    }

    func testInstallMetadataFailureRemovesOnlyNewSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginManagerRollback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makePackage(at: root)
        let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        let metadataStore = RecordingPluginMetadataStore()
        metadataStore.failNextInstall()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor()
        )
        let pending = try await manager.prepareInstallation(from: source)

        do {
            _ = try await manager.confirmAndInstall(pendingID: pending.id)
            XCTFail("Injected metadata failure must fail installation.")
        } catch {
            XCTAssertEqual(error as? PluginManagerInjectedError, .install)
        }

        XCTAssertTrue(metadataStore.records.isEmpty)
        XCTAssertTrue(
            pluginSnapshots(below: managedRoot).isEmpty,
            "A failed metadata transaction must remove its newly-created package."
        )
        XCTAssertEqual(manager.operation, .awaitingConfirmation)
    }

    func testSuccessfulUpgradeRemovesPreviousHashSnapshot() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-v1.blocksplugin",
            version: "1.0.0",
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        let firstURL = managedPackageURL(
            metadata: first,
            managedRoot: fixture.managedRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-v2.blocksplugin",
            version: "1.0.1",
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        let second = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )
        let secondURL = managedPackageURL(
            metadata: second,
            managedRoot: fixture.managedRoot
        )

        XCTAssertNotEqual(first.packageHash, second.packageHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(
            fixture.metadataStore.records.first?.packageHash,
            second.packageHash
        )
    }

    func testSuccessfulUpgradeDeletesOnlyRevokedSecrets() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-secrets-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["removed_key", "shared_key"],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "removed_key",
            value: "removed-value"
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "shared_key",
            value: "shared-value"
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-secrets-v2.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["shared_key"],
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        let second = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )

        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: second.id,
                secretID: "removed_key"
            )
        )
        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: second.id,
                secretID: "shared_key"
            ),
            "shared-value"
        )
        XCTAssertEqual(
            fixture.secretStore.deletedKeys,
            ["\(second.id)::removed_key"]
        )
        XCTAssertEqual(
            pluginSnapshots(below: fixture.managedRoot),
            [
                managedPackageURL(
                    metadata: second,
                    managedRoot: fixture.managedRoot
                ),
            ]
        )
        XCTAssertTrue(
            managedTransactionFiles(below: fixture.managedRoot).isEmpty
        )
    }

    func testUpgradeRevokesSecretWhenSensitiveFieldTypeChanges()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-session-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["session_cookie"],
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: ["api.example.com"]
                ),
            ],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "session_cookie",
            value: "old-session"
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-secret-v2.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["session_cookie"],
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .secret,
                    title: "API Secret",
                    required: true
                ),
            ],
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        let second = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )

        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: second.id,
                secretID: "session_cookie"
            )
        )
        XCTAssertEqual(
            fixture.secretStore.deletedKeys,
            ["\(second.id)::session_cookie"]
        )
        do {
            _ = try await fixture.manager.setEnabled(
                true,
                pluginID: second.id
            )
            XCTFail("A changed sensitive field must require secret re-entry.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .missingRequiredSecret("session_cookie")
            )
        }
    }

    func testUpgradeRevokesSessionCredentialWhenAllowedDomainsChange()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let networkDomains = ["api.example.com", "auth.example.com"]
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-domain-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["session_cookie"],
            networkDomains: networkDomains,
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: ["api.example.com"]
                ),
            ],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "session_cookie",
            value: "old-session"
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-domain-v2.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["session_cookie"],
            networkDomains: networkDomains,
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: ["auth.example.com"]
                ),
            ],
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        let second = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )

        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: second.id,
                secretID: "session_cookie"
            )
        )
        XCTAssertEqual(
            fixture.secretStore.deletedKeys,
            ["\(second.id)::session_cookie"]
        )
    }

    func testUpgradeKeepsSessionCredentialWhenNormalizedContractIsUnchanged()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let networkDomains = ["api.example.com", "auth.example.com"]
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-normalized-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["session_cookie"],
            networkDomains: networkDomains,
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: [
                        "AUTH.EXAMPLE.COM",
                        "api.example.com",
                    ]
                ),
            ],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "session_cookie",
            value: "current-session"
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-normalized-v2.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["session_cookie"],
            networkDomains: networkDomains,
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: [
                        "api.example.com",
                        "auth.example.com",
                    ]
                ),
            ],
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        let second = try await fixture.manager.confirmAndInstall(
            pendingID: secondPending.id
        )

        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: second.id,
                secretID: "session_cookie"
            ),
            "current-session"
        )
        XCTAssertTrue(fixture.secretStore.deletedKeys.isEmpty)
    }

    func testUpgradeAcrossSchemaBoundaryRevokesSharedSecretInBothDirections()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacySource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-legacy-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["api_key"],
            usesLegacyV1SecretDeclarations: true,
            scriptSuffix: "v1"
        )
        let legacyPending = try await fixture.manager.prepareInstallation(
            from: legacySource
        )
        let legacy = try await fixture.manager.confirmAndInstall(
            pendingID: legacyPending.id
        )
        fixture.secretStore.configure(
            pluginID: legacy.id,
            secretID: "api_key",
            value: "legacy-value"
        )

        let v2Source = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-schema-v2.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["api_key"],
            scriptSuffix: "v2"
        )
        let v2Pending = try await fixture.manager.prepareInstallation(
            from: v2Source
        )
        let v2 = try await fixture.manager.confirmAndInstall(
            pendingID: v2Pending.id
        )
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: v2.id,
                secretID: "api_key"
            )
        )

        fixture.secretStore.configure(
            pluginID: v2.id,
            secretID: "api_key",
            value: "v2-value"
        )
        let legacyReplacementSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-legacy-v3.blocksplugin",
            version: "1.0.2",
            requiredSecretIDs: ["api_key"],
            usesLegacyV1SecretDeclarations: true,
            scriptSuffix: "v3"
        )
        let legacyReplacementPending =
            try await fixture.manager.prepareInstallation(
                from: legacyReplacementSource
            )
        let legacyReplacement =
            try await fixture.manager.confirmAndInstall(
                pendingID: legacyReplacementPending.id
            )
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: legacyReplacement.id,
                secretID: "api_key"
            )
        )
        XCTAssertEqual(
            fixture.secretStore.deletedKeys,
            [
                "\(legacy.id)::api_key",
                "\(legacy.id)::api_key",
            ]
        )
    }

    func testChangedSecretContractRecoversRevocationAfterInterruptedUpgrade()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let networkDomains = ["api.example.com", "auth.example.com"]
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-contract-recovery-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["session_cookie"],
            networkDomains: networkDomains,
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: ["api.example.com"]
                ),
            ],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "session_cookie",
            value: "old-session"
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-contract-recovery-v2.blocksplugin",
            version: "1.0.1",
            requiredSecretIDs: ["session_cookie"],
            networkDomains: networkDomains,
            configurationFields: [
                .init(
                    id: "session_cookie",
                    type: .sessionCredential,
                    title: "Session Cookie",
                    required: true,
                    allowedDomains: ["auth.example.com"]
                ),
            ],
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        fixture.secretStore.failDelete(atAttempt: 1)
        do {
            _ = try await fixture.manager.confirmAndInstall(
                pendingID: secondPending.id
            )
            XCTFail("Injected Keychain failure must interrupt the upgrade.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .secretDelete
            )
        }

        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: first.id,
                secretID: "session_cookie"
            ),
            "old-session"
        )
        XCTAssertEqual(
            managedTransactionFiles(below: fixture.managedRoot).count,
            1
        )

        let recoveredManager = BlocksNativePluginManager(
            repository: fixture.metadataStore,
            managedRoot: fixture.managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: fixture.secretStore
        )
        await recoveredManager.reload()

        XCTAssertNil(recoveredManager.lastErrorMessage)
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: first.id,
                secretID: "session_cookie"
            )
        )
        XCTAssertTrue(
            managedTransactionFiles(below: fixture.managedRoot).isEmpty
        )
    }

    func testUpgradeSecretDeleteFailureRecoversForwardOnReload() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-recovery-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["first_key", "second_key"],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "first_key",
            value: "first-value"
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "second_key",
            value: "second-value"
        )
        let firstURL = managedPackageURL(
            metadata: first,
            managedRoot: fixture.managedRoot
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-recovery-v2.blocksplugin",
            version: "1.0.1",
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        fixture.secretStore.failDelete(atAttempt: 2)
        do {
            _ = try await fixture.manager.confirmAndInstall(
                pendingID: secondPending.id
            )
            XCTFail("Injected Keychain failure must fail the upgrade.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .secretDelete
            )
        }

        let interruptedMetadata = try fixture.metadataStore.metadata(
            id: first.id
        )
        let secondURL = managedPackageURL(
            metadata: interruptedMetadata,
            managedRoot: fixture.managedRoot
        )
        XCTAssertNotEqual(interruptedMetadata.packageHash, first.packageHash)
        XCTAssertFalse(interruptedMetadata.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(
            managedTransactionFiles(below: fixture.managedRoot).count,
            1
        )
        XCTAssertEqual(
            fixture.manager.operation,
            .awaitingConfirmation
        )

        let recoveredManager = BlocksNativePluginManager(
            repository: fixture.metadataStore,
            managedRoot: fixture.managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: fixture.secretStore
        )
        await recoveredManager.reload()

        XCTAssertNil(recoveredManager.lastErrorMessage)
        XCTAssertEqual(
            recoveredManager.plugins.first?.packageHash,
            interruptedMetadata.packageHash
        )
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: first.id,
                secretID: "first_key"
            )
        )
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: first.id,
                secretID: "second_key"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(
            managedTransactionFiles(below: fixture.managedRoot).isEmpty
        )
    }

    func testUpgradeMarkerBeforeMetadataCommitRollsBackWithoutDeletingSecrets()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginUpgradePrepareRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let metadataStore = RecordingPluginMetadataStore()
        let secretStore = RecordingPluginSecretStore()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: secretStore,
            upgradeCheckpointHook: { checkpoint in
                if checkpoint == .transactionPersisted {
                    throw PluginManagerInjectedError.upgradeCheckpoint
                }
            }
        )
        let firstSource = try makePackage(
            at: root,
            directoryName: "Fixture-prepare-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["api_key"],
            scriptSuffix: "v1"
        )
        let firstPending = try await manager.prepareInstallation(
            from: firstSource
        )
        let first = try await manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        secretStore.configure(
            pluginID: first.id,
            secretID: "api_key",
            value: "still-authorized-before-commit"
        )
        let firstURL = managedPackageURL(
            metadata: first,
            managedRoot: managedRoot
        )

        let secondSource = try makePackage(
            at: root,
            directoryName: "Fixture-prepare-v2.blocksplugin",
            version: "1.0.1",
            scriptSuffix: "v2"
        )
        let secondPending = try await manager.prepareInstallation(
            from: secondSource
        )
        do {
            _ = try await manager.confirmAndInstall(
                pendingID: secondPending.id
            )
            XCTFail("The injected pre-commit interruption must escape.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .upgradeCheckpoint
            )
        }

        XCTAssertEqual(
            metadataStore.records.first?.packageHash,
            first.packageHash
        )
        XCTAssertEqual(
            try secretStore.value(
                pluginID: first.id,
                secretID: "api_key"
            ),
            "still-authorized-before-commit"
        )
        XCTAssertEqual(pluginSnapshots(below: managedRoot).count, 2)
        XCTAssertEqual(managedTransactionFiles(below: managedRoot).count, 1)

        let recoveredManager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: secretStore
        )
        await recoveredManager.reload()

        XCTAssertNil(recoveredManager.lastErrorMessage)
        XCTAssertEqual(
            recoveredManager.plugins.first?.packageHash,
            first.packageHash
        )
        XCTAssertEqual(
            try secretStore.value(
                pluginID: first.id,
                secretID: "api_key"
            ),
            "still-authorized-before-commit"
        )
        XCTAssertEqual(pluginSnapshots(below: managedRoot), [firstURL])
        XCTAssertTrue(managedTransactionFiles(below: managedRoot).isEmpty)
    }

    func testUpgradeWithoutSecretRevocationRecoversAfterPostCommitCleanupFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginUpgradeCleanupRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let metadataStore = RecordingPluginMetadataStore()
        let secretStore = RecordingPluginSecretStore()
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: executor,
            secretStore: secretStore,
            upgradeCheckpointHook: { checkpoint in
                if checkpoint == .beforePreviousPackageRemoval {
                    throw PluginManagerInjectedError.upgradeCheckpoint
                }
            }
        )
        let firstSource = try makePackage(
            at: root,
            directoryName: "Fixture-cleanup-v1.blocksplugin",
            version: "1.0.0",
            scriptSuffix: "v1"
        )
        let firstPending = try await manager.prepareInstallation(from: firstSource)
        let first = try await manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        let firstURL = managedPackageURL(
            metadata: first,
            managedRoot: managedRoot
        )

        let secondSource = try makePackage(
            at: root,
            directoryName: "Fixture-cleanup-v2.blocksplugin",
            version: "1.0.1",
            scriptSuffix: "v2"
        )
        let secondPending = try await manager.prepareInstallation(from: secondSource)
        do {
            _ = try await manager.confirmAndInstall(pendingID: secondPending.id)
            XCTFail("The injected post-commit cleanup failure must escape.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .upgradeCheckpoint
            )
        }

        let committed = try metadataStore.metadata(id: first.id)
        let replacementURL = managedPackageURL(
            metadata: committed,
            managedRoot: managedRoot
        )
        XCTAssertNotEqual(committed.packageHash, first.packageHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: replacementURL.path)
        )
        XCTAssertEqual(managedTransactionFiles(below: managedRoot).count, 1)
        XCTAssertEqual(manager.operation, .awaitingConfirmation)
        XCTAssertGreaterThanOrEqual(executor.cancelCount, 2)

        let recoveryExecutor = RecordingPluginExecutor()
        let recoveredManager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: recoveryExecutor,
            secretStore: secretStore
        )
        await recoveredManager.reload()

        XCTAssertNil(recoveredManager.lastErrorMessage)
        XCTAssertEqual(
            recoveredManager.plugins.first?.packageHash,
            committed.packageHash
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: replacementURL.path)
        )
        XCTAssertTrue(managedTransactionFiles(below: managedRoot).isEmpty)
        XCTAssertEqual(recoveryExecutor.cancelCount, 1)
    }

    func testUpgradeCancelsBeforeAndAfterDisablingPreviousRevision() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-race-v1.blocksplugin",
            version: "1.0.0",
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-race-v2.blocksplugin",
            version: "1.0.1",
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        fixture.metadataStore.pauseNextInstall()
        let cancelCountBeforeUpgrade = fixture.executor.cancelCount

        let upgrade = Task { @MainActor in
            try await fixture.manager.confirmAndInstall(
                pendingID: secondPending.id
            )
        }
        try await fixture.metadataStore.waitUntilInstallStarts()

        XCTAssertGreaterThan(
            fixture.executor.cancelCount,
            cancelCountBeforeUpgrade
        )
        XCTAssertEqual(
            fixture.executor.cancelCount - cancelCountBeforeUpgrade,
            2
        )

        fixture.metadataStore.resumeInstall()
        _ = try await upgrade.value

        XCTAssertEqual(
            fixture.executor.cancelCount - cancelCountBeforeUpgrade,
            2
        )
        XCTAssertEqual(fixture.executor.cancelledPluginIDs.last, first.id)
    }

    func testFailedUpgradeKeepsPreviousMetadataPackageAndSecrets() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-v1.blocksplugin",
            version: "1.0.0",
            requiredSecretIDs: ["api_key"],
            scriptSuffix: "v1"
        )
        let firstPending = try await fixture.manager.prepareInstallation(
            from: firstSource
        )
        let first = try await fixture.manager.confirmAndInstall(
            pendingID: firstPending.id
        )
        fixture.secretStore.configure(
            pluginID: first.id,
            secretID: "api_key"
        )
        let firstURL = managedPackageURL(
            metadata: first,
            managedRoot: fixture.managedRoot
        )

        let secondSource = try makePackage(
            at: fixture.root,
            directoryName: "Fixture-v2.blocksplugin",
            version: "1.0.1",
            scriptSuffix: "v2"
        )
        let secondPending = try await fixture.manager.prepareInstallation(
            from: secondSource
        )
        fixture.metadataStore.failNextInstall()
        do {
            _ = try await fixture.manager.confirmAndInstall(
                pendingID: secondPending.id
            )
            XCTFail("Injected metadata failure must fail upgrade.")
        } catch {
            XCTAssertEqual(error as? PluginManagerInjectedError, .install)
        }

        XCTAssertEqual(
            fixture.metadataStore.records.first?.packageHash,
            first.packageHash
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(pluginSnapshots(below: fixture.managedRoot), [firstURL])
        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: first.id,
                secretID: "api_key"
            ),
            "fixture-secret"
        )
        XCTAssertTrue(
            managedTransactionFiles(below: fixture.managedRoot).isEmpty
        )
    }

    func testInterruptedUninstallRecoversAfterMetadataFailureAndRestart() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["api_key"]
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        fixture.secretStore.configure(
            pluginID: installed.id,
            secretID: "api_key"
        )
        fixture.metadataStore.failNextRemove()
        let installedURL = managedPackageURL(
            metadata: installed,
            managedRoot: fixture.managedRoot
        )

        do {
            try await fixture.manager.uninstall(pluginID: installed.id)
            XCTFail("Injected metadata failure must fail uninstall.")
        } catch {
            XCTAssertEqual(error as? PluginManagerInjectedError, .remove)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertEqual(fixture.metadataStore.records.map(\.id), [installed.id])
        XCTAssertFalse(fixture.metadataStore.records[0].isEnabled)
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "api_key"
            )
        )

        let recoveredManager = BlocksNativePluginManager(
            repository: fixture.metadataStore,
            managedRoot: fixture.managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: fixture.secretStore
        )
        await recoveredManager.reload()

        XCTAssertTrue(recoveredManager.plugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertNil(recoveredManager.lastErrorMessage)
    }

    func testInterruptedUninstallRecoversAfterSecretFailureAndRestart() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            requiredSecretIDs: ["first_key", "second_key"]
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        fixture.secretStore.configure(
            pluginID: installed.id,
            secretID: "first_key",
            value: "first-value"
        )
        fixture.secretStore.configure(
            pluginID: installed.id,
            secretID: "second_key",
            value: "second-value"
        )
        fixture.secretStore.failDelete(atAttempt: 2)
        let installedURL = managedPackageURL(
            metadata: installed,
            managedRoot: fixture.managedRoot
        )

        do {
            try await fixture.manager.uninstall(pluginID: installed.id)
            XCTFail("Injected Keychain failure must fail uninstall.")
        } catch {
            XCTAssertEqual(error as? PluginManagerInjectedError, .secretDelete)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertEqual(fixture.metadataStore.removeCount, 0)
        XCTAssertFalse(fixture.metadataStore.records[0].isEnabled)
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "first_key"
            )
        )
        XCTAssertEqual(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "second_key"
            ),
            "second-value"
        )

        let recoveredManager = BlocksNativePluginManager(
            repository: fixture.metadataStore,
            managedRoot: fixture.managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: fixture.secretStore
        )
        await recoveredManager.reload()

        XCTAssertTrue(recoveredManager.plugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertNil(
            try fixture.secretStore.value(
                pluginID: installed.id,
                secretID: "second_key"
            )
        )
        XCTAssertNil(recoveredManager.lastErrorMessage)
    }

    func testTombstoneCheckpointCrashRecoversIdempotentlyOnReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginTombstoneRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let metadataStore = RecordingPluginMetadataStore()
        let secretStore = RecordingPluginSecretStore()
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: executor,
            secretStore: secretStore,
            uninstallCheckpointHook: { checkpoint in
                if checkpoint == .tombstonePersisted {
                    throw PluginManagerInjectedError.uninstallCheckpoint
                }
            }
        )
        let source = try makePackage(
            at: root,
            requiredSecretIDs: ["api_key"]
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(
            pendingID: pending.id
        )
        secretStore.configure(
            pluginID: installed.id,
            secretID: "api_key"
        )
        let connection = await manager.connectionTest(
            pluginID: installed.id,
            capability: .translation
        )
        XCTAssertTrue(connection.succeeded)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let installedURL = managedPackageURL(
            metadata: installed,
            managedRoot: managedRoot
        )

        do {
            try await manager.uninstall(pluginID: installed.id)
            XCTFail("Injected checkpoint must interrupt uninstall.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .uninstallCheckpoint
            )
        }
        XCTAssertFalse(metadataStore.records[0].isEnabled)
        XCTAssertGreaterThanOrEqual(executor.cancelCount, 2)
        XCTAssertFalse(manager.pluginSnapshotIsAuthoritative)
        XCTAssertFalse(manager.isReadyForMutations)
        do {
            _ = try await manager.setEnabled(true, pluginID: installed.id)
            XCTFail("A pending uninstall tombstone must block same-process enable.")
        } catch let error as BlocksNativePluginManagerError {
            guard case .recoveryConflict = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        XCTAssertFalse(metadataStore.records[0].isEnabled)
        XCTAssertTrue(manager.hostOperationAdmissionGate.isRevoked(
            pluginID: installed.id
        ))
        XCTAssertEqual(executor.invocationCount, 1)

        let recoveredManager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: secretStore
        )
        await recoveredManager.reload()

        XCTAssertTrue(recoveredManager.plugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertNil(
            try secretStore.value(
                pluginID: installed.id,
                secretID: "api_key"
            )
        )
        XCTAssertNil(recoveredManager.lastErrorMessage)
    }

    func testTombstoneRecoveryClearsConfigurationAndValidationBeforeReinstall()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginTombstoneConfigurationRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "BlocksPluginTombstoneConfiguration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        let metadataStore = RecordingPluginMetadataStore()
        let secretStore = RecordingPluginSecretStore()
        let configurationStore = BlocksNativePluginConfigurationStore(
            defaults: defaults
        )
        let validationStore = BlocksNativePluginValidationStore(defaults: defaults)
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: secretStore,
            configurationStore: configurationStore,
            validationStore: validationStore,
            uninstallCheckpointHook: { checkpoint in
                if checkpoint == .packageRemoved {
                    throw PluginManagerInjectedError.uninstallCheckpoint
                }
            }
        )
        let source = try makePackage(
            at: root,
            configurationFields: [
                .init(
                    id: "mode",
                    type: .text,
                    title: "Mode",
                    required: true,
                    defaultValue: .string("fresh")
                ),
            ]
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        let manifest = try XCTUnwrap(manager.manifest(pluginID: installed.id))
        try await manager.saveConfiguration(
            ["mode": .string("stale")],
            pluginID: installed.id
        )
        try validationStore.invalidateAndAdvanceCredentialRevision(
            pluginID: installed.id
        )

        do {
            try await manager.uninstall(pluginID: installed.id)
            XCTFail("Injected interruption must leave the tombstone for recovery.")
        } catch {
            XCTAssertEqual(
                error as? PluginManagerInjectedError,
                .uninstallCheckpoint
            )
        }
        XCTAssertEqual(
            try configurationStore.configuration(
                pluginID: installed.id,
                manifest: manifest
            )["mode"],
            .string("stale")
        )
        XCTAssertEqual(
            try validationStore.credentialRevision(pluginID: installed.id),
            1
        )
        XCTAssertFalse(managedTransactionFiles(below: managedRoot).isEmpty)

        let recoveredManager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor(),
            secretStore: secretStore,
            configurationStore: configurationStore,
            validationStore: validationStore
        )
        await recoveredManager.reload()

        XCTAssertTrue(recoveredManager.plugins.isEmpty)
        XCTAssertEqual(
            try configurationStore.configuration(
                pluginID: installed.id,
                manifest: manifest
            )["mode"],
            .string("fresh")
        )
        XCTAssertEqual(
            try validationStore.credentialRevision(pluginID: installed.id),
            0
        )
        XCTAssertNil(try validationStore.validatedRevision(pluginID: installed.id))
        XCTAssertTrue(managedTransactionFiles(below: managedRoot).isEmpty)

        let reinstallPending = try await recoveredManager.prepareInstallation(
            from: source
        )
        let reinstalled = try await recoveredManager.confirmAndInstall(
            pendingID: reinstallPending.id
        )
        let reinstalledManifest = try XCTUnwrap(
            recoveredManager.manifest(pluginID: reinstalled.id)
        )
        XCTAssertEqual(
            try configurationStore.configuration(
                pluginID: reinstalled.id,
                manifest: reinstalledManifest
            )["mode"],
            .string("fresh")
        )
    }

    func testReloadRemovesInterruptedInstallStagingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginInstallOrphan-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let orphan = managedRoot.appendingPathComponent(
            ".installing-orphan.blocksplugin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        try Data("orphan".utf8).write(
            to: orphan.appendingPathComponent("plugin.js")
        )

        let manager = BlocksNativePluginManager(
            repository: RecordingPluginMetadataStore(),
            managedRoot: managedRoot,
            executor: RecordingPluginExecutor()
        )
        await manager.reload()

        XCTAssertTrue(manager.plugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testReloadPersistenceIsOffMainSerializedAndRejectsStaleGeneration()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginReloadWorker-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let old = pluginMetadata(
            id: "com.example.old",
            isEnabled: false,
            approvalStatus: .approved,
            capabilities: [.translation]
        )
        let current = pluginMetadata(
            id: "com.example.current",
            isEnabled: false,
            approvalStatus: .approved,
            capabilities: [.translation]
        )
        let repository = ReloadProbePluginMetadataStore(
            snapshots: [[old], [current]]
        )
        let manager = BlocksNativePluginManager(
            repository: repository,
            managedRoot: root.appendingPathComponent("Managed", isDirectory: true),
            executor: RecordingPluginExecutor(),
            secretStore: RecordingPluginSecretStore()
        )

        let initialReload = Task { @MainActor in
            await manager.reload()
        }
        try await repository.waitUntilFirstListStarts()
        let latestReload = Task { @MainActor in
            await manager.reload()
        }
        repository.releaseFirstList()
        await initialReload.value
        await latestReload.value

        XCTAssertEqual(manager.plugins.map(\.id), [current.id])
        XCTAssertTrue(manager.pluginSnapshotIsAuthoritative)
        XCTAssertFalse(repository.listExecutedOnMainThread)
        XCTAssertEqual(repository.maximumConcurrentListCalls, 1)
    }

    func testBusyManagerRejectsOverlappingMutationWithoutChangingOperation() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(at: fixture.root)
        let pending = try await fixture.manager.prepareInstallation(from: source)
        fixture.metadataStore.pauseNextInstall()
        let installation = Task {
            try await fixture.manager.confirmAndInstall(pendingID: pending.id)
        }
        try await fixture.metadataStore.waitUntilInstallStarts()
        XCTAssertEqual(fixture.manager.operation, .installing)

        do {
            try await fixture.manager.uninstall(pluginID: "com.example.fixture")
            XCTFail("A second mutation must be rejected while install is active.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginManagerError,
                .operationInProgress
            )
        }
        XCTAssertEqual(fixture.manager.operation, .installing)
        let connectionTest = await fixture.manager.connectionTest(
            pluginID: "com.example.fixture",
            capability: .translation
        )
        XCTAssertFalse(connectionTest.succeeded)
        XCTAssertEqual(connectionTest.errorCode, "plugin_manager_busy")
        XCTAssertEqual(fixture.manager.operation, .installing)
        fixture.manager.cancelPendingInstallation()
        XCTAssertEqual(fixture.manager.operation, .installing)
        XCTAssertEqual(fixture.manager.pendingInstallation?.id, pending.id)

        fixture.metadataStore.resumeInstall()
        _ = try await installation.value
        XCTAssertEqual(fixture.manager.operation, .idle)
    }

    func testCatalogInstallPlanRequiresARevalidatedHashBeforeInstalling()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try makePackage(
            at: fixture.root,
            directoryName: "CatalogFixture.blocksplugin"
        )
        var catalog = try catalogFixture(for: package)
        let service = PluginDevelopmentService(
            pluginManager: fixture.manager,
            runtime: BlocksPluginRuntimeCoordinator(manager: fixture.manager),
            builtInCatalogLoader: { catalog }
        )

        let plan = try await service.execute(
            .init(operation: .catalogInstall, catalogID: "com.example.fixture"),
            requestID: .make()
        )
        let initialHash = try XCTUnwrap(
            plan.inspection?.confirmation.packageSHA256
        )
        XCTAssertTrue(plan.plugins.isEmpty)
        XCTAssertTrue(fixture.manager.plugins.isEmpty)

        do {
            _ = try await service.execute(
                .init(
                    operation: .catalogInstall,
                    confirmed: true,
                    catalogID: "com.example.fixture"
                ),
                requestID: .make()
            )
            XCTFail("An apply request without a reviewed hash must not install.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .missingField("confirmation_sha256")
            )
        }
        XCTAssertTrue(fixture.manager.plugins.isEmpty)

        do {
            _ = try await service.execute(
                .init(
                    operation: .catalogInstall,
                    confirmationSHA256: String(repeating: "0", count: 64),
                    confirmed: true,
                    catalogID: "com.example.fixture"
                ),
                requestID: .make()
            )
            XCTFail("A mismatched reviewed hash must not install the package.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .confirmationHashMismatch
            )
        }
        XCTAssertTrue(fixture.manager.plugins.isEmpty)

        try Data(
            "function translate(input) { return input.text + '-updated'; }".utf8
        ).write(to: package.appendingPathComponent("plugin.js"))
        catalog = try catalogFixture(for: package)
        let currentHash = try XCTUnwrap(
            try catalog.validatedPackage(
                for: try XCTUnwrap(catalog.document.entries.first)
            ).installationConfirmation.packageSHA256
        )
        XCTAssertNotEqual(initialHash, currentHash)

        do {
            _ = try await service.execute(
                .init(
                    operation: .catalogInstall,
                    confirmationSHA256: initialHash,
                    confirmed: true,
                    catalogID: "com.example.fixture"
                ),
                requestID: .make()
            )
            XCTFail("A superseded plan hash must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? TranslationSourceManagementServiceError,
                .confirmationHashMismatch
            )
        }
        XCTAssertTrue(fixture.manager.plugins.isEmpty)

        let installed = try await service.execute(
            .init(
                operation: .catalogInstall,
                confirmationSHA256: currentHash,
                confirmed: true,
                catalogID: "com.example.fixture"
            ),
            requestID: .make()
        )
        XCTAssertEqual(installed.plugins.map(\.id), ["com.example.fixture"])
    }

    func testSinglePlatformResultConfirmsEachDestructiveActionIndependently()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "TwoDestructiveActions.blocksplugin",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["clipboard.record.delete"],
                actions: [.init(id: "run", displayName: "Run", entryFunction: "run")]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(pendingID: pending.id)
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        var requests: [BlocksPluginDestructiveActionConfirmationRequest] = []
        var handlerCount = 0
        runtime.configureDestructiveActionConfirmationHandler { request in
            requests.append(request)
            return true
        }
        runtime.actionRegistry.register("clipboard.record.delete") { _, _ in
            handlerCount += 1
            return .bool(true)
        }
        fixture.executor.nextPlatformResult = .init(actions: [
            .init(actionID: "clipboard.record.delete", input: ["record_id": .string("first")], expectedRevision: 1),
            .init(actionID: "clipboard.record.delete", input: ["record_id": .string("second")], expectedRevision: 2),
        ])

        _ = try await runtime.performPluginAction(
            pluginID: installed.id, actionID: "run", kind: .uiAction,
            causationID: UUID()
        )

        XCTAssertEqual(handlerCount, 2)
        XCTAssertEqual(requests.map(\.targetID), ["first", "second"])
        XCTAssertEqual(requests.map(\.expectedRevision), [1, 2])
        XCTAssertNotEqual(requests[0].requestID, requests[1].requestID)
    }

#if DEBUG
    @MainActor
    func testDestructiveCapabilityBindsConfirmationRequestIDAndConsumesOnce()
        async throws
    {
        let registry = BlocksPluginHostActionRegistry()
        let pluginID = "com.example.request-id-binding"
        let causationID = UUID()
        let dispatchID = UUID()
        let requestID = UUID()
        let invocation = BlocksPluginActionInvocation(
            actionID: "clipboard.record.delete",
            input: ["record_id": .string("fixture-record")],
            expectedRevision: 1
        )
        var handlerCount = 0
        registry.register(
            .init(id: invocation.actionID, risk: .destructive)
        ) { _, _ in
            handlerCount += 1
            return .bool(true)
        }
        let capability = BlocksPluginDestructiveActionCapability.makeForTesting(
            pluginID: pluginID, actionID: invocation.actionID,
            targetID: "fixture-record", requestID: requestID,
            dispatchID: dispatchID, causationID: causationID,
            expectedRevision: invocation.expectedRevision,
            executionGeneration: 7, lifecycleGeneration: 11
        )
        let context = BlocksPluginHostActionRegistry.Context(
            requestingPluginID: pluginID, causationID: causationID,
            expectedRevision: invocation.expectedRevision, origin: .explicitUser
        )

        do {
            _ = try await registry.perform(
                invocation, context: context, destructiveCapability: capability,
                destructiveConfirmationRequestID: UUID(), dispatchID: dispatchID,
                executionGeneration: 7, lifecycleGeneration: 11
            )
            XCTFail("A mismatched confirmation request ID must fail closed.")
        } catch let error as BlocksPluginRuntimeError {
            XCTAssertEqual(
                error.errorDescription,
                BlocksPluginRuntimeError.invalidHostOperation(
                    "destructive_host_action_capability_required"
                ).errorDescription
            )
        }
        XCTAssertEqual(handlerCount, 0)

        _ = try await registry.perform(
            invocation, context: context, destructiveCapability: capability,
            destructiveConfirmationRequestID: requestID, dispatchID: dispatchID,
            executionGeneration: 7, lifecycleGeneration: 11
        )
        XCTAssertEqual(handlerCount, 1)

        do {
            _ = try await registry.perform(
                invocation, context: context, destructiveCapability: capability,
                destructiveConfirmationRequestID: requestID, dispatchID: dispatchID,
                executionGeneration: 7, lifecycleGeneration: 11
            )
            XCTFail("A consumed destructive capability must not be replayed.")
        } catch let error as BlocksPluginRuntimeError {
            XCTAssertEqual(
                error.errorDescription,
                BlocksPluginRuntimeError.invalidHostOperation(
                    "destructive_host_action_capability_required"
                ).errorDescription
            )
        }
        XCTAssertEqual(handlerCount, 1)
    }
#endif

    func testPluginDevelopmentInvokeRejectsDestructiveHostActionsEvenWithConfirm()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "DestructiveInvoke.blocksplugin",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["clipboard.record.delete"],
                actions: [
                    .init(id: "run", displayName: "Run", entryFunction: "run"),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)

        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        var handlerInvocationCount = 0
        runtime.actionRegistry.register("clipboard.record.delete") { context, input in
            handlerInvocationCount += 1
            XCTFail("CLI destructive invoke must be rejected before the handler.")
            return .bool(true)
        }
        fixture.executor.nextPlatformResult = .init(actions: [
            .init(
                actionID: "clipboard.record.delete",
                input: ["confirmed": .bool(true)],
                expectedRevision: 1
            ),
        ])
        let service = PluginDevelopmentService(
            pluginManager: fixture.manager,
            runtime: runtime
        )

        for confirmed in [false, true] {
            do {
                _ = try await service.execute(
                    .init(
                        operation: .invoke,
                        pluginID: installed.id,
                        actionID: "run",
                        actionInput: ["confirmed": .bool(true)],
                        confirmed: confirmed
                    ),
                    requestID: .make()
                )
                XCTFail("CLI confirmation flags must not authorize deletion.")
            } catch {
                guard case let .invalidHostOperation(reason) =
                        error as? BlocksPluginRuntimeError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(reason, "destructive_host_actions_unavailable_from_cli")
            }
        }
        XCTAssertEqual(handlerInvocationCount, 0)
    }

    func testRequestedHostActionRechecksPersistedRunnableAndPermissionBeforeHandler()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "HostActionAdmission.blocksplugin",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["system.notification"],
                actions: [
                    .init(id: "run", displayName: "Run", entryFunction: "run"),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        let probe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await probe.recordInvocation()
            return .null
        }
        fixture.executor.nextPlatformResult = .init(actions: [
            .init(actionID: "system.notification"),
        ])

        fixture.metadataStore.setSafetyDisabled(true, for: installed.id)
        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("Persisted safety-disable must reject a stale-snapshot host action.")
        } catch {
            XCTAssertEqual(
                error as? BlocksNativePluginExecutionError,
                .pluginDisabled
            )
        }

        fixture.metadataStore.setSafetyDisabled(false, for: installed.id)
        fixture.metadataStore.replacePermissions([], for: installed.id)
        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("Persisted permission revocation must reject a stale-snapshot host action.")
        } catch {
            guard case let .invalidHostOperation(reason) =
                    error as? BlocksPluginRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "unapproved:system.notification")
        }

        let invocationCount = await probe.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testRequestedHostActionLeaseDrainsBeforeDisable() async throws {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            directoryName: "HostActionDrain.blocksplugin",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["system.notification"],
                actions: [
                    .init(id: "run", displayName: "Run", entryFunction: "run"),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        let probe = SuspendedPluginHostActionProbe()
        let actionStarted = expectation(
            description: "The admitted host action starts before disable drains it."
        )
        runtime.actionRegistry.register("system.notification") { _, _ in
            actionStarted.fulfill()
            return await probe.perform()
        }
        fixture.executor.nextPlatformResult = .init(actions: [
            .init(actionID: "system.notification"),
        ])

        let firstAction = Task { @MainActor in
            try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
        }
        await fulfillment(of: [actionStarted], timeout: 2)

        let disableFinished = LifecycleCompletionProbe()
        let disable = Task { @MainActor in
            defer { disableFinished.markCompleted() }
            return try await fixture.manager.setEnabled(
                false,
                pluginID: installed.id
            )
        }
        await waitUntilAdmissionIsRevoked(
            fixture.manager.hostOperationAdmissionGate,
            pluginID: installed.id
        )

        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("A host action starting after the lifecycle cutoff must be rejected.")
        } catch {
            // The exact outer action error is not the contract; not invoking
            // the registered handler after the cutoff is.
        }
        XCTAssertFalse(disableFinished.isCompleted)
        let countBeforeRelease = await probe.invocationCount
        XCTAssertEqual(countBeforeRelease, 1)

        await probe.release()
        _ = try await firstAction.value
        let disabledMetadata = try await disable.value
        XCTAssertFalse(disabledMetadata.isEnabled)
        XCTAssertTrue(disableFinished.isCompleted)
        let finalInvocationCount = await probe.invocationCount
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testTerminationRevokesHostOperationsBeforeWillTerminateHook()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginTerminationAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let router = BlocksPluginHostOperationRouter()
        let executor = TerminationHookHostOperationExecutor(
            router: router,
            pluginID: "com.example.fixture"
        )
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins",
                isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platformRepository,
            hostOperationRouter: router
        )
        let source = try makePackage(
            at: root,
            directoryName: "TerminationHook.blocksplugin",
            capabilities: [.hooks],
            platform: .init(
                hooks: [
                    .init(id: "terminate", event: .appWillTerminate),
                ],
                storage: .init(kinds: [.keyValue])
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)

        await runtime.dispatchAppWillTerminate()

        let response = try XCTUnwrap(executor.response)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, "host_operation_failed")
        XCTAssertNil(
            try platformRepository.privateValue(
                pluginID: installed.id,
                key: "termination-hook-write"
            )
        )
    }

    func testHostActionIdempotencyDeduplicatesConflictsAndRetries()
        async throws
    {
        let fixture = try makeManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try makePackage(
            at: fixture.root,
            capabilities: [.actions],
            platform: .init(
                hostActions: [
                    "system.notification",
                    "system.open_plugin_page",
                ],
                actions: [
                    .init(
                        id: "run",
                        displayName: "Run",
                        entryFunction: "run"
                    ),
                ]
            )
        )
        let pending = try await fixture.manager.prepareInstallation(from: source)
        let installed = try await fixture.manager.confirmAndInstall(
            pendingID: pending.id
        )
        _ = try await fixture.manager.setEnabled(true, pluginID: installed.id)

        let runtime = BlocksPluginRuntimeCoordinator(manager: fixture.manager)
        var hostActionCount = 0
        var failNextHostAction = false
        runtime.actionRegistry.register("system.notification") { _, _ in
            hostActionCount += 1
            if failNextHostAction {
                failNextHostAction = false
                throw PluginManagerInjectedError.install
            }
            try await Task.sleep(for: .milliseconds(25))
            return .object(["call": .int(hostActionCount)])
        }
        runtime.actionRegistry.register("system.open_plugin_page") { _, _ in
            hostActionCount += 1
            return .null
        }

        func request(
            actionID: String = "system.notification",
            input: [String: JSONValue],
            key: String,
            expectedRevision: Int64?
        ) {
            fixture.executor.nextPlatformResult = .init(actions: [
                .init(
                    actionID: actionID,
                    input: input,
                    idempotencyKey: key,
                    expectedRevision: expectedRevision
                ),
            ])
        }

        request(
            input: ["value": .string("first")],
            key: "shared",
            expectedRevision: 1
        )
        async let first = runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        async let second = runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        let firstResult = try await first
        let secondResult = try await second
        XCTAssertEqual(hostActionCount, 1)
        XCTAssertEqual(firstResult.actions, secondResult.actions)

        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        XCTAssertEqual(hostActionCount, 1)

        await runtime.setSafeModeEnabled(true)
        await runtime.setSafeModeEnabled(false)
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        XCTAssertEqual(hostActionCount, 2)

        for conflictingAction in [
            BlocksPluginActionInvocation(
                actionID: "system.notification",
                input: ["value": .string("different-input")],
                idempotencyKey: "shared",
                expectedRevision: 1
            ),
            BlocksPluginActionInvocation(
                actionID: "system.open_plugin_page",
                input: ["value": .string("first")],
                idempotencyKey: "shared",
                expectedRevision: 1
            ),
            BlocksPluginActionInvocation(
                actionID: "system.notification",
                input: ["value": .string("first")],
                idempotencyKey: "shared",
                expectedRevision: 2
            ),
        ] {
            fixture.executor.nextPlatformResult = .init(
                actions: [conflictingAction]
            )
            do {
                _ = try await runtime.performPluginAction(
                    pluginID: installed.id,
                    actionID: "run"
                )
                XCTFail("A conflicting idempotency key must fail closed.")
            } catch {
                guard case BlocksPluginRuntimeError.idempotencyConflict = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    error.localizedDescription,
                    "A plugin host action idempotency key conflicts with a different request."
                )
            }
            XCTAssertEqual(hostActionCount, 2)
        }

        request(
            input: ["value": .string("empty")],
            key: "",
            expectedRevision: 1
        )
        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("An empty idempotency key must fail closed.")
        } catch {
            guard case let .invalidHostOperation(reason) = error as? BlocksPluginRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "invalid_idempotency_key")
        }
        XCTAssertEqual(hostActionCount, 2)

        request(
            input: ["value": .string("oversized-key")],
            key: String(repeating: "k", count: 257),
            expectedRevision: 1
        )
        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("An oversized idempotency key must fail closed.")
        } catch {
            guard case let .invalidHostOperation(reason) =
                    error as? BlocksPluginRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "invalid_idempotency_key")
        }
        XCTAssertEqual(hostActionCount, 2)

        request(
            input: ["value": .string("retry")],
            key: "retry",
            expectedRevision: 1
        )
        failNextHostAction = true
        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("A failed host action must surface its failure.")
        } catch PluginManagerInjectedError.install {
            // Expected: a failed entry must not remain cached.
        }
        XCTAssertEqual(hostActionCount, 3)

        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        XCTAssertEqual(hostActionCount, 4)
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        XCTAssertEqual(hostActionCount, 4)

        await runtime.setSafeModeEnabled(true)
        await runtime.setSafeModeEnabled(false)
        let countBeforeBudgetExercise = hostActionCount
        runtime.actionRegistry.register("system.notification") { _, _ in
            hostActionCount += 1
            return .string(String(repeating: "x", count: 300_000))
        }
        for index in 0..<16 {
            request(
                input: ["value": .string("\(index)")],
                key: "budget-\(index)",
                expectedRevision: 1
            )
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
        }
        XCTAssertEqual(hostActionCount, countBeforeBudgetExercise + 16)

        request(
            input: ["value": .string("0")],
            key: "budget-0",
            expectedRevision: 1
        )
        _ = try await runtime.performPluginAction(
            pluginID: installed.id,
            actionID: "run"
        )
        XCTAssertEqual(
            hostActionCount,
            countBeforeBudgetExercise + 17,
            "The total byte budget must evict the oldest large result."
        )
    }

    private func catalogFixture(
        for package: URL
    ) throws -> BlocksBuiltInPluginCatalog {
        let validated = try BlocksNativePluginPackageValidator().validate(
            directory: package
        )
        let entry = BlocksBuiltInPluginCatalogEntry(
            id: validated.manifest.id,
            version: validated.manifest.version,
            category: .translation,
            symbolName: "puzzlepiece.extension",
            packageDirectory: package.lastPathComponent,
            packageSHA256: validated.packageSHA256,
            localizations: ["en": .init(name: "Fixture", summary: "")]
        )
        return .init(
            document: .init(catalogVersion: "test", entries: [entry]),
            resourceRoot: package.deletingLastPathComponent()
        )
    }

    private func makePackage(
        at root: URL,
        directoryName: String = "Fixture.blocksplugin",
        pluginID: String = "com.example.fixture",
        version: String = "1.0.0",
        requiredSecretIDs: [String] = [],
        usesLegacyV1SecretDeclarations: Bool = false,
        networkDomains: [String] = ["api.example.com"],
        networkMaximumRequestBytes: Int =
            BlocksNativePluginNetworkPermission.defaultMaximumRequestBytes,
        configurationFields:
            [BlocksNativePluginConfigurationField] = [],
        scriptSuffix: String = "",
        capabilities: [BlocksNativePluginCapability] = [.translation],
        dataPermissions: [BlocksNativePluginDataPermission] = [],
        platform: BlocksPluginPlatformConfiguration? = nil,
        schemaVersion: Int? = nil,
        presentation: BlocksNativePluginPresentation? = nil,
        translation: BlocksNativePluginTranslationConfiguration? = nil,
        entrySource: String? = nil
    ) throws -> URL {
        precondition(
            !usesLegacyV1SecretDeclarations || configurationFields.isEmpty
        )
        let package = root.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let explicitlyConfiguredSensitiveIDs = Set(
            configurationFields.lazy
                .filter { $0.type.isSensitive }
                .map(\.id)
        )
        func secretDisplayName(for secretID: String) -> String {
            secretID
                .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
                .map { component in
                    switch component.lowercased() {
                    case "api": "API"
                    case "id": "ID"
                    case "jwt": "JWT"
                    case "url": "URL"
                    default: component.capitalized
                    }
                }
                .joined(separator: " ")
        }
        let sensitiveFields: [BlocksNativePluginConfigurationField] =
            requiredSecretIDs.compactMap { secretID in
                guard !usesLegacyV1SecretDeclarations,
                      !explicitlyConfiguredSensitiveIDs.contains(secretID) else {
                    return nil
                }
                return BlocksNativePluginConfigurationField(
                    id: secretID,
                    type: .secret,
                    title: secretDisplayName(for: secretID),
                    required: true
                )
            }
        let allConfigurationFields =
            sensitiveFields + configurationFields
        let manifest = BlocksNativePluginManifest(
            schemaVersion: schemaVersion
                ?? (platform == nil
                    ? (usesLegacyV1SecretDeclarations
                        ? 1
                        : (allConfigurationFields.isEmpty ? 1 : 2))
                    : 4),
            id: pluginID,
            displayName: "Fixture",
            version: version,
            entryPoint: "plugin.js",
            capabilities: capabilities,
            translation: translation,
            permissions: .init(
                network: .init(
                    domains: networkDomains,
                    methods: [.post],
                    maximumRequestBytes: networkMaximumRequestBytes
                ),
                secrets: requiredSecretIDs.map {
                    .init(
                        id: $0,
                        displayName: secretDisplayName(for: $0),
                        required: true
                    )
                },
                data: dataPermissions
            ),
            configurationFields: allConfigurationFields,
            presentation: presentation,
            platform: platform
        )
        try JSONEncoder().encode(manifest).write(
            to: package.appendingPathComponent("manifest.json")
        )
        let source = entrySource
            ?? "function translate(input) { return input.text + '\(scriptSuffix)'; }"
        try Data(source.utf8).write(
            to: package.appendingPathComponent("plugin.js")
        )
        return package
    }

    private func makeManagerFixture() throws -> (
        root: URL,
        managedRoot: URL,
        metadataStore: RecordingPluginMetadataStore,
        secretStore: RecordingPluginSecretStore,
        executor: RecordingPluginExecutor,
        manager: BlocksNativePluginManager
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BlocksPluginManagerFixture-\(UUID().uuidString)",
                isDirectory: true
            )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let metadataStore = RecordingPluginMetadataStore()
        let secretStore = RecordingPluginSecretStore()
        let executor = RecordingPluginExecutor()
        let manager = BlocksNativePluginManager(
            repository: metadataStore,
            managedRoot: managedRoot,
            executor: executor,
            secretStore: secretStore
        )
        return (
            root,
            managedRoot,
            metadataStore,
            secretStore,
            executor,
            manager
        )
    }

    private func waitUntilAdmissionIsRevoked(
        _ gate: BlocksPluginHostOperationAdmissionGate,
        pluginID: String
    ) async {
        while !gate.isRevoked(pluginID: pluginID) {
            await Task.yield()
        }
    }

    private func pluginPresentation() -> BlocksNativePluginPresentation {
        .init(
            summary: "Fixture plugin",
            purpose: "Exercises plugin contracts.",
            trigger: "On demand.",
            dataUsage: "Uses only the configured fixture data."
        )
    }

    private func pluginMetadata(
        id: String = "com.example.fixture",
        isEnabled: Bool,
        approvalStatus: BlocksNativePluginApprovalStatus,
        capabilities: [BlocksNativePluginCapability]
    ) -> BlocksNativePluginMetadata {
        BlocksNativePluginMetadata(
            id: id,
            displayName: "Fixture",
            packageVersion: "1.0.0",
            packageHash: "fixture-hash",
            manifestJSON: "{}",
            capabilities: capabilities,
            installedRelativePath: "com.example.fixture/fixture-hash",
            isEnabled: isEnabled,
            approvalStatus: approvalStatus,
            approvedPermissions: [],
            approvedDomains: [],
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func managedPackageURL(
        metadata: BlocksNativePluginMetadata,
        managedRoot: URL
    ) -> URL {
        managedRoot
            .appendingPathComponent(
                metadata.installedRelativePath,
                isDirectory: true
            )
            .appendingPathExtension("blocksplugin")
            .standardizedFileURL
    }

    private func pluginSnapshots(below root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension == "blocksplugin" else {
                return nil
            }
            return url.standardizedFileURL
        }.sorted { $0.path < $1.path }
    }

    private func managedTransactionFiles(below root: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return entries.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(".upgrading-secrets-")
                || name.hasPrefix(".uninstalling-")
        }.sorted { $0.path < $1.path }
    }

    private func waitForMainActorCondition(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started
                >= timeoutNanoseconds {
                XCTFail("Timed out waiting for the main-actor condition.")
                return
            }
            await Task.yield()
        }
    }

    func testP1BindingDriftAndNonAuthoritativeSnapshotFailOpenWithoutFailure()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1BindingDrift-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "reviewed",
                    event: .clipboardWillWritePasteboard,
                    timeoutMilliseconds: 250,
                    failurePolicy: .failClosed
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)

        // The manager's snapshot is authoritative here; mutate only the
        // persisted binding to exercise each independent drift dimension.
        for replacement in [
            BlocksPluginPlatformConfiguration(hooks: [
                .init(id: "reviewed", event: .clipboardWillWritePasteboard,
                      timeoutMilliseconds: 251, failurePolicy: .failClosed),
            ]),
            BlocksPluginPlatformConfiguration(hooks: [
                .init(id: "reviewed", event: .clipboardWillWritePasteboard,
                      timeoutMilliseconds: 250, failurePolicy: .failOpen),
            ]),
        ] {
            try platform.synchronizeManifest(
                pluginID: installed.id,
                platform: replacement
            )
            let result = await runtime.dispatch(
                .init(name: .clipboardWillWritePasteboard)
            )
            XCTAssertTrue(result.allowed)
            XCTAssertEqual(executor.invocationCount, 0)
            XCTAssertEqual(
                try platform.hookBindings(pluginID: installed.id)
                    .first?.consecutiveFailureCount,
                0
            )
        }

        // Removing the binding is the startup-sync equivalent of a manifest
        // hook deletion: the stale runtime snapshot cannot execute it.
        try platform.synchronizeManifest(pluginID: installed.id, platform: .init())
        let missing = await runtime.dispatch(
            .init(name: .clipboardWillWritePasteboard)
        )
        XCTAssertTrue(missing.allowed)
        XCTAssertEqual(executor.invocationCount, 0)

        // A refresh failure leaves the UI snapshot resident, but must never
        // leave it authoritative for a fail-closed hook dispatch.
        database.close()
        await manager.reload()
        XCTAssertFalse(manager.pluginSnapshotIsAuthoritative)
        let nonAuthoritative = await runtime.dispatch(
            .init(name: .clipboardWillWritePasteboard)
        )
        XCTAssertTrue(nonAuthoritative.allowed)
        XCTAssertEqual(executor.invocationCount, 0)
    }

    func testP1DisableInvalidatesSuspendedFailClosedHookSuccessAndCancellation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1Epoch-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = P1SuspendedPlatformExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ), executor: executor, secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let source = try makePackage(
            at: root, capabilities: [.hooks],
            platform: .init(hooks: [
                .init(id: "cutoff", event: .clipboardWillWritePasteboard,
                      failurePolicy: .failClosed),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }

        for reply in [P1SuspendedPlatformExecutor.Reply.success,
                      P1SuspendedPlatformExecutor.Reply.cancelled] {
            let dispatch = Task { @MainActor in
                await runtime.dispatch(.init(
                    name: .clipboardWillWritePasteboard,
                    payload: ["text": .string("original")]
                ))
            }
            await executor.waitUntilStarted()
            _ = try await manager.setEnabled(false, pluginID: installed.id)
            await executor.release(reply)
            let result = await dispatch.value
            let actionInvocationCount = await actionProbe.invocationCount
            XCTAssertTrue(result.allowed)
            XCTAssertEqual(result.envelope.payload["text"], .string("original"))
            XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
            XCTAssertEqual(actionInvocationCount, 0)
            XCTAssertEqual(
                try platform.hookBindings(pluginID: installed.id)
                    .first?.consecutiveFailureCount,
                0
            )
            _ = try await manager.setEnabled(true, pluginID: installed.id)
        }
    }

    func testP1RevokedLifecycleAdmissionSkipsNewFailClosedHookInvocation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1RevokedAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "cutoff",
                    event: .clipboardWillWritePasteboard,
                    failurePolicy: .failClosed
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)

        // Disable/uninstall/upgrade publish this same synchronous cutoff before
        // their first suspension. A binding loaded before it must not allocate
        // a fresh runner or turn a stale fail-closed policy into a host block.
        manager.revokeHostOperations(pluginID: installed.id)
        let result = await runtime.dispatch(.init(
            name: .clipboardWillWritePasteboard,
            payload: ["text": .string("original")]
        ))

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.envelope.payload["text"], .string("original"))
        XCTAssertEqual(executor.invocationCount, 0)
        XCTAssertEqual(
            try platform.hookBindings(pluginID: installed.id)
                .first?.consecutiveFailureCount,
            0
        )
    }

    func testPrivacyBoundHookAdmissionRechecksBeforeRunnerAndPayloadDelivery()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginPrivacyBoundAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let bindingGate = PluginHookBindingsLoadGate()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platform,
            hookBindingsLoadedHook: {
                await bindingGate.suspendAfterLoad()
            }
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks],
            platform: .init(hooks: [
                .init(
                    id: "privacy-bound",
                    event: .clipboardWillPersistCapture,
                    failurePolicy: .failClosed
                ),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        var authorizationGeneration = 1

        let dispatch = Task { @MainActor in
            await runtime.dispatchFromFeature(
                .init(
                    name: .clipboardWillPersistCapture,
                    payload: ["text": .string("privacy-sensitive-sentinel")]
                ),
                admissionIsCurrent: {
                    authorizationGeneration == 1
                }
            )
        }
        await bindingGate.waitUntilSuspended()
        // PrivacyStore advances this generation and the clipboard coordinator
        // cancels this same task when the source is restricted.
        authorizationGeneration = 2
        dispatch.cancel()
        await bindingGate.release()
        let result = await dispatch.value

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(executor.invocationCount, 0)
        XCTAssertNil(executor.lastInvocation)
        XCTAssertEqual(
            try platform.hookBindings(pluginID: installed.id)
                .first?.consecutiveFailureCount,
            0
        )
    }

    func testP1UpgradeInvalidatesSuspendedFailClosedHookReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1UpgradeEpoch-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = P1SuspendedPlatformExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ), executor: executor, secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let declaration = BlocksPluginPlatformConfiguration(hooks: [
            .init(id: "cutoff", event: .clipboardWillWritePasteboard,
                  failurePolicy: .failClosed),
        ])
        let source = try makePackage(
            at: root, pluginID: "com.example.p1-upgrade", version: "1.0.0",
            capabilities: [.hooks], platform: declaration
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let dispatch = Task { @MainActor in
            await runtime.dispatch(.init(
                name: .clipboardWillWritePasteboard,
                payload: ["text": .string("original")]
            ))
        }
        await executor.waitUntilStarted()
        let replacement = try makePackage(
            at: root, directoryName: "P1UpgradeReplacement.blocksplugin",
            pluginID: installed.id, version: "1.0.1",
            capabilities: [.hooks], platform: declaration
        )
        let replacementPending = try await manager.prepareInstallation(
            from: replacement
        )
        _ = try await manager.confirmAndInstall(pendingID: replacementPending.id)
        await executor.release(.success)
        let result = await dispatch.value
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.envelope.payload["text"], .string("original"))
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
        XCTAssertEqual(
            try platform.hookBindings(pluginID: installed.id)
                .first?.consecutiveFailureCount,
            0
        )
    }

    func testP1ScheduleDisableInvalidatesSuspendedSuccessAndCancellation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1ScheduleEpoch-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = P1SuspendedPlatformExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ), executor: executor, secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let schedule = BlocksPluginScheduleDeclaration(
            id: "p1-schedule", kind: .interval,
            configuration: ["seconds": .int(60)]
        )
        let source = try makePackage(
            at: root, capabilities: [.actions],
            platform: .init(
                hostActions: ["system.notification"], schedules: [schedule]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: schedule.id
        )
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }
        let binding = BlocksPluginScheduleBinding(
            pluginID: installed.id, scheduleID: schedule.id, kind: .interval,
            configuration: schedule.configuration, isEnabled: true
        )

        for reply in [P1SuspendedPlatformExecutor.Reply.success,
                      P1SuspendedPlatformExecutor.Reply.cancelled] {
            let task = Task { @MainActor in
                await runtime.executeSchedule(binding)
            }
            await executor.waitUntilStarted()
            _ = try await manager.setEnabled(false, pluginID: installed.id)
            await executor.release(reply)
            await task.value
            let actionInvocationCount = await actionProbe.invocationCount
            XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
            XCTAssertEqual(actionInvocationCount, 0)
            _ = try await manager.setEnabled(true, pluginID: installed.id)
        }
    }

    func testP1RetainedScheduleIDRejectsOldTaskAfterUpgradeBeforeReload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1ScheduleBindingAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RecordingPluginExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let oldSchedule = BlocksPluginScheduleDeclaration(
            id: "retained-schedule",
            kind: .interval,
            entryFunction: "runOldSchedule",
            configuration: ["seconds": .int(1)]
        )
        let source = try makePackage(
            at: root,
            pluginID: "com.example.p1.schedule-binding",
            version: "1.0.0",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["system.notification"],
                schedules: [oldSchedule]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: oldSchedule.id
        )

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        defer { runtime.forceShutdownForApplicationTermination() }
        let scheduleGate = RetainedScheduleTaskGate()
        runtime.scheduleTaskBeforeExecutionHook = {
            await scheduleGate.suspendBeforeExecution()
        }
        runtime.scheduleTaskDidCompleteExecutionHook = {
            await scheduleGate.markExecutionCompleted()
        }
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }
        await runtime.reloadSchedules()
        guard await scheduleGate.waitUntilSuspended() else {
            await scheduleGate.release()
            return XCTFail("The retained schedule task never reached runner admission.")
        }

        let newSchedule = BlocksPluginScheduleDeclaration(
            id: oldSchedule.id,
            kind: .interval,
            entryFunction: "runNewSchedule",
            configuration: ["seconds": .int(60)]
        )
        let replacement = try makePackage(
            at: root,
            directoryName: "ScheduleBindingReplacement.blocksplugin",
            pluginID: installed.id,
            version: "1.0.1",
            capabilities: [.actions],
            platform: .init(
                hostActions: ["system.notification"],
                schedules: [newSchedule]
            )
        )
        let replacementPending = try await manager.prepareInstallation(
            from: replacement
        )
        _ = try await manager.confirmAndInstall(pendingID: replacementPending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: newSchedule.id
        )

        await scheduleGate.release()
        guard await scheduleGate.waitUntilExecutionCompleted() else {
            return XCTFail("The retained schedule task did not complete after release.")
        }
        XCTAssertEqual(executor.invocationCount, 0)
        XCTAssertNil(executor.lastPlatformInvocation)
        let oldHostActionInvocationCount = await actionProbe.invocationCount
        XCTAssertEqual(oldHostActionInvocationCount, 0)

        runtime.scheduleTaskBeforeExecutionHook = nil
        runtime.scheduleTaskDidCompleteExecutionHook = nil
        await runtime.reloadSchedules()
        executor.nextPlatformResult = .init(actions: [
            .init(actionID: "system.notification"),
        ])
        await runtime.executeSchedule(.init(
            pluginID: installed.id,
            scheduleID: newSchedule.id,
            kind: newSchedule.kind,
            configuration: newSchedule.configuration,
            isEnabled: true
        ))
        XCTAssertEqual(executor.invocationCount, 1)
        XCTAssertEqual(
            executor.lastPlatformInvocation?.entryFunction,
            newSchedule.entryFunction
        )
        let newHostActionInvocationCount = await actionProbe.invocationCount
        XCTAssertEqual(newHostActionInvocationCount, 1)
    }

    func testP1RetainedScheduleTaskRejectsOldGenerationBeforeScheduledTriggerHook()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1RetainedScheduleGeneration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = RetainedScheduleGenerationExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let schedule = BlocksPluginScheduleDeclaration(
            id: "retained-schedule",
            kind: .interval,
            entryFunction: "runSchedule",
            configuration: ["seconds": .int(1)]
        )
        let source = try makePackage(
            at: root,
            pluginID: "com.example.p1.retained-schedule-generation",
            capabilities: [.hooks, .actions, .ui],
            platform: .init(
                hooks: [
                    .init(
                        id: "scheduled-trigger",
                        event: .automationScheduledTrigger
                    ),
                ],
                hostActions: ["system.notification"],
                schedules: [schedule]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: schedule.id
        )

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        defer { runtime.forceShutdownForApplicationTermination() }
        let scheduleGate = RetainedScheduleTaskGate()
        runtime.scheduleTaskBeforeExecutionHook = {
            await scheduleGate.suspendBeforeExecution()
        }
        runtime.scheduleTaskDidCompleteExecutionHook = {
            await scheduleGate.markExecutionCompleted()
        }
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }
        await runtime.reloadSchedules()
        guard await scheduleGate.waitUntilSuspended() else {
            await scheduleGate.release()
            return XCTFail("The retained schedule task never reached runner admission.")
        }

        _ = try await manager.setEnabled(false, pluginID: installed.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: schedule.id
        )

        await scheduleGate.release()
        guard await scheduleGate.waitUntilExecutionCompleted() else {
            return XCTFail("The retained schedule task did not complete after release.")
        }
        let oldHookInvocationCount = await executor.platformInvocationCount(
            kind: .hook
        )
        let oldScheduleInvocationCount = await executor.platformInvocationCount(
            kind: .schedule
        )
        let oldHostActionInvocationCount = await actionProbe.invocationCount
        XCTAssertEqual(
            oldHookInvocationCount,
            0,
            "The old task must be rejected before its scheduled-trigger hook."
        )
        XCTAssertEqual(oldScheduleInvocationCount, 0)
        XCTAssertEqual(oldHostActionInvocationCount, 0)

        let currentScheduleGate = RetainedScheduleTaskGate()
        runtime.scheduleTaskBeforeExecutionHook = {
            await currentScheduleGate.suspendBeforeExecution()
        }
        runtime.scheduleTaskDidCompleteExecutionHook = {
            await currentScheduleGate.markExecutionCompleted()
        }
        await runtime.reloadSchedules()
        guard await currentScheduleGate.waitUntilSuspended() else {
            await currentScheduleGate.release()
            return XCTFail("The current schedule task never reached runner admission.")
        }
        await currentScheduleGate.release()
        guard await currentScheduleGate.waitUntilExecutionCompleted() else {
            return XCTFail("The current schedule task did not complete after release.")
        }
        let newHookInvocationCount = await executor.platformInvocationCount(
            kind: .hook
        )
        let newScheduleInvocationCount = await executor.platformInvocationCount(
            kind: .schedule
        )
        let newHostActionInvocationCount = await actionProbe.invocationCount
        XCTAssertEqual(newHookInvocationCount, 1)
        XCTAssertEqual(newScheduleInvocationCount, 1)
        XCTAssertEqual(newHostActionInvocationCount, 1)
    }

    @MainActor
    func testManualTriggerHookLifecycleCutoffSkipsActionRunnerAfterDispatch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginManualTriggerPreflight-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = LifecycleCutoffAfterTriggerHookExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks, .actions, .ui],
            platform: .init(
                hooks: [
                    .init(
                        id: "manual-trigger",
                        event: .automationManualTrigger
                    ),
                ],
                hostActions: ["system.notification"],
                actions: [
                    .init(id: "run", displayName: "Run"),
                ]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        await executor.installLifecycleCutoff { @MainActor in
            manager.revokeHostOperations(pluginID: installed.id)
        }

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }

        do {
            _ = try await runtime.performPluginAction(
                pluginID: installed.id,
                actionID: "run"
            )
            XCTFail("A lifecycle cutoff after the trigger-hook dispatch must reject the action runner.")
        } catch {
            let rejectedByLifecycle: Bool
            if case let .invalidHostOperation(reason) =
                error as? BlocksPluginRuntimeError {
                rejectedByLifecycle = reason == "plugins_disabled_by_safe_mode"
            } else {
                rejectedByLifecycle = false
            }
            XCTAssertTrue(rejectedByLifecycle)
        }

        let hookInvocationCount = await executor.platformInvocationCount(
            kind: .hook
        )
        let actionInvocationCount = await executor.platformInvocationCount(
            kind: .action
        )
        let hostActionInvocationCount = await actionProbe.invocationCount
        XCTAssertEqual(
            hookInvocationCount,
            1,
            "The automation-manual-trigger hook must finish before it publishes the cutoff."
        )
        XCTAssertEqual(actionInvocationCount, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
        XCTAssertEqual(hostActionInvocationCount, 0)
    }

    @MainActor
    func testScheduledTriggerHookLifecycleCutoffSkipsScheduleRunnerAfterDispatch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginScheduledTriggerPreflight-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = LifecycleCutoffAfterTriggerHookExecutor()
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ),
            executor: executor,
            secretStore: RecordingPluginSecretStore(),
            platformRepository: BlocksPluginPlatformRepository(database: database)
        )
        let schedule = BlocksPluginScheduleDeclaration(
            id: "refresh",
            kind: .interval,
            configuration: ["seconds": .int(60)]
        )
        let source = try makePackage(
            at: root,
            capabilities: [.hooks, .actions, .ui],
            platform: .init(
                hooks: [
                    .init(
                        id: "scheduled-trigger",
                        event: .automationScheduledTrigger
                    ),
                ],
                hostActions: ["system.notification"],
                schedules: [schedule]
            )
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        try await manager.setScheduleEnabled(
            true,
            pluginID: installed.id,
            scheduleID: schedule.id
        )
        await executor.installLifecycleCutoff { @MainActor in
            manager.revokeHostOperations(pluginID: installed.id)
        }

        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        let actionProbe = PluginHostActionInvocationProbe()
        runtime.actionRegistry.register("system.notification") { _, _ in
            await actionProbe.recordInvocation()
            return .null
        }
        await runtime.executeSchedule(.init(
            pluginID: installed.id,
            scheduleID: schedule.id,
            kind: schedule.kind,
            configuration: schedule.configuration,
            isEnabled: true
        ))

        let hookInvocationCount = await executor.platformInvocationCount(
            kind: .hook
        )
        let scheduleInvocationCount = await executor.platformInvocationCount(
            kind: .schedule
        )
        let hostActionInvocationCount = await actionProbe.invocationCount
        XCTAssertEqual(
            hookInvocationCount,
            1,
            "The automation-scheduled-trigger hook must finish before it publishes the cutoff."
        )
        XCTAssertEqual(scheduleInvocationCount, 0)
        XCTAssertTrue(runtime.uiStateByPluginID.isEmpty)
        XCTAssertEqual(hostActionInvocationCount, 0)
    }

    @MainActor
    func testP1SettlementGatePluginOutcomeInvalidatesWaitingActionReply()
        async
    {
        let gate = PluginExecutionSettlementGate()
        let failing = gate.captureToken(pluginID: "com.example.settlement")
        let concurrent = gate.captureToken(pluginID: "com.example.settlement")
        let waiterProbe = SettlementWaiterRegistrationProbe()
        let completion = LifecycleCompletionProbe()
        gate.onWaiterRegistered = { waiterProbe.register() }

        gate.beginOutcomeSettlement(failing)
        let waitingReply = Task { @MainActor in
            defer { completion.markCompleted() }
            return await gate.authorizeEffects(concurrent)
        }
        await waiterProbe.waitUntilRegistered()
        XCTAssertFalse(completion.isCompleted)
        gate.finishOutcomeSettlement(failing, invalidatePlugin: true)

        let waitingReplyWasAuthorized = await waitingReply.value
        let failingReplyWasAuthorized = await gate.authorizeEffects(failing)
        XCTAssertFalse(waitingReplyWasAuthorized)
        XCTAssertFalse(failingReplyWasAuthorized)
    }

    @MainActor
    func testP1SettlementGateHookThresholdOnlyInvalidatesSameBinding()
        async
    {
        let gate = PluginExecutionSettlementGate()
        let failing = gate.captureToken(
            pluginID: "com.example.hook-settlement", hookID: "clipboard"
        )
        let sameBinding = gate.captureToken(
            pluginID: "com.example.hook-settlement", hookID: "clipboard"
        )
        let directAction = gate.captureToken(
            pluginID: "com.example.hook-settlement"
        )
        let waiterProbe = SettlementWaiterRegistrationProbe()
        let completion = LifecycleCompletionProbe()
        gate.onWaiterRegistered = { waiterProbe.register() }

        gate.beginOutcomeSettlement(failing)
        let waitingReply = Task { @MainActor in
            defer { completion.markCompleted() }
            return await gate.authorizeEffects(sameBinding)
        }
        await waiterProbe.waitUntilRegistered()
        XCTAssertFalse(completion.isCompleted)
        gate.finishOutcomeSettlement(failing, invalidateHook: true)

        let waitingReplyWasAuthorized = await waitingReply.value
        let directActionWasAuthorized = await gate.authorizeEffects(directAction)
        XCTAssertFalse(waitingReplyWasAuthorized)
        XCTAssertTrue(directActionWasAuthorized)
    }

    @MainActor
    func testP1SettlementGateGlobalReloadBranchesGateReplies() async {
        let disabledGate = PluginExecutionSettlementGate()
        let disabled = disabledGate.captureToken(pluginID: "com.example.reload")
        let disabledProbe = SettlementWaiterRegistrationProbe()
        let disabledCompletion = LifecycleCompletionProbe()
        disabledGate.onWaiterRegistered = { disabledProbe.register() }
        disabledGate.beginGlobalSettlement()
        let disabledReply = Task { @MainActor in
            defer { disabledCompletion.markCompleted() }
            return await disabledGate.authorizeEffects(disabled)
        }
        await disabledProbe.waitUntilRegistered()
        XCTAssertFalse(disabledCompletion.isCompleted)
        disabledGate.finishGlobalSettlement(
            invalidatingPluginIDs: ["com.example.reload"]
        )
        let disabledReplyWasAuthorized = await disabledReply.value
        XCTAssertFalse(disabledReplyWasAuthorized)

        let unchangedGate = PluginExecutionSettlementGate()
        let unchanged = unchangedGate.captureToken(pluginID: "com.example.reload")
        let unchangedProbe = SettlementWaiterRegistrationProbe()
        let unchangedCompletion = LifecycleCompletionProbe()
        unchangedGate.onWaiterRegistered = { unchangedProbe.register() }
        unchangedGate.beginGlobalSettlement()
        let unchangedReply = Task { @MainActor in
            defer { unchangedCompletion.markCompleted() }
            return await unchangedGate.authorizeEffects(unchanged)
        }
        await unchangedProbe.waitUntilRegistered()
        XCTAssertFalse(unchangedCompletion.isCompleted)
        unchangedGate.finishGlobalSettlement()
        let unchangedReplyWasAuthorized = await unchangedReply.value
        XCTAssertTrue(unchangedReplyWasAuthorized)

        let failedGate = PluginExecutionSettlementGate()
        let failed = failedGate.captureToken(pluginID: "com.example.reload")
        let failedProbe = SettlementWaiterRegistrationProbe()
        let failedCompletion = LifecycleCompletionProbe()
        failedGate.onWaiterRegistered = { failedProbe.register() }
        failedGate.beginGlobalSettlement()
        let failedReply = Task { @MainActor in
            defer { failedCompletion.markCompleted() }
            return await failedGate.authorizeEffects(failed)
        }
        await failedProbe.waitUntilRegistered()
        XCTAssertFalse(failedCompletion.isCompleted)
        failedGate.finishGlobalSettlement(invalidateAll: true)
        let failedReplyWasAuthorized = await failedReply.value
        XCTAssertFalse(failedReplyWasAuthorized)
    }

    func testP1HookThresholdSettlementFailsOpenForCurrentFailClosedReply()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1HookThreshold-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = StorageEnvironment(
            rootDirectory: root.appendingPathComponent("Data", isDirectory: true)
        )
        let database = try AppDatabase.open(environment: environment)
        defer { database.close() }
        let executor = P1SuspendedPlatformExecutor()
        let platform = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: BlocksNativePluginMetadataRepository(database: database),
            managedRoot: environment.rootDirectory.appendingPathComponent(
                "TranslationPlugins", isDirectory: true
            ), executor: executor, secretStore: RecordingPluginSecretStore(),
            platformRepository: platform
        )
        let source = try makePackage(
            at: root, capabilities: [.hooks], platform: .init(hooks: [
                .init(id: "threshold", event: .clipboardWillWritePasteboard,
                      failurePolicy: .failClosed),
            ])
        )
        let pending = try await manager.prepareInstallation(from: source)
        let installed = try await manager.confirmAndInstall(pendingID: pending.id)
        _ = try await manager.setEnabled(true, pluginID: installed.id)
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)

        for attempt in 1...3 {
            let dispatch = Task { @MainActor in
                await runtime.dispatch(.init(
                    name: .clipboardWillWritePasteboard,
                    payload: ["text": .string("original")]
                ))
            }
            await executor.waitUntilStarted()
            await executor.release(.cancelled)
            let result = await dispatch.value
            if attempt < 3 {
                XCTAssertFalse(result.allowed)
            } else {
                XCTAssertTrue(result.allowed)
                XCTAssertEqual(result.envelope.payload["text"], .string("original"))
            }
        }
        XCTAssertEqual(
            try platform.hookBindings(pluginID: installed.id).first?.safetyDisabled,
            true
        )
    }

    func testP1OutcomeAndAuditCommitAtomicallyForPluginAndHook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1OutcomeAudit-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: .init(rootDirectory: root)
        )
        defer { database.close() }
        let metadata = BlocksNativePluginMetadataRepository(database: database)
        let platform = BlocksPluginPlatformRepository(database: database)
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4, id: "com.example.p1-outcome-audit",
            displayName: "Outcome Audit", version: "1.0.0",
            entryPoint: "plugin.js", capabilities: [.actions, .hooks],
            platform: .init(hooks: [
                .init(id: "atomic-hook", event: .clipboardWillWritePasteboard),
            ])
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function run() {}",
            packageSHA256: "p1-outcome-audit",
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: manifest.id, displayName: manifest.displayName,
                version: manifest.version, packageSHA256: "p1-outcome-audit",
                isSigned: false, capabilities: manifest.capabilities,
                networkDomains: [], networkMethods: [], secretIDs: []
            )
        )
        _ = try metadata.installApproved(
            package: package, installedRelativePath: manifest.id,
            permissions: manifest.declaredPermissionTokens, domains: []
        )
        try platform.synchronizeManifest(
            pluginID: manifest.id, platform: manifest.platform
        )

        XCTAssertFalse(try platform.recordExecutionOutcomeAndAppendAudit(
            pluginID: manifest.id, succeeded: false, level: .error,
            category: "action", outcome: "failed"
        ))
        XCTAssertFalse(try platform.recordHookExecutionOutcomeAndAppendAudit(
            pluginID: manifest.id, hookID: "atomic-hook", succeeded: false,
            level: .error, category: "hook", outcome: "failed"
        ))

        XCTAssertEqual(
            try metadata.metadata(id: manifest.id).consecutiveFailureCount, 1
        )
        XCTAssertEqual(
            try platform.hookBindings(pluginID: manifest.id)
                .first { $0.hookID == "atomic-hook" }?.consecutiveFailureCount,
            1
        )
        XCTAssertThrowsError(try platform.recordExecutionOutcomeAndAppendAudit(
            pluginID: manifest.id, succeeded: false, level: .error,
            category: "action", outcome: "failed",
            metadata: ["invalid": .double(.nan)]
        ))
        XCTAssertThrowsError(try platform.recordHookExecutionOutcomeAndAppendAudit(
            pluginID: manifest.id, hookID: "atomic-hook", succeeded: false,
            level: .error, category: "hook", outcome: "failed",
            metadata: ["invalid": .double(.nan)]
        ))

        XCTAssertEqual(
            try metadata.metadata(id: manifest.id).consecutiveFailureCount, 1
        )
        XCTAssertEqual(
            try platform.hookBindings(pluginID: manifest.id)
                .first { $0.hookID == "atomic-hook" }?.consecutiveFailureCount,
            1
        )
    }

    func testP1SharedNamespaceRequiresOwnerExportBeforeACLWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginP1SharedACL-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.open(
            environment: .init(rootDirectory: root)
        )
        defer { database.close() }
        let metadata = BlocksNativePluginMetadataRepository(database: database)
        let platform = BlocksPluginPlatformRepository(database: database)

        func package(
            _ manifest: BlocksNativePluginManifest,
            _ hash: String
        ) throws -> BlocksNativePluginValidatedPackage {
            .init(
                manifest: manifest,
                manifestData: try JSONEncoder().encode(manifest),
                entrySource: "function run() {}",
                packageSHA256: hash,
                relativeFilePaths: ["manifest.json", "plugin.js"],
                installationConfirmation: .init(
                    pluginID: manifest.id, displayName: manifest.displayName,
                    version: manifest.version, packageSHA256: hash,
                    isSigned: false, capabilities: manifest.capabilities,
                    networkDomains: [], networkMethods: [], secretIDs: []
                )
            )
        }
        let owner = BlocksNativePluginManifest(
            schemaVersion: 4, id: "com.example.p1-owner",
            displayName: "Owner", version: "1.0.0", entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(sharedState: [
                .init(id: "legal", access: .readWrite),
            ])
        )
        let consumer = BlocksNativePluginManifest(
            schemaVersion: 4, id: "com.example.p1-consumer",
            displayName: "Consumer", version: "1.0.0", entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(sharedState: [
                .init(id: "ghost", ownerPluginID: owner.id, access: .read),
                .init(id: "ghost-write", ownerPluginID: owner.id, access: .write),
            ])
        )
        _ = try metadata.installApproved(
            package: try package(owner, "p1-owner"),
            installedRelativePath: owner.id,
            permissions: owner.declaredPermissionTokens, domains: []
        )
        _ = try metadata.installApproved(
            package: try package(consumer, "p1-consumer"),
            installedRelativePath: consumer.id,
            permissions: consumer.declaredPermissionTokens, domains: []
        )
        _ = try metadata.setEnabled(true, pluginID: owner.id)
        _ = try metadata.setEnabled(true, pluginID: consumer.id)
        XCTAssertThrowsError(
            try platform.synchronizeManifest(
                pluginID: consumer.id, platform: consumer.platform
            )
        )
        XCTAssertThrowsError(
            try platform.grantSharedNamespace(
                ownerPluginID: owner.id, namespace: "ghost",
                consumerPluginID: consumer.id, access: .write
            )
        )
        XCTAssertThrowsError(
            try platform.putSharedValue(
                actorPluginID: consumer.id, ownerPluginID: owner.id,
                namespace: "ghost", key: "x", schemaVersion: 1, value: .int(1)
            )
        )
        XCTAssertNil(try platform.sharedValue(
            actorPluginID: owner.id, ownerPluginID: owner.id,
            namespace: "ghost", key: "x"
        ))

        try platform.grantSharedNamespace(
            ownerPluginID: owner.id, namespace: "legal",
            consumerPluginID: consumer.id, access: .read
        )
        XCTAssertNoThrow(try platform.sharedValue(
            actorPluginID: consumer.id, ownerPluginID: owner.id,
            namespace: "legal", key: "x"
        ))

        // Owner replacement first changes the durable manifest, then sync
        // revokes an over-broad consumer ACL in the same platform transaction.
        try platform.grantSharedNamespace(
            ownerPluginID: owner.id, namespace: "legal",
            consumerPluginID: consumer.id, access: .readWrite
        )
        let narrowedOwner = BlocksNativePluginManifest(
            schemaVersion: 4, id: owner.id, displayName: owner.displayName,
            version: "1.0.1", entryPoint: owner.entryPoint,
            capabilities: owner.capabilities,
            platform: .init(sharedState: [
                .init(id: "legal", access: .read),
            ])
        )
        _ = try metadata.installApproved(
            package: try package(narrowedOwner, "p1-owner-narrowed"),
            installedRelativePath: owner.id,
            permissions: narrowedOwner.declaredPermissionTokens, domains: []
        )
        _ = try metadata.setEnabled(true, pluginID: owner.id)
        try platform.synchronizeManifest(
            pluginID: owner.id, platform: narrowedOwner.platform
        )
        XCTAssertThrowsError(try platform.sharedValue(
            actorPluginID: consumer.id, ownerPluginID: owner.id,
            namespace: "legal", key: "x"
        ))

        let removedOwner = BlocksNativePluginManifest(
            schemaVersion: 4, id: owner.id, displayName: owner.displayName,
            version: "1.0.2", entryPoint: owner.entryPoint,
            capabilities: owner.capabilities, platform: .init()
        )
        _ = try metadata.installApproved(
            package: try package(removedOwner, "p1-owner-removed"),
            installedRelativePath: owner.id,
            permissions: removedOwner.declaredPermissionTokens, domains: []
        )
        _ = try metadata.setEnabled(true, pluginID: owner.id)
        try platform.synchronizeManifest(
            pluginID: owner.id, platform: removedOwner.platform
        )
        XCTAssertThrowsError(try platform.sharedValue(
            actorPluginID: consumer.id, ownerPluginID: owner.id,
            namespace: "legal", key: "x"
        ))
    }
}

// MARK: - Synchronous host-operation lifecycle barriers

@MainActor
final class BlocksPluginHostOperationLifecycleBarrierTests: XCTestCase {
    private let safeModePreferenceKey = "blocks.plugins.safeMode"
    private var previousSafeModePreference: Any?

    override func setUp() async throws {
        try await super.setUp()
        previousSafeModePreference = UserDefaults.standard.object(
            forKey: safeModePreferenceKey
        )
        UserDefaults.standard.set(false, forKey: safeModePreferenceKey)
    }

    override func tearDown() async throws {
        if let previousSafeModePreference {
            UserDefaults.standard.set(
                previousSafeModePreference,
                forKey: safeModePreferenceKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: safeModePreferenceKey)
        }
        previousSafeModePreference = nil
        try await super.tearDown()
    }

    private enum Lifecycle {
        case safeMode
        case disable
        case uninstall
        case forceTermination
        case gracefulTermination
    }

    func testRealHostRouterDrainsAdmittedWritesBeforeEveryLifecycleCutoff()
        async throws
    {
        continueAfterFailure = false
        let safeModeKey = "blocks.plugins.safeMode"
        let defaults = UserDefaults.standard
        let previousSafeMode = defaults.object(forKey: safeModeKey)
        defer {
            if let previousSafeMode {
                defaults.set(previousSafeMode, forKey: safeModeKey)
            } else {
                defaults.removeObject(forKey: safeModeKey)
            }
        }
        for lifecycle in [
            Lifecycle.safeMode,
            .disable,
            .uninstall,
            .forceTermination,
            .gracefulTermination,
        ] {
            try await assertLifecycleCutoff(lifecycle, operation: "storage.put")
            try await assertLifecycleCutoff(lifecycle, operation: "shared.put")
        }
    }

    func testHostRouterWritesResumeOnlyAfterAnExplicitAllow() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        fixture.gate.revokeAndDrain(pluginID: fixture.pluginID)
        XCTAssertFalse(
            fixture.manager.hostOperationRouter.perform(
                fixture.request(operation: "storage.put", value: .int(1))
            ).ok
        )

        fixture.gate.allow(pluginID: fixture.pluginID)
        fixture.barrier.release()
        let restored = fixture.manager.hostOperationRouter.perform(
            fixture.request(operation: "storage.put", value: .int(2))
        )
        XCTAssertTrue(restored.ok)
        XCTAssertEqual(
            try fixture.platformRepository.privateValue(
                pluginID: fixture.pluginID,
                key: "lifecycle-key"
            )?.value,
            .int(2)
        )
    }

    func testSharedConsumerHostRouterFailsClosedWhenOwnerMetadataIsNotRunnable()
        throws
    {
        enum OwnerLifecycle: CaseIterable {
            case disabled
            case safetyDisabled
            case pendingApproval
            case removed
        }

        for lifecycle in OwnerLifecycle.allCases {
            let fixture = try makeSharedAccessFixture()
            defer {
                fixture.database.close()
                try? FileManager.default.removeItem(at: fixture.root)
            }

            let put = fixture.perform(
                operation: "shared.put",
                value: .string("before")
            )
            XCTAssertTrue(put.ok, "\(lifecycle)")
            XCTAssertTrue(fixture.perform(operation: "shared.get").ok, "\(lifecycle)")
            let before = try XCTUnwrap(fixture.ownerValue())
            XCTAssertEqual(before.value, .string("before"), "\(lifecycle)")
            XCTAssertEqual(before.revision, 1, "\(lifecycle)")

            switch lifecycle {
            case .disabled:
                _ = try fixture.metadataRepository.setEnabled(
                    false,
                    pluginID: fixture.ownerPluginID
                )
            case .safetyDisabled:
                XCTAssertTrue(try fixture.platformRepository.recordExecutionOutcome(
                    pluginID: fixture.ownerPluginID,
                    succeeded: false,
                    disableThreshold: 1
                ))
            case .pendingApproval:
                _ = try fixture.metadataRepository.installPending(
                    package: fixture.pendingOwnerPackage,
                    installedRelativePath: fixture.ownerPluginID
                )
            case .removed:
                try fixture.metadataRepository.remove(pluginID: fixture.ownerPluginID)
            }

            XCTAssertFalse(
                fixture.perform(operation: "shared.get").ok,
                "\(lifecycle) owner must no longer expose the namespace."
            )
            XCTAssertFalse(
                fixture.perform(
                    operation: "shared.put",
                    value: .string("after")
                ).ok,
                "\(lifecycle) owner must reject consumer writes."
            )

            switch lifecycle {
            case .removed:
                // Deleting the owner intentionally cascades its shared rows;
                // the rejected consumer write must not recreate one.
                XCTAssertNil(try fixture.ownerValue())
            case .disabled, .safetyDisabled, .pendingApproval:
                let after = try XCTUnwrap(fixture.ownerValue())
                XCTAssertEqual(after.value, before.value, "\(lifecycle)")
                XCTAssertEqual(after.revision, before.revision, "\(lifecycle)")
            }
        }
    }

    func testHostRouterMapsPrivateStorageQuotaToStableCode() throws {
        let fixture = try makeFixture()
        defer {
            fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        fixture.barrier.release()
        let response = fixture.manager.hostOperationRouter.perform(
            fixture.request(
                operation: "storage.put",
                value: .string(String(repeating: "x", count: 1_048_576))
            )
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, "storage_quota_exceeded")
        XCTAssertEqual(
            response.errorMessage,
            "The plugin storage quota was exceeded."
        )
        XCTAssertNil(try fixture.platformRepository.privateValue(
            pluginID: fixture.pluginID,
            key: "lifecycle-key"
        ))
    }

    func testHostRouterEnforcesCompleteStorageKindOperationMatrix() throws {
        func assertRejectedStorageOperation(
            fixture: Fixture,
            operation: String,
            key: String
        ) throws {
            let before = try fixture.platformRepository.privateValue(
                pluginID: fixture.pluginID,
                key: key
            )
            var input: [String: JSONValue] = ["key": .string(key)]
            if operation == "storage.put"
                || operation == "storage.queue.enqueue" {
                input["value"] = .string("rejected mutation")
            }
            let response = fixture.manager.hostOperationRouter.perform(
                .init(
                    pluginID: fixture.pluginID,
                    operation: operation,
                    input: input
                )
            )
            XCTAssertFalse(response.ok, operation)
            XCTAssertEqual(
                response.errorCode,
                "storage_kind_not_declared",
                operation
            )
            let after = try fixture.platformRepository.privateValue(
                pluginID: fixture.pluginID,
                key: key
            )
            XCTAssertEqual(after?.value, before?.value, operation)
            XCTAssertEqual(after?.revision, before?.revision, operation)
        }

        let keyValueOnly = try makeFixture(
            storageKinds: [.keyValue],
            blockAfterAdmission: false
        )
        defer {
            keyValueOnly.database.close()
            try? FileManager.default.removeItem(at: keyValueOnly.root)
        }
        let keyValuePut = keyValueOnly.manager.hostOperationRouter.perform(
            .init(
                pluginID: keyValueOnly.pluginID,
                operation: "storage.put",
                input: [
                    "key": .string("key-value"),
                    "value": .int(1),
                ]
            )
        )
        XCTAssertTrue(keyValuePut.ok)
        XCTAssertEqual(
            try keyValueOnly.platformRepository.privateValue(
                pluginID: keyValueOnly.pluginID,
                key: "key-value"
            )?.value,
            .int(1)
        )
        XCTAssertTrue(keyValueOnly.manager.hostOperationRouter.perform(
            .init(
                pluginID: keyValueOnly.pluginID,
                operation: "storage.get",
                input: ["key": .string("key-value")]
            )
        ).ok)
        _ = try keyValueOnly.platformRepository.putPrivateValue(
            pluginID: keyValueOnly.pluginID,
            key: "queue-probe",
            value: .array([.int(1)])
        )
        try assertRejectedStorageOperation(
            fixture: keyValueOnly,
            operation: "storage.queue.enqueue",
            key: "queue-probe"
        )
        try assertRejectedStorageOperation(
            fixture: keyValueOnly,
            operation: "storage.queue.dequeue",
            key: "queue-probe"
        )

        let queueOnly = try makeFixture(
            storageKinds: [.queue],
            blockAfterAdmission: false
        )
        defer {
            queueOnly.database.close()
            try? FileManager.default.removeItem(at: queueOnly.root)
        }
        let queued = queueOnly.manager.hostOperationRouter.perform(
            .init(
                pluginID: queueOnly.pluginID,
                operation: "storage.queue.enqueue",
                input: [
                    "key": .string("queue"),
                    "value": .int(1),
                ]
            )
        )
        XCTAssertTrue(queued.ok)
        let dequeued = queueOnly.manager.hostOperationRouter.perform(
            .init(
                pluginID: queueOnly.pluginID,
                operation: "storage.queue.dequeue",
                input: ["key": .string("queue")]
            )
        )
        XCTAssertTrue(dequeued.ok)
        XCTAssertEqual(
            try queueOnly.platformRepository.privateValue(
                pluginID: queueOnly.pluginID,
                key: "queue"
            )?.value,
            .array([])
        )
        _ = try queueOnly.platformRepository.putPrivateValue(
            pluginID: queueOnly.pluginID,
            key: "key-value-probe",
            value: .int(1)
        )
        try assertRejectedStorageOperation(
            fixture: queueOnly,
            operation: "storage.get",
            key: "key-value-probe"
        )
        try assertRejectedStorageOperation(
            fixture: queueOnly,
            operation: "storage.put",
            key: "key-value-probe"
        )

        let documentOnly = try makeFixture(
            storageKinds: [.document],
            blockAfterAdmission: false
        )
        defer {
            documentOnly.database.close()
            try? FileManager.default.removeItem(at: documentOnly.root)
        }
        _ = try documentOnly.platformRepository.putPrivateValue(
            pluginID: documentOnly.pluginID,
            key: "document-probe",
            value: .string("stable")
        )
        for operation in [
            "storage.get",
            "storage.put",
            "storage.queue.enqueue",
            "storage.queue.dequeue",
        ] {
            try assertRejectedStorageOperation(
                fixture: documentOnly,
                operation: operation,
                key: "document-probe"
            )
        }
    }

    func testGracefulTerminationDrainsAdmittedResourceReadBeforeShutdown()
        async throws
    {
        let fixture = try makeFixture()
        defer {
            fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let stagedReference = await fixture.runtime.resources.stageTextResource(
            "resource survives the graceful cutoff",
            kind: .text,
            mediaType: "text/plain"
        )
        let reference = try XCTUnwrap(stagedReference)
        fixture.runtime.resources.authorize(
            pluginID: fixture.pluginID,
            resourceIDs: [reference.id]
        )
        let router = fixture.manager.hostOperationRouter
        let admitted = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    continuation.resume(returning: router.perform(.init(
                        pluginID: fixture.pluginID,
                        operation: "resource.read",
                        input: [
                            "resource_id": .string(reference.id),
                            "offset": .int(0),
                            "length": .int(262_144),
                        ]
                    )))
                }
            }
        }
        await fixture.barrier.waitUntilAdmitted()

        let lifecycleFinished = LifecycleCompletionProbe()
        let termination = Task { @MainActor in
            await fixture.runtime.dispatchAppWillTerminate()
            lifecycleFinished.markCompleted()
        }
        while !fixture.gate.isRevoked(pluginID: fixture.pluginID) {
            await Task.yield()
        }
        XCTAssertFalse(lifecycleFinished.isCompleted)

        fixture.barrier.release()
        let response = await admitted.value
        await termination.value

        XCTAssertTrue(response.ok)
        guard case let .object(responseValue)? = response.value else {
            return XCTFail("Expected a resource.read object response.")
        }
        XCTAssertEqual(
            responseValue.string("data_base64"),
            Data("resource survives the graceful cutoff".utf8)
                .base64EncodedString()
        )
        XCTAssertTrue(lifecycleFinished.isCompleted)
        XCTAssertFalse(router.perform(.init(
            pluginID: fixture.pluginID,
            operation: "resource.read",
            input: [
                "resource_id": .string(reference.id),
                "offset": .int(0),
                "length": .int(262_144),
            ]
        )).ok)
    }

    func testSafeModeDrainsAdmittedResourceReadBeforeReportingEnabled()
        async throws
    {
        let fixture = try makeFixture()
        defer {
            fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let stagedReference = await fixture.runtime.resources.stageTextResource(
            "resource survives the safe-mode cutoff",
            kind: .text,
            mediaType: "text/plain"
        )
        let reference = try XCTUnwrap(stagedReference)
        fixture.runtime.resources.authorize(
            pluginID: fixture.pluginID,
            resourceIDs: [reference.id]
        )
        let router = fixture.manager.hostOperationRouter
        let admitted = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    continuation.resume(returning: router.perform(.init(
                        pluginID: fixture.pluginID,
                        operation: "resource.read",
                        input: [
                            "resource_id": .string(reference.id),
                            "offset": .int(0),
                            "length": .int(262_144),
                        ]
                    )))
                }
            }
        }
        await fixture.barrier.waitUntilAdmitted()

        let lifecycleFinished = LifecycleCompletionProbe()
        let transition = Task { @MainActor in
            await fixture.runtime.setSafeModeEnabled(true)
            lifecycleFinished.markCompleted()
        }
        while !fixture.gate.isRevoked(pluginID: fixture.pluginID) {
            await Task.yield()
        }
        XCTAssertFalse(lifecycleFinished.isCompleted)
        XCTAssertTrue(fixture.runtime.safeModeEnabled)

        fixture.barrier.release()
        let response = await admitted.value
        await transition.value

        XCTAssertTrue(response.ok)
        XCTAssertTrue(lifecycleFinished.isCompleted)
        XCTAssertTrue(fixture.runtime.safeModeEnabled)
        XCTAssertFalse(router.perform(.init(
            pluginID: fixture.pluginID,
            operation: "resource.read",
            input: [
                "resource_id": .string(reference.id),
                "offset": .int(0),
                "length": .int(262_144),
            ]
        )).ok)
    }

    private func assertLifecycleCutoff(
        _ lifecycle: Lifecycle,
        operation: String
    ) async throws {
        let fixture = try makeFixture()
        defer {
            fixture.database.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let lifecycleFinished = LifecycleCompletionProbe()
        let router = fixture.manager.hostOperationRouter
        let admittedRequest = fixture.request(operation: operation, value: .int(1))
        let admitted = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    continuation.resume(
                        returning: router.perform(admittedRequest)
                    )
                }
            }
        }
        await fixture.barrier.waitUntilAdmitted()

        var lifecycleTask: Task<Void, Never>?
        let mustDrainBeforeCompletion: Bool
        switch lifecycle {
        case .safeMode:
            lifecycleTask = Task { @MainActor in
                await fixture.runtime.setSafeModeEnabled(true)
                lifecycleFinished.markCompleted()
            }
            mustDrainBeforeCompletion = true
        case .forceTermination:
            fixture.runtime.forceShutdownForApplicationTermination()
            lifecycleFinished.markCompleted()
            mustDrainBeforeCompletion = false
        case .gracefulTermination:
            lifecycleTask = Task { @MainActor in
                await fixture.runtime.dispatchAppWillTerminate()
                lifecycleFinished.markCompleted()
            }
            mustDrainBeforeCompletion = true
        case .disable:
            lifecycleTask = Task { @MainActor in
                _ = try? await fixture.manager.setEnabled(
                    false,
                    pluginID: fixture.pluginID
                )
                lifecycleFinished.markCompleted()
            }
            mustDrainBeforeCompletion = true
        case .uninstall:
            lifecycleTask = Task { @MainActor in
                try? await fixture.manager.uninstall(pluginID: fixture.pluginID)
                lifecycleFinished.markCompleted()
            }
            mustDrainBeforeCompletion = true
        }
        while !fixture.gate.isRevoked(pluginID: fixture.pluginID) {
            await Task.yield()
        }
        if mustDrainBeforeCompletion {
            XCTAssertFalse(
                lifecycleFinished.isCompleted,
                "The lifecycle transition must drain admitted work before completing."
            )
        } else {
            XCTAssertTrue(
                lifecycleFinished.isCompleted,
                "The emergency cutoff must not block the main actor on async leases."
            )
        }

        fixture.barrier.release()
        let admittedResponse = await admitted.value
        await lifecycleTask?.value
        XCTAssertTrue(lifecycleFinished.isCompleted)
        XCTAssertTrue(admittedResponse.ok)

        let rejected = fixture.manager.hostOperationRouter.perform(
            fixture.request(operation: operation, value: .int(2))
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.errorCode, "host_operation_failed")
        XCTAssertEqual(
            rejected.errorMessage,
            "The host operation could not be completed."
        )

        let persistedRevision: Int64?
        if operation == "storage.put" {
            persistedRevision = try fixture.platformRepository.privateValue(
                pluginID: fixture.pluginID,
                key: "lifecycle-key"
            )?.revision
        } else {
            persistedRevision = try? fixture.platformRepository.sharedValue(
                actorPluginID: fixture.pluginID,
                ownerPluginID: fixture.pluginID,
                namespace: "lifecycle-shared",
                key: "lifecycle-key"
            )?.revision
        }
        switch lifecycle {
        case .uninstall:
            // A completed uninstall can cascade-delete the admitted write;
            // a recoverable partial uninstall can retain that first revision.
            // Neither outcome may contain the rejected second write.
            XCTAssertTrue(
                persistedRevision == nil || persistedRevision == 1
            )
            if let metadata = try? fixture.metadataRepository.metadata(
                id: fixture.pluginID
            ) {
                XCTAssertFalse(metadata.isEnabled)
            }
        default:
            XCTAssertEqual(persistedRevision, 1)
        }
    }

    private func makeFixture(
        storageKinds: [BlocksPluginStorageKind] = [.keyValue, .queue],
        blockAfterAdmission: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginHostLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        UserDefaults.standard.set(false, forKey: "blocks.plugins.safeMode")
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let pluginID = "com.example.host-lifecycle"
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: pluginID,
            displayName: "Host lifecycle",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(
                storage: .init(kinds: storageKinds),
                sharedState: [
                    .init(
                        id: "lifecycle-shared",
                        schemaVersion: 1,
                        schema: [:],
                        access: .readWrite
                    ),
                ]
            )
        )
        let package = BlocksNativePluginValidatedPackage(
            manifest: manifest,
            manifestData: try JSONEncoder().encode(manifest),
            entrySource: "function run() {}",
            packageSHA256: "host-lifecycle-fixture",
            relativeFilePaths: ["manifest.json", "plugin.js"],
            installationConfirmation: .init(
                pluginID: pluginID,
                displayName: manifest.displayName,
                version: manifest.version,
                packageSHA256: "host-lifecycle-fixture",
                isSigned: false,
                capabilities: manifest.capabilities,
                networkDomains: [],
                networkMethods: [],
                secretIDs: []
            )
        )
        let metadataRepository = BlocksNativePluginMetadataRepository(
            database: database
        )
        _ = try metadataRepository.installApproved(
            package: package,
            installedRelativePath: pluginID,
            permissions: manifest.declaredPermissionTokens,
            domains: []
        )
        _ = try metadataRepository.setEnabled(true, pluginID: pluginID)
        let validationStore = BlocksNativePluginValidationStore()
        try validationStore.markValidated(
            BlocksNativePluginValidationRevision.make(
                packageHash: package.packageSHA256,
                configuration: [:],
                credentialRevision: 0
            ),
            pluginID: pluginID
        )

        let barrier = HostOperationAdmissionBarrier()
        let admissionCheckpoint: (@Sendable (String) -> Void)?
        if blockAfterAdmission {
            admissionCheckpoint = { _ in barrier.blockAfterAdmission() }
        } else {
            admissionCheckpoint = nil
        }
        let gate = BlocksPluginHostOperationAdmissionGate(
            admissionCheckpoint: admissionCheckpoint
        )
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        let manager = BlocksNativePluginManager(
            repository: metadataRepository,
            managedRoot: root.appendingPathComponent("Managed", isDirectory: true),
            executor: RecordingPluginExecutor(),
            secretStore: RecordingPluginSecretStore(),
            validationStore: validationStore,
            platformRepository: platformRepository,
            hostOperationAdmissionGate: gate
        )
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        return Fixture(
            root: root,
            database: database,
            manager: manager,
            metadataRepository: metadataRepository,
            runtime: runtime,
            platformRepository: platformRepository,
            gate: gate,
            barrier: barrier,
            pluginID: pluginID
        )
    }

    private func makeSharedAccessFixture() throws -> SharedAccessFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlocksPluginSharedOwnerLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        let database = try AppDatabase.open(
            environment: StorageEnvironment(rootDirectory: root)
        )
        let ownerPluginID = "com.example.shared-owner"
        let consumerPluginID = "com.example.shared-consumer"
        let ownerManifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: ownerPluginID,
            displayName: "Shared owner",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(sharedState: [
                .init(id: "shared", access: .readWrite),
            ])
        )
        let consumerManifest = BlocksNativePluginManifest(
            schemaVersion: 4,
            id: consumerPluginID,
            displayName: "Shared consumer",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.actions],
            platform: .init(sharedState: [
                .init(
                    id: "shared",
                    ownerPluginID: ownerPluginID,
                    access: .readWrite
                ),
            ])
        )

        func package(
            _ manifest: BlocksNativePluginManifest,
            hash: String
        ) throws -> BlocksNativePluginValidatedPackage {
            .init(
                manifest: manifest,
                manifestData: try JSONEncoder().encode(manifest),
                entrySource: "function run() {}",
                packageSHA256: hash,
                relativeFilePaths: ["manifest.json", "plugin.js"],
                installationConfirmation: .init(
                    pluginID: manifest.id,
                    displayName: manifest.displayName,
                    version: manifest.version,
                    packageSHA256: hash,
                    isSigned: false,
                    capabilities: manifest.capabilities,
                    networkDomains: [],
                    networkMethods: [],
                    secretIDs: []
                )
            )
        }

        let ownerPackage = try package(ownerManifest, hash: "shared-owner-v1")
        let consumerPackage = try package(
            consumerManifest,
            hash: "shared-consumer-v1"
        )
        let pendingOwnerPackage = try package(
            ownerManifest,
            hash: "shared-owner-v2-pending"
        )
        let metadataRepository = BlocksNativePluginMetadataRepository(
            database: database
        )
        let platformRepository = BlocksPluginPlatformRepository(database: database)
        _ = try metadataRepository.installApproved(
            package: ownerPackage,
            installedRelativePath: ownerPluginID,
            permissions: ownerManifest.declaredPermissionTokens,
            domains: []
        )
        _ = try metadataRepository.installApproved(
            package: consumerPackage,
            installedRelativePath: consumerPluginID,
            permissions: consumerManifest.declaredPermissionTokens,
            domains: []
        )
        _ = try metadataRepository.setEnabled(true, pluginID: ownerPluginID)
        _ = try metadataRepository.setEnabled(true, pluginID: consumerPluginID)
        try platformRepository.synchronizeManifest(
            pluginID: ownerPluginID,
            platform: ownerManifest.platform
        )
        try platformRepository.synchronizeManifest(
            pluginID: consumerPluginID,
            platform: consumerManifest.platform
        )

        let manager = BlocksNativePluginManager(
            repository: metadataRepository,
            managedRoot: root.appendingPathComponent("Managed", isDirectory: true),
            executor: RecordingPluginExecutor(),
            secretStore: RecordingPluginSecretStore(),
            platformRepository: platformRepository
        )
        let runtime = BlocksPluginRuntimeCoordinator(manager: manager)
        return SharedAccessFixture(
            root: root,
            database: database,
            metadataRepository: metadataRepository,
            platformRepository: platformRepository,
            manager: manager,
            runtime: runtime,
            ownerPluginID: ownerPluginID,
            consumerPluginID: consumerPluginID,
            pendingOwnerPackage: pendingOwnerPackage
        )
    }

    private struct Fixture {
        let root: URL
        let database: AppDatabase
        let manager: BlocksNativePluginManager
        let metadataRepository: BlocksNativePluginMetadataRepository
        let runtime: BlocksPluginRuntimeCoordinator
        let platformRepository: BlocksPluginPlatformRepository
        let gate: BlocksPluginHostOperationAdmissionGate
        let barrier: HostOperationAdmissionBarrier
        let pluginID: String

        func request(
            operation: String,
            value: JSONValue
        ) -> BlocksPluginHostOperationRequest {
            var input: [String: JSONValue] = [
                "key": .string("lifecycle-key"),
                "value": value,
            ]
            if operation == "shared.put" {
                input["owner_plugin_id"] = .string(pluginID)
                input["namespace"] = .string("lifecycle-shared")
                input["schema_version"] = .int(1)
            }
            return .init(
                pluginID: pluginID,
                operation: operation,
                input: input
            )
        }
    }

    private struct SharedAccessFixture {
        let root: URL
        let database: AppDatabase
        let metadataRepository: BlocksNativePluginMetadataRepository
        let platformRepository: BlocksPluginPlatformRepository
        let manager: BlocksNativePluginManager
        let runtime: BlocksPluginRuntimeCoordinator
        let ownerPluginID: String
        let consumerPluginID: String
        let pendingOwnerPackage: BlocksNativePluginValidatedPackage

        @MainActor
        func perform(
            operation: String,
            value: JSONValue? = nil
        ) -> BlocksPluginHostOperationResponse {
            var input: [String: JSONValue] = [
                "owner_plugin_id": .string(ownerPluginID),
                "namespace": .string("shared"),
                "key": .string("state"),
            ]
            if let value {
                input["value"] = value
                input["schema_version"] = .int(1)
            }
            return manager.hostOperationRouter.perform(.init(
                pluginID: consumerPluginID,
                operation: operation,
                input: input
            ))
        }

        func ownerValue() throws -> BlocksPluginStoredValue? {
            try platformRepository.sharedValue(
                actorPluginID: ownerPluginID,
                ownerPluginID: ownerPluginID,
                namespace: "shared",
                key: "state"
            )
        }
    }
}

private final class HostOperationAdmissionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var didAdmit = false
    private var admissionContinuation: CheckedContinuation<Void, Never>?

    func blockAfterAdmission() {
        let continuation = lock.withLock {
            didAdmit = true
            defer { admissionContinuation = nil }
            return admissionContinuation
        }
        continuation?.resume()
        releaseGate.wait()
    }

    func waitUntilAdmitted() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !didAdmit else { return true }
                admissionContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseGate.signal()
    }
}

private final class LifecycleCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    var isCompleted: Bool {
        lock.withLock { didComplete }
    }

    func markCompleted() {
        lock.withLock { didComplete = true }
    }
}

private actor DestructiveConfirmationSuspension {
    private var releaseContinuation: CheckedContinuation<Bool, Never>?
    private var pendingDecision: Bool?

    func wait() async -> Bool {
        if let pendingDecision {
            self.pendingDecision = nil
            return pendingDecision
        }
        return await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release(approved: Bool) {
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume(returning: approved)
        } else {
            pendingDecision = approved
        }
    }
}

private actor PluginHostActionInvocationProbe {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}

/// Continuation-only observation point for gate tests. It is signalled only
/// after `authorizeEffects` has appended its continuation to the gate.
private final class SettlementWaiterRegistrationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func register() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            registered = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func waitUntilRegistered() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !registered else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

private actor DeferredPluginPasteLeaseHolder {
    private var lease: BlocksPluginHostOperationAdmissionGate.Lease?

    init(lease: BlocksPluginHostOperationAdmissionGate.Lease) {
        self.lease = lease
    }

    func release() {
        lease?.release()
        lease = nil
    }
}

private actor SuspendedPluginHostActionProbe {
    private(set) var invocationCount = 0
    private var didStart = false
    private var wasReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func perform() async -> JSONValue {
        invocationCount += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !wasReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return .null
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        wasReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class TerminationHookHostOperationExecutor:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let router: BlocksPluginHostOperationRouter
    private let pluginID: String
    private var storedResponse: BlocksPluginHostOperationResponse?

    init(router: BlocksPluginHostOperationRouter, pluginID: String) {
        self.router = router
        self.pluginID = pluginID
    }

    var response: BlocksPluginHostOperationResponse? {
        lock.withLock { storedResponse }
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        if invocation.event?.name == .appWillTerminate {
            let response = router.perform(.init(
                pluginID: pluginID,
                operation: "storage.put",
                input: [
                    "key": .string("termination-hook-write"),
                    "value": .string("must-not-persist"),
                ]
            ))
            lock.withLock { storedResponse = response }
        }
        return .init()
    }
}

private enum PluginManagerInjectedError: Error, Equatable {
    case install
    case list
    case remove
    case secretDelete
    case secretSave
    case installStartTimedOut
    case uninstallCheckpoint
    case upgradeCheckpoint
}

private final class ReloadProbePluginMetadataStore:
    BlocksNativePluginMetadataStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstListGate = DispatchSemaphore(value: 0)
    private let snapshots: [[BlocksNativePluginMetadata]]
    private var listCallCount = 0
    private var activeListCalls = 0
    private var storedMaximumConcurrentListCalls = 0
    private var storedListExecutedOnMainThread = false

    init(snapshots: [[BlocksNativePluginMetadata]]) {
        self.snapshots = snapshots
    }

    var maximumConcurrentListCalls: Int {
        lock.withLock { storedMaximumConcurrentListCalls }
    }

    var listExecutedOnMainThread: Bool {
        lock.withLock { storedListExecutedOnMainThread }
    }

    func waitUntilFirstListStarts() async throws {
        for _ in 0..<400 {
            if lock.withLock({ listCallCount > 0 }) {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw PluginManagerInjectedError.installStartTimedOut
    }

    func releaseFirstList() {
        firstListGate.signal()
    }

    func list() throws -> [BlocksNativePluginMetadata] {
        let callIndex = lock.withLock { () -> Int in
            let index = listCallCount
            listCallCount += 1
            activeListCalls += 1
            storedMaximumConcurrentListCalls = max(
                storedMaximumConcurrentListCalls,
                activeListCalls
            )
            storedListExecutedOnMainThread =
                storedListExecutedOnMainThread || Thread.isMainThread
            return index
        }
        if callIndex == 0 {
            firstListGate.wait()
        }
        defer {
            lock.withLock {
                activeListCalls -= 1
            }
        }
        guard !snapshots.isEmpty else { return [] }
        return snapshots[min(callIndex, snapshots.count - 1)]
    }

    func metadata(id: String) throws -> BlocksNativePluginMetadata {
        throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(id)
    }

    func installApproved(
        package: BlocksNativePluginValidatedPackage,
        installedRelativePath: String,
        permissions: [String],
        domains: [String],
        installationOrigin: BlocksNativePluginInstallationOrigin,
        builtInCatalogVersion: String?,
        now: Date
    ) throws -> BlocksNativePluginMetadata {
        throw PluginManagerInjectedError.install
    }

    func setEnabled(
        _ isEnabled: Bool,
        pluginID: String,
        now: Date
    ) throws -> BlocksNativePluginMetadata {
        throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(pluginID)
    }

    func remove(pluginID: String) throws {
        throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(pluginID)
    }
}

private final class RecordingPluginMetadataStore:
    BlocksNativePluginMetadataStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRecords: [String: BlocksNativePluginMetadata] = [:]
    private var shouldFailNextInstall = false
    private var shouldFailNextRemove = false
    private var shouldFailNextList = false
    private var installGate: DispatchSemaphore?
    private var installDidStart = false
    private var storedRemoveCount = 0

    var records: [BlocksNativePluginMetadata] {
        lock.withLock {
            storedRecords.values.sorted { $0.id < $1.id }
        }
    }

    var removeCount: Int {
        lock.withLock { storedRemoveCount }
    }

    func failNextInstall() {
        lock.withLock {
            shouldFailNextInstall = true
        }
    }

    func failNextRemove() {
        lock.withLock {
            shouldFailNextRemove = true
        }
    }

    func failNextList() {
        lock.withLock {
            shouldFailNextList = true
        }
    }

    func replacePermissions(_ permissions: [String], for pluginID: String) {
        lock.withLock {
            guard let current = storedRecords[pluginID] else { return }
            storedRecords[pluginID] = BlocksNativePluginMetadata(
                id: current.id,
                displayName: current.displayName,
                packageVersion: current.packageVersion,
                packageHash: current.packageHash,
                manifestJSON: current.manifestJSON,
                capabilities: current.capabilities,
                installedRelativePath: current.installedRelativePath,
                installationOrigin: current.installationOrigin,
                builtInCatalogVersion: current.builtInCatalogVersion,
                isEnabled: current.isEnabled,
                approvalStatus: current.approvalStatus,
                approvedPermissions: permissions,
                approvedDomains: current.approvedDomains,
                debugEnabled: current.debugEnabled,
                safetyDisabled: current.safetyDisabled,
                consecutiveFailureCount: current.consecutiveFailureCount,
                installedAt: current.installedAt,
                updatedAt: Date()
            )
        }
    }

    func setSafetyDisabled(_ disabled: Bool, for pluginID: String) {
        lock.withLock {
            guard let current = storedRecords[pluginID] else { return }
            storedRecords[pluginID] = BlocksNativePluginMetadata(
                id: current.id,
                displayName: current.displayName,
                packageVersion: current.packageVersion,
                packageHash: current.packageHash,
                manifestJSON: current.manifestJSON,
                capabilities: current.capabilities,
                installedRelativePath: current.installedRelativePath,
                installationOrigin: current.installationOrigin,
                builtInCatalogVersion: current.builtInCatalogVersion,
                isEnabled: current.isEnabled,
                approvalStatus: current.approvalStatus,
                approvedPermissions: current.approvedPermissions,
                approvedDomains: current.approvedDomains,
                debugEnabled: current.debugEnabled,
                safetyDisabled: disabled,
                consecutiveFailureCount: disabled ? 3 : 0,
                installedAt: current.installedAt,
                updatedAt: Date()
            )
        }
    }

    func pauseNextInstall() {
        lock.withLock {
            installGate = DispatchSemaphore(value: 0)
            installDidStart = false
        }
    }

    func resumeInstall() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            let value = installGate
            installGate = nil
            return value
        }
        gate?.signal()
    }

    func waitUntilInstallStarts() async throws {
        for _ in 0..<200 {
            if lock.withLock({ installDidStart }) {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw PluginManagerInjectedError.installStartTimedOut
    }

    func list() throws -> [BlocksNativePluginMetadata] {
        try lock.withLock {
            if shouldFailNextList {
                shouldFailNextList = false
                throw PluginManagerInjectedError.list
            }
            return storedRecords.values.sorted { $0.id < $1.id }
        }
    }

    func metadata(id: String) throws -> BlocksNativePluginMetadata {
        guard let value = lock.withLock({ storedRecords[id] }) else {
            throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(id)
        }
        return value
    }

    func installApproved(
        package: BlocksNativePluginValidatedPackage,
        installedRelativePath: String,
        permissions: [String],
        domains: [String],
        installationOrigin: BlocksNativePluginInstallationOrigin,
        builtInCatalogVersion: String?,
        now: Date
    ) throws -> BlocksNativePluginMetadata {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            installDidStart = true
            return installGate
        }
        gate?.wait()
        return try lock.withLock {
            if shouldFailNextInstall {
                shouldFailNextInstall = false
                throw PluginManagerInjectedError.install
            }
            let existing = storedRecords[package.manifest.id]
            let metadata = BlocksNativePluginMetadata(
                id: package.manifest.id,
                displayName: package.manifest.displayName,
                packageVersion: package.manifest.version,
                packageHash: package.packageSHA256,
                manifestJSON: String(decoding: package.manifestData, as: UTF8.self),
                capabilities: package.manifest.capabilities,
                installedRelativePath: installedRelativePath,
                installationOrigin: installationOrigin,
                builtInCatalogVersion: builtInCatalogVersion,
                isEnabled: existing?.packageHash == package.packageSHA256
                    ? existing?.isEnabled ?? false
                    : false,
                approvalStatus: .approved,
                approvedPermissions: permissions,
                approvedDomains: domains,
                installedAt: existing?.installedAt ?? now,
                updatedAt: now
            )
            storedRecords[metadata.id] = metadata
            return metadata
        }
    }

    func setEnabled(
        _ isEnabled: Bool,
        pluginID: String,
        now: Date
    ) throws -> BlocksNativePluginMetadata {
        try lock.withLock {
            guard let current = storedRecords[pluginID] else {
                throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(
                    pluginID
                )
            }
            let updated = BlocksNativePluginMetadata(
                id: current.id,
                displayName: current.displayName,
                packageVersion: current.packageVersion,
                packageHash: current.packageHash,
                manifestJSON: current.manifestJSON,
                capabilities: current.capabilities,
                installedRelativePath: current.installedRelativePath,
                isEnabled: isEnabled,
                approvalStatus: current.approvalStatus,
                approvedPermissions: current.approvedPermissions,
                approvedDomains: current.approvedDomains,
                debugEnabled: current.debugEnabled,
                safetyDisabled: current.safetyDisabled,
                consecutiveFailureCount: current.consecutiveFailureCount,
                installedAt: current.installedAt,
                updatedAt: now
            )
            storedRecords[pluginID] = updated
            return updated
        }
    }

    func remove(pluginID: String) throws {
        try lock.withLock {
            if shouldFailNextRemove {
                shouldFailNextRemove = false
                throw PluginManagerInjectedError.remove
            }
            guard storedRecords.removeValue(forKey: pluginID) != nil else {
                throw BlocksNativePluginMetadataRepositoryError.pluginNotFound(
                    pluginID
                )
            }
            storedRemoveCount += 1
        }
    }
}

private final class RecordingPluginSecretStore:
    BlocksNativePluginSecretStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var configuredValues: [String: String] = [:]
    private var storedDeletedKeys: [String] = []
    private var deleteAttempt = 0
    private var failingDeleteAttempt: Int?
    private var shouldFailNextSave = false
    private var storedContainsExecutedOnMainThread = false

    var deletedKeys: [String] {
        lock.withLock { storedDeletedKeys }
    }

    var containsExecutedOnMainThread: Bool {
        lock.withLock { storedContainsExecutedOnMainThread }
    }

    func configure(
        pluginID: String,
        secretID: String,
        value: String = "fixture-secret"
    ) {
        lock.withLock {
            configuredValues["\(pluginID)::\(secretID)"] = value
        }
    }

    func failDelete(atAttempt attempt: Int) {
        lock.withLock {
            deleteAttempt = 0
            failingDeleteAttempt = attempt
        }
    }

    func failNextSave() {
        lock.withLock {
            shouldFailNextSave = true
        }
    }

    func value(pluginID: String, secretID: String) throws -> String? {
        lock.withLock {
            configuredValues["\(pluginID)::\(secretID)"]
        }
    }

    func contains(pluginID: String, secretID: String) throws -> Bool {
        lock.withLock {
            storedContainsExecutedOnMainThread =
                storedContainsExecutedOnMainThread || Thread.isMainThread
            return configuredValues["\(pluginID)::\(secretID)"] != nil
        }
    }

    func save(_ value: String, pluginID: String, secretID: String) throws {
        try lock.withLock {
            if shouldFailNextSave {
                shouldFailNextSave = false
                throw PluginManagerInjectedError.secretSave
            }
            configuredValues["\(pluginID)::\(secretID)"] = value
        }
    }

    func delete(pluginID: String, secretID: String) throws {
        let key = "\(pluginID)::\(secretID)"
        try lock.withLock {
            deleteAttempt += 1
            if deleteAttempt == failingDeleteAttempt {
                failingDeleteAttempt = nil
                throw PluginManagerInjectedError.secretDelete
            }
            configuredValues.removeValue(forKey: key)
            storedDeletedKeys.append(key)
        }
    }
}

private final class PluginRunnerTestHost:
    NSObject,
    NSXPCListenerDelegate,
    BlocksNativePluginRunnerHostXPCProtocol
{
    private let listener = NSXPCListener.anonymous()
    private var acceptedConnections: [NSXPCConnection] = []

    var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    override init() {
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
    }

    func shutdown() {
        listener.suspend()
        acceptedConnections.forEach { $0.invalidate() }
        acceptedConnections.removeAll()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerHostXPCProtocol.self
        )
        newConnection.exportedObject = self
        acceptedConnections.append(newConnection)
        newConnection.resume()
        return true
    }

    func performNetworkRequest(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        reply(nil, "The round-trip fixture does not permit network access.")
    }

    func emitProgress(_ progressData: Data) {}

    func performHostOperation(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        let request = try? JSONDecoder().decode(
            BlocksPluginHostOperationRequest.self,
            from: requestData
        )
        let response = BlocksPluginHostOperationResponse(
            requestID: request?.requestID ?? UUID(),
            ok: false,
            errorCode: "host_operation_unavailable",
            errorMessage: "The round-trip fixture does not expose host operations."
        )
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }
}

private enum PluginXPCIntegrationTestError: Error {
    case metadataMissing
    case unexpectedSecretRequest
    case conditionTimedOut
}

private actor PausablePluginMetadataResolver {
    private var metadata: BlocksNativePluginMetadata
    private(set) var readCount = 0
    private var secondReadContinuation:
        CheckedContinuation<BlocksNativePluginMetadata, Never>?
    private var secondReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(metadata: BlocksNativePluginMetadata) {
        self.metadata = metadata
    }

    func resolve(pluginID: String) async throws -> BlocksNativePluginMetadata {
        guard pluginID == metadata.id else {
            throw PluginXPCIntegrationTestError.metadataMissing
        }
        readCount += 1
        guard readCount == 2 else {
            return metadata
        }
        return await withCheckedContinuation { continuation in
            secondReadContinuation = continuation
            let waiters = secondReadWaiters
            secondReadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSecondReadStarts() async {
        guard readCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondReadWaiters.append(continuation)
        }
    }

    func resumeSecondRead(with metadata: BlocksNativePluginMetadata) {
        self.metadata = metadata
        let continuation = secondReadContinuation
        secondReadContinuation = nil
        continuation?.resume(returning: metadata)
    }
}

final class RecordingPluginXPCConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    var connectionCount: Int {
        lock.withLock { connections.count }
    }

    func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            serviceName: BlocksNativePluginXPC.serviceName
        )
        lock.withLock {
            connections.append(connection)
        }
        return connection
    }

    func connection(at index: Int) -> NSXPCConnection? {
        lock.withLock {
            guard connections.indices.contains(index) else { return nil }
            return connections[index]
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock {
            storage = true
        }
    }

    func claim() -> Bool {
        lock.withLock {
            guard !storage else { return false }
            storage = true
            return true
        }
    }
}

private final class LockedStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func set(_ value: String?) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class LockedTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(initialValue: TimeInterval = 0) {
        storage = initialValue
    }

    var value: TimeInterval {
        lock.withLock { storage }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            storage += interval
        }
    }
}

private final class LockedProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BlocksNativePluginProgress] = []

    var values: [BlocksNativePluginProgress] {
        lock.withLock { storage }
    }

    func append(_ event: BlocksNativePluginProgress) {
        lock.withLock {
            storage.append(event)
        }
    }
}

private final class CancellableTranslationCommunityTransport:
    TranslationCommunityWebHTTPTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var started = false
    private var observedCancellation = false

    var didStart: Bool {
        lock.withLock { started }
    }

    var didObserveCancellation: Bool {
        lock.withLock { observedCancellation }
    }

    func data(
        for request: URLRequest,
        allowedHosts: Set<String>
    ) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            started = true
        }
        do {
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        } catch is CancellationError {
            lock.withLock {
                observedCancellation = true
            }
            throw CancellationError()
        }
    }
}

private final class ClipboardRecordUpdateHostActionExecutor:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedNextAction: BlocksPluginActionInvocation?
    private var storedClipboardRecordUpdatedPayload: [String: JSONValue]?
    private var storedCancelCount = 0

    var nextAction: BlocksPluginActionInvocation? {
        get { lock.withLock { storedNextAction } }
        set { lock.withLock { storedNextAction = newValue } }
    }

    var observedClipboardRecordUpdatedPayload: [String: JSONValue]? {
        lock.withLock { storedClipboardRecordUpdatedPayload }
    }

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    func cancelExecutions(pluginID: String) {
        lock.withLock { storedCancelCount += 1 }
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        if invocation.kind == .hook,
           invocation.event?.name == .clipboardRecordUpdated {
            lock.withLock {
                storedClipboardRecordUpdatedPayload = invocation.event?.payload
            }
            return .init()
        }
        let action = lock.withLock { () -> BlocksPluginActionInvocation? in
            defer { storedNextAction = nil }
            return storedNextAction
        }
        return .init(actions: action.map { [$0] } ?? [])
    }
}

private final class ClipboardTagDeleteHostActionExecutor:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedInvocationCount = 0
    private var storedNextAction: BlocksPluginActionInvocation?
    private var storedClipboardTagChangedPayload: [String: JSONValue]?
    private var storedClipboardTagChangedPayloads: [[String: JSONValue]] = []

    var invocationCount: Int {
        lock.withLock { storedInvocationCount }
    }

    var nextAction: BlocksPluginActionInvocation? {
        get { lock.withLock { storedNextAction } }
        set { lock.withLock { storedNextAction = newValue } }
    }

    var observedClipboardTagChangedPayload: [String: JSONValue]? {
        lock.withLock { storedClipboardTagChangedPayload }
    }

    var observedClipboardTagChangedPayloads: [[String: JSONValue]] {
        lock.withLock { storedClipboardTagChangedPayloads }
    }

    func execute(
        package _: BlocksNativePluginValidatedPackage,
        metadata _: BlocksNativePluginMetadata,
        invocation _: BlocksNativePluginInvocation,
        progress _: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package _: BlocksNativePluginValidatedPackage,
        metadata _: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds _: Double,
        progress _: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        lock.withLock { storedInvocationCount += 1 }
        if invocation.kind == .hook,
           invocation.event?.name == .clipboardTagChanged {
            lock.withLock {
                storedClipboardTagChangedPayload = invocation.event?.payload
                if let payload = invocation.event?.payload {
                    storedClipboardTagChangedPayloads.append(payload)
                }
            }
            return .init()
        }
        let action = lock.withLock { () -> BlocksPluginActionInvocation? in
            defer { storedNextAction = nil }
            return storedNextAction
        }
        return .init(actions: action.map { [$0] } ?? [])
    }
}

@MainActor
private final class FeatureAdmissionCaptureService: ScreenshotCapturing {
    private let capture: ScreenshotCapture

    init(capture: ScreenshotCapture) {
        self.capture = capture
    }

    func capture(
        intent _: ScreenshotCaptureIntent,
        requiresEditingContext _: Bool
    ) async throws -> ScreenshotCapture {
        capture
    }

    func cancelCurrentCapture() {}
}

@MainActor
private final class FeatureAdmissionEditorPresenter: ScreenshotEditorPresenting {
    func prepareForNewCapture() async -> Bool { true }

    func present(
        capture _: ScreenshotCapture,
        retake _: @escaping () -> Void,
        completion _: @escaping (ScreenshotEditorOutcome) async -> Void
    ) {}

    func edit(capture _: ScreenshotCapture) async -> ScreenshotEditorOutcome {
        .cancelled
    }

    func cancelCurrentSession() {}
}

@MainActor
private final class FeatureAdmissionPasteboardWriter: ScreenshotPasteboardWriting {
    private(set) var writeCount = 0

    func write(_ image: NSImage) async throws -> ClipboardPasteboardWriteLease {
        _ = image
        writeCount += 1
        return .init(changeCount: writeCount)
    }

    func write(
        _ artifact: FinalizedScreenshotArtifact
    ) async throws -> ClipboardPasteboardWriteLease {
        try await write(artifact.image)
    }

    func write(
        _ artifact: FinalizedScreenshotArtifact,
        operationAllowed: @escaping @MainActor () -> Bool
    ) async throws -> ClipboardPasteboardWriteLease {
        _ = artifact
        guard operationAllowed() else {
            throw ClipboardAutoPasteError.featureDisabled
        }
        writeCount += 1
        return .init(changeCount: writeCount)
    }
}

@MainActor
private final class FeatureAdmissionArchiveWriter: ScreenshotClipboardArchiving {
    private(set) var archiveCount = 0

    func archive(
        capture _: ScreenshotCapture,
        image _: NSImage,
        automaticallyRecognizesText _: Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        archiveCount += 1
        return .stored
    }

    func archive(
        artifact _: FinalizedScreenshotArtifact,
        automaticallyRecognizesText _: Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        archiveCount += 1
        return .stored
    }

    func archive(
        artifact _: FinalizedScreenshotArtifact,
        automaticallyRecognizesText _: Bool,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> ScreenshotClipboardArchiveResult {
        guard isCurrent() else { return .ignoredFeatureDisabled }
        archiveCount += 1
        return .stored
    }
}

private final class FeatureAdmissionResourceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [String] = []
    private var removed: [String] = []

    func recordRegistered(_ id: String) {
        lock.withLock { registered.append(id) }
    }

    func recordRemoved(_ ids: [String]) {
        lock.withLock { removed.append(contentsOf: ids) }
    }

    func registeredIDs() -> [String] {
        lock.withLock { registered }
    }

    func removedIDs() -> [String] {
        lock.withLock { removed }
    }
}

private final class FeatureAdmissionSuspendedHookExecutor:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let onWillStarted: @Sendable () -> Void
    private let onWillInvocation: @Sendable (Int) -> Void
    private let suspendedWillEvent: BlocksPluginEventName
    private var shouldSuspendFirstWill = true
    private var didNotifyWillStarted = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var storedResourceID: String?
    private var eventNames: [BlocksPluginEventName] = []

    init(
        onWillStarted: @escaping @Sendable () -> Void,
        onWillInvocation: @escaping @Sendable (Int) -> Void = { _ in },
        suspendedWillEvent: BlocksPluginEventName = .screenshotWillFinalizeOutput
    ) {
        self.onWillStarted = onWillStarted
        self.onWillInvocation = onWillInvocation
        self.suspendedWillEvent = suspendedWillEvent
    }

    nonisolated func cancelExecutions(pluginID _: String) {}

    func execute(
        package _: BlocksNativePluginValidatedPackage,
        metadata _: BlocksNativePluginMetadata,
        invocation _: BlocksNativePluginInvocation,
        progress _: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package _: BlocksNativePluginValidatedPackage,
        metadata _: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds _: Double,
        progress _: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        guard let event = invocation.event else { return .init() }
        let willState = lock.withLock {
            () -> (suspend: Bool, notify: Bool, invocationCount: Int) in
            eventNames.append(event.name)
            guard event.name == suspendedWillEvent else {
                return (false, false, 0)
            }
            let invocationCount = eventNames.filter {
                $0 == suspendedWillEvent
            }.count
            storedResourceID = event.resources.first?.id
            let notify = !didNotifyWillStarted
            didNotifyWillStarted = true
            guard shouldSuspendFirstWill, !released else {
                return (false, notify, invocationCount)
            }
            shouldSuspendFirstWill = false
            return (true, notify, invocationCount)
        }
        guard event.name == suspendedWillEvent else {
            return .init()
        }
        if willState.notify { onWillStarted() }
        onWillInvocation(willState.invocationCount)
        if willState.suspend {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        let mutation = BlocksPluginMutation(
            field: event.name == .clipboardWillPersistCapture ? "summary" : "format",
            value: .string(event.name == .clipboardWillPersistCapture ? "updated" : "jpeg")
        )
        return .init(hook: .init(
            mutations: [mutation],
            actions: [.init(actionID: "system.notification")],
            uiStatePatches: [.init(
                componentID: "runtime-status",
                property: "value",
                operation: .replace,
                value: .string("ran")
            )]
        ))
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func releaseCurrentWillAndRearm() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            shouldSuspendFirstWill = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func resourceID() -> String? {
        lock.withLock { storedResourceID }
    }

    func terminalInvocationCount() -> Int {
        lock.withLock {
            eventNames.count {
                $0 == .screenshotOutputFinished || $0 == .screenshotOutputFailed
            }
        }
    }

    func invocationCount(for event: BlocksPluginEventName) -> Int {
        lock.withLock { eventNames.count { $0 == event } }
    }
}

private final class FeatureAdmissionPermissionPause: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !released else { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final class FeatureAdmissionActionExecutor:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var eventNames: [BlocksPluginEventName] = []

    nonisolated func cancelExecutions(pluginID _: String) {}

    func execute(
        package _: BlocksNativePluginValidatedPackage,
        metadata _: BlocksNativePluginMetadata,
        invocation _: BlocksNativePluginInvocation,
        progress _: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package _: BlocksNativePluginValidatedPackage,
        metadata _: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds _: Double,
        progress _: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        guard let event = invocation.event else { return .init() }
        lock.withLock { eventNames.append(event.name) }
        guard event.name == .screenshotOutputFinished else { return .init() }
        return .init(hook: .init(
            actions: [.init(actionID: "system.notification")]
        ))
    }

    func invocationCount(for event: BlocksPluginEventName) -> Int {
        lock.withLock { eventNames.count { $0 == event } }
    }
}

@MainActor
private func featureAdmissionScreenshotImage() throws -> NSImage {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try XCTUnwrap(context.makeImage())
    return NSImage(cgImage: image, size: CGSize(width: 2, height: 2))
}

private func pluginAuditEventCount(
    databaseURL: URL,
    pluginID: String
) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY,
        nil
    ) == SQLITE_OK else {
        throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close(database) }
    let escapedPluginID = pluginID.replacingOccurrences(of: "'", with: "''")
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*) FROM plugin_audit_events WHERE plugin_id = '\(escapedPluginID)'",
        -1,
        &statement,
        nil
    ) == SQLITE_OK else {
        throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw CocoaError(.fileReadUnknown)
    }
    return Int(sqlite3_column_int(statement, 0))
}

private actor AsyncModuleFIFOPluginExecutor: BlocksNativePluginExecuting {
    private var storedMarkers: [String] = []
    private let blockingMarker: String
    private let effectsMarker: String?
    private let onMarker: @Sendable (String) -> Void
    private var blockingContinuation: CheckedContinuation<Void, Never>?
    private var blockingMarkerReleased = false
    private var storedEffectsInvocationCount = 0
    private var markerWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        blockingMarker: String = "screenshot.output_finished:A",
        effectsMarker: String? = nil,
        onMarker: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.blockingMarker = blockingMarker
        self.effectsMarker = effectsMarker
        self.onMarker = onMarker
    }

    nonisolated func cancelExecutions(pluginID: String) {}

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        guard let event = invocation.event else { return .init() }
        let sequence: String
        if case let .string(value)? = event.payload["sequence"] {
            sequence = value
        } else {
            sequence = ""
        }
        let marker = "\(event.name.rawValue):\(sequence)"
        storedMarkers.append(marker)
        onMarker(marker)
        let waiters = markerWaiters.removeValue(forKey: marker) ?? []
        waiters.forEach { $0.resume() }

        if marker == blockingMarker, !blockingMarkerReleased {
            await withCheckedContinuation { continuation in
                blockingContinuation = continuation
            }
        }
        if marker == effectsMarker {
            storedEffectsInvocationCount += 1
            return .init(hook: .init(
                mutations: [.init(field: "text", value: .string("mutated"))],
                actions: [.init(actionID: "system.notification")],
                uiStatePatches: [.init(
                    componentID: "unreachable",
                    property: "value",
                    operation: .replace,
                    value: .string("mutated")
                )]
            ))
        }
        return .init()
    }

    func waitForMarker(_ marker: String) async {
        guard !storedMarkers.contains(marker) else { return }
        await withCheckedContinuation { continuation in
            markerWaiters[marker, default: []].append(continuation)
        }
    }

    func releaseFirstScreenshot() {
        releaseBlockingMarker()
    }

    func releaseBlockingMarker() {
        blockingMarkerReleased = true
        blockingContinuation?.resume()
        blockingContinuation = nil
    }

    func markers() -> [String] {
        storedMarkers
    }

    func effectsInvocationCount() -> Int {
        storedEffectsInvocationCount
    }
}

private actor PluginAsyncCompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private final class CancelledFailClosedHookExecutor:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var readyCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    nonisolated func cancelExecutions(pluginID: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                readyCount += 1
            }
        }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        while !lock.withLock({ readyCount >= 1 }) {
            await Task.yield()
        }
    }
}

private actor HookActionOriginProbe {
    private var origins: [BlocksPluginHostInvocationOrigin] = []
    private var recordedSensitiveEffectCount = 0

    func recordOrigin(_ origin: BlocksPluginHostInvocationOrigin) {
        origins.append(origin)
    }

    func recordSensitiveEffect() {
        recordedSensitiveEffectCount += 1
    }

    func firstOriginIsBackground() -> Bool {
        guard origins.count == 1, case .background = origins[0] else {
            return false
        }
        return true
    }

    func secondOriginIsExplicitUser() -> Bool {
        guard origins.count == 2, case .explicitUser = origins[1] else {
            return false
        }
        return true
    }

    func sensitiveEffectCount() -> Int {
        recordedSensitiveEffectCount
    }
}

private actor ScheduledProviderRequestProbe {
    private var recordedRejectionReason: String?
    private var recordedUnexpectedUserInitiatedInvocationCount = 0

    func recordScheduledRejection() {
        recordedRejectionReason = "provider.request.requires_user_initiated"
    }

    func recordUnexpectedUserInitiatedInvocation() {
        recordedUnexpectedUserInitiatedInvocationCount += 1
    }

    func rejectionReason() -> String? {
        recordedRejectionReason
    }

    func unexpectedUserInitiatedInvocationCount() -> Int {
        recordedUnexpectedUserInitiatedInvocationCount
    }
}

@MainActor
private final class ScreenshotCaptureStartProbe: ScreenshotCapturing {
    private(set) var captureCount = 0

    func capture(
        intent _: ScreenshotCaptureIntent,
        requiresEditingContext _: Bool
    ) async throws -> ScreenshotCapture {
        captureCount += 1
        throw CancellationError()
    }

    func cancelCurrentCapture() {}
}

@MainActor
private final class ScreenshotColorSampleStartProbe {
    private var completion: (@Sendable (NSColor?) -> Void)?
    private(set) var startCount = 0

    func start(
        completion: @escaping @Sendable (NSColor?) -> Void
    ) -> AnyObject {
        startCount += 1
        self.completion = completion
        return self
    }

    func complete(_ color: NSColor?) {
        completion?(color)
    }
}

private actor P1SuspendedPlatformExecutor: BlocksNativePluginExecuting {
    enum Reply: Sendable {
        case success
        case cancelled
    }

    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var replyContinuation: CheckedContinuation<Reply, Never>?

    nonisolated func cancelExecutions(pluginID: String) {}

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let reply = await withCheckedContinuation {
            replyContinuation = $0
        }
        switch reply {
        case .success:
            if invocation.kind == .schedule {
                return .init(
                    actions: [.init(actionID: "system.notification")],
                    uiStatePatches: [.init(
                        componentID: "unreachable", property: "value",
                        operation: .replace, value: .string("mutated")
                    )]
                )
            }
            return .init(hook: .init(
                mutations: [.init(field: "text", value: .string("mutated"))],
                actions: [.init(actionID: "system.notification")],
                uiStatePatches: [.init(
                    componentID: "unreachable", property: "value",
                    operation: .replace, value: .string("mutated")
                )]
            ))
        case .cancelled:
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ reply: Reply) {
        let continuation = replyContinuation
        replyContinuation = nil
        continuation?.resume(returning: reply)
        started = false
    }
}

/// Holds one real scheduler task after its sleep and before runner admission.
/// This models an old task waking while lifecycle code has not yet called the
/// coordinator's asynchronous schedule reload/cancellation path.
private actor RetainedScheduleTaskGate {
    private var suspended = false
    private var executionCompleted = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendBeforeExecution() async {
        guard !suspended else { return }
        suspended = true
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !suspended {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func release() {
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    func markExecutionCompleted() {
        guard !executionCompleted else { return }
        executionCompleted = true
    }

    func waitUntilExecutionCompleted(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !executionCompleted {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Test-only executor that makes the runner-preflight race deterministic. A
/// trigger hook completes, synchronously publishes the lifecycle cutoff, then
/// returns to its dispatch. The caller's immediate post-dispatch preflight must
/// therefore reject the following action or schedule runner invocation.
private actor LifecycleCutoffAfterTriggerHookExecutor: BlocksNativePluginExecuting {
    private var lifecycleCutoff: (@Sendable () async -> Void)?
    private var platformInvocationCounts:
        [BlocksPluginRuntimeInvocationKind: Int] = [:]

    nonisolated func cancelExecutions(pluginID: String) {}

    func installLifecycleCutoff(
        _ lifecycleCutoff: @escaping @Sendable () async -> Void
    ) {
        self.lifecycleCutoff = lifecycleCutoff
    }

    func platformInvocationCount(
        kind: BlocksPluginRuntimeInvocationKind
    ) -> Int {
        platformInvocationCounts[kind, default: 0]
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        platformInvocationCounts[invocation.kind, default: 0] += 1
        if invocation.kind == .hook {
            await lifecycleCutoff?()
            return .init()
        }
        return .init(
            actions: [.init(actionID: "system.notification")],
            uiStatePatches: [
                .init(
                    componentID: "must-not-mutate",
                    property: "value",
                    operation: .replace,
                    value: .string("mutated")
                ),
            ]
        )
    }
}

/// A retained schedule task must be rejected before its trigger hook. The hook
/// deliberately requests a harmless test action so the regression observes
/// both runner admission and the externally visible effect boundary.
private actor RetainedScheduleGenerationExecutor: BlocksNativePluginExecuting {
    private var platformInvocationCounts:
        [BlocksPluginRuntimeInvocationKind: Int] = [:]

    nonisolated func cancelExecutions(pluginID: String) {}

    func platformInvocationCount(
        kind: BlocksPluginRuntimeInvocationKind
    ) -> Int {
        platformInvocationCounts[kind, default: 0]
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        .init(text: "unused")
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        platformInvocationCounts[invocation.kind, default: 0] += 1
        if invocation.kind == .hook {
            return .init(hook: .init(
                actions: [.init(actionID: "system.notification")]
            ))
        }
        return .init()
    }
}

private actor PluginHookBindingsLoadGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendAfterLoad() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
        suspended = false
    }
}

private final class RecordingPluginExecutor: BlocksNativePluginExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocationCount = 0
    private var storedCancelCount = 0
    private var storedCancelledPluginIDs: [String] = []
    private var activeExecutionsByPluginID: [String: Int] = [:]
    private var shouldFailNextExecution = false
    private var storedLastInvocation:
        BlocksNativePluginInvocation?
    private var storedLastPlatformInvocation:
        BlocksPluginRuntimeInvocation?
    private var storedNextPlatformResult: BlocksPluginRuntimeResult?

    var invocationCount: Int {
        lock.lock()
        let value = storedInvocationCount
        lock.unlock()
        return value
    }

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    var cancelledPluginIDs: [String] {
        lock.withLock { storedCancelledPluginIDs }
    }

    var lastInvocation: BlocksNativePluginInvocation? {
        lock.withLock { storedLastInvocation }
    }

    var lastPlatformInvocation: BlocksPluginRuntimeInvocation? {
        lock.withLock { storedLastPlatformInvocation }
    }

    var nextPlatformResult: BlocksPluginRuntimeResult? {
        get { lock.withLock { storedNextPlatformResult } }
        set { lock.withLock { storedNextPlatformResult = newValue } }
    }

    func registerActiveExecution(pluginID: String) {
        lock.withLock {
            activeExecutionsByPluginID[pluginID, default: 0] += 1
        }
    }

    func activeExecutionCount(pluginID: String) -> Int {
        lock.withLock { activeExecutionsByPluginID[pluginID, default: 0] }
    }

    func failNextExecution() {
        lock.withLock {
            shouldFailNextExecution = true
        }
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        let shouldFail = lock.withLock {
            storedInvocationCount += 1
            storedLastInvocation = invocation
            let shouldFail = shouldFailNextExecution
            shouldFailNextExecution = false
            return shouldFail
        }
        if shouldFail {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "fixture_failure",
                message: "Fixture connection failure."
            )
        }
        return BlocksNativePluginOutput(text: "ok")
    }

    func cancelExecutions(pluginID: String) {
        lock.withLock {
            storedCancelCount += 1
            storedCancelledPluginIDs.append(pluginID)
            activeExecutionsByPluginID[pluginID] = 0
        }
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        let shouldFail = lock.withLock {
            storedInvocationCount += 1
            storedLastPlatformInvocation = invocation
            let shouldFail = shouldFailNextExecution
            shouldFailNextExecution = false
            return shouldFail
        }
        if shouldFail {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "fixture_failure",
                message: "Fixture platform failure."
            )
        }
        return lock.withLock { storedNextPlatformResult ?? .init() }
    }
}

@MainActor
private final class ClipboardPluginFailOpenPasteboard:
    ClipboardPasteboardWriting
{
    private(set) var items: [ClipboardPasteboardWriteItem] = []
    private(set) var writeCallCount = 0
    private(set) var changeCount: Int

    init(changeCount: Int) {
        self.changeCount = changeCount
    }

    func writeItems(_ items: [ClipboardPasteboardWriteItem]) -> Bool {
        writeCallCount += 1
        changeCount += 1
        self.items = items
        return true
    }
}

@MainActor
final class PluginCenterCatalogPolicyTests: XCTestCase {
    func testPluginCenterRouteTokenRoundTripsWithoutRebuildingViewIdentity() {
        let routes: [PluginCenterRoute] = [
            .catalog,
            .installed("plugin.sample"),
            .builtIn("builtin.sample"),
        ]

        for route in routes {
            XCTAssertEqual(PluginCenterRoute(token: route.token), route)
        }
        XCTAssertEqual(PluginCenterRoute(token: "unexpected"), .catalog)
    }

    func testBuiltInPresentationLoaderResolvesPackageCopyOffTheViewPath()
        async throws
    {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        let presentations = await BlocksBuiltInPluginPresentationLoader().load(
            catalog: catalog,
            localeIdentifier: "zh_CN"
        )

        XCTAssertEqual(presentations.count, catalog.document.entries.count)
        for entry in catalog.document.entries {
            let presentation = try XCTUnwrap(presentations[entry.id])
            XCTAssertFalse(presentation.purpose.isEmpty)
            XCTAssertFalse(presentation.trigger.isEmpty)
            XCTAssertFalse(presentation.dataUsage.isEmpty)
        }
    }

    func testInstalledBuiltInPluginIsNotRepeatedInCatalog() throws {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        let first = try XCTUnwrap(catalog.document.entries.first)

        let visible = PluginCenterCatalogPolicy.visibleEntries(
            catalog.document.entries,
            installedPluginIDs: [first.id],
            query: ""
        )

        XCTAssertFalse(visible.contains { $0.id == first.id })
        XCTAssertEqual(
            visible.count,
            catalog.document.entries.count - 1
        )
    }

    func testCatalogSearchUsesLocalizedNameAndSummary() throws {
        let catalog = try BlocksBuiltInPluginCatalog.load()
        let first = try XCTUnwrap(catalog.document.entries.first)
        let localization = first.localized()
        let query = String(
            try XCTUnwrap(
                (localization.name.isEmpty
                    ? localization.summary
                    : localization.name).first
            )
        )

        let visible = PluginCenterCatalogPolicy.visibleEntries(
            catalog.document.entries,
            installedPluginIDs: [],
            query: query
        )

        XCTAssertTrue(visible.contains { $0.id == first.id })
    }
}
