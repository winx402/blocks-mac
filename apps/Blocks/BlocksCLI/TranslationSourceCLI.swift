import BlocksCore
import Darwin
import Foundation

private let translationSourceMaximumConfigurationBytes = 1_048_576
private let translationSourceMaximumSecretBytes = 65_536
private let translationSourceMaximumTestTextBytes = 16_384
private let translationSourceMaximumTestImageBytes =
    TranslationSourceImageEncoder.maximumSourceImageBytes

struct TranslationSourceCLIError: Error {
    let code: String
    let message: String

    init(
        code: String = "invalid_arguments",
        message: String
    ) {
        self.code = code
        self.message = message
    }
}

func runTranslationSourceCLI(
    args: [String],
    pluginScope: Bool = false,
    brokerAction: BlocksAction = .translationSourceManage
) -> Never {
    let requestID = ActionRequestID.make()
    do {
        if let local = try executeLocalPackageCommand(
            args,
            pluginScope: pluginScope
        ) {
            if let outputURL = local.scaffoldOutputURL,
               let scaffold = local.result.scaffold {
                try writeScaffold(scaffold, to: outputURL)
            }
            emit(ActionBrokerTerminalResponse.completed(
                requestID: requestID,
                actionID: brokerAction.actionID,
                result: local.result
            ))
        }
        let invocation = try parseTranslationSourceInvocation(args)
        let request = ActionBrokerRequest(
            requestID: requestID,
            actionID: brokerAction.actionID,
            payload: invocation.input.withPluginScope(pluginScope)
        )
        let response = try submitToBroker(
            request,
            outputFile: nil,
            timeout: invocation.timeout,
            resultType: TranslationSourceManagementActionResult.self
        )
        if response.status == .completed,
           let outputURL = invocation.scaffoldOutputURL {
            guard let scaffold = response.result?.scaffold else {
                throw TranslationSourceCLIError(
                    code: "invalid_broker_response",
                    message:
                        "The action host did not return the scaffold files."
                )
            }
            try writeScaffold(
                scaffold,
                to: outputURL
            )
        }
        emit(
            response,
            exitCode: response.status == .completed
                ? 0
                : response.error?.code == "confirmation_required" ? 3 : 1
        )
    } catch let error as TranslationSourceCLIError {
        emitTranslationSourceFailure(
            requestID: requestID,
            action: brokerAction,
            code: error.code,
            message: error.message,
            exitCode: 2
        )
    } catch let error as BlocksNativePluginValidationError {
        emitTranslationSourceFailure(
            requestID: requestID,
            action: brokerAction,
            code: "plugin_package_invalid",
            message: error.localizedDescription,
            exitCode: 2
        )
    } catch let error as TranslationSourceActionValidationError {
        emitTranslationSourceFailure(
            requestID: requestID,
            action: brokerAction,
            code: "plugin_package_invalid",
            message: error.localizedDescription,
            exitCode: 2
        )
    } catch {
        emitTranslationSourceFailure(
            requestID: requestID,
            action: brokerAction,
            code: "broker_unavailable",
            message:
                "BlocksActionBroker is unavailable. Enable CLI integration in Blocks settings.",
            exitCode: 1
        )
    }
}

private struct LocalPackageCommandResult {
    let result: TranslationSourceManagementActionResult
    let scaffoldOutputURL: URL?
}

private func executeLocalPackageCommand(
    _ args: [String],
    pluginScope: Bool
) throws -> LocalPackageCommandResult? {
    guard let command = args.first else { return nil }
    let tail = Array(args.dropFirst())

    switch command {
    case "scaffold":
        let options = try parseScaffoldOptions(
            tail,
            pluginScope: pluginScope
        )
        let scaffold = try BlocksNativePluginScaffoldFactory.make(
            id: options.id,
            displayName: options.displayName,
            pluginScope: pluginScope
        )
        return LocalPackageCommandResult(
            result: TranslationSourceManagementActionResult(
                operation: .scaffold,
                scaffold: scaffold
            ),
            scaffoldOutputURL: options.outputURL
        )

    case "validate":
        guard tail.count == 1 else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks \(pluginScope ? "plugin" : "translation-source") validate PATH.blocksplugin"
            )
        }
        return try localInspectionResult(
            path: tail[0],
            operation: .validatePackage
        )

    case "inspect":
        let path: String?
        if tail.count == 2, tail[0] == "--package" {
            path = tail[1]
        } else if tail.count == 1,
                  isTranslationSourcePackagePath(tail[0]) {
            path = tail[0]
        } else {
            path = nil
        }
        guard let path else { return nil }
        return try localInspectionResult(
            path: path,
            operation: .inspectPackage
        )

    default:
        return nil
    }
}

private func localInspectionResult(
    path: String,
    operation: TranslationSourceManagementOperation
) throws -> LocalPackageCommandResult {
    let package = try BlocksNativePluginPackageValidator().validate(
        directory: URL(fileURLWithPath: path).standardizedFileURL
    )
    return LocalPackageCommandResult(
        result: TranslationSourceManagementActionResult(
            operation: operation,
            inspection: TranslationSourcePackageInspection(
                manifest: package.manifest,
                confirmation: package.installationConfirmation
            )
        ),
        scaffoldOutputURL: nil
    )
}

func runPluginCLI(args: [String]) -> Never {
    let operationID = UUID().uuidString.lowercased()
    do {
        if args.first == "logs", args.dropFirst().first == "follow" {
            try followPluginLogs(
                args: Array(args.dropFirst(2)),
                operationID: operationID
            )
        }
        let execution = try executePluginDevelopmentCommand(
            args,
            operationID: operationID
        )
        emit(PluginCLIEnvelope(
            command: execution.command,
            ok: true,
            operationID: operationID,
            data: execution.data,
            diagnostics: execution.diagnostics
        ))
    } catch let error as PluginCLICommandError {
        emit(
            PluginCLIEnvelope(
                command: args.joined(separator: " "),
                ok: false,
                operationID: operationID,
                data: nil,
                diagnostics: [
                    .init(
                        level: "error",
                        code: error.code,
                        message: error.message
                    ),
                ]
            ),
            exitCode: error.exitCode
        )
    } catch let error as BlocksNativePluginValidationError {
        emit(
            PluginCLIEnvelope(
                command: args.joined(separator: " "),
                ok: false,
                operationID: operationID,
                data: nil,
                diagnostics: [
                    .init(
                        level: "error",
                        code: "plugin_package_invalid",
                        message: error.localizedDescription
                    ),
                ]
            ),
            exitCode: 2
        )
    } catch {
        emit(
            PluginCLIEnvelope(
                command: args.joined(separator: " "),
                ok: false,
                operationID: operationID,
                data: nil,
                diagnostics: [
                    .init(
                        level: "error",
                        code: "plugin_command_failed",
                        message: error.localizedDescription
                    ),
                ]
            ),
            exitCode: 4
        )
    }
}

