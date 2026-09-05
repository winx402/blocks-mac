#!/usr/bin/env python3
"""P2 action-core smoke test.

This dependency-free harness validates the proposed CLI JSON contract against
the schema/catalog files under docs/技术知识库/action-schemas. It does not read
the real screen, pasteboard, files, or external models.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_ROOT = ROOT / "docs" / "技术知识库" / "action-schemas"
CATALOG_PATH = SCHEMA_ROOT / "actions.catalog.json"
ENVELOPE_SCHEMA_PATH = SCHEMA_ROOT / "shared" / "envelope.schema.json"
HOOK_SCHEMA_PATH = SCHEMA_ROOT / "hooks" / "hook-manifest.schema.json"

CONFIRMATION_PRIORITY = {
    "preview": 1,
    "external_transfer": 2,
    "destructive_or_hook": 3,
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_catalog() -> dict[str, Any]:
    catalog = load_json(CATALOG_PATH)
    if not isinstance(catalog, dict) or "actions" not in catalog:
        raise SystemExit(f"Invalid catalog: {CATALOG_PATH}")
    return catalog


def action_defs() -> dict[str, dict[str, Any]]:
    return load_catalog()["actions"]


def schema_path(action: str, kind: str) -> Path:
    actions = action_defs()
    if action not in actions:
        raise KeyError(action)
    key = f"{kind}_schema"
    return SCHEMA_ROOT / actions[action][key]


def load_action_schema(action: str, kind: str) -> dict[str, Any]:
    return load_json(schema_path(action, kind))


def json_type_name(value: Any) -> str:
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int) and not isinstance(value, bool):
        return "integer"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    if value is None:
        return "null"
    return type(value).__name__


def type_matches(expected: str, value: Any) -> bool:
    actual = json_type_name(value)
    if expected == "number":
        return actual in {"integer", "number"}
    return actual == expected


def resolve_ref(ref: str, base_path: Path) -> tuple[dict[str, Any], Path]:
    if ref.startswith("#"):
        raise ValueError(f"Local JSON pointer refs are not supported in this spike: {ref}")
    ref_path = (base_path.parent / ref).resolve()
    return load_json(ref_path), ref_path


def validate_instance(schema: dict[str, Any], instance: Any, *, base_path: Path, path: str = "$") -> list[str]:
    errors: list[str] = []

    if "$ref" in schema:
        ref_schema, ref_path = resolve_ref(schema["$ref"], base_path)
        return validate_instance(ref_schema, instance, base_path=ref_path, path=path)

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: expected one of {schema['enum']}, got {instance!r}")

    expected_type = schema.get("type")
    if expected_type:
        if not type_matches(expected_type, instance):
            errors.append(f"{path}: expected {expected_type}, got {json_type_name(instance)}")
            return errors

    if isinstance(instance, str):
        min_length = schema.get("minLength")
        if min_length is not None and len(instance) < min_length:
            errors.append(f"{path}: string shorter than minLength {min_length}")
        pattern = schema.get("pattern")
        if pattern and not re.search(pattern, instance):
            errors.append(f"{path}: string does not match pattern {pattern}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        minimum = schema.get("minimum")
        maximum = schema.get("maximum")
        if minimum is not None and instance < minimum:
            errors.append(f"{path}: number below minimum {minimum}")
        if maximum is not None and instance > maximum:
            errors.append(f"{path}: number above maximum {maximum}")

    if isinstance(instance, list):
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(instance):
                errors.extend(validate_instance(item_schema, item, base_path=base_path, path=f"{path}[{index}]"))

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for field in required:
            if field not in instance:
                errors.append(f"{path}: missing required field {field!r}")

        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for field, value in instance.items():
            if field in properties:
                errors.extend(validate_instance(properties[field], value, base_path=base_path, path=f"{path}.{field}"))
            elif additional is False:
                errors.append(f"{path}: unexpected field {field!r}")

    return errors


def defaults_for(schema: dict[str, Any]) -> dict[str, Any]:
    defaults: dict[str, Any] = {}
    for field, field_schema in schema.get("properties", {}).items():
        if "default" in field_schema:
            defaults[field] = field_schema["default"]
    return defaults


def with_defaults(schema: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    merged = defaults_for(schema)
    merged.update(payload)
    return merged


def validate_or_exit(schema: dict[str, Any], instance: Any, *, base_path: Path, label: str) -> None:
    errors = validate_instance(schema, instance, base_path=base_path)
    if errors:
        raise SystemExit(f"{label} validation failed:\n" + "\n".join(f"- {error}" for error in errors))


def audit_id(action: str, payload: dict[str, Any]) -> str:
    raw = json.dumps({"action": action, "payload": payload}, sort_keys=True)
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]
    return f"act_{int(time.time())}_{digest}"


def error_payload(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def confirmation(level: str, reason: str, preview: dict[str, Any]) -> dict[str, Any]:
    return {"level": level, "reason": reason, "preview": preview}


def envelope(
    action: str,
    *,
    ok: bool,
    result: dict[str, Any] | None = None,
    warnings: list[str] | None = None,
    error: dict[str, Any] | None = None,
    requires_confirmation: dict[str, Any] | None = None,
    input_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "ok": ok,
        "action": action,
        "result": result or {},
        "warnings": warnings or [],
        "audit_id": audit_id(action, input_payload or {}),
    }
    if error:
        body["error"] = error
    if requires_confirmation:
        body["requires_confirmation"] = requires_confirmation
    validate_envelope(body)
    return body


def validate_envelope(body: dict[str, Any]) -> None:
    schema = load_json(ENVELOPE_SCHEMA_PATH)
    validate_or_exit(schema, body, base_path=ENVELOPE_SCHEMA_PATH, label="envelope")
    if body["ok"] and body["action"] in action_defs():
        output_schema = load_action_schema(body["action"], "output")
        validate_or_exit(output_schema, body["result"], base_path=schema_path(body["action"], "output"), label="result")


def highest_confirmation(current: dict[str, Any] | None, candidate: dict[str, Any]) -> dict[str, Any]:
    if current is None:
        return candidate
    if CONFIRMATION_PRIORITY[candidate["level"]] > CONFIRMATION_PRIORITY[current["level"]]:
        return candidate
    return current


def required_confirmation(action: str, payload: dict[str, Any]) -> dict[str, Any] | None:
    request: dict[str, Any] | None = None

    if action == "blocks.screenshot.capture":
        if not payload.get("dry_run", True):
            request = highest_confirmation(
                request,
                confirmation(
                    "preview",
                    "Real screen capture must be visible to the user before execution in this spike.",
                    {"mode": payload["mode"], "send_to_ai": payload.get("send_to_ai", False)},
                ),
            )
        if payload.get("send_to_ai", False):
            request = highest_confirmation(
                request,
                confirmation(
                    "external_transfer",
                    "Screenshot content may be transferred to an external provider.",
                    {"mode": payload["mode"], "send_to_ai": True},
                ),
            )

    if action == "blocks.clipboard.search" and payload.get("include_content", False):
        request = confirmation(
            "preview",
            "Full clipboard content requires explicit authorization.",
            {"query": payload.get("query", ""), "limit": payload.get("limit", 10)},
        )

    if action == "blocks.translate.text":
        provider = payload.get("provider", "mock")
        source = payload.get("source", "manual")
        if provider != "mock":
            request = highest_confirmation(
                request,
                confirmation(
                    "external_transfer",
                    "Non-mock providers may receive user text.",
                    {"provider": provider, "source": source, "characters": len(payload["text"])},
                ),
            )
        if source in {"clipboard", "screenshot"}:
            request = highest_confirmation(
                request,
                confirmation(
                    "external_transfer",
                    "Screenshot and clipboard sources are sensitive local context.",
                    {"provider": provider, "source": source, "characters": len(payload["text"])},
                ),
            )

    return request


def run_action(action: str, payload: dict[str, Any]) -> dict[str, Any]:
    actions = action_defs()
    if action not in actions:
        return envelope(
            action,
            ok=False,
            error=error_payload("unknown_action", f"Unknown action: {action}"),
            input_payload=payload,
        )

    input_schema_path = schema_path(action, "input")
    input_schema = load_json(input_schema_path)
    payload = with_defaults(input_schema, payload)
    errors = validate_instance(input_schema, payload, base_path=input_schema_path)
    if errors:
        return envelope(
            action,
            ok=False,
            error=error_payload("invalid_input", "; ".join(errors)),
            input_payload=payload,
        )

    confirmation_request = required_confirmation(action, payload)
    if confirmation_request:
        return envelope(
            action,
            ok=False,
            requires_confirmation=confirmation_request,
            error=error_payload("requires_confirmation", "Confirmation required."),
            input_payload=payload,
        )

    if action == "blocks.screenshot.capture":
        return envelope(
            action,
            ok=True,
            result={"capture_id": "cap_mock", "mode": payload["mode"], "image_available": False},
            warnings=["dry_run_only"],
            input_payload=payload,
        )

    if action == "blocks.clipboard.search":
        return envelope(
            action,
            ok=True,
            result={
                "items": [
                    {
                        "id": "clip_mock_1",
                        "kind": "text",
                        "created_at": "2026-07-01T00:00:00Z",
                        "summary": "Mock clipboard item; content redacted.",
                    }
                ],
                "truncated": False,
            },
            input_payload=payload,
        )

    if action == "blocks.translate.text":
        return envelope(
            action,
            ok=True,
            result={
                "source_language": payload.get("source_language", "auto"),
                "target_language": payload["target_language"],
                "text": f"[mock:{payload['target_language']}] {payload['text']}",
            },
            warnings=["mock_translation"],
            input_payload=payload,
        )

    raise AssertionError(f"unhandled action: {action}")


def validate_hook_manifest(path: Path) -> list[str]:
    manifest = load_json(path)
    schema = load_json(HOOK_SCHEMA_PATH)
    errors = validate_instance(schema, manifest, base_path=HOOK_SCHEMA_PATH)
    if manifest.get("created_by") == "agent" and manifest.get("status") != "draft":
        errors.append("$.status: agent-created hooks must remain draft until user enables them")
    if manifest.get("status") == "enabled" and manifest.get("confirmation_level") != "destructive_or_hook":
        errors.append("$.confirmation_level: enabled hooks require destructive_or_hook confirmation")
    if manifest.get("effect") in {"block", "modify", "external_transfer"}:
        if manifest.get("confirmation_level") != "destructive_or_hook":
            errors.append("$.confirmation_level: block/modify/external_transfer hooks require destructive_or_hook")
    return errors


def validate_schemas() -> dict[str, Any]:
    checked: list[str] = []
    catalog = load_catalog()
    checked.append(str(CATALOG_PATH.relative_to(ROOT)))

    for shared in [
        SCHEMA_ROOT / "shared" / "confirmation.schema.json",
        SCHEMA_ROOT / "shared" / "error.schema.json",
        ENVELOPE_SCHEMA_PATH,
        HOOK_SCHEMA_PATH,
    ]:
        schema = load_json(shared)
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            raise SystemExit(f"{shared} must use JSON Schema Draft 2020-12")
        checked.append(str(shared.relative_to(ROOT)))

    for action, definition in catalog["actions"].items():
        for kind in ["input", "output"]:
            path = SCHEMA_ROOT / definition[f"{kind}_schema"]
            schema = load_json(path)
            if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
                raise SystemExit(f"{path} must use JSON Schema Draft 2020-12")
            checked.append(str(path.relative_to(ROOT)))
        if not definition.get("confirmation_rules"):
            raise SystemExit(f"{action} must define confirmation_rules")

    for example in sorted((SCHEMA_ROOT / "examples").glob("*.json")):
        payload = load_json(example)
        if "hook_id" in payload:
            hook_errors = validate_hook_manifest(example)
            if hook_errors:
                raise SystemExit(f"{example} hook validation failed:\n" + "\n".join(hook_errors))
        else:
            validate_envelope(payload)
        checked.append(str(example.relative_to(ROOT)))

    return {"ok": True, "checked": checked, "count": len(checked)}


def emit(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))


def parse_json_arg(raw: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit("JSON payload must be an object")
    return value


def run_smoke() -> dict[str, Any]:
    cases = [
        ("blocks.screenshot.capture", {"mode": "region", "dry_run": True}),
        ("blocks.clipboard.search", {"query": "hello", "limit": 5, "include_content": False}),
        ("blocks.translate.text", {"text": "hello", "target_language": "zh", "provider": "mock"}),
        ("blocks.clipboard.search", {"include_content": True}),
        ("blocks.translate.text", {"text": "hello", "target_language": "zh", "provider": "codex"}),
        ("blocks.screenshot.capture", {"mode": "region", "dry_run": False}),
        ("blocks.translate.text", {"text": "hello"}),
        ("missing.action", {}),
    ]
    results = [run_action(action, payload) for action, payload in cases]
    hook_path = SCHEMA_ROOT / "examples" / "hook-sensitive-clipboard-review.json"
    hook_errors = validate_hook_manifest(hook_path)
    return {
        "ok": all("audit_id" in item for item in results) and not hook_errors,
        "cases": len(cases),
        "requires_confirmation_cases": sum(1 for item in results if "requires_confirmation" in item),
        "hook_validated": not hook_errors,
        "results": results,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="P2 action-core smoke test")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate-schemas")
    sub.add_parser("list")

    schema_parser = sub.add_parser("schema")
    schema_parser.add_argument("action")
    schema_parser.add_argument("--kind", choices=["input", "output"], default="input")

    run_parser = sub.add_parser("run")
    run_parser.add_argument("action")
    run_parser.add_argument("--json", required=True, help="JSON object payload")

    hook_parser = sub.add_parser("validate-hook")
    hook_parser.add_argument("--json", required=True, help="Hook manifest JSON file")

    sub.add_parser("smoke")
    args = parser.parse_args(argv)

    if args.command == "validate-schemas":
        emit(validate_schemas())
        return 0

    if args.command == "list":
        emit({"actions": sorted(action_defs())})
        return 0

    if args.command == "schema":
        try:
            emit({"ok": True, "action": args.action, "kind": args.kind, "schema": load_action_schema(args.action, args.kind)})
            return 0
        except KeyError:
            emit({"ok": False, "error": error_payload("unknown_action", args.action)})
            return 1

    if args.command == "run":
        emit(run_action(args.action, parse_json_arg(args.json)))
        return 0

    if args.command == "validate-hook":
        hook_path = (ROOT / args.json).resolve()
        errors = validate_hook_manifest(hook_path)
        emit({"ok": not errors, "errors": errors, "path": str(hook_path)})
        return 0 if not errors else 1

    if args.command == "smoke":
        result = run_smoke()
        emit(result)
        return 0 if result["ok"] else 1

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
