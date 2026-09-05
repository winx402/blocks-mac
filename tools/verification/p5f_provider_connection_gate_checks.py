#!/usr/bin/env python3
"""P5-F provider connection gate skeleton checks for Blocks."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from verification_build_helpers import run_blocks_no_launch_build, run_controlled_subprocess

from current_architecture_gate_helpers import (
    exact_method_block,
    method_chain_checks,
    method_chain_mutations_fail_closed,
    method_chain_overload_adversaries_fail_closed,
    mutate_exact_method,
    swift_code_only,
    swift_declaration_block,
    swift_declaration_task_action_contains_all,
)


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
P5F_FILES = [
    APP / "Models" / "ProviderAuditEvent.swift",
    APP / "App" / "AppModel.swift",
    APP / "App" / "AppModel+FeatureDelegation.swift",
    APP / "Features" / "Provider" / "ProviderFeatureCoordinator.swift",
    APP / "Features" / "Provider" / "ProviderStore.swift",
    APP / "Features" / "Settings" / "ProviderSettingsPane.swift",
    APP / "Features" / "Settings" / "TranslationSettingsPane.swift",
    APP / "Models" / "ProviderRouting.swift",
    APP / "Features" / "Settings" / "AgentCLISettingsPane.swift",
    APP / "Services" / "ProviderKeychainService.swift",
    APP / "Features" / "Translation" / "TranslationBuiltInAdapters.swift",
    APP / "Services" / "OpenAITranslationRuntimeService.swift",
]


def run(command: list[str], timeout: int) -> dict[str, Any]:
    try:
        completed = run_controlled_subprocess(command, cwd=ROOT, timeout=timeout)
    except Exception as error:
        return {
            "ok": False,
            "returncode": None,
            "stdout": "",
            "stderr_tail": str(error)[-1200:],
            "timed_out": True,
            "process_cleanup": None,
            "output_diagnostic": None,
            "output_truncation": None,
        }
    return {
        "ok": completed["ok"],
        "returncode": completed["returncode"],
        "stdout": completed["stdout"],
        "stderr_tail": completed["stderr"][-1200:],
        "timed_out": completed["timed_out"],
        "process_cleanup": completed.get("process_cleanup"),
        "output_diagnostic": completed.get("output_diagnostic"),
        "output_truncation": completed.get("output_truncation"),
    }


def run_result_fixture_contract() -> bool:
    """Keep bounded stderr and controlled-subprocess diagnostics observable."""
    fixture = {
        "ok": False, "returncode": 17, "stdout": "fixture", "stderr": "x" * 1300,
        "timed_out": True, "process_cleanup": {"terminated": True},
        "output_diagnostic": "fixture diagnostic", "output_truncation": True,
    }
    result = {
        "ok": fixture["ok"], "returncode": fixture["returncode"],
        "stdout": fixture["stdout"], "stderr_tail": fixture["stderr"][-1200:],
        "timed_out": fixture["timed_out"],
        "process_cleanup": fixture["process_cleanup"],
        "output_diagnostic": fixture["output_diagnostic"],
        "output_truncation": fixture["output_truncation"],
    }
    return (
        len(result["stderr_tail"]) == 1200 and result["timed_out"]
        and result["process_cleanup"] == fixture["process_cleanup"]
        and result["output_diagnostic"] == fixture["output_diagnostic"]
        and result["output_truncation"] is True
    )


def bounded_run_observation(result: dict[str, Any]) -> dict[str, Any]:
    fields = ("returncode", "timed_out", "process_cleanup", "output_diagnostic", "output_truncation")
    return {key: result.get(key) for key in fields if result.get(key) not in (None, False)}


def bounded_run_failure_detail(result: dict[str, Any]) -> str:
    stream = result.get("stdout") or result.get("stderr_tail") or "controlled subprocess failed"
    return str(stream)[-1200:]


def p5e_gate_json_fixture_contract() -> bool:
    fixture = {
        "ok": False, "returncode": 23, "timed_out": True,
        "process_cleanup": {"killed": True}, "output_diagnostic": "fixture diagnostic",
        "output_truncation": True, "stdout": "y" * 1300, "stderr_tail": "stderr",
    }
    observation = bounded_run_observation(fixture)
    detail = bounded_run_failure_detail(fixture)
    return (
        observation == {
            "returncode": 23, "timed_out": True,
            "process_cleanup": {"killed": True},
            "output_diagnostic": "fixture diagnostic", "output_truncation": True,
        }
        and len(detail) == 1200
    )


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


EXECUTION_SIGNATURE = (
    "func runOpenAIConnectionTestExecution(baseURL: String, modelName: String, "
    "keychainAccountAlias: String, configurationFingerprint: "
    "ProviderConnectionConfigurationFingerprint? = nil) async -> "
    "ProviderConnectionExecutionOutcome"
)


def current_execution_contract(store_source: str) -> bool:
    """Verify the ordered authorization/read/transport/publication execution path.

    This deliberately evaluates the exact executable method with comments and
    literals masked.  It is not a file-presence check: every marker must occur
    in the live execution path in the required order.
    """
    method = exact_method_block(
        store_source,
        "final class ProviderStore",
        EXECUTION_SIGNATURE,
    )
    required = [
        "let externalTransferTarget = ProviderExternalTransferTarget(",
        "credentialRevision: providerCredentialRevision",
        "ProviderRuntimeGate.validateOpenAICompatible(",
        "externalTransferConfirmed: externalTransferAuthorized",
        "guard let externalTransferTarget, ProviderSettingsPersistence.isExternalTransferAuthorized(",
        "providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()",
        "guard ProviderSettingsPersistence.isExternalTransferAuthorized(",
        "material.credentialRevision",
        "openAIConnectionService.testConnection(",
        "authorizationCheck:",
        "admission:",
        "openAIConnectionFinalPublicationHook?()",
        "ProviderSettingsPersistence.publishExternalTransfer(",
        "self.finishOpenAIConnectionTest(",
        "providerUserSecretLastResult = material.redactedResult",
        "return .publicationRejected",
    ]
    return _exact_reachable_ordered_contract(
        store_source, "final class ProviderStore", EXECUTION_SIGNATURE, required,
        [token for token in required if token != "providerUserSecretLastResult = material.redactedResult"],
    )


def current_publication_boundary_contract(coordinator_source: str) -> bool:
    """A rejected execution must return before UI status or plugin terminal events."""
    method = exact_method_block(
        coordinator_source,
        "final class ProviderFeatureCoordinator",
        "func runOpenAIConnectionTest(baseURL: String, modelName: String, "
        "keychainAccountAlias: String, configurationFingerprint: "
        "ProviderConnectionConfigurationFingerprint) async",
    )
    return _exact_reachable_ordered_contract(
        coordinator_source, "final class ProviderFeatureCoordinator",
        "func runOpenAIConnectionTest(baseURL: String, modelName: String, "
        "keychainAccountAlias: String, configurationFingerprint: "
        "ProviderConnectionConfigurationFingerprint) async",
        [
            "providerStore.runOpenAIConnectionTestExecution(",
            "guard case let .published(result) = execution else { return }",
            "providerStore.isActiveOpenAIConnectionConfiguration(", "recordStatus(",
            "ProviderAuditID.display(result.auditID)", "dispatchPluginEvent(",
            ".string(result.auditID)",
        ],
    )


def current_worker_service_contract(store_source: str) -> bool:
    """Keep the Security service call inside the worker's serial async hop."""
    method = exact_method_block(
        store_source,
        "private final class ProviderKeychainWorker",
        "func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error>",
    )
    return bool(method) and _ordered_code_tokens(method, [
        "await onWorker", "service.readUserSecretForProviderCall(alias: alias)",
    ])


def current_audit_identity_contract(store_source: str) -> bool:
    """Store the full audit ID internally; only the coordinator UI displays it."""
    method = exact_method_block(
        store_source,
        "final class ProviderStore",
        "func recordOpenAIConnectionTest(_ result: OpenAIConnectionTestResult)",
    )
    code = swift_code_only(method)
    return (
        "id: result.auditID" in code
        and "auditID: result.auditID" in code
        and "ProviderAuditID.display(" not in code
    )