private struct PluginCLIEnvelope: Codable {
    let schemaVersion = 1
    let command: String
    let ok: Bool
    let operationID: String
    let data: JSONValue?
    let diagnostics: [PluginCLIDiagnostic]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command, ok
        case operationID = "operation_id"
        case data, diagnostics
    }
}

private struct PluginCLIDiagnostic: Codable {
    let level: String
    let code: String
    let message: String
}

private struct PluginCLIExecution {
    let command: String
    let data: JSONValue?
    let diagnostics: [PluginCLIDiagnostic]

    init(
        command: String,
        data: JSONValue? = nil,
        diagnostics: [PluginCLIDiagnostic] = []
    ) {
        self.command = command
        self.data = data
        self.diagnostics = diagnostics
    }
}

private struct PluginCLICommandError: Error {
    let code: String
    let message: String
    let exitCode: Int32

    init(
        _ code: String,
        _ message: String,
        exitCode: Int32 = 2
    ) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }
}

private func executePluginDevelopmentCommand(
    _ args: [String],
    operationID: String
) throws -> PluginCLIExecution {
    guard let command = args.first else {
        throw PluginCLICommandError("invalid_arguments", pluginUsage)
    }
    let tail = Array(args.dropFirst())
    switch command {
    case "init", "scaffold":
        let options = try parseScaffoldOptions(tail, pluginScope: true)
        let scaffold = try BlocksNativePluginScaffoldFactory.make(
            id: options.id,
            displayName: options.displayName,
            pluginScope: true
        )
        try writeScaffold(scaffold, to: options.outputURL)
        return .init(
            command: "plugin init",
            data: .object([
                "path": .string(options.outputURL.path),
                "plugin_id": .string(options.id),
                "schema_version": .int(6),
            ])
        )

    case "api":
        return try pluginAPICommand(tail)

    case "validate":
        let filtered = tail.filter { $0 != "--strict" }
        guard filtered.count == 1,
              tail.count == filtered.count + (tail.contains("--strict") ? 1 : 0) else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin validate PATH.blocksplugin [--strict]"
            )
        }
        let package = try BlocksNativePluginPackageValidator().validate(
            directory: URL(fileURLWithPath: filtered[0]).standardizedFileURL
        )
        return .init(
            command: "plugin validate",
            data: try jsonValue(PluginValidationOutput(
                strict: tail.contains("--strict"),
                packageSHA256: package.packageSHA256,
                manifest: package.manifest,
                permissions: package.installationConfirmation
            ))
        )

    case "doctor":
        guard tail.isEmpty else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin doctor"
            )
        }
        return try pluginDoctor(operationID: operationID)

    case "test":
        return try testPluginPackage(tail)

    case "pack":
        return try packPlugin(tail)

    case "install":
        return try installPluginCommand(tail)

    case "list":
        guard tail.isEmpty || tail == ["--json"] else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin list [--json]"
            )
        }
        return try brokerPluginExecution(
            command: "plugin list",
            input: .init(operation: .list)
        )

    case "inspect":
        guard tail.count == 1 else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin inspect PLUGIN_ID"
            )
        }
        return try brokerPluginExecution(
            command: "plugin inspect",
            input: .init(operation: .inspect, pluginID: tail[0])
        )

    case "configure":
        let parsed = try parseConfigureOptions(tail)
        return try brokerPluginExecution(
            command: "plugin configure",
            input: .init(
                operation: .configure,
                pluginID: parsed.sourceID,
                configuration: parsed.configuration
            )
        )

    case "secret":
        guard tail.count == 4,
              tail[0] == "set",
              tail[3] == "--stdin" else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin secret set PLUGIN_ID FIELD_ID --stdin"
            )
        }
        var data = try readBounded(
            from: .standardInput,
            maximumBytes: translationSourceMaximumSecretBytes,
            label: "secret"
        )
        while data.last == 0x0A || data.last == 0x0D { data.removeLast() }
        guard let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty else {
            throw PluginCLICommandError(
                "invalid_secret",
                "Secret input must be non-empty UTF-8 read from stdin."
            )
        }
        return try brokerPluginExecution(
            command: "plugin secret set",
            input: .init(
                operation: .setSecret,
                pluginID: tail[1],
                secretID: tail[2],
                secretValue: secret
            )
        )

    case "enable", "disable":
        guard tail.count == 1 else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin \(command) PLUGIN_ID"
            )
        }
        return try brokerPluginExecution(
            command: "plugin \(command)",
            input: .init(
                operation: command == "enable" ? .enable : .disable,
                pluginID: tail[0]
            )
        )

    case "invoke":
        return try invokePluginCommand(tail)

    case "debug":
        guard tail.count == 2,
              ["on", "off"].contains(tail[1]) else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin debug PLUGIN_ID on|off"
            )
        }
        return try brokerPluginExecution(
            command: "plugin debug",
            input: .init(
                operation: .setDebug,
                pluginID: tail[0],
                debugEnabled: tail[1] == "on"
            )
        )

    case "logs":
        return try pluginLogsCommand(tail)

    case "safety-reset":
        guard tail.count == 2, tail[1] == "--confirm" else {
            throw PluginCLICommandError(
                "confirmation_required",
                "Usage: blocks plugin safety-reset PLUGIN_ID --confirm",
                exitCode: 3
            )
        }
        return try brokerPluginExecution(
            command: "plugin safety-reset",
            input: .init(
                operation: .clearSafetyDisable,
                pluginID: tail[0],
                confirmed: true
            )
        )

    case "catalog":
        return try pluginCatalogCommand(tail)

    case "remove":
        guard tail.count == 2, tail[1] == "--confirm" else {
            throw PluginCLICommandError(
                "confirmation_required",
                "Usage: blocks plugin remove PLUGIN_ID --confirm",
                exitCode: 3
            )
        }
        return try brokerPluginExecution(
            command: "plugin remove",
            input: .init(
                operation: .remove,
                pluginID: tail[0],
                confirmed: true
            )
        )

    default:
        throw PluginCLICommandError(
            "unknown_command",
            "Unknown plugin command: \(command).\n\(pluginUsage)"
        )
    }
}

private struct PluginValidationOutput: Codable {
    let strict: Bool
    let packageSHA256: String
    let manifest: BlocksNativePluginManifest
    let permissions: BlocksNativePluginInstallationConfirmation

    init(
        strict: Bool,
        packageSHA256: String,
        manifest: BlocksNativePluginManifest,
        permissions: BlocksNativePluginInstallationConfirmation
    ) {
        self.strict = strict
        self.packageSHA256 = packageSHA256
        self.manifest = manifest
        self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey {
        case strict
        case packageSHA256 = "package_sha256"
        case manifest, permissions
    }
}

private struct PluginEventFixture: Decodable {
    let kind: BlocksPluginRuntimeInvocationKind
    let name: String?
    let actionID: String?
    let scheduleID: String?
    let payload: [String: JSONValue]?
    let source: [String: JSONValue]?
    let input: [String: JSONValue]?
    let configuration: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case kind, name, payload, source, input, configuration
        case actionID = "action_id"
        case scheduleID = "schedule_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(
            BlocksPluginRuntimeInvocationKind.self,
            forKey: .kind
        ) ?? .hook
        name = try container.decodeIfPresent(String.self, forKey: .name)
        actionID = try container.decodeIfPresent(
            String.self,
            forKey: .actionID
        )
        scheduleID = try container.decodeIfPresent(
            String.self,
            forKey: .scheduleID
        )
        payload = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .payload
        )
        source = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .source
        )
        input = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .input
        )
        configuration = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .configuration
        )
    }
}

