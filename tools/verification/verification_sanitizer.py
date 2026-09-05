#!/usr/bin/env python3
"""Shared low-sensitivity output helpers for verification scripts."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()

EMAIL_RE = re.compile(r"(?<![\w.+-])[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}(?![\w.+-])")
ABSOLUTE_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_<>])/(?:Users|Applications|Library|System|private|var|tmp)"
    r"(?:/[^\s\"'<>|,;)]+)+"
)
LONG_HEX_RE = re.compile(r"\b[0-9A-Fa-f]{48,}\b")
TCC_ROW_RE = re.compile(r"^(?P<label>TCC\s+(?:ScreenCapture|Accessibility)\s+row:\s*)(?P<body>.*)$")
CSREQ_RE = re.compile(r"\b(?:csreq|requirement|requirement_data|auth_requirement)\b\s*[:=]\s*[^,\n}]+", re.IGNORECASE)


def _replace_known_roots(text: str) -> str:
    replacements = [
        (str(ROOT), "<ROOT>"),
        (str(HOME), "<HOME>"),
    ]
    for raw, replacement in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
        if raw:
            text = text.replace(raw, replacement)
    return text


def _sanitize_tcc_rows(text: str) -> str:
    sanitized_lines: list[str] = []
    for line in text.splitlines(keepends=True):
        newline = "\n" if line.endswith("\n") else ""
        body = line[:-1] if newline else line
        match = TCC_ROW_RE.match(body)
        if match is None:
            sanitized_lines.append(line)
            continue
        fields = [field.strip() for field in match.group("body").split("|")]
        visible = [field for field in fields[:5] if field]
        visible.append("<REDACTED_TCC_REQUIREMENT>")
        sanitized_lines.append(f"{match.group('label')}{' | '.join(visible)}{newline}")
    return "".join(sanitized_lines)


def sanitize_text(value: object) -> str:
    """Redact local-only sensitive material from verifier stdout/stderr/details."""
    text = "" if value is None else str(value)
    text = _replace_known_roots(text)
    text = EMAIL_RE.sub("<EMAIL>", text)
    text = _sanitize_tcc_rows(text)
    text = CSREQ_RE.sub("<REDACTED_TCC_REQUIREMENT>", text)
    text = LONG_HEX_RE.sub("<REDACTED_HEX>", text)
    text = ABSOLUTE_PATH_RE.sub("<PATH>", text)
    return text


def sanitize_command(command: list[object]) -> list[str]:
    return [sanitize_text(item) for item in command]


def sanitize_payload(value: Any) -> Any:
    if isinstance(value, dict):
        return {sanitize_text(key): sanitize_payload(item) for key, item in value.items()}
    if isinstance(value, list):
        return [sanitize_payload(item) for item in value]
    if isinstance(value, tuple):
        return [sanitize_payload(item) for item in value]
    if isinstance(value, str):
        return sanitize_text(value)
    return value


def sanitizer_self_check() -> dict[str, Any]:
    sample = "\n".join([
        f"{ROOT}/DerivedData/Blocks/Build/Products/Debug/Blocks.app",
        f"{HOME}/Applications/BlocksDev.app",
        "developer@example.com",
        "/private/tmp/blocks-p5m-sample/P5MProviderRoutingRunner.swift",
        "TCC ScreenCapture row: kTCCServiceScreenCapture | com.example.Blocks | 2 | 0 | 1 | FADE0C" + "A" * 80,
        "csreq = FADE0C" + "B" * 80,
    ])
    redacted = sanitize_text(sample)
    forbidden = [
        str(ROOT),
        str(HOME),
        "developer@example.com",
        "/private/tmp/blocks-p5m-sample",
        "FADE0C",
        "A" * 48,
        "B" * 48,
    ]
    required = [
        "<ROOT>",
        "<HOME>",
        "<EMAIL>",
        "<PATH>",
        "<REDACTED_TCC_REQUIREMENT>",
    ]
    failures = [f"forbidden:{item}" for item in forbidden if item and item in redacted]
    failures.extend(f"missing:{item}" for item in required if item not in redacted)
    return {
        "ok": not failures,
        "failures": failures,
        "sample": redacted,
    }