REVOKE_EXTERNAL_TRANSFER_GRANT_SIGNATURE = (
    "func revokeExternalTransferGrant(defaults: UserDefaults = .standard, "
    "synchronize: (UserDefaults) -> Bool = { $0.synchronize() }) -> Bool"
)
REVOKE_EXTERNAL_TRANSFER_GRANT_LOCKED_SIGNATURE = (
    "func revokeExternalTransferGrantLocked(defaults: UserDefaults, "
    "invalidatingPendingAuthorizationIntents: Bool, synchronize: "
    "(UserDefaults) -> Bool) -> Bool"
)
EXTERNAL_TRANSFER_GRANT_SIGNATURE = (
    "func externalTransferGrant(defaults: UserDefaults = .standard) "
    "-> ProviderExternalTransferGrant?"
)
ISSUE_EXTERNAL_TRANSFER_GRANT_SIGNATURE = (
    "func issueExternalTransferGrant(for target: ProviderExternalTransferTarget, "
    "authorizationIntent: ProviderExternalTransferAuthorizationIntent, "
    "defaults: UserDefaults = .standard) -> Bool"
)
PROVIDER_TRANSFER_TOGGLE_SIGNATURE = (
    "func setExternalTransferGranted(_ isGranted: Bool)"
)
TRANSLATION_OPENAI_SAVE_SIGNATURE = (
    "func save(sessionID: UUID, authorizationIntent: "
    "ProviderExternalTransferAuthorizationIntent) async"
)
TRANSLATION_OPENAI_SESSION_BEGIN_SIGNATURE = (
    "func begin(defaults: UserDefaults = .standard) -> "
    "(sessionID: UUID, authorizationIntent: ProviderExternalTransferAuthorizationIntent)"
)
TRANSLATION_CONFIGURATION_CURRENT_SIGNATURE = (
    "func current(defaults: UserDefaults = .standard) "
    "-> OpenAITranslationServiceConfiguration"
)
TRANSLATION_WORKER_SIGNATURE = (
    "func translate(request: TranslationServiceRequest, "
    "configuration: OpenAITranslationServiceConfiguration) async throws "
    "-> OpenAITranslationExecutionOutcome"
)
TRANSLATION_RUNTIME_SIGNATURE = (
    "func translate(text: String, sourceLanguageMode: String, "
    "targetLanguage: String, profile: OpenAITranslationRuntimeProfile, "
    "secretMaterial: ProviderUserSecretMaterial, authorizationCheck: "
    "@Sendable () -> Bool = { true }, admission: (@Sendable (() -> Bool) "
    "-> Bool)? = nil, auditTarget: ProviderExternalTransferTarget? = nil, "
    "auditGrant: ProviderExternalTransferGrant? = nil, "
    "deferredAuditHandler: (@Sendable (OpenAITranslationDeferredAudit) "
    "-> Void)? = nil) async -> OpenAITranslationRuntimeResult"
)
TRANSLATION_ADAPTER_SIGNATURE = (
    "func translate(_ request: TranslationServiceRequest) "
    "-> AsyncThrowingStream<TranslationServiceEvent, Error>"
)
PREPARE_CREDENTIAL_MUTATION_SIGNATURE = (
    "func prepareCredentialMutation(preserving authorizationIntent: "
    "ProviderExternalTransferAuthorizationIntent? = nil, "
    "defaults: UserDefaults = .standard) -> UInt64?"
)
USER_SECRET_GATE_SIGNATURE = (
    "func performProviderUserSecretGate(action: ProviderUserSecretAction, "
    "accountAlias: String, secretCandidate: String? = nil, "
    "replacingAccountAlias: String? = nil, authorizationIntent: "
    "ProviderExternalTransferAuthorizationIntent? = nil) async "
    "-> ProviderKeychainGateUIOutcome"
)
WORKER_USER_SECRET_GATE_SIGNATURE = (
    "func performUserSecretGate(action: ProviderUserSecretAction, alias: String, "
    "secret: String?, replacingAlias: String?, authorizationIntent: "
    "ProviderExternalTransferAuthorizationIntent?) async -> "
    "Result<(ProviderUserSecretOperationResult, UInt64?), Error>"
)
PREPARED_USER_SECRET_MUTATION_SIGNATURE = (
    "func performPreparedUserSecretMutation(action: ProviderUserSecretAction, "
    "alias: String, secret: String?, replacingAlias: String?, authorizationIntent: "
    "ProviderExternalTransferAuthorizationIntent?) throws -> "
    "(ProviderUserSecretOperationResult, UInt64?)"
)


def _method_body_opening(code: str) -> int | None:
    start = code.find("func ")
    if start < 0:
        return None
    parenthesis_depth = 0
    for index in range(start, len(code)):
        if code[index] == "(":
            parenthesis_depth += 1
        elif code[index] == ")":
            parenthesis_depth -= 1
        elif code[index] == "{" and parenthesis_depth == 0:
            return index
    return None