private struct PluginExpectedFixture: Decodable, Equatable {
    let diagnosticCodes: [String]
    let hostActions: [String]
    let uiPatchIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case diagnosticCodes = "diagnostic_codes"
        case hostActions = "host_actions"
        case uiPatchIDs = "ui_patch_ids"
    }

    init(
        diagnosticCodes: [String],
        hostActions: [String],
        uiPatchIDs: [String] = []
    ) {
        self.diagnosticCodes = diagnosticCodes
        self.hostActions = hostActions
        self.uiPatchIDs = uiPatchIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diagnosticCodes = try container.decodeIfPresent(
            [String].self,
            forKey: .diagnosticCodes
        ) ?? []
        hostActions = try container.decodeIfPresent(
            [String].self,
            forKey: .hostActions
        ) ?? []
        uiPatchIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .uiPatchIDs
        ) ?? []
    }
}

private struct PluginTestOutput: Codable {
    let kind: String
    let declarationID: String
    let entryFunction: String
    let diagnosticCodes: [String]
    let hostActions: [String]
    let uiPatchIDs: [String]
    let output: [String: JSONValue]
    let matchedExpectation: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind
        case declarationID = "declaration_id"
        case entryFunction = "entry_function"
        case diagnosticCodes = "diagnostic_codes"
        case hostActions = "host_actions"
        case uiPatchIDs = "ui_patch_ids"
        case output
        case matchedExpectation = "matched_expectation"
    }
}

private func pluginAPICommand(
    _ args: [String]
) throws -> PluginCLIExecution {
    guard args.first == "list" || args.first == "show" else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin api list [--json] | show CAPABILITY_ID"
        )
    }
    let actions = BlocksPluginHostAPIV2.actionIDs.sorted()
    let events = BlocksPluginEventName.allCases.map(\.rawValue).sorted()
    let slots = BlocksPluginUISlot.allCases.map(\.rawValue).sorted()
    if args[0] == "list" {
        guard args.count == 1 || args == ["list", "--json"] else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin api list [--json]"
            )
        }
        return .init(
            command: "plugin api list",
            data: .object([
                "host_api_version": .int(BlocksPluginHostAPIV2.version),
                "actions": .array(actions.map(JSONValue.string)),
                "events": .array(events.map(JSONValue.string)),
                "ui_slots": .array(slots.map(JSONValue.string)),
                "resource_kinds": .array(
                    BlocksPluginResourceKind.allCases.map { .string($0.rawValue) }
                ),
            ])
        )
    }
    guard args.count == 2 else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin api show CAPABILITY_ID"
        )
    }
    let id = args[1]
    let kind: String
    if actions.contains(id) { kind = "action" }
    else if events.contains(id) { kind = "event" }
    else if slots.contains(id) { kind = "ui_slot" }
    else {
        throw PluginCLICommandError(
            "capability_not_found",
            "No public plugin capability named \(id)."
        )
    }
    return .init(
        command: "plugin api show",
        data: .object([
            "id": .string(id),
            "kind": .string(kind),
            "host_api_version": .int(BlocksPluginHostAPIV2.version),
            "schema": .object([:]),
        ])
    )
}

private protocol PluginDoctorRunnerProbing {
    func probe() throws
}

private struct EmbeddedPluginDoctorRunnerProbe: PluginDoctorRunnerProbing {
    private static let expectedText = "blocks-plugin-doctor-ready"

    func probe() throws {
        let manifest = BlocksNativePluginManifest(
            schemaVersion: 3,
            id: "com.blocks.plugin-doctor-probe",
            displayName: "Blocks Plugin Doctor Probe",
            version: "1.0.0",
            entryPoint: "plugin.js",
            capabilities: [.translation],
            translation: .init(acceptedInputs: [.text])
        )
        let request = BlocksNativePluginRunnerRequest(
            manifest: manifest,
            entrySource: """
            function translate() {
              return { status: "completed", text: "\(Self.expectedText)" };
            }
            """,
            invocation: .init(
                pluginID: manifest.id,
                kind: .translation,
                input: ["text": .string("")]
            ),
            executionTimeLimitSeconds: 1
        )
        let response = BlocksNativePluginJavaScriptRunner(
            networkBroker: { _ in
                throw PluginCLICommandError(
                    "network_disabled",
                    "Doctor does not perform network requests.",
                    exitCode: 4
                )
            }
        ).execute(request)
        guard response.status == .completed,
              response.output?.status == .completed,
              response.output?.text == Self.expectedText else {
            throw PluginCLICommandError(
                "javascript_runner_probe_failed",
                "The isolated JavaScript runner probe did not complete.",
                exitCode: 4
            )
        }
    }
}

private func pluginDoctor(
    operationID _: String,
    runnerProbe: any PluginDoctorRunnerProbing =
        EmbeddedPluginDoctorRunnerProbe()
) throws -> PluginCLIExecution {
    try runnerProbe.probe()
    do {
        let host = try submitPluginBroker(.init(operation: .list))
        return .init(
            command: "plugin doctor",
            data: .object([
                "host_api_version": .int(BlocksPluginHostAPIV2.version),
                "manifest_schema_version": .int(
                    BlocksNativePluginManifest.currentSchemaVersion
                ),
                "javascript_runner": .string("ready"),
                "blocks_host": .string("ready"),
                "installed_plugin_count": .int(host.plugins.count),
            ])
        )
    } catch let error as PluginCLICommandError {
        throw PluginCLICommandError(
            error.code,
            error.message,
            exitCode: 5
        )
    }
}

