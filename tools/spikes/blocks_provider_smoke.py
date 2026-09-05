#!/usr/bin/env python3
"""P2-B provider smoke tests for 积木工具.

The script validates a low-sensitive Codex CLI provider call. It records
capability, timing, and structured-output status without persisting raw JSONL
events or secrets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any


LOW_SENSITIVE_PROMPT = (
    'Return exactly one JSON object matching the provided schema: '
    '{"ok":true,"message":"pong","input_characters":4}. '
    "Do not include explanations or extra keys."
)

OUTPUT_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["ok", "message", "input_characters"],
    "properties": {
        "ok": {"type": "boolean"},
        "message": {"type": "string", "enum": ["pong"]},
        "input_characters": {"type": "integer", "minimum": 4, "maximum": 4},
    },
}


def audit_id(provider: str, payload: dict[str, Any]) -> str:
    raw = json.dumps({"provider": provider, "payload": payload}, sort_keys=True)
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]
    return f"provider_{int(time.time())}_{digest}"


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def run_command(args: list[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=False,
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def parse_json_lines(raw: str) -> tuple[int, dict[str, int], dict[str, Any] | None]:
    event_count = 0
    event_types: dict[str, int] = {}
    structured: dict[str, Any] | None = None

    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_count += 1
        event_type = str(event.get("type", "unknown"))
        event_types[event_type] = event_types.get(event_type, 0) + 1
        structured = find_structured_output(event) or structured

    return event_count, event_types, structured


def find_structured_output(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if set(["ok", "message", "input_characters"]).issubset(value):
            return value
        for child in value.values():
            found = find_structured_output(child)
            if found:
                return found
    if isinstance(value, list):
        for child in value:
            found = find_structured_output(child)
            if found:
                return found
    if isinstance(value, str):
        text = value.strip()
        if text.startswith("{") and text.endswith("}"):
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                return None
            return find_structured_output(parsed)
    return None


def validate_structured_output(value: dict[str, Any] | None) -> list[str]:
    if value is None:
        return ["missing structured output"]
    errors: list[str] = []
    if value.get("ok") is not True:
        errors.append("ok must be true")
    if value.get("message") != "pong":
        errors.append("message must be pong")
    if value.get("input_characters") != 4:
        errors.append("input_characters must be 4")
    extra = sorted(set(value) - {"ok", "message", "input_characters"})
    if extra:
        errors.append(f"unexpected keys: {extra}")
    return errors


def codex_version() -> str:
    codex = shutil.which("codex")
    if not codex:
        return "not_found"
    result = run_command([codex, "--version"], timeout=10)
    return (result.stdout or result.stderr).strip()


def run_codex(timeout: int) -> dict[str, Any]:
    codex = shutil.which("codex")
    if not codex:
        payload = {
            "ok": False,
            "provider": "codex",
            "status": "provider_unavailable",
            "version": "not_found",
            "warnings": ["codex CLI was not found in PATH"],
        }
        payload["audit_id"] = audit_id("codex", payload)
        return payload

    started = time.monotonic()
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".schema.json", delete=True) as schema_file:
        json.dump(OUTPUT_SCHEMA, schema_file)
        schema_file.flush()
        command = [
            codex,
            "exec",
            "--ephemeral",
            "--sandbox",
            "read-only",
            "--cd",
            "/tmp",
            "--skip-git-repo-check",
            "--output-schema",
            schema_file.name,
            "--json",
            LOW_SENSITIVE_PROMPT,
        ]
        try:
            result = run_command(command, timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired as exc:
            result = subprocess.CompletedProcess(command, 124, exc.stdout or "", exc.stderr or "")
            timed_out = True

    duration_ms = int((time.monotonic() - started) * 1000)
    event_count, event_types, structured = parse_json_lines(result.stdout)
    validation_errors = validate_structured_output(structured)
    stderr_summary = (result.stderr or "").strip().splitlines()[:3]

    status = "ok"
    if timed_out:
        status = "provider_timeout"
    elif result.returncode != 0:
        status = "provider_error"
    elif validation_errors:
        status = "provider_invalid_output"

    command_shape = [
        "codex",
        "exec",
        "--ephemeral",
        "--sandbox",
        "read-only",
        "--cd",
        "/tmp",
        "--skip-git-repo-check",
        "--output-schema",
        "<temp.schema.json>",
        "--json",
        "<low-sensitive prompt>",
    ]
    payload = {
        "ok": status == "ok",
        "provider": "codex",
        "status": status,
        "version": codex_version(),
        "duration_ms": duration_ms,
        "exit_code": result.returncode,
        "command_shape": command_shape,
        "jsonl_event_count": event_count,
        "jsonl_event_types": event_types,
        "structured_output_valid": not validation_errors,
        "structured_output_summary": structured if structured else {},
        "validation_errors": validation_errors,
        "stderr_summary": stderr_summary,
        "warnings": [
            "Raw JSONL events are parsed in memory only and are not persisted or emitted.",
            "Prompt is fixed low-sensitive text.",
        ],
    }
    payload["audit_id"] = audit_id("codex", payload)
    return payload


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="P2-B provider smoke tests")
    sub = parser.add_subparsers(dest="provider", required=True)
    codex_parser = sub.add_parser("codex")
    codex_parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args(argv)

    if args.provider == "codex":
        payload = run_codex(timeout=args.timeout)
        emit(payload)
        return 0 if payload["ok"] else 1

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