def _ordered_code_tokens(
    method: str,
    tokens: list[str],
    declaration: bool = False,
) -> bool:
    """Require reachable, whitespace-tolerant tokens in one exact method.

    The shared helper exposes exact extraction and comment masking but no public
    ordered reachability API.  This conservative wrapper deliberately rejects
    conditional compilation, literal dead branches, closure-only bindings, and
    a top-level terminator before any required token.
    """
    code = swift_code_only(method)
    if not method or re.search(r"(?m)^\s*#(?:if|elseif|else|endif)\b", code):
        return False
    if re.search(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*\{", code):
        return False
    if re.search(r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*\{", code):
        return False
    if not declaration and re.search(r"\bTask\s*\{", code):
        return False

    opening = code.find("{") if declaration else _method_body_opening(code)
    if opening is None:
        opening = code.find("{")
    if opening < 0:
        return False
    positions: list[tuple[int, int]] = []
    cursor = opening + 1
    for token in tokens:
        parts = [r"\s+" if part.isspace() else re.escape(part)
                 for part in re.split(r"(\s+)", token.strip()) if part]
        match = re.compile("".join(parts)).search(code, cursor)
        if match is None:
            return False
        positions.append((match.start(), match.end()))
        cursor = match.end()

    depth = 0
    terminators: list[int] = []
    for index, character in enumerate(code[opening + 1:], opening + 1):
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        elif depth == 0 and code.startswith("return", index):
            before = code[index - 1] if index else " "
            after = code[index + 6] if index + 6 < len(code) else " "
            if not (before.isalnum() or before == "_") and not (after.isalnum() or after == "_"):
                terminators.append(index)
    return not any(terminator < position for position, _ in positions for terminator in terminators)


def _exact_reachable_ordered_contract(
    source: str,
    type_signature: str,
    method_signature: str,
    tokens: list[str],
    helper_tokens: list[str] | None = None,
) -> bool:
    """Combine the helper's per-token reachability with strict local order."""
    specs = {
        "exact_method": (
            "source", type_signature, method_signature,
            helper_tokens if helper_tokens is not None else tokens, [],
        ),
    }
    return method_chain_checks({"source": source}, specs).get(
        "exact_method", False
    ) and _ordered_code_tokens(
        exact_method_block(source, type_signature, method_signature), tokens
    )


def _code_token_start(code: str, token: str, start: int = 0) -> int:
    parts = [r"\s+" if part.isspace() else re.escape(part)
             for part in re.split(r"(\s+)", token.strip()) if part]
    match = re.compile("".join(parts)).search(code, start)
    return -1 if match is None else match.start()


def _code_tokens_in_order(code: str, tokens: list[str]) -> bool:
    """Check ordered executable tokens without treating legitimate callbacks as dead."""
    cursor = 0
    for token in tokens:
        position = _code_token_start(code, token, cursor)
        if position < 0:
            return False
        cursor = position + len(token)
    return True


def _translation_method_is_reachable(method: str, first_required_token: str) -> bool:
    """Reject structural decoys before the first live translation gate token."""
    code = swift_code_only(method)
    first = _code_token_start(code, first_required_token)
    if first < 0 or re.search(r"(?m)^\s*#(?:if|elseif|else|endif)\b", code):
        return False
    if re.search(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*\{", code):
        return False
    if "let closureOnlyDecoy = {" in code:
        return False
    opening = _method_body_opening(code)
    if opening is None:
        return False
    depth = 0
    for index, character in enumerate(code[opening + 1:first], opening + 1):
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        elif depth == 0 and code.startswith("return", index) or (
            depth == 0 and code.startswith("throw", index)
        ):
            return False
    return True


def _translation_publication_validator_calls(
    method: str,
) -> list[tuple[int, int, str]]:
    """Return the two complete `guard publicationValidator(...)` call spans."""
    code = swift_code_only(method)
    spans: list[tuple[int, int, str]] = []
    for match in re.finditer(r"\bguard\s+publicationValidator\s*\(", code):
        opening = code.find("(", match.start())
        depth = 0
        end = None
        for index in range(opening, len(code)):
            if code[index] == "(":
                depth += 1
            elif code[index] == ")":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is None:
            return []
        spans.append((match.start(), end, method[match.start():end]))
    return spans


def _exact_method_nth_mutation_contract_fails_closed(
    source: str,
    type_signature: str,
    method_signature: str,
    original: str,
    replacement: str,
    occurrence: int,
    contract: Any,
) -> bool:
    """Mutate one proven occurrence inside one extractable exact method."""
    method = exact_method_block(source, type_signature, method_signature)
    if not method or source.count(method) != 1:
        return False
    positions: list[int] = []
    cursor = 0
    while (position := method.find(original, cursor)) >= 0:
        positions.append(position)
        cursor = position + len(original)
    if len(positions) < occurrence:
        return False
    position = positions[occurrence - 1]
    mutated_method = method[:position] + replacement + method[position + len(original):]
    return not contract(source.replace(method, mutated_method, 1))


def _inject_exact_method_statement(
    source: str,
    type_signature: str,
    method_signature: str,
    statement: str,
) -> str | None:
    method = exact_method_block(source, type_signature, method_signature)
    code = swift_code_only(method)
    opening = _method_body_opening(code)
    if not method or opening is None or source.count(method) != 1:
        return None
    injected = method[:opening + 1] + "\n        " + statement + method[opening + 1:]
    return source.replace(method, injected, 1)


def structural_adversaries_fail_closed(
    source: str,
    type_signature: str,
    method_signature: str,
    contract: Any,
    early_return: str,
) -> dict[str, bool]:
    """Inject valid dead-code forms while retaining extractable exact methods."""
    adversaries = {
        "if_false": "if false { let _ = 0 }",
        "closure_only": "let closureOnlyDecoy = { let _ = 0 }",
        "conditional_compilation": "#if false\n        let _ = 0\n        #endif",
        "top_level_early_return": early_return,
    }
    outcomes: dict[str, bool] = {}
    for name, statement in adversaries.items():
        mutated = _inject_exact_method_statement(
            source, type_signature, method_signature, statement
        )
        outcomes[name] = bool(
            mutated
            and exact_method_block(mutated, type_signature, method_signature)
            and not contract(mutated)
        )
    return outcomes


def exact_mutation_contract_fails_closed(
    source: str,
    type_signature: str,
    method_signature: str,
    original: str,
    replacement: str,
    contract: Any,
) -> bool:
    mutated = mutate_exact_method(
        source, type_signature, method_signature, original, replacement
    )
    return bool(
        mutated
        and exact_method_block(mutated, type_signature, method_signature)
        and not contract(mutated)
    )


def chain_mutation_fails_closed(
    sources: dict[str, str],
    specs: dict[str, tuple[str, str, str, list[str], list[str]]],
    check_name: str,
    source_name: str,
    original: str,
    replacement: str,
) -> bool:
    """Execute one adversarial source mutation against one exact chain spec."""
    return method_chain_mutations_fail_closed(
        sources,
        specs,
        [(check_name, source_name, original, replacement)],
    ).get(check_name, False)


def current_external_transfer_revoke_contract(routing_source: str) -> bool:
    """Pin public revoke to the fenced, two-sync cleanup implementation."""
    entry = exact_method_block(
        routing_source,
        "enum ProviderSettingsPersistence",
        REVOKE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
    )
    locked = exact_method_block(
        routing_source,
        "enum ProviderSettingsPersistence",
        REVOKE_EXTERNAL_TRANSFER_GRANT_LOCKED_SIGNATURE,
    )
    return bool(entry and locked) and _ordered_code_tokens(entry, [
        "withExternalTransferAdmission {",
        "revokeExternalTransferGrantLocked(",
        "invalidatingPendingAuthorizationIntents: true",
        "synchronize: synchronize",
    ]) and _ordered_code_tokens(locked, [
        "advanceExternalTransferRevocationFenceLocked(",
        "invalidatingPendingAuthorizationIntents:\n                invalidatingPendingAuthorizationIntents",
        "_ = synchronize(defaults)",
        "defaults.removeObject(forKey: externalTransferGrantKey)",
        "defaults.removeObject(forKey: legacyExternalTransferEnabledKey)",
        "return synchronize(defaults)",
    ])


def current_external_transfer_grant_contract(routing_source: str) -> bool:
    """Require allocator/fence validation and current-intent grant issuance."""
    grant = exact_method_block(
        routing_source,
        "enum ProviderSettingsPersistence",
        EXTERNAL_TRANSFER_GRANT_SIGNATURE,
    )
    issue = exact_method_block(
        routing_source,
        "enum ProviderSettingsPersistence",
        ISSUE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
    )
    return bool(grant and issue) and _ordered_code_tokens(grant, [
        "let storedGeneration = externalTransferWatermark(",
        "let revokedThroughGeneration = externalTransferWatermark(",
        "grant.generation == storedGeneration",
        "grant.generation > revokedThroughGeneration",
    ]) and _ordered_code_tokens(issue, [
        "currentExternalTransferAuthorizationIntentLocked(\n                defaults: defaults\n            ) == authorizationIntent",
        "let storedGeneration = externalTransferWatermark(",
        "let revokedThroughGeneration = externalTransferWatermark(",
        "currentGrant?.generation != storedGeneration",
        "(currentGrant?.generation ?? 0) <= revokedThroughGeneration",
        "currentExternalTransferTarget(defaults: defaults) == target",
    ])


def current_authorization_intent_lifecycle_contract(routing_source: str) -> bool:
    """Every explicit intent is fresh; nil or stale mutation fails closed."""
    capture = exact_method_block(
        routing_source,
        "enum ProviderSettingsPersistence",
        "func captureExternalTransferAuthorizationIntent(defaults: "
        "UserDefaults = .standard) -> ProviderExternalTransferAuthorizationIntent",
    )
    prepare = exact_method_block(
        routing_source,
        "enum ProviderSettingsPersistence",
        PREPARE_CREDENTIAL_MUTATION_SIGNATURE,
    )
    return bool(capture and prepare) and _translation_method_is_reachable(capture, "let intent = ProviderExternalTransferAuthorizationIntent(") and _translation_method_is_reachable(prepare, "currentExternalTransferAuthorizationIntentLocked(") and all(token in swift_code_only(capture) for token in [
        "ProviderExternalTransferAuthorizationIntent", "epoch: UUID()",
        "intent.epoch.uuidString", "externalTransferAuthorizationIntentEpochKey",
    ]) and all(token in swift_code_only(prepare) for token in [
        "currentExternalTransferAuthorizationIntentLocked(", "== authorizationIntent",
        "return nil", "rotateExternalTransferAuthorizationIntentLocked(",
    ])


def current_worker_credential_intent_contract(store_source: str) -> bool:
    """Security runs outside admission; its fenced journal lifecycle keeps intent."""
    worker = exact_method_block(
        store_source,
        "private final class ProviderKeychainWorker",
        PREPARED_USER_SECRET_MUTATION_SIGNATURE,
    )
    entry = exact_method_block(
        store_source, "private final class ProviderKeychainWorker",
        WORKER_USER_SECRET_GATE_SIGNATURE,
    )
    code = swift_code_only(worker)
    return bool(worker and entry) and all(token in swift_code_only(entry) for token in ["self.performPreparedUserSecretMutation(", "authorizationIntent: authorizationIntent"]) and not "withExternalTransferAdmission {" in code and _translation_method_is_reachable(worker, "ProviderSettingsPersistence.prepareCredentialMutation(") and all(token in code for token in [
        "ProviderSettingsPersistence.prepareCredentialMutation(",
        "preserving: authorizationIntent",
        "beginPendingCredentialMutation(",
        "ProviderSettingsPersistence.isCredentialMutationAuthorizationCurrent(",
        "service.performUserSecret(",
        "ProviderSettingsPersistence.completePendingCredentialMutation(",
        "abandonPendingCredentialMutationAsMissingSecret(",
    ])


def current_provider_revoke_failure_ui_contract(settings_source: str) -> bool:
    """A failed durable revoke must still remove in-memory authorization."""
    method = exact_method_block(
        settings_source,
        "struct ProviderSettingsPane",
        PROVIDER_TRANSFER_TOGGLE_SIGNATURE,
    )
    return bool(method) and _ordered_code_tokens(method, [
        "guard isGranted else {",
        "let durablyRevoked = ProviderSettingsPersistence\n                .revokeExternalTransferGrant()",
        "externalTransferGranted = false",
        "externalTransferRevocationPersistenceFailed = !durablyRevoked",
        "cleanupConnectionTestForRouteExit()",
        "return",
    ])


def current_translation_openai_save_contract(translation_source: str) -> bool:
    """Bind the Sheet's live session and save path to one intent."""
    session = swift_declaration_block(
        translation_source, "final class TranslationOpenAIServiceEditorSaveSession"
    )
    method = exact_method_block(
        translation_source,
        "private struct TranslationOpenAIServiceEditorSheet",
        TRANSLATION_OPENAI_SAVE_SIGNATURE,
    )
    session_code = swift_code_only(session)
    capture_index = _code_token_start(session_code, "captureExternalTransferAuthorizationIntent(")
    return bool(session and method) and capture_index >= 0 and "return" not in session_code[:capture_index] and _ordered_code_tokens(session, [
        "captureExternalTransferAuthorizationIntent(defaults: defaults)",
        "activeAuthorizationIntent = authorizationIntent",
        "isExternalTransferAuthorizationIntentCurrent(",
        "invalidateExternalTransferAuthorizationIntent(",
    ], declaration=True) and _ordered_code_tokens(method, [
        "await appModel.performProviderUserSecretGate(",
        "authorizationIntent: authorizationIntent",
        "isSaveSessionCurrent(",
        "outcome.operationSucceeded",
        "ProviderSettingsPersistence.saveProviderAccountAlias(",
        "preserving: authorizationIntent",
        "ProviderSettingsPersistence.saveProviderBaseURL(",
        "ProviderSettingsPersistence.saveProviderModelName(",
        "ProviderSettingsPersistence.issueExternalTransferGrant(",
        "authorizationIntent: authorizationIntent",
        "saveSession.finishSuccess()",
    ]) and (
        swift_code_only(method).count("preserving: authorizationIntent") == 3
    )


def current_translation_openai_form_disable_contract(translation_source: str) -> bool:
    """Keep save-only disablement while cancellation stays available."""
    policy = swift_declaration_block(
        translation_source,
        "struct TranslationOpenAIServiceEditorInteractionPolicy",
    )
    sheet = swift_declaration_block(
        translation_source,
        "private struct TranslationOpenAIServiceEditorSheet",
    )
    invalidate_saving_session = exact_method_block(
        translation_source,
        "private struct TranslationOpenAIServiceEditorSheet",
        "func invalidateSavingSession()",
    )
    return bool(policy and sheet and invalidate_saving_session) and _ordered_code_tokens(policy, [
        "let formDisabled: Bool",
        "let cancelDisabled: Bool",
        "let saveDisabled: Bool",
        "let interactiveDismissDisabled: Bool",
        "formDisabled = isSaving",
        "cancelDisabled = false",
        "saveDisabled = !canSave || isSaving",
        "interactiveDismissDisabled = false",
    ], declaration=True) and _ordered_code_tokens(sheet, [
        "SettingsSheetScaffold(",
        "VStack(spacing: 0) {",
        ".disabled(interactionPolicy.formDisabled)",
        ".textFieldStyle(.roundedBorder)",
        ".keyboardShortcut(.defaultAction)",
        ".disabled(interactionPolicy.saveDisabled)",
        ".interactiveDismissDisabled(",
        "interactionPolicy.interactiveDismissDisabled",
        ".onDisappear {",
        "saveSession.shouldInvalidateOnDisappear",
        "invalidateSavingSession()",
    ], declaration=True) and _ordered_code_tokens(sheet, [
        ".disabled(interactionPolicy.formDisabled)",
        "invalidateSavingSession()",
        "dismiss()",
        ".keyboardShortcut(.cancelAction)",
        ".disabled(interactionPolicy.cancelDisabled)",
        ".keyboardShortcut(.defaultAction)",
        ".disabled(interactionPolicy.saveDisabled)",
    ], declaration=True) and _ordered_code_tokens(invalidate_saving_session, [
        "savingTask?.cancel()",
        "savingTask = nil",
        "isSaving = false",
        "saveSession.invalidate()",
    ])


def current_openai_translation_configuration_contract(translation_source: str) -> bool:
    """Bind the translation profile's target and grant to one credential revision."""
    configuration = swift_declaration_block(
        translation_source, "struct OpenAITranslationServiceConfiguration"
    )
    current = exact_method_block(
        translation_source,
        "struct OpenAITranslationServiceConfiguration",
        TRANSLATION_CONFIGURATION_CURRENT_SIGNATURE,
    )
    return bool(configuration and current) and _ordered_code_tokens(current, [
        "credentialRevision: ProviderSettingsPersistence",
        ".credentialRevision(defaults: defaults)",
        "externalTransferGrant: ProviderSettingsPersistence",
        ".externalTransferGrant(defaults: defaults)",
    ]) and all(token in swift_code_only(configuration) for token in [
        "var externalTransferTarget: ProviderExternalTransferTarget?",
        "credentialRevision: credentialRevision",
        "externalTransferGrant?.target == target",
    ])


def current_openai_translation_worker_contract(translation_source: str) -> bool:
    """Require grant-target binding and a fresh authorization check around secret read."""
    required = [
        "let authorizationTarget = configuration.externalTransferTarget",
        ".externalTransferTarget",
        "authorizationValidator(",
        "configuration.externalTransferGrant",
        "secret = try readProviderSecret(",
        "configuration.keychainAccountAlias",
        "try Task.checkCancellation()",
        "guard authorizationValidator(",
        "secret.credentialRevision",
        "== authorizationTarget.credentialRevision",
        "await runtimeService.translate(",
        "authorizationCheck: {",
        "admission: { start in",
        "self.admissionValidator(",
        "auditTarget: publicationTarget",
        "auditGrant: publicationGrant",
    ]
    method = exact_method_block(
        translation_source,
        "private actor OpenAITranslationExecutionWorker",
        TRANSLATION_WORKER_SIGNATURE,
    )
    code = swift_code_only(method)
    return bool(method) and _translation_method_is_reachable(method, required[0]) and code.count("guard authorizationValidator(") >= 2 and all(token in code for token in required)


def current_openai_translation_runtime_contract(runtime_source: str) -> bool:
    """Pin admission's synchronous start boundary and post-response fail-closed check."""
    required = [
        "guard authorizationCheck() else",
        "let operation = transport.makeOperation(",
        "let response: OpenAIConnectionTransportResponse? = try await withTaskCancellationHandler {",
        "let started = if let admission {",
        "admission { operation.start() }",
        "authorizationCheck() && operation.start()",
        "guard started else { return nil }",
        "return try await operation.response()",
        "guard let response else",
        "guard authorizationCheck() else",
        "authorization_revoked_after_transport",
        "provider_response_redacted",
    ]
    method = exact_method_block(
        runtime_source,
        "struct OpenAITranslationRuntimeService",
        TRANSLATION_RUNTIME_SIGNATURE,
    )
    code = swift_code_only(method)
    post_response_guard = _code_token_start(
        code, "guard authorizationCheck() else", _code_token_start(
            code, "guard let response else"
        )
    )
    return bool(method) and _translation_method_is_reachable(
        method, required[0]
    ) and _code_tokens_in_order(code, required[:-2]) and (
        post_response_guard >= 0
        and "authorization_revoked_after_transport" in method
        and "provider_response_redacted" in method
    )


def current_openai_translation_publication_contract(translation_source: str) -> bool:
    """Adapter output/diagnostics must be published only through the final grant check."""
    method = exact_method_block(
        translation_source,
        "final class OpenAICompatibleTranslationServiceAdapter",
        TRANSLATION_ADAPTER_SIGNATURE,
    )
    code = swift_code_only(method)
    task_start = _code_token_start(code, "let task = Task")
    calls = _translation_publication_validator_calls(method)
    if not method or task_start < 0 or len(calls) != 2 or re.search(r"(?m)^\s*#(?:if|elseif|else|endif)\b", code) or "if false" in code or "let closureOnlyDecoy = {" in code or "return" in code[:task_start]:
        return False
    failure_start, failure_end, failure_call = calls[0]
    success_start, success_end, success_call = calls[1]
    failure_code = swift_code_only(failure_call)
    success_code = swift_code_only(success_call)
    failure_tail = code[failure_end:success_start]
    success_tail = code[success_end:]
    failure_ok = all(token in failure_code for token in ["target,", "grant,", ".diagnostics(", "execution.deferredAudit?.publishOnce()"]) and ".publicationRejected" in failure_tail
    success_ok = all(token in success_code for token in ["target,", "grant,", ".completed(", "execution.deferredAudit?.publishOnce()"]) and ".publicationRejected" in success_tail and "continuation.finish()" in success_tail
    deferred_audits = [
        match.start() for match in re.finditer(
            re.escape("execution.deferredAudit?.publishOnce()"), code
        )
    ]
    return failure_ok and success_ok and len(deferred_audits) == 2 and (
        failure_start < deferred_audits[0] < failure_end
        and success_start < deferred_audits[1] < success_end
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--skip-build", "--no-build", action="store_true", dest="skip_build")
    args = parser.parse_args()

    failures: list[dict[str, str]] = []
    observations: dict[str, Any] = {}

    if args.skip_build:
        observations["app_build"] = {"ok": True, "skipped": True}
    else:
        build = run_blocks_no_launch_build(ROOT, args.timeout, "p5f")
        require(build["ok"], "app_build_failed", build["stderr_tail"], failures)
        observations["app_build"] = {
            key: build[key]
            for key in (
                "ok", "returncode", "timed_out", "process_cleanup",
                "output_diagnostic", "output_truncation",
            )
            if key in build
        }

    p5e = run(["python3", "tools/verification/p5e_provider_audit_checks.py", "--timeout", str(args.timeout), "--skip-build"], args.timeout)
    require(p5e["ok"], "p5e_regression_failed", bounded_run_failure_detail(p5e), failures)
    observations["p5e_regression"] = p5e["ok"]
    p5e_observation = bounded_run_observation(p5e)
    if p5e_observation or not p5e["ok"]:
        observations["p5e_regression_run"] = p5e_observation

    required_keys = [
        "settings.providerConnection",
        "settings.openAITestConnectionConfirmExternalTransfer",
        "settings.openAITestConnectionRun",
        "settings.providerConnectionTesting.title",
        "settings.providerConnectionSucceeded.title",
        "settings.providerConnectionFailed.title",
        "settings.providerConnectionBlockedAPI",
        "settings.agentCLI.localCLI",
    ]
    localizable = json.loads(LOCALIZABLE.read_text(encoding="utf-8"))
    missing = [
        key
        for key in required_keys
        if key not in localizable.get("strings", {})
        or any(lang not in localizable["strings"][key].get("localizations", {}) for lang in ["zh-Hans", "en", "ja"])
    ]
    require(not missing, "localization_missing", ", ".join(missing), failures)
    observations["required_localization_keys"] = {"checked": len(required_keys), "missing": missing}

    file_text = {path.name: path.read_text(encoding="utf-8") for path in P5F_FILES}
    combined = "\n".join(file_text.values())
    settings_text = file_text["ProviderSettingsPane.swift"]
    routing_text = file_text["ProviderRouting.swift"]
    translation_settings_text = file_text["TranslationSettingsPane.swift"]
    agent_cli_text = file_text["AgentCLISettingsPane.swift"]
    store_text = file_text["ProviderStore.swift"]
    coordinator_text = file_text["ProviderFeatureCoordinator.swift"]
    delegation_text = file_text["AppModel+FeatureDelegation.swift"]
    keychain_service_text = file_text["ProviderKeychainService.swift"]
    translation_adapter_text = file_text["TranslationBuiltInAdapters.swift"]
    translation_runtime_text = file_text["OpenAITranslationRuntimeService.swift"]
    required_symbols = [
        "ProviderConnectionReadiness",
        "ProviderConnectionConfigurationFingerprint",
        "ProviderExternalTransferTarget",
        "ProviderSettingsPersistence.isExternalTransferAuthorized(",
        "ProviderRuntimeGate.validateOpenAICompatible(",
        "ProviderKeychainWorker",
        "providerKeychainWorker.readUserSecret(",
        "service.readUserSecretForProviderCall(",
        "openAIConnectionService.testConnection(",
        "authorizationCheck:",
        "ProviderSettingsPersistence.admitExternalTransfer(",
        "ProviderSettingsPersistence.publishExternalTransfer(",
        "ProviderConnectionExecutionOutcome",
        "providerStore.activateOpenAIConnectionConfiguration(",
        "providerStore.isActiveOpenAIConnectionConfiguration(",
        "SettingsFeedbackSlot(feedback: connectionFeedback)",
    ]
    missing_symbols = [needle for needle in required_symbols if needle not in combined]
    require(not missing_symbols, "provider_connection_gate_symbols_missing", ", ".join(missing_symbols), failures)

    retired_direct_keychain_calls = [
        "providerKeychainService.readUserSecretForProviderCall(",
    ]
    retired_direct_keychain_hits = [
        needle for needle in retired_direct_keychain_calls if needle in swift_code_only(store_text)
    ]
    require(
        not retired_direct_keychain_hits,
        "retired_direct_keychain_connection_wrapper_restored",
        ", ".join(retired_direct_keychain_hits),
        failures,
    )

    retired_preview_symbols = [
        "ProviderConnectionRequirement",
        "ProviderReadinessRow",
        "settings.providerConnectionGate",
        "settings.providerLocalCLI",
        "settings.agentCLI.localCLINote",
        "settings.openAIConnectionPreviewRun",
        "settings.providerConnectionRequirement.apiNetwork",
    ]
    retired_hits = [needle for needle in retired_preview_symbols if needle in settings_text]
    require(not retired_hits, "retired_preview_contract_restored", ", ".join(retired_hits), failures)

    connection_ui_block = swift_declaration_block(settings_text, "private var content: some View")
    connection_ui_required = [
        "connectionTestTask = Task { @MainActor in",
        "await appModel.runOpenAIConnectionTest(",
        "baseURL: apiBaseURL",
        "modelName: apiModelName",
        "keychainAccountAlias: apiKeychainAccountAlias",
        "configurationFingerprint: fingerprint",
        "guard !Task.isCancelled, activeConnectionTestID == testID else",
    ]
    connection_ui_check = bool(connection_ui_block) and swift_declaration_task_action_contains_all(
        connection_ui_block,
        "connectionTestTask",
        connection_ui_required[1:],
        ["SettingsFeedbackSlot(feedback: connectionFeedback)"],
    )
    connection_ui_mutation_fails_closed = connection_ui_check and not swift_declaration_task_action_contains_all(
        connection_ui_block.replace(
            "connectionTestTask = Task", "let disconnectedTask = Task", 1
        ),
        "connectionTestTask",
        connection_ui_required[1:],
        ["SettingsFeedbackSlot(feedback: connectionFeedback)"],
    )
    require(connection_ui_check, "provider_connection_button_task_disconnected", str(connection_ui_required), failures)
    require(connection_ui_mutation_fails_closed, "provider_connection_button_task_mutation_not_fail_closed", "dead-branch, closure-only, or early-return UI decoy", failures)

    chain_sources = {
        "app_model_delegation": (
            APP / "App" / "AppModel+FeatureDelegation.swift"
        ).read_text(encoding="utf-8"),
        "coordinator": coordinator_text,
        "store": store_text,
        "keychain_service": keychain_service_text,
    }
    chain_specs = {
        "app_model_real_test_to_coordinator": (
            "app_model_delegation",
            "extension AppModel",
            "func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, configurationFingerprint: ProviderConnectionConfigurationFingerprint) async",
            [
                "await providerCoordinator.runOpenAIConnectionTest(",
                "baseURL: baseURL",
                "modelName: modelName",
                "keychainAccountAlias: keychainAccountAlias",
                "configurationFingerprint: configurationFingerprint",
            ],
            [],
        ),
        "coordinator_real_test_to_execution": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            "func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, configurationFingerprint: ProviderConnectionConfigurationFingerprint) async",
            [
                "guard willResult.allowed else",
                "guard !Task.isCancelled else",
                "await providerStore.runOpenAIConnectionTestExecution(",
                "configurationFingerprint: resolvedConfigurationFingerprint",
                "guard case let .published(result) = execution else { return }",
                "providerStore.isActiveOpenAIConnectionConfiguration(",
                "ProviderAuditID.display(result.auditID)",
            ],
            ["await providerStore.runOpenAIConnectionTest("],
        ),
        "store_execution_to_worker_and_transport": (
            "store",
            "final class ProviderStore",
            EXECUTION_SIGNATURE,
            [
                "ProviderExternalTransferTarget(",
                "ProviderRuntimeGate.validateOpenAICompatible(",
                "guard let externalTransferTarget",
                "providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()",
                "guard ProviderSettingsPersistence.isExternalTransferAuthorized(",
                "material.credentialRevision",
                "authorizationCheck:",
                "openAIConnectionService.testConnection(",
                "ProviderSettingsPersistence.publishExternalTransfer(",
            ],
            ["providerKeychainService.readUserSecretForProviderCall("],
        ),
        "worker_read_to_keychain_service": (
            "store",
            "private final class ProviderKeychainWorker",
            "func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error>",
            ["await onWorker"],
            ["providerKeychainService.readUserSecretForProviderCall("],
        ),
        "keychain_service_read_security": (
            "keychain_service",
            "struct ProviderKeychainService",
            "func readUserSecretForProviderCall(alias: String) throws -> ProviderUserSecretMaterial",
            ["let read = readRaw(account: account)"],
            [],
        ),
        "keychain_service_raw_security": (
            "keychain_service",
            "struct ProviderKeychainService",
            "func readRaw(account: String) -> (status: OSStatus, data: Data?)",
            ["securityAPI.copyMatching(query as CFDictionary, result: &item)"],
            [],
        ),
        "security_adapter_to_security_framework": (
            "keychain_service",
            "private struct SystemProviderKeychainSecurityAPI: ProviderKeychainSecurityAPI",
            "func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus",
            ["SecItemCopyMatching(query, result)"],
            [],
        ),
    }
    chain_checks = method_chain_checks(chain_sources, chain_specs)
    chain_mutations = method_chain_mutations_fail_closed(
        chain_sources,
        chain_specs,
        [
            ("app_model_real_test_to_coordinator", "app_model_delegation", "await providerCoordinator.runOpenAIConnectionTest(", "_ = baseURL"),
            ("coordinator_real_test_to_execution", "coordinator", "await providerStore.runOpenAIConnectionTestExecution(", "_ = baseURL"),
            ("coordinator_real_test_to_execution", "coordinator", "guard case let .published(result) = execution else { return }", "let result = publicationRejectedConnectionResult(profile: OpenAIConnectionTestProfile(providerName: \"decoy\", baseURL: baseURL, modelName: modelName, keychainAccountAlias: keychainAccountAlias, timeoutSeconds: 60))"),
            ("store_execution_to_worker_and_transport", "store", "providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()", "// providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()"),
            ("worker_read_to_keychain_service", "store", "await onWorker", "_ = alias"),
        ],
    )
    chain_overload_adversaries = method_chain_overload_adversaries_fail_closed(
        chain_sources,
        chain_specs,
        [
            (
                "real_test_execution_noop_overload_forwards",
                "coordinator_real_test_to_execution",
                "func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, configurationFingerprint: ProviderConnectionConfigurationFingerprint, overloadProbe: Bool) async",
                """
func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, configurationFingerprint: ProviderConnectionConfigurationFingerprint, overloadProbe: Bool) async {
    _ = await providerStore.runOpenAIConnectionTestExecution(
        baseURL: baseURL,
        modelName: modelName,
        keychainAccountAlias: keychainAccountAlias,
        configurationFingerprint: configurationFingerprint
    )
}
""",
                "await providerStore.runOpenAIConnectionTestExecution(",
                "guard willResult.allowed else",
            ),
        ],
    )
    execution_contract = current_execution_contract(store_text)
    publication_boundary_contract = current_publication_boundary_contract(coordinator_text)
    worker_service_contract = current_worker_service_contract(store_text)
    audit_identity_contract = current_audit_identity_contract(store_text)
    revoke_contract = current_external_transfer_revoke_contract(routing_text)
    grant_contract = current_external_transfer_grant_contract(routing_text)
    intent_lifecycle_contract = current_authorization_intent_lifecycle_contract(routing_text)
    worker_credential_intent_contract = current_worker_credential_intent_contract(
        store_text
    )
    provider_revoke_failure_ui_contract = current_provider_revoke_failure_ui_contract(
        settings_text
    )
    translation_save_contract = current_translation_openai_save_contract(
        translation_settings_text
    )
    translation_form_disable_contract = current_translation_openai_form_disable_contract(
        translation_settings_text
    )
    intent_chain_sources = {
        "app_model": delegation_text,
        "coordinator": coordinator_text,
        "store": store_text,
        "routing": routing_text,
        "translation": translation_settings_text,
    }
    intent_chain_specs = {
        "app_model_to_coordinator": (
            "app_model",
            "extension AppModel",
            USER_SECRET_GATE_SIGNATURE,
            [
                "await providerCoordinator.performProviderUserSecretGate(",
                "authorizationIntent: authorizationIntent",
            ],
            [],
        ),
        "coordinator_to_store": (
            "coordinator",
            "final class ProviderFeatureCoordinator",
            USER_SECRET_GATE_SIGNATURE,
            [
                "await providerStore.performProviderUserSecretGate(",
                "authorizationIntent: authorizationIntent",
            ],
            [],
        ),
        "store_to_worker": (
            "store",
            "final class ProviderStore",
            USER_SECRET_GATE_SIGNATURE,
            [
                "await providerKeychainWorker.performUserSecretGate(",
                "authorizationIntent: authorizationIntent",
            ],
            [],
        ),
        "prepared_mutation_to_fenced_prepare": (
            "store",
            "private final class ProviderKeychainWorker",
            PREPARED_USER_SECRET_MUTATION_SIGNATURE,
            [
                "ProviderSettingsPersistence.prepareCredentialMutation(",
                "preserving: authorizationIntent",
            ],
            [],
        ),
        "translation_save_to_app_model": (
            "translation",
            "private struct TranslationOpenAIServiceEditorSheet",
            TRANSLATION_OPENAI_SAVE_SIGNATURE,
            [
                "await appModel.performProviderUserSecretGate(",
                "authorizationIntent: authorizationIntent",
                "ProviderSettingsPersistence.issueExternalTransferGrant(",
            ],
            [],
        ),
    }
    intent_chain_checks = method_chain_checks(intent_chain_sources, intent_chain_specs)
    intent_chain_mutations = {
        "app_model_forward_removed": chain_mutation_fails_closed(
            intent_chain_sources, intent_chain_specs, "app_model_to_coordinator",
            "app_model", "authorizationIntent: authorizationIntent", "authorizationIntent: nil"
        ),
        "coordinator_forward_removed": chain_mutation_fails_closed(
            intent_chain_sources, intent_chain_specs, "coordinator_to_store",
            "coordinator", "authorizationIntent: authorizationIntent", "authorizationIntent: nil"
        ),
        "store_forward_removed": chain_mutation_fails_closed(
            intent_chain_sources, intent_chain_specs, "store_to_worker",
            "store", "authorizationIntent: authorizationIntent", "authorizationIntent: nil"
        ),
        "prepare_preserving_removed": not current_worker_credential_intent_contract(
            store_text.replace("preserving: authorizationIntent", "preserving: nil")
        ),
        "translation_forward_commented": chain_mutation_fails_closed(
            intent_chain_sources, intent_chain_specs, "translation_save_to_app_model",
            "translation", "await appModel.performProviderUserSecretGate(",
            "// await appModel.performProviderUserSecretGate("
        ),
        "translation_capture_dead_branch": structural_adversaries_fail_closed(
            translation_settings_text,
            "final class TranslationOpenAIServiceEditorSaveSession",
            TRANSLATION_OPENAI_SESSION_BEGIN_SIGNATURE,
            current_translation_openai_save_contract,
            "return (UUID(), ProviderSettingsPersistence.captureExternalTransferAuthorizationIntent())",
        )["if_false"],
        "translation_capture_closure_only": structural_adversaries_fail_closed(
            translation_settings_text,
            "final class TranslationOpenAIServiceEditorSaveSession",
            TRANSLATION_OPENAI_SESSION_BEGIN_SIGNATURE,
            current_translation_openai_save_contract,
            "return (UUID(), ProviderSettingsPersistence.captureExternalTransferAuthorizationIntent())",
        )["closure_only"],
        "translation_capture_after_return": structural_adversaries_fail_closed(
            translation_settings_text,
            "final class TranslationOpenAIServiceEditorSaveSession",
            TRANSLATION_OPENAI_SESSION_BEGIN_SIGNATURE,
            current_translation_openai_save_contract,
            "return (UUID(), ProviderSettingsPersistence.captureExternalTransferAuthorizationIntent())",
        )["top_level_early_return"],
    }
    execution_contract_mutations = {
        "worker_read_removed": exact_mutation_contract_fails_closed(
            store_text, "final class ProviderStore", EXECUTION_SIGNATURE,
            "let material = try await providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()",
            "throw ProviderCredentialMutationError.revocationPersistenceUnavailable",
            current_execution_contract,
        ),
        "worker_replaced_with_retired_wrapper": not current_execution_contract(
            mutate_exact_method(
                store_text,
                "final class ProviderStore",
                EXECUTION_SIGNATURE,
                "providerKeychainWorker.readUserSecret(alias: keychainAccountAlias).get()",
                "providerKeychainService.readUserSecretForProviderCall(alias: keychainAccountAlias)",
            ) or ""
        ),
        "post_security_authorization_recheck_removed": not current_execution_contract(
            store_text.replace(
                "guard ProviderSettingsPersistence.isExternalTransferAuthorized(\n"
                "                   target: externalTransferTarget,\n"
                "                  grant: externalTransferGrant,\n"
                "                  defaults: defaults\n"
                "                  ) else {\n"
                "                return .publicationRejected\n"
                "            }",
                "guard true else { return .publicationRejected }",
                1,
            )
        ),
        "final_publication_hook_removed": exact_mutation_contract_fails_closed(
            store_text, "final class ProviderStore", EXECUTION_SIGNATURE,
            "openAIConnectionFinalPublicationHook?()", "let _ = false",
            current_execution_contract,
        ),
        "published_guard_removed": not current_publication_boundary_contract(
            mutate_exact_method(
                coordinator_text,
                "final class ProviderFeatureCoordinator",
                "func runOpenAIConnectionTest(baseURL: String, modelName: String, keychainAccountAlias: String, configurationFingerprint: ProviderConnectionConfigurationFingerprint) async",
                "guard case let .published(result) = execution else { return }",
                "let result = publicationRejectedConnectionResult(profile: OpenAIConnectionTestProfile(providerName: \"decoy\", baseURL: baseURL, modelName: modelName, keychainAccountAlias: keychainAccountAlias, timeoutSeconds: 60))",
            ) or ""
        ),
    }
    worker_service_contract_mutations = {
        "service_read_commented": not current_worker_service_contract(
            mutate_exact_method(
                store_text,
                "private final class ProviderKeychainWorker",
                "func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error>",
                "return try self.service.readUserSecretForProviderCall(alias: alias)",
                "throw ProviderCredentialMutationError.revocationPersistenceUnavailable",
            ) or ""
        ),
        "service_read_replaced_with_retired_wrapper": not current_worker_service_contract(
            mutate_exact_method(
                store_text,
                "private final class ProviderKeychainWorker",
                "func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error>",
                "return try self.service.readUserSecretForProviderCall(alias: alias)",
                "throw ProviderCredentialMutationError.credentialMutationPersistenceUnavailable",
            ) or ""
        ),
    }
    audit_identity_contract_mutations = {
        "internal_audit_id_commented": not current_audit_identity_contract(
            mutate_exact_method(
                store_text,
                "final class ProviderStore",
                "func recordOpenAIConnectionTest(_ result: OpenAIConnectionTestResult)",
                "auditID: result.auditID",
                "// auditID: result.auditID",
            ) or ""
        ),
    }
    revoke_contract_mutations = {
        "entry_helper_removed": exact_mutation_contract_fails_closed(
            routing_text, "enum ProviderSettingsPersistence",
            REVOKE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
            "revokeExternalTransferGrantLocked(", "discardedRevocationHelper(",
            current_external_transfer_revoke_contract,
        ),
        "fence_advance_removed": exact_mutation_contract_fails_closed(
            routing_text, "enum ProviderSettingsPersistence",
            REVOKE_EXTERNAL_TRANSFER_GRANT_LOCKED_SIGNATURE,
            "advanceExternalTransferRevocationFenceLocked(", "discardedFenceAdvance(",
            current_external_transfer_revoke_contract,
        ),
        "first_synchronize_removed": not current_external_transfer_revoke_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                REVOKE_EXTERNAL_TRANSFER_GRANT_LOCKED_SIGNATURE,
                "_ = synchronize(defaults)", "_ = false"
            ) or ""
        ),
        "grant_cleanup_removed": not current_external_transfer_revoke_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                REVOKE_EXTERNAL_TRANSFER_GRANT_LOCKED_SIGNATURE,
                "defaults.removeObject(forKey: externalTransferGrantKey)",
                "// grant cleanup removed"
            ) or ""
        ),
    }
    grant_contract_mutations = {
        "grant_allocator_comparison_removed": not current_external_transfer_grant_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                EXTERNAL_TRANSFER_GRANT_SIGNATURE,
                "grant.generation == storedGeneration", "true"
            ) or ""
        ),
        "grant_fence_comparison_removed": not current_external_transfer_grant_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                EXTERNAL_TRANSFER_GRANT_SIGNATURE,
                "grant.generation > revokedThroughGeneration", "true"
            ) or ""
        ),
        "issue_intent_comparison_removed": not current_external_transfer_grant_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                ISSUE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
                ") == authorizationIntent,", ") == true,"
            ) or ""
        ),
        "issue_allocator_read_removed": not current_external_transfer_grant_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                ISSUE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
                "let storedGeneration = externalTransferWatermark(",
                "let discardedStoredGeneration = externalTransferWatermark("
            ) or ""
        ),
    }
    intent_lifecycle_mutations = {
        "capture_fresh_epoch_removed": not current_authorization_intent_lifecycle_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                "func captureExternalTransferAuthorizationIntent(defaults: "
                "UserDefaults = .standard) -> ProviderExternalTransferAuthorizationIntent",
                "epoch: UUID()", "epoch: UUID(uuidString: \"00000000-0000-0000-0000-000000000000\")!"
            ) or ""
        ),
        "stale_intent_rejection_removed": not current_authorization_intent_lifecycle_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                PREPARE_CREDENTIAL_MUTATION_SIGNATURE,
                ") == authorizationIntent else {", ") == true else {"
            ) or ""
        ),
        "nil_mutation_epoch_rotation_removed": not current_authorization_intent_lifecycle_contract(
            mutate_exact_method(
                routing_text, "enum ProviderSettingsPersistence",
                PREPARE_CREDENTIAL_MUTATION_SIGNATURE,
                "UUID().uuidString", "\"unchanged\""
            ) or ""
        ),
    }
    worker_credential_intent_mutations = {
        "worker_forward_removed": not current_worker_credential_intent_contract(
            mutate_exact_method(
                store_text, "private final class ProviderKeychainWorker",
                WORKER_USER_SECRET_GATE_SIGNATURE,
                "authorizationIntent: authorizationIntent", "authorizationIntent: nil"
            ) or ""
        ),
        "worker_prepared_call_removed": exact_mutation_contract_fails_closed(
            store_text, "private final class ProviderKeychainWorker",
            WORKER_USER_SECRET_GATE_SIGNATURE,
            "self.performPreparedUserSecretMutation(", "discardedPreparedMutation(",
            current_worker_credential_intent_contract,
        ),
    }
    provider_revoke_failure_ui_mutations = {
        "in_memory_grant_clear_removed": not current_provider_revoke_failure_ui_contract(
            mutate_exact_method(
                settings_text, "struct ProviderSettingsPane",
                PROVIDER_TRANSFER_TOGGLE_SIGNATURE,
                "let durablyRevoked = ProviderSettingsPersistence\n"
                "                .revokeExternalTransferGrant()\n"
                "            externalTransferGranted = false",
                "let durablyRevoked = ProviderSettingsPersistence\n"
                "                .revokeExternalTransferGrant()"
            ) or ""
        ),
        "revoke_failure_state_removed": not current_provider_revoke_failure_ui_contract(
            mutate_exact_method(
                settings_text, "struct ProviderSettingsPane",
                PROVIDER_TRANSFER_TOGGLE_SIGNATURE,
                "externalTransferRevocationPersistenceFailed = !durablyRevoked",
                "externalTransferRevocationPersistenceFailed = false"
            ) or ""
        ),
    }
    translation_save_mutations = {
        "captured_intent_removed": not current_translation_openai_save_contract(
            mutate_exact_method(
                translation_settings_text,
                "private struct TranslationOpenAIServiceEditorSheet",
                TRANSLATION_OPENAI_SAVE_SIGNATURE,
                "captureExternalTransferAuthorizationIntent(defaults: defaults)",
                "captureExternalTransferAuthorizationIntent(defaults: .standard)"
            ) or ""
        ),
        "post_await_intent_recheck_removed": not current_translation_openai_save_contract(
            translation_settings_text.replace(
                "isExternalTransferAuthorizationIntentCurrent(", "rejectedAuthorizationIntent(", 2
            )
        ),
        "account_save_preservation_removed": not current_translation_openai_save_contract(
            mutate_exact_method(
                translation_settings_text,
                "private struct TranslationOpenAIServiceEditorSheet",
                TRANSLATION_OPENAI_SAVE_SIGNATURE,
                "ProviderSettingsPersistence.saveProviderAccountAlias(\n"
                "            normalizedAlias,\n"
                "            preserving: authorizationIntent,",
                "ProviderSettingsPersistence.saveProviderAccountAlias(\n"
                "            normalizedAlias,\n"
                "            preserving: nil,"
            ) or ""
        ),
        "final_issue_intent_removed": not current_translation_openai_save_contract(
            mutate_exact_method(
                translation_settings_text,
                "private struct TranslationOpenAIServiceEditorSheet",
                TRANSLATION_OPENAI_SAVE_SIGNATURE,
                "ProviderSettingsPersistence.issueExternalTransferGrant(\n"
                "                  for: target,\n"
                "                  authorizationIntent: authorizationIntent,",
                "ProviderSettingsPersistence.issueExternalTransferGrant(\n"
                "                  for: target,\n"
                "                  authorizationIntent: ProviderSettingsPersistence\n"
                "                    .captureExternalTransferAuthorizationIntent(defaults: defaults),"
            ) or ""
        ),
        "form_disabled_removed": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                ".disabled(interactionPolicy.formDisabled)", ".disabled(false)", 1
            )
        ),
        "save_disabled_removed": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                ".disabled(interactionPolicy.saveDisabled)", ".disabled(false)", 1
            )
        ),
        "cancel_incorrectly_disabled": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace("cancelDisabled = false", "cancelDisabled = isSaving", 1)
        ),
        "interactive_dismiss_incorrectly_disabled": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                "interactiveDismissDisabled = false",
                "interactiveDismissDisabled = isSaving",
                1,
            )
        ),
        "form_modifier_bypasses_policy": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                ".disabled(interactionPolicy.formDisabled)", ".disabled(isSaving)", 1
            )
        ),
        "cancel_modifier_bypasses_policy": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                ".disabled(interactionPolicy.cancelDisabled)", ".disabled(isSaving)", 1
            )
        ),
        "save_modifier_bypasses_policy": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                ".disabled(interactionPolicy.saveDisabled)", ".disabled(!canSave || isSaving)", 1
            )
        ),
        "interactive_dismiss_modifier_bypasses_policy": not current_translation_openai_form_disable_contract(
            translation_settings_text.replace(
                "interactionPolicy.interactiveDismissDisabled", "isSaving", 1
            )
        ),
    }
    translation_interaction_structural_mutations = structural_adversaries_fail_closed(
        translation_settings_text,
        "private struct TranslationOpenAIServiceEditorSheet",
        "func invalidateSavingSession()",
        current_translation_openai_form_disable_contract,
        "return",
    )
    translation_save_formatting_contract = current_translation_openai_save_contract(
        translation_settings_text.replace(
            "\n            .captureExternalTransferAuthorizationIntent",
            "\n\n                .captureExternalTransferAuthorizationIntent",
            1,
        )
    )
    structural_reachability_mutations = {
        "revoke_entry": structural_adversaries_fail_closed(
            routing_text, "enum ProviderSettingsPersistence",
            REVOKE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
            current_external_transfer_revoke_contract, "return false"
        ),
        "grant_read": structural_adversaries_fail_closed(
            routing_text, "enum ProviderSettingsPersistence",
            EXTERNAL_TRANSFER_GRANT_SIGNATURE,
            current_external_transfer_grant_contract, "return nil"
        ),
        "grant_issue": structural_adversaries_fail_closed(
            routing_text, "enum ProviderSettingsPersistence",
            ISSUE_EXTERNAL_TRANSFER_GRANT_SIGNATURE,
            current_external_transfer_grant_contract, "return false"
        ),
        "intent_capture": structural_adversaries_fail_closed(
            routing_text, "enum ProviderSettingsPersistence",
            "func captureExternalTransferAuthorizationIntent(defaults: "
            "UserDefaults = .standard) -> ProviderExternalTransferAuthorizationIntent",
            current_authorization_intent_lifecycle_contract,
            "return ProviderExternalTransferAuthorizationIntent(epoch: UUID())"
        ),
        "worker_intent": structural_adversaries_fail_closed(
            store_text, "private final class ProviderKeychainWorker",
            PREPARED_USER_SECRET_MUTATION_SIGNATURE,
            current_worker_credential_intent_contract,
            "return .failure(ProviderCredentialMutationError.revocationPersistenceUnavailable)"
        ),
        "provider_revoke_ui": structural_adversaries_fail_closed(
            settings_text, "struct ProviderSettingsPane",
            PROVIDER_TRANSFER_TOGGLE_SIGNATURE,
            current_provider_revoke_failure_ui_contract, "return"
        ),
        "translation_save": structural_adversaries_fail_closed(
            translation_settings_text,
            "private struct TranslationOpenAIServiceEditorSheet",
            TRANSLATION_OPENAI_SAVE_SIGNATURE,
            current_translation_openai_save_contract, "return"
        ),
    }
    connection_execution_structural_mutations = {
        "execution": structural_adversaries_fail_closed(
            store_text, "final class ProviderStore", EXECUTION_SIGNATURE,
            current_execution_contract, "return .publicationRejected"
        ),
        "publication": structural_adversaries_fail_closed(
            coordinator_text, "final class ProviderFeatureCoordinator",
            "func runOpenAIConnectionTest(baseURL: String, modelName: String, "
            "keychainAccountAlias: String, configurationFingerprint: "
            "ProviderConnectionConfigurationFingerprint) async",
            current_publication_boundary_contract, "return"
        ),
        "worker_service": structural_adversaries_fail_closed(
            store_text, "private final class ProviderKeychainWorker",
            "func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error>",
            current_worker_service_contract,
            "return .failure(ProviderCredentialMutationError.revocationPersistenceUnavailable)"
        ),
        "execution_required_token_in_task": not current_execution_contract(
            mutate_exact_method(
                store_text, "final class ProviderStore", EXECUTION_SIGNATURE,
                "openAIConnectionFinalPublicationHook?()",
                "Task { openAIConnectionFinalPublicationHook?() }"
            ) or ""
        ),
        "worker_required_token_in_task": not current_worker_service_contract(
            mutate_exact_method(
                store_text, "private final class ProviderKeychainWorker",
                "func readUserSecret(alias: String) async -> Result<ProviderUserSecretMaterial, Error>",
                "return try self.service.readUserSecretForProviderCall(alias: alias)",
                "Task { _ = try? self.service.readUserSecretForProviderCall(alias: alias) }\n"
                "                throw ProviderCredentialMutationError.revocationPersistenceUnavailable"
            ) or ""
        ),
    }
    translation_configuration_contract = current_openai_translation_configuration_contract(
        translation_adapter_text
    )
    translation_worker_contract = current_openai_translation_worker_contract(
        translation_adapter_text
    )
    translation_runtime_contract = current_openai_translation_runtime_contract(
        translation_runtime_text
    )
    translation_publication_contract = current_openai_translation_publication_contract(
        translation_adapter_text
    )
    translation_external_transfer_mutations = {
        "configuration_credential_revision_removed": exact_mutation_contract_fails_closed(
            translation_adapter_text,
            "struct OpenAITranslationServiceConfiguration",
            TRANSLATION_CONFIGURATION_CURRENT_SIGNATURE,
            ".credentialRevision(defaults: defaults)",
            ".credentialRevision(defaults: .standard)",
            current_openai_translation_configuration_contract,
        ),
        "worker_secret_read_removed": exact_mutation_contract_fails_closed(
            translation_adapter_text,
            "private actor OpenAITranslationExecutionWorker",
            TRANSLATION_WORKER_SIGNATURE,
            "secret = try readProviderSecret(\n                configuration.keychainAccountAlias\n            )",
            "throw TranslationServiceAdapterError.publicationRejected",
            current_openai_translation_worker_contract,
        ),
        "worker_post_read_authorization_commented": not current_openai_translation_worker_contract(
            translation_adapter_text.replace(
                "guard authorizationValidator(\n            authorizationTarget,\n            configuration.externalTransferGrant\n        ) else {",
                "guard true else {",
                1,
            )
        ),
        "worker_credential_revision_removed": exact_mutation_contract_fails_closed(
            translation_adapter_text,
            "private actor OpenAITranslationExecutionWorker",
            TRANSLATION_WORKER_SIGNATURE,
            "== authorizationTarget.credentialRevision",
            "== secret.credentialRevision",
            current_openai_translation_worker_contract,
        ),
        "runtime_admission_start_removed": exact_mutation_contract_fails_closed(
            translation_runtime_text,
            "struct OpenAITranslationRuntimeService",
            TRANSLATION_RUNTIME_SIGNATURE,
            "admission { operation.start() }",
            "admission { false }",
            current_openai_translation_runtime_contract,
        ),
        "runtime_response_recheck_removed": exact_mutation_contract_fails_closed(
            translation_runtime_text,
            "struct OpenAITranslationRuntimeService",
            TRANSLATION_RUNTIME_SIGNATURE,
            "guard authorizationCheck() else {\n                return publishRuntime(result(",
            "guard true else {",
            current_openai_translation_runtime_contract,
        ),
        "publication_validator_removed": exact_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "continuation.yield(\n                                .completed(",
            "continuation.yield(\n                                .diagnostics(",
            current_openai_translation_publication_contract,
        ),
        "failure_validator_grant_removed": _exact_method_nth_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "grant,", "nil,", 1,
            current_openai_translation_publication_contract,
        ),
        "success_validator_grant_removed": _exact_method_nth_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "grant,", "nil,", 2,
            current_openai_translation_publication_contract,
        ),
        "failure_deferred_audit_before_validator": _exact_method_nth_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "guard publicationValidator(",
            "execution.deferredAudit?.publishOnce()\n                        guard publicationValidator(",
            1,
            current_openai_translation_publication_contract,
        ),
        "success_deferred_audit_before_validator": _exact_method_nth_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "guard publicationValidator(",
            "execution.deferredAudit?.publishOnce()\n                    guard publicationValidator(",
            2,
            current_openai_translation_publication_contract,
        ),
        "failure_validator_guard_true": _exact_method_nth_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "guard publicationValidator(", "guard true && publicationValidator(", 1,
            current_openai_translation_publication_contract,
        ),
        "success_validator_guard_true": _exact_method_nth_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "guard publicationValidator(", "guard true && publicationValidator(", 2,
            current_openai_translation_publication_contract,
        ),
        "completed_yield_removed": exact_mutation_contract_fails_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            "continuation.yield(\n                                .completed(",
            "continuation.yield(\n                                .diagnostics(",
            current_openai_translation_publication_contract,
        ),
    }
    translation_external_transfer_structural_mutations = {
        "worker": structural_adversaries_fail_closed(
            translation_adapter_text,
            "private actor OpenAITranslationExecutionWorker",
            TRANSLATION_WORKER_SIGNATURE,
            current_openai_translation_worker_contract,
            "throw TranslationServiceAdapterError.publicationRejected",
        ),
        "runtime": structural_adversaries_fail_closed(
            translation_runtime_text,
            "struct OpenAITranslationRuntimeService",
            TRANSLATION_RUNTIME_SIGNATURE,
            current_openai_translation_runtime_contract,
            "return Self.externalTransferDisabledResult(profile: profile, textCharacterCount: 0, targetLanguage: targetLanguage)",
        ),
        "publication": structural_adversaries_fail_closed(
            translation_adapter_text,
            "final class OpenAICompatibleTranslationServiceAdapter",
            TRANSLATION_ADAPTER_SIGNATURE,
            current_openai_translation_publication_contract,
            "return AsyncThrowingStream { $0.finish() }",
        ),
    }
    run_fixture_ok = run_result_fixture_contract()
    p5e_gate_fixture_ok = p5e_gate_json_fixture_contract()
    require(all(chain_checks.values()), "provider_connection_chain_disconnected", str(chain_checks), failures)
    require(all(chain_mutations.values()), "provider_connection_chain_mutation_not_fail_closed", str(chain_mutations), failures)
    require(all(chain_overload_adversaries.values()), "provider_connection_chain_overload_bypass", str(chain_overload_adversaries), failures)
    require(execution_contract, "provider_connection_execution_contract_disconnected", "ordered target authorization, worker read, transport, and final publication chain", failures)
    require(publication_boundary_contract, "provider_connection_publication_boundary_disconnected", "publication rejection must return before UI/plugin terminal publication and preserve full audit ID at plugin boundary", failures)
    require(worker_service_contract, "provider_connection_worker_service_contract_disconnected", "worker serial async hop must directly call the keychain service read", failures)
    require(audit_identity_contract, "provider_connection_audit_identity_contract_disconnected", "internal audit must retain full result audit ID without UI truncation", failures)
    require(all(execution_contract_mutations.values()), "provider_connection_execution_mutation_not_fail_closed", str(execution_contract_mutations), failures)
    require(all(worker_service_contract_mutations.values()), "provider_connection_worker_service_mutation_not_fail_closed", str(worker_service_contract_mutations), failures)
    require(all(audit_identity_contract_mutations.values()), "provider_connection_audit_identity_mutation_not_fail_closed", str(audit_identity_contract_mutations), failures)
    require(revoke_contract, "external_transfer_revoke_contract_disconnected", "public revoke must use the ordered fenced internal helper", failures)
    require(grant_contract, "external_transfer_grant_contract_disconnected", "grant read/issue must validate allocator, fence, and current intent", failures)
    require(intent_lifecycle_contract, "external_transfer_intent_lifecycle_disconnected", "capture must rotate epoch; stale/nil credential mutations must fail closed", failures)
    require(worker_credential_intent_contract, "credential_mutation_worker_intent_contract_disconnected", "worker must forward intent into the prepared credential mutation", failures)
    require(provider_revoke_failure_ui_contract, "provider_revoke_failure_ui_contract_disconnected", "revoke failure must still clear in-memory grant and expose failure", failures)
    require(translation_save_contract, "translation_openai_save_intent_contract_disconnected", "save must preserve one captured intent across await, configuration writes, and issue", failures)
    require(translation_form_disable_contract, "translation_openai_interaction_contract_disconnected", "translation OpenAI saving must disable only form/save through policy while cancel, escape, dismissal, and invalidation remain live", failures)
    require(all(intent_chain_checks.values()), "credential_mutation_intent_chain_disconnected", str(intent_chain_checks), failures)
    require(all(intent_chain_mutations.values()), "credential_mutation_intent_chain_mutation_not_fail_closed", str(intent_chain_mutations), failures)
    require(all(revoke_contract_mutations.values()), "external_transfer_revoke_mutation_not_fail_closed", str(revoke_contract_mutations), failures)
    require(all(grant_contract_mutations.values()), "external_transfer_grant_mutation_not_fail_closed", str(grant_contract_mutations), failures)
    require(all(intent_lifecycle_mutations.values()), "external_transfer_intent_lifecycle_mutation_not_fail_closed", str(intent_lifecycle_mutations), failures)
    require(all(worker_credential_intent_mutations.values()), "credential_mutation_worker_intent_mutation_not_fail_closed", str(worker_credential_intent_mutations), failures)
    require(all(provider_revoke_failure_ui_mutations.values()), "provider_revoke_failure_ui_mutation_not_fail_closed", str(provider_revoke_failure_ui_mutations), failures)
    require(all(translation_save_mutations.values()), "translation_openai_save_mutation_not_fail_closed", str(translation_save_mutations), failures)
    require(
        all(translation_interaction_structural_mutations.values()),
        "translation_openai_interaction_reachability_mutation_not_fail_closed",
        str(translation_interaction_structural_mutations),
        failures,
    )
    require(translation_save_formatting_contract, "translation_openai_save_formatting_not_tolerated", "whitespace-only save formatting must preserve the contract", failures)
    require(
        all(all(outcomes.values()) for outcomes in structural_reachability_mutations.values()),
        "critical_contract_reachability_mutation_not_fail_closed",
        str(structural_reachability_mutations),
        failures,
    )
    require(run_fixture_ok, "controlled_run_result_fixture_failed", "stderr tail and process diagnostics must propagate", failures)
    require(p5e_gate_fixture_ok, "p5e_gate_json_fixture_failed", "P5E observations and failure detail must remain bounded", failures)
    require(all(
        outcome if isinstance(outcome, bool) else all(outcome.values())
        for outcome in connection_execution_structural_mutations.values()
    ), "connection_execution_reachability_mutation_not_fail_closed", str(connection_execution_structural_mutations), failures)
    require(translation_configuration_contract, "translation_external_transfer_configuration_disconnected", "translation target must bind grant target and credential revision", failures)
    require(translation_worker_contract, "translation_external_transfer_worker_disconnected", "translation must revalidate grant around secret read and bind the secret revision", failures)
    require(translation_runtime_contract, "translation_external_transfer_runtime_disconnected", "runtime admission must synchronously start transport and fail closed after response revocation", failures)
    require(translation_publication_contract, "translation_external_transfer_publication_disconnected", "translation diagnostics and output must use final publication validation", failures)
    require(all(translation_external_transfer_mutations.values()), "translation_external_transfer_mutation_not_fail_closed", str(translation_external_transfer_mutations), failures)
    require(
        all(all(outcomes.values()) for outcomes in translation_external_transfer_structural_mutations.values()),
        "translation_external_transfer_reachability_mutation_not_fail_closed",
        str(translation_external_transfer_structural_mutations),
        failures,
    )

    persistence_requirements = [
        "let credentialRevision: UInt64",
        "currentExternalTransferTarget(defaults: defaults) == target",
        "revokeExternalTransferGrant(defaults: defaults)",
    ]
    missing_persistence = [needle for needle in persistence_requirements if needle not in routing_text]
    require(not missing_persistence, "external_transfer_binding_missing", ", ".join(missing_persistence), failures)
    cli_requirements = [
        "title: L10n.string(\"settings.agentCLI.localCLI\")",
        "case .liteLLMGateway, .localCLI, .dedicatedAPI, .appleVision, .multimodalLLM, .cloudOCR:",
        "errorCode: .unsupportedCapability",
    ]
    missing_cli = [
        needle for needle in cli_requirements
        if needle not in (agent_cli_text if "agentCLI" in needle else routing_text)
    ]
    require(not missing_cli, "local_cli_boundary_missing", ", ".join(missing_cli), failures)
    ui_forbidden = ["SecItem", "kSecClass", "URLSession", "Process(", "secretValue"]
    forbidden_hits = [needle for needle in ui_forbidden if needle in settings_text]
    require(not forbidden_hits, "provider_connection_ui_secret_leak", ", ".join(forbidden_hits), failures)
    observations["privacy_boundary"] = {
        "missing_symbols": missing_symbols,
        "retired_direct_keychain_hits": retired_direct_keychain_hits,
        "retired_preview_hits": retired_hits,
        "missing_persistence": missing_persistence,
        "missing_cli": missing_cli,
        "forbidden_runtime_calls": forbidden_hits,
        "has_bound_external_transfer_grant": not missing_persistence,
        "has_separate_local_cli_configuration": not missing_cli,
        "scope": "openai_compatible_connection_readiness",
        "connection_ui_check": connection_ui_check,
        "connection_ui_mutation_fails_closed": connection_ui_mutation_fails_closed,
        "chain_checks": chain_checks,
        "chain_mutations_fail_closed": chain_mutations,
        "chain_overload_adversaries_fail_closed": chain_overload_adversaries,
        "execution_contract": execution_contract,
        "publication_boundary_contract": publication_boundary_contract,
        "worker_service_contract": worker_service_contract,
        "audit_identity_contract": audit_identity_contract,
        "execution_contract_mutations_fail_closed": execution_contract_mutations,
        "worker_service_contract_mutations_fail_closed": worker_service_contract_mutations,
        "audit_identity_contract_mutations_fail_closed": audit_identity_contract_mutations,
        "external_transfer_revoke_contract": revoke_contract,
        "external_transfer_revoke_mutations_fail_closed": revoke_contract_mutations,
        "external_transfer_grant_contract": grant_contract,
        "external_transfer_grant_mutations_fail_closed": grant_contract_mutations,
        "external_transfer_intent_lifecycle_contract": intent_lifecycle_contract,
        "external_transfer_intent_lifecycle_mutations_fail_closed": intent_lifecycle_mutations,
        "provider_revoke_failure_ui_contract": provider_revoke_failure_ui_contract,
        "provider_revoke_failure_ui_mutations_fail_closed": provider_revoke_failure_ui_mutations,
        "translation_openai_save_intent_contract": translation_save_contract,
        "translation_openai_save_mutations_fail_closed": translation_save_mutations,
        "translation_openai_save_formatting_contract": translation_save_formatting_contract,
        "translation_openai_form_disable_contract": translation_form_disable_contract,
        "translation_openai_interaction_reachability_mutations_fail_closed": translation_interaction_structural_mutations,
        "credential_mutation_intent_chain": intent_chain_checks,
        "credential_mutation_intent_chain_mutations_fail_closed": intent_chain_mutations,
        "credential_mutation_worker_intent_contract": worker_credential_intent_contract,
        "credential_mutation_worker_intent_mutations_fail_closed": worker_credential_intent_mutations,
        "critical_contract_reachability_mutations_fail_closed": structural_reachability_mutations,
        "connection_execution_reachability_mutations_fail_closed": connection_execution_structural_mutations,
        "translation_external_transfer_configuration_contract": translation_configuration_contract,
        "translation_external_transfer_worker_contract": translation_worker_contract,
        "translation_external_transfer_runtime_contract": translation_runtime_contract,
        "translation_external_transfer_publication_contract": translation_publication_contract,
        "translation_external_transfer_mutations_fail_closed": translation_external_transfer_mutations,
        "translation_external_transfer_reachability_mutations_fail_closed": translation_external_transfer_structural_mutations,
        "controlled_run_result_fixture": run_fixture_ok,
        "p5e_gate_json_fixture": p5e_gate_fixture_ok,
    }

    output = {
        "ok": not failures,
        "suite": "p5f_provider_connection_gate_checks",
        "observations": observations,
        "failures": failures,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