private func testPluginPackage(
    _ args: [String]
) throws -> PluginCLIExecution {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin test PATH.blocksplugin --event FIXTURE [--expect EXPECTED]"
        )
    }
    var eventPath: String?
    var expectedPath: String?
    var index = 1
    while index < args.count {
        guard args.indices.contains(index + 1) else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Missing value for \(args[index])."
            )
        }
        switch args[index] {
        case "--event": eventPath = args[index + 1]
        case "--expect": expectedPath = args[index + 1]
        default:
            throw PluginCLICommandError(
                "invalid_arguments",
                "Unknown plugin test option: \(args[index])"
            )
        }
        index += 2
    }
    guard let eventPath else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Plugin test requires --event FIXTURE."
        )
    }
    let package = try BlocksNativePluginPackageValidator().validate(
        directory: URL(fileURLWithPath: path).standardizedFileURL
    )
    let fixture = try JSONDecoder().decode(
        PluginEventFixture.self,
        from: readBoundedFile(
            path: eventPath,
            maximumBytes: 1_048_576,
            label: "event_fixture"
        )
    )
    let declarationID: String
    let entryFunction: String
    let envelope: BlocksPluginEventEnvelope?
    switch fixture.kind {
    case .hook:
        guard let name = fixture.name,
              let event = BlocksPluginEventName(rawValue: name),
              let hook = package.manifest.platform?.hooks.first(where: {
                  $0.event == event
              }) else {
            throw PluginCLICommandError(
                "fixture_event_not_subscribed",
                "The package does not subscribe to the fixture event.",
                exitCode: 4
            )
        }
        declarationID = hook.id
        entryFunction = hook.entryFunction
        envelope = BlocksPluginEventEnvelope(
            name: event,
            source: fixture.source ?? ["fixture": .bool(true)],
            payload: fixture.payload ?? [:]
        )
    case .action, .uiAction:
        guard let actionID = fixture.actionID,
              let action = package.manifest.platform?.actions.first(where: {
                  $0.id == actionID
              }) else {
            throw PluginCLICommandError(
                "fixture_action_not_declared",
                "The package does not declare the fixture action.",
                exitCode: 4
            )
        }
        declarationID = action.id
        entryFunction = action.entryFunction
        envelope = nil
    case .schedule:
        guard let scheduleID = fixture.scheduleID,
              let schedule = package.manifest.platform?.schedules.first(where: {
                  $0.id == scheduleID
              }) else {
            throw PluginCLICommandError(
                "fixture_schedule_not_declared",
                "The package does not declare the fixture schedule.",
                exitCode: 4
            )
        }
        declarationID = schedule.id
        entryFunction = schedule.entryFunction
        envelope = nil
    }
    let invocation = BlocksPluginRuntimeInvocation(
        pluginID: package.manifest.id,
        kind: fixture.kind,
        entryFunction: entryFunction,
        event: envelope,
        input: fixture.input ?? [:],
        configuration: fixture.configuration ?? [:]
    )
    let runner = BlocksNativePluginJavaScriptRunner(
        networkBroker: { _ in
            throw PluginCLICommandError(
                "fixture_network_not_stubbed",
                "The isolated test fixture did not provide a network stub.",
                exitCode: 4
            )
        },
        hostOperationBroker: { request in
            BlocksPluginHostOperationResponse(
                requestID: request.requestID,
                ok: true,
                value: .object([
                    "stubbed": .bool(true),
                    "operation": .string(request.operation),
                ])
            )
        }
    )
    let response = runner.executePlatform(.init(
        manifest: package.manifest,
        entrySource: package.entrySource,
        invocation: invocation,
        executionTimeLimitSeconds: 2
    ))
    guard response.status == .completed, let result = response.result else {
        throw PluginCLICommandError(
            response.errorCode ?? "plugin_test_failed",
            response.errorMessage ?? "The isolated plugin test failed.",
            exitCode: 4
        )
    }
    let actual = PluginExpectedFixture(
        diagnosticCodes: result.diagnostics.map(\.code),
        hostActions: (result.hook?.actions ?? result.actions).map(\.actionID),
        uiPatchIDs: (result.hook?.uiStatePatches ?? result.uiStatePatches)
            .map(\.componentID)
    )
    let expected: PluginExpectedFixture? = try expectedPath.map {
        try JSONDecoder().decode(
            PluginExpectedFixture.self,
            from: readBoundedFile(
                path: $0,
                maximumBytes: 1_048_576,
                label: "expected_fixture"
            )
        )
    }
    if let expected, expected != actual {
        throw PluginCLICommandError(
            "fixture_expectation_failed",
            "Plugin output did not match the expected fixture.",
            exitCode: 4
        )
    }
    return .init(
        command: "plugin test",
        data: try jsonValue(PluginTestOutput(
            kind: fixture.kind.rawValue,
            declarationID: declarationID,
            entryFunction: entryFunction,
            diagnosticCodes: actual.diagnosticCodes,
            hostActions: actual.hostActions,
            uiPatchIDs: actual.uiPatchIDs,
            output: result.output,
            matchedExpectation: expected.map { $0 == actual }
        ))
    )
}

private func packPlugin(_ args: [String]) throws -> PluginCLIExecution {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin pack PATH.blocksplugin --output OUTPUT.blocksplugin"
        )
    }
    guard args.count == 3, args[1] == "--output" else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin pack PATH.blocksplugin --output OUTPUT.blocksplugin"
        )
    }
    let source = URL(fileURLWithPath: path).standardizedFileURL
    let destination = URL(fileURLWithPath: args[2]).standardizedFileURL
    guard destination.pathExtension == "blocksplugin",
          source != destination,
          !FileManager.default.fileExists(atPath: destination.path) else {
        throw PluginCLICommandError(
            "invalid_output",
            "The output must be a new .blocksplugin directory."
        )
    }
    let package = try BlocksNativePluginPackageValidator().validate(
        directory: source
    )
    try FileManager.default.copyItem(at: source, to: destination)
    do {
        let packed = try BlocksNativePluginPackageValidator().validate(
            directory: destination
        )
        guard packed.packageSHA256 == package.packageSHA256 else {
            throw PluginCLICommandError(
                "pack_hash_mismatch",
                "The packed package hash changed during copy.",
                exitCode: 4
            )
        }
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
    return .init(
        command: "plugin pack",
        data: .object([
            "path": .string(destination.path),
            "package_sha256": .string(package.packageSHA256),
        ])
    )
}

private func installPluginCommand(
    _ args: [String]
) throws -> PluginCLIExecution {
    if args.count == 2, args[0] == "--plan" {
        let package = try BlocksNativePluginPackageValidator().validate(
            directory: URL(fileURLWithPath: args[1]).standardizedFileURL
        )
        return .init(
            command: "plugin install --plan",
            data: try jsonValue(PluginValidationOutput(
                strict: true,
                packageSHA256: package.packageSHA256,
                manifest: package.manifest,
                permissions: package.installationConfirmation
            )),
            diagnostics: [
                .init(
                    level: "info",
                    code: "confirmation_required",
                    message: "Review the plan, then use --apply with --confirm-hash."
                ),
            ]
        )
    }
    guard args.count == 4,
          args[0] == "--apply",
          args[2] == "--confirm-hash" else {
        throw PluginCLICommandError(
            "confirmation_required",
            "Usage: blocks plugin install --plan PATH | --apply PATH --confirm-hash SHA256",
            exitCode: 3
        )
    }
    let snapshot = try TranslationSourcePackageSnapshot.validatingPackage(
        at: URL(fileURLWithPath: args[1]).standardizedFileURL
    )
    return try brokerPluginExecution(
        command: "plugin install --apply",
        input: .init(
            operation: .install,
            package: snapshot,
            confirmationSHA256: args[3]
        ),
        timeout: 120
    )
}

private func invokePluginCommand(
    _ args: [String]
) throws -> PluginCLIExecution {
    let usage = "Usage: blocks plugin invoke PLUGIN_ID ACTION_ID [--file PATH | --stdin] [--confirm]"
    let parsed: PluginDevelopmentInvokeArguments
    do {
        parsed = try PluginDevelopmentInvokeArguments.parse(args)
    } catch {
        throw PluginCLICommandError(
            "invalid_arguments",
            usage
        )
    }
    let input: [String: JSONValue]
    switch parsed.inputSource {
    case .none:
        input = [:]
    case .standardInput, .file:
        let data: Data
        switch parsed.inputSource {
        case .standardInput:
            data = try readBounded(
                from: .standardInput,
                maximumBytes: 1_048_576,
                label: "action_input"
            )
        case let .file(path):
            data = try readBoundedFile(
                path: path,
                maximumBytes: 1_048_576,
                label: "action_input"
            )
        case .none:
            preconditionFailure("The no-input case is handled before reading input data.")
        }
        input = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: data
        )
    }
    return try brokerPluginExecution(
        command: "plugin invoke",
        input: .init(
            operation: .invoke,
            pluginID: parsed.pluginID,
            actionID: parsed.actionID,
            actionInput: input,
            confirmed: parsed.confirmed
        ),
        timeout: 60
    )
}

private func pluginLogsCommand(
    _ args: [String]
) throws -> PluginCLIExecution {
    guard let command = args.first else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin logs show|follow|export|clear ..."
        )
    }
    switch command {
    case "show":
        guard args.count == 2 else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin logs show PLUGIN_ID"
            )
        }
        return try brokerPluginExecution(
            command: "plugin logs show",
            input: .init(
                operation: .showLogs,
                pluginID: args[1]
            )
        )
    case "export":
        guard args.count == 4, args[2] == "--output" else {
            throw PluginCLICommandError(
                "invalid_arguments",
                "Usage: blocks plugin logs export PLUGIN_ID --output PATH"
            )
        }
        let result = try submitPluginBroker(.init(
            operation: .showLogs,
            pluginID: args[1],
            maximumLogBytes: 1_048_576
        ))
        let output = URL(fileURLWithPath: args[3]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw PluginCLICommandError(
                "output_exists",
                "The log export destination already exists."
            )
        }
        try Data((result.logs ?? "").utf8).write(
            to: output,
            options: .withoutOverwriting
        )
        return .init(
            command: "plugin logs export",
            data: .object(["path": .string(output.path)])
        )
    case "clear":
        guard args.count == 3, args[2] == "--confirm" else {
            throw PluginCLICommandError(
                "confirmation_required",
                "Usage: blocks plugin logs clear PLUGIN_ID --confirm",
                exitCode: 3
            )
        }
        return try brokerPluginExecution(
            command: "plugin logs clear",
            input: .init(
                operation: .clearLogs,
                pluginID: args[1],
                confirmed: true
            )
        )
    default:
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin logs show|follow|export|clear ..."
        )
    }
}

private func followPluginLogs(
    args: [String],
    operationID: String
) throws -> Never {
    guard args.count == 1 else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin logs follow PLUGIN_ID"
        )
    }
    let pluginID = args[0]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var previous = ""
    while true {
        let result = try submitPluginBroker(.init(
            operation: .showLogs,
            pluginID: pluginID
        ))
        let current = result.logs ?? ""
        if current != previous {
            let envelope = PluginCLIEnvelope(
                command: "plugin logs follow",
                ok: true,
                operationID: operationID,
                data: .object(["logs": .string(current)]),
                diagnostics: []
            )
            FileHandle.standardOutput.write(try encoder.encode(envelope))
            FileHandle.standardOutput.write(Data("\n".utf8))
            previous = current
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

private func pluginCatalogCommand(
    _ args: [String]
) throws -> PluginCLIExecution {
    if args == ["list"] || args == ["list", "--json"] {
        return try brokerPluginExecution(
            command: "plugin catalog list",
            input: .init(operation: .catalogList)
        )
    }
    guard args.first == "install", args.count >= 2 else {
        throw PluginCLICommandError(
            "invalid_arguments",
            "Usage: blocks plugin catalog list [--json] | install CATALOG_ID --plan | install CATALOG_ID --apply --confirm-hash SHA256"
        )
    }
    let catalogID = args[1]
    if args.count == 3, args[2] == "--plan" {
        let execution = try brokerPluginExecution(
            command: "plugin catalog install --plan",
            input: .init(
                operation: .catalogInstall,
                catalogID: catalogID
            ),
            timeout: 120
        )
        return .init(
            command: execution.command,
            data: execution.data,
            diagnostics: [
                .init(
                    level: "info",
                    code: "confirmation_required",
                    message: "Review the plan, then use --apply with --confirm-hash."
                ),
            ]
        )
    }
    guard args.count == 5,
          args[2] == "--apply",
          args[3] == "--confirm-hash" else {
        let exitCode: Int32 = args.dropFirst(2).first == "--apply" ? 3 : 2
        throw PluginCLICommandError(
            exitCode == 3 ? "confirmation_required" : "invalid_arguments",
            "Usage: blocks plugin catalog install CATALOG_ID --plan | --apply --confirm-hash SHA256",
            exitCode: exitCode
        )
    }
    return try brokerPluginExecution(
        command: "plugin catalog install --apply",
        input: .init(
            operation: .catalogInstall,
            confirmationSHA256: args[4],
            confirmed: true,
            catalogID: catalogID
        ),
        timeout: 120
    )
}

private func brokerPluginExecution(
    command: String,
    input: PluginDevelopmentActionInput,
    timeout: TimeInterval = 30
) throws -> PluginCLIExecution {
    let result = try submitPluginBroker(input, timeout: timeout)
    return .init(command: command, data: try jsonValue(result))
}

private func submitPluginBroker(
    _ input: PluginDevelopmentActionInput,
    timeout: TimeInterval = 30
) throws -> PluginDevelopmentActionResult {
    let request = ActionBrokerRequest(
        requestID: ActionRequestID.make(),
        actionID: BlocksAction.pluginManage.actionID,
        payload: input
    )
    let response = try submitToBroker(
        request,
        outputFile: nil,
        timeout: timeout,
        resultType: PluginDevelopmentActionResult.self
    )
    guard response.status == .completed, let result = response.result else {
        let code = response.error?.code ?? "plugin_operation_failed"
        let exitCode: Int32
        if code == "broker_unavailable" { exitCode = 5 }
        else if code.contains("confirmation") || code.contains("permission") {
            exitCode = 3
        } else { exitCode = 4 }
        throw PluginCLICommandError(
            code,
            response.error?.message ?? "The plugin operation failed.",
            exitCode: exitCode
        )
    }
    return result
}

private func jsonValue<Value: Encodable>(
    _ value: Value
) throws -> JSONValue {
    try JSONDecoder().decode(
        JSONValue.self,
        from: JSONEncoder().encode(value)
    )
}

private struct TranslationSourceCLIInvocation {
    let input: TranslationSourceManagementActionInput
    let timeout: TimeInterval
    let scaffoldOutputURL: URL?
}

private func parseTranslationSourceInvocation(
    _ args: [String]
) throws -> TranslationSourceCLIInvocation {
    guard let command = args.first else {
        throw TranslationSourceCLIError(
            message: translationSourceUsage
        )
    }
    let tail = Array(args.dropFirst())
    switch command {
    case "list":
        guard tail.isEmpty || tail == ["--json"] else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source list [--json]"
            )
        }
        return invocation(.init(operation: .list))

    case "scaffold":
        let options = try parseScaffoldOptions(tail)
        return TranslationSourceCLIInvocation(
            input: TranslationSourceManagementActionInput(
                operation: .scaffold,
                scaffoldID: options.id,
                scaffoldDisplayName: options.displayName
            ),
            timeout: 30,
            scaffoldOutputURL: options.outputURL
        )

    case "validate":
        let package = try parseSinglePackage(tail, command: command)
        return invocation(.init(
            operation: .validatePackage,
            package: package
        ))

    case "inspect":
        guard !tail.isEmpty else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source inspect SOURCE_ID | --package PATH"
            )
        }
        if tail.first == "--package" {
            guard tail.count == 2 else {
                throw TranslationSourceCLIError(
                    message:
                        "Usage: blocks translation-source inspect PATH.blocksplugin | SOURCE_ID"
                )
            }
            return invocation(.init(
                operation: .inspectPackage,
                package: try loadPackage(at: tail[1])
            ))
        }
        guard tail.count == 1 else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source inspect SOURCE_ID"
            )
        }
        if isTranslationSourcePackagePath(tail[0]) {
            return invocation(.init(
                operation: .inspectPackage,
                package: try loadPackage(at: tail[0])
            ))
        }
        return invocation(.init(
            operation: .inspectInstalled,
            sourceID: tail[0]
        ))

    case "install":
        let options = try parseInstallOptions(tail)
        return invocation(
            .init(
                operation: .install,
                package: try loadPackage(at: options.path),
                confirmationSHA256: options.confirmationSHA256
            ),
            timeout: 120
        )

    case "configure":
        let options = try parseConfigureOptions(tail)
        return invocation(.init(
            operation: .configure,
            sourceID: options.sourceID,
            configuration: options.configuration
        ))

    case "secret":
        return try parseSecretInvocation(tail)

    case "test":
        let options = try parseTestOptions(tail)
        return invocation(
            .init(
                operation: .test,
                sourceID: options.sourceID,
                testText: options.testText,
                testImage: options.testImage,
                capability: options.capability
            ),
            timeout: 90
        )

    case "enable", "disable":
        guard tail.count == 1 else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source \(command) SOURCE_ID"
            )
        }
        return invocation(.init(
            operation: command == "enable" ? .enable : .disable,
            sourceID: tail[0]
        ))

    case "reorder":
        guard !tail.isEmpty else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source reorder SOURCE_ID [SOURCE_ID ...]"
            )
        }
        return invocation(.init(
            operation: .reorder,
            orderedSourceIDs: tail
        ))

    case "export":
        guard tail.count == 2,
              tail[1] == "--redact-secrets" else {
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source export SOURCE_ID --redact-secrets"
            )
        }
        return invocation(.init(
            operation: .exportRedacted,
            sourceID: tail[0]
        ))

    case "debug":
        guard tail.count == 2,
              ["on", "off"].contains(tail[1]) else {
            throw TranslationSourceCLIError(
                message: "Usage: blocks plugin debug PLUGIN_ID on|off"
            )
        }
        return invocation(.init(
            operation: .setDebug,
            sourceID: tail[0],
            debugEnabled: tail[1] == "on"
        ))

    case "logs":
        guard tail.count == 3,
              tail[0] == "clear",
              tail[2] == "--confirm" else {
            throw TranslationSourceCLIError(
                code: "confirmation_required",
                message: "Usage: blocks plugin logs clear PLUGIN_ID --confirm"
            )
        }
        return invocation(.init(
            operation: .clearLogs,
            sourceID: tail[1],
            confirmed: true
        ))

    case "safety-reset":
        guard tail.count == 2, tail[1] == "--confirm" else {
            throw TranslationSourceCLIError(
                code: "confirmation_required",
                message: "Usage: blocks plugin safety-reset PLUGIN_ID --confirm"
            )
        }
        return invocation(.init(
            operation: .clearSafetyDisable,
            sourceID: tail[0],
            confirmed: true
        ))

    case "remove":
        guard tail.count == 2,
              tail[1] == "--confirm" else {
            throw TranslationSourceCLIError(
                code: "confirmation_required",
                message:
                    "Usage: blocks translation-source remove SOURCE_ID --confirm"
            )
        }
        return invocation(.init(
            operation: .remove,
            sourceID: tail[0],
            confirmed: true
        ))

    default:
        throw TranslationSourceCLIError(
            message:
                "Unknown translation-source command: \(command).\n\(translationSourceUsage)"
        )
    }
}

private func invocation(
    _ input: TranslationSourceManagementActionInput,
    timeout: TimeInterval = 30
) -> TranslationSourceCLIInvocation {
    TranslationSourceCLIInvocation(
        input: input,
        timeout: timeout,
        scaffoldOutputURL: nil
    )
}

private struct ScaffoldOptions {
    let id: String
    let displayName: String
    let outputURL: URL
}

private func parseScaffoldOptions(
    _ args: [String],
    pluginScope: Bool = false
) throws -> ScaffoldOptions {
    let defaultID = pluginScope
        ? "com.example.blocks.plugin"
        : "com.example.blocks.translation-source"
    let defaultDisplayName = pluginScope
        ? "Custom Blocks Plugin"
        : "Custom Translation Source"
    let defaultOutputName = pluginScope
        ? "CustomBlocksPlugin.blocksplugin"
        : "CustomTranslationSource.blocksplugin"
    var id: String?
    var displayName: String?
    var outputPath: String?
    var index = 0
    var seen = Set<String>()
    while index < args.count {
        let option = args[index]
        guard ["--id", "--name", "--output"].contains(option) else {
            throw TranslationSourceCLIError(
                message: "Unknown scaffold option: \(option)"
            )
        }
        try rejectDuplicateSourceOption(option, seen: &seen)
        let value = try sourceOptionValue(
            after: option,
            index: index,
            args: args
        )
        switch option {
        case "--id": id = value
        case "--name": displayName = value
        case "--output": outputPath = value
        default: break
        }
        index += 2
    }
    let outputURL = outputPath.map {
        URL(fileURLWithPath: $0).standardizedFileURL
    } ?? URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(defaultOutputName, isDirectory: true)
    guard outputURL.pathExtension == "blocksplugin" else {
        throw TranslationSourceCLIError(
            message: "The scaffold output must end in .blocksplugin."
        )
    }
    return ScaffoldOptions(
        id: id ?? defaultID,
        displayName: displayName ?? defaultDisplayName,
        outputURL: outputURL
    )
}

private struct InstallOptions {
    let path: String
    let confirmationSHA256: String
}

private func parseInstallOptions(
    _ args: [String]
) throws -> InstallOptions {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw TranslationSourceCLIError(
            message:
                "Usage: blocks translation-source install PATH.blocksplugin --confirm-hash SHA256"
        )
    }
    var confirmationSHA256: String?
    var index = 1
    var seen = Set<String>()
    while index < args.count {
        let option = args[index]
        guard option == "--confirm-hash" else {
            throw TranslationSourceCLIError(
                message: "Unknown install option: \(option)"
            )
        }
        try rejectDuplicateSourceOption(option, seen: &seen)
        confirmationSHA256 = try sourceOptionValue(
            after: option,
            index: index,
            args: args
        )
        index += 2
    }
    guard let confirmationSHA256,
          confirmationSHA256.count == 64,
          confirmationSHA256.allSatisfy(\.isHexDigit) else {
        throw TranslationSourceCLIError(
            code: "confirmation_required",
            message:
                "Review `validate` or `inspect --package`, then pass its 64-character SHA-256 with --confirm-hash."
        )
    }
    return InstallOptions(
        path: path,
        confirmationSHA256:
            confirmationSHA256.lowercased()
    )
}

private struct ConfigureOptions {
    let sourceID: String
    let configuration: [String: JSONValue]
}

private func parseConfigureOptions(
    _ args: [String]
) throws -> ConfigureOptions {
    guard let sourceID = args.first, !sourceID.hasPrefix("--") else {
        throw TranslationSourceCLIError(
            message:
                "Usage: blocks translation-source configure SOURCE_ID (--file PATH | --stdin)"
        )
    }
    let options = Array(args.dropFirst())
    let data: Data
    if options == ["--stdin"] {
        data = try readBounded(
            from: .standardInput,
            maximumBytes:
                translationSourceMaximumConfigurationBytes,
            label: "configuration"
        )
    } else if options.count == 2, options[0] == "--file" {
        data = try readBoundedFile(
            path: options[1],
            maximumBytes:
                translationSourceMaximumConfigurationBytes
        )
    } else {
        throw TranslationSourceCLIError(
            message:
                "Usage: blocks translation-source configure SOURCE_ID (--file PATH | --stdin)"
        )
    }
    let configuration: [String: JSONValue]
    do {
        configuration = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: data
        )
    } catch {
        throw TranslationSourceCLIError(
            code: "invalid_configuration",
            message:
                "Configuration input must be one JSON object."
        )
    }
    return ConfigureOptions(
        sourceID: sourceID,
        configuration: configuration
    )
}

private func parseSecretInvocation(
    _ args: [String]
) throws -> TranslationSourceCLIInvocation {
    guard args.count == 4,
          args[0] == "set",
          args[3] == "--stdin" else {
        throw TranslationSourceCLIError(
            message:
                "Usage: blocks translation-source secret set SOURCE_ID SECRET_ID --stdin"
        )
    }
    var data = try readBounded(
        from: .standardInput,
        maximumBytes: translationSourceMaximumSecretBytes,
        label: "secret"
    )
    if data.last == 0x0A {
        data.removeLast()
        if data.last == 0x0D {
            data.removeLast()
        }
    }
    guard let value = String(data: data, encoding: .utf8),
          !value.isEmpty else {
        throw TranslationSourceCLIError(
            code: "invalid_secret",
            message:
                "Secret input must be non-empty UTF-8 read from stdin."
        )
    }
    return invocation(.init(
        operation: .setSecret,
        sourceID: args[1],
        secretID: args[2],
        secretValue: value
    ))
}

private struct TestOptions {
    let sourceID: String
    let capability: BlocksNativePluginCapability
    let testText: String?
    let testImage: TranslationSourceEncodedImage?
}

private func parseTestOptions(
    _ args: [String]
) throws -> TestOptions {
    guard let sourceID = args.first, !sourceID.hasPrefix("--") else {
        throw TranslationSourceCLIError(
            message:
                "Usage: blocks translation-source test SOURCE_ID [--stdin] [--image PATH] [--capability translation|ocr]"
        )
    }
    let tail = Array(args.dropFirst())
    var capability = BlocksNativePluginCapability.translation
    var readsTestText = false
    var imagePath: String?
    var index = 0
    var seen = Set<String>()
    while index < tail.count {
        let option = tail[index]
        try rejectDuplicateSourceOption(option, seen: &seen)
        switch option {
        case "--stdin":
            readsTestText = true
            index += 1
        case "--image":
            imagePath = try sourceOptionValue(
                after: option,
                index: index,
                args: tail
            )
            index += 2
        case "--capability":
            let value = try sourceOptionValue(
                after: option,
                index: index,
                args: tail
            )
            guard let parsed = BlocksNativePluginCapability(
                rawValue: value
            ) else {
                throw TranslationSourceCLIError(
                    message:
                        "Capability must be translation or ocr."
                )
            }
            capability = parsed
            index += 2
        default:
            throw TranslationSourceCLIError(
                message:
                    "Usage: blocks translation-source test SOURCE_ID [--stdin] [--image PATH] [--capability translation|ocr]"
            )
        }
    }
    let testText: String?
    if readsTestText {
        var data = try readBounded(
            from: .standardInput,
            maximumBytes: translationSourceMaximumTestTextBytes,
            label: "test_text"
        )
        while data.last == 0x0A || data.last == 0x0D {
            data.removeLast()
        }
        guard let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw TranslationSourceCLIError(
                code: "invalid_test_text",
                message:
                    "Test input must be non-empty UTF-8 read from stdin."
            )
        }
        testText = value
    } else {
        testText = nil
    }
    let testImage: TranslationSourceEncodedImage?
    if let imagePath {
        let sourceData = try readBoundedFile(
            path: imagePath,
            maximumBytes: translationSourceMaximumTestImageBytes,
            label: "test_image"
        )
        do {
            testImage = try TranslationSourceImageEncoder.encode(
                sourceData: sourceData
            )
        } catch let error as TranslationSourceImageEncodingError {
            throw TranslationSourceCLIError(
                code: "invalid_test_image",
                message: error.localizedDescription
            )
        }
    } else {
        testImage = nil
    }
    return TestOptions(
        sourceID: sourceID,
        capability: capability,
        testText: testText,
        testImage: testImage
    )
}

private func isTranslationSourcePackagePath(
    _ argument: String
) -> Bool {
    if URL(fileURLWithPath: argument).pathExtension == "blocksplugin" {
        return true
    }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: argument,
        isDirectory: &isDirectory
    ) && isDirectory.boolValue
}

private func parseSinglePackage(
    _ args: [String],
    command: String
) throws -> TranslationSourcePackageSnapshot {
    guard args.count == 1 else {
        throw TranslationSourceCLIError(
            message:
                "Usage: blocks translation-source \(command) PATH.blocksplugin"
        )
    }
    return try loadPackage(at: args[0])
}

private func loadPackage(
    at path: String
) throws -> TranslationSourcePackageSnapshot {
    try TranslationSourcePackageSnapshot.validatingPackage(
        at: URL(fileURLWithPath: path).standardizedFileURL
    )
}

private func requireNoArguments(
    _ args: [String],
    command: String
) throws {
    guard args.isEmpty else {
        throw TranslationSourceCLIError(
            message:
                "`\(command)` does not accept arguments."
        )
    }
}

private func sourceOptionValue(
    after option: String,
    index: Int,
    args: [String]
) throws -> String {
    guard args.indices.contains(index + 1),
          !args[index + 1].hasPrefix("--") else {
        throw TranslationSourceCLIError(
            message: "Missing value for \(option)."
        )
    }
    return args[index + 1]
}

private func rejectDuplicateSourceOption(
    _ option: String,
    seen: inout Set<String>
) throws {
    guard seen.insert(option).inserted else {
        throw TranslationSourceCLIError(
            message: "Duplicate option: \(option)"
        )
    }
}

private func readBounded(
    from handle: FileHandle,
    maximumBytes: Int,
    label: String
) throws -> Data {
    do {
        let data = try handle.read(
            upToCount: maximumBytes + 1
        ) ?? Data()
        guard data.count <= maximumBytes else {
            throw TranslationSourceCLIError(
                code: "\(label)_too_large",
                message:
                    "The \(label) input exceeds \(maximumBytes) bytes."
            )
        }
        return data
    } catch let error as TranslationSourceCLIError {
        throw error
    } catch {
        throw TranslationSourceCLIError(
            code: "\(label)_read_failed",
            message: "Unable to read \(label) input."
        )
    }
}

private func readBoundedFile(
    path: String,
    maximumBytes: Int,
    label: String = "configuration"
) throws -> Data {
    let descriptor = path.withCString {
        Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw TranslationSourceCLIError(
            code: "\(label)_read_failed",
            message: "Unable to open the \(label) file."
        )
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG else {
        Darwin.close(descriptor)
        throw TranslationSourceCLIError(
            code: "\(label)_read_failed",
            message:
                "The \(label) path must be a regular file."
        )
    }
    let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: true
    )
    return try readBounded(
        from: handle,
        maximumBytes: maximumBytes,
        label: label
    )
}

private func writeScaffold(
    _ scaffold: TranslationSourceScaffold,
    to outputURL: URL
) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard !fileManager.fileExists(
        atPath: outputURL.path,
        isDirectory: &isDirectory
    ) else {
        throw TranslationSourceCLIError(
            code: "output_exists",
            message:
                "The scaffold destination already exists."
        )
    }
    do {
        try fileManager.createDirectory(
            at: outputURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for (relativePath, data) in scaffold.files.sorted(by: {
            $0.key < $1.key
        }) {
            let components = relativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard !components.isEmpty,
                  components.allSatisfy({
                      $0 != "." && $0 != ".."
                  }) else {
                throw TranslationSourceCLIError(
                    code: "invalid_scaffold",
                    message:
                        "The action host returned an invalid scaffold path."
                )
            }
            let destination = outputURL.appendingPathComponent(
                relativePath
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: destination, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }
        _ = try BlocksNativePluginPackageValidator()
            .validate(directory: outputURL)
    } catch {
        try? fileManager.removeItem(at: outputURL)
        throw error
    }
}

private func emitTranslationSourceFailure(
    requestID: ActionRequestID,
    action: BlocksAction = .translationSourceManage,
    code: String,
    message: String,
    exitCode: Int32
) -> Never {
    emitActionFailure(
        actionID: action.actionID,
        requestID: requestID,
        error: ActionBrokerError(
            category: .invalidRequest,
            code: code,
            message: message,
            retryable: false
        ),
        resultType:
            TranslationSourceManagementActionResult.self,
        exitCode: exitCode
    )
}

let translationSourceUsage = """
translation sources:
  blocks translation-source list [--json]
  blocks translation-source scaffold [--id ID --name NAME --output PATH.blocksplugin]
  blocks translation-source validate PATH.blocksplugin
  blocks translation-source inspect SOURCE_ID
  blocks translation-source inspect PATH.blocksplugin
  blocks translation-source install PATH.blocksplugin --confirm-hash SHA256
  blocks translation-source configure SOURCE_ID (--file PATH | --stdin)
  blocks translation-source secret set SOURCE_ID SECRET_ID --stdin
  blocks translation-source test SOURCE_ID [--stdin] [--image PATH] [--capability translation|ocr]
  blocks translation-source enable SOURCE_ID
  blocks translation-source disable SOURCE_ID
  blocks translation-source reorder SOURCE_ID [SOURCE_ID ...]
  blocks translation-source export SOURCE_ID --redact-secrets
  blocks translation-source remove SOURCE_ID --confirm
"""

let pluginUsage = """
Blocks plugin development and management

  blocks plugin init [--id ID --name NAME --output PATH.blocksplugin]
  blocks plugin api list [--json]
  blocks plugin api show CAPABILITY_ID
  blocks plugin validate PATH.blocksplugin [--strict]
  blocks plugin doctor
  blocks plugin test PATH.blocksplugin --event FIXTURE [--expect EXPECTED]
  blocks plugin pack PATH.blocksplugin [--output PATH.blocksplugin]
  blocks plugin install --plan PATH.blocksplugin
  blocks plugin install --apply PATH.blocksplugin --confirm-hash SHA256
  blocks plugin list [--json]
  blocks plugin inspect PLUGIN_ID
  blocks plugin configure PLUGIN_ID (--file PATH | --stdin)
  blocks plugin secret set PLUGIN_ID SECRET_ID --stdin
  blocks plugin invoke PLUGIN_ID ACTION_ID [--file PATH | --stdin] [--confirm]
  blocks plugin enable PLUGIN_ID
  blocks plugin disable PLUGIN_ID
  blocks plugin debug PLUGIN_ID on|off
  blocks plugin logs show PLUGIN_ID
  blocks plugin logs follow PLUGIN_ID
  blocks plugin logs export PLUGIN_ID --output PATH
  blocks plugin logs clear PLUGIN_ID --confirm
  blocks plugin safety-reset PLUGIN_ID --confirm
  blocks plugin catalog list
  blocks plugin catalog install CATALOG_ID --plan
  blocks plugin catalog install CATALOG_ID --apply --confirm-hash SHA256
  blocks plugin remove PLUGIN_ID --confirm

Init, API discovery, validation, fixture tests, and packing work offline in an
isolated runner. Installed operations use the same broker-backed lifecycle as
the plugin center. Every command emits a stable JSON envelope. Secrets are
accepted only through stdin and never emitted by list, inspect, logs, or tests.
"""
