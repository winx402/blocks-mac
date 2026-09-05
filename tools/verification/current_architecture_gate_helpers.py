#!/usr/bin/env python3
"""Exact, fail-closed source helpers for current architecture gates."""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence


MethodSpec = tuple[str, str, str, Sequence[str], Sequence[str]]
MutationSpec = tuple[str, str, str, str]
OverloadAdversarySpec = tuple[str, str, str, str, str, str]
NonCodeAdversarySpec = tuple[str, str, str, str, str]


def swift_code_only(source: str) -> str:
    """Mask Swift comments and string literals while preserving source offsets."""
    output = list(source)
    index = 0
    block_comment_depth = 0
    line_comment = False
    string_delimiter: str | None = None
    string_hash_count = 0

    def mask(position: int) -> None:
        if output[position] not in "\r\n":
            output[position] = " "

    while index < len(source):
        if line_comment:
            if source[index] in "\r\n":
                line_comment = False
            else:
                mask(index)
            index += 1
            continue

        if block_comment_depth:
            if source.startswith("/*", index):
                mask(index)
                if index + 1 < len(source):
                    mask(index + 1)
                block_comment_depth += 1
                index += 2
                continue
            if source.startswith("*/", index):
                mask(index)
                if index + 1 < len(source):
                    mask(index + 1)
                block_comment_depth -= 1
                index += 2
                continue
            mask(index)
            index += 1
            continue

        if string_delimiter is not None:
            closing = string_delimiter + ("#" * string_hash_count)
            if source.startswith(closing, index):
                for offset in range(len(closing)):
                    mask(index + offset)
                index += len(closing)
                string_delimiter = None
                string_hash_count = 0
                continue
            if string_hash_count == 0 and source[index] == "\\":
                mask(index)
                if index + 1 < len(source):
                    mask(index + 1)
                index += 2
                continue
            mask(index)
            index += 1
            continue

        if source.startswith("//", index):
            mask(index)
            mask(index + 1)
            line_comment = True
            index += 2
            continue
        if source.startswith("/*", index):
            mask(index)
            mask(index + 1)
            block_comment_depth = 1
            index += 2
            continue

        hash_end = index
        while hash_end < len(source) and source[hash_end] == "#":
            hash_end += 1
        delimiter = ""
        if source.startswith('\"\"\"', hash_end):
            delimiter = '\"\"\"'
        elif source.startswith('\"', hash_end):
            delimiter = '\"'
        if delimiter:
            string_hash_count = hash_end - index
            string_delimiter = delimiter
            opening_length = string_hash_count + len(delimiter)
            for offset in range(opening_length):
                mask(index + offset)
            index += opening_length
            continue

        index += 1

    return "".join(output)


def _balanced_block_end(source: str, opening_brace: int) -> int | None:
    return _balanced_delimiter_end(source, opening_brace, "{", "}")


def _balanced_delimiter_end(source: str, opening_index: int, opening: str, closing: str) -> int | None:
    depth = 0
    for index in range(opening_index, len(source)):
        if source[index] == opening:
            depth += 1
        elif source[index] == closing:
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _brace_depths(source: str) -> list[int]:
    depths: list[int] = []
    depth = 0
    for character in source:
        depths.append(depth)
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
    return depths


def _exact_signature_start(source: str, signature: str) -> int | None:
    pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(signature)}(?![A-Za-z0-9_])")
    matches = list(pattern.finditer(source))
    return matches[0].start() if len(matches) == 1 else None


def _swift_declaration_span(source: str, signature: str) -> tuple[int, int] | None:
    code = swift_code_only(source)
    start = _exact_signature_start(code, signature)
    if start is None:
        return None
    opening_brace = code.find("{", start + len(signature))
    if opening_brace < 0:
        return None
    end = _balanced_block_end(code, opening_brace)
    return (start, end) if end is not None else None


def swift_declaration_block(source: str, signature: str) -> str:
    span = _swift_declaration_span(source, signature)
    return source[span[0]:span[1]] if span is not None else ""


def _normalized_signature(signature: str) -> str:
    normalized = re.sub(r"\s+", " ", signature.strip())
    normalized = re.sub(r"\s*\(\s*", "(", normalized)
    normalized = re.sub(r"\s*\)\s*", ")", normalized)
    normalized = re.sub(r"\s*,\s*", ",", normalized)
    normalized = re.sub(r"\s*:\s*", ":", normalized)
    normalized = re.sub(r"\s*->\s*", "->", normalized)
    normalized = re.sub(r"\s*=\s*", "=", normalized)
    return normalized


def _method_span(type_block: str, exact_signature: str) -> tuple[int, int] | None:
    expected = _normalized_signature(exact_signature)
    matches: list[tuple[int, int]] = []
    code = swift_code_only(type_block)
    brace_depths = _brace_depths(code)
    for candidate in re.finditer(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*", code):
        start = candidate.start()
        if start >= len(brace_depths) or brace_depths[start] != 1:
            continue
        parenthesis_depth = 0
        opening_brace = -1
        for index in range(start, len(code)):
            char = code[index]
            if char == "(":
                parenthesis_depth += 1
            elif char == ")":
                parenthesis_depth -= 1
            elif char == "{" and parenthesis_depth == 0:
                opening_brace = index
                break
        if opening_brace < 0:
            continue
        if _normalized_signature(type_block[start:opening_brace]) != expected:
            continue
        end = _balanced_block_end(code, opening_brace)
        if end is not None:
            matches.append((start, end))
    return matches[0] if len(matches) == 1 else None


def exact_method_block(source: str, type_signature: str, method_signature: str) -> str:
    type_block = swift_declaration_block(source, type_signature)
    method_span = _method_span(type_block, method_signature)
    return type_block[method_span[0]:method_span[1]] if method_span is not None else ""


def exact_method_call_block(
    source: str,
    type_signature: str,
    method_signature: str,
    callee: str,
) -> str:
    method = exact_method_block(source, type_signature, method_signature)
    if not method:
        return ""
    code = swift_code_only(method)
    pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(callee)}\s*\(")
    matches = list(pattern.finditer(code))
    if len(matches) != 1:
        return ""
    opening_parenthesis = code.find("(", matches[0].start())
    call_end = _balanced_delimiter_end(code, opening_parenthesis, "(", ")")
    return method[matches[0].start():call_end] if call_end is not None else ""


def exact_method_call_argument(
    source: str,
    type_signature: str,
    method_signature: str,
    callee: str,
    argument_label: str,
) -> str:
    call = exact_method_call_block(source, type_signature, method_signature, callee)
    return swift_call_argument(call, argument_label)


def swift_call_argument(call: str, argument_label: str) -> str:
    if not call:
        return ""
    code = swift_code_only(call)
    opening_parenthesis = code.find("(")
    if opening_parenthesis < 0:
        return ""
    call_end = _balanced_delimiter_end(code, opening_parenthesis, "(", ")")
    if call_end is None:
        return ""
    arguments_end = call_end - 1
    segments: list[tuple[int, int]] = []
    segment_start = opening_parenthesis + 1
    depths = {"(": 0, "[": 0, "{": 0}
    closing_to_opening = {")": "(", "]": "[", "}": "{"}
    for index in range(segment_start, arguments_end):
        character = code[index]
        if character in depths:
            depths[character] += 1
        elif character in closing_to_opening:
            depths[closing_to_opening[character]] -= 1
        elif character == "," and all(depth == 0 for depth in depths.values()):
            segments.append((segment_start, index))
            segment_start = index + 1
    segments.append((segment_start, arguments_end))

    matches: list[str] = []
    for start, end in segments:
        segment_code = code[start:end]
        colon = segment_code.find(":")
        if colon < 0 or segment_code[:colon].strip() != argument_label:
            continue
        expression_start = start + colon + 1
        matches.append(call[expression_start:end].strip())
    return matches[0] if len(matches) == 1 else ""


def swift_code_contains_all(source: str, required_tokens: Sequence[str]) -> bool:
    return all(_code_token_present(source, token) for token in required_tokens)


def _exact_method_body_span(
    source: str,
    type_signature: str,
    method_signature: str,
) -> tuple[int, int] | None:
    type_span = _swift_declaration_span(source, type_signature)
    if type_span is None:
        return None
    type_block = source[type_span[0]:type_span[1]]
    method_span = _method_span(type_block, method_signature)
    if method_span is None:
        return None
    method_start = type_span[0] + method_span[0]
    method = type_block[method_span[0]:method_span[1]]
    code = swift_code_only(method)
    opening_brace = code.find("{")
    method_end = _balanced_block_end(code, opening_brace) if opening_brace >= 0 else None
    if method_end is None:
        return None
    return method_start + opening_brace + 1, method_start + method_end - 1


def _conditional_compilation_depths(source: str) -> list[int] | None:
    code = swift_code_only(source)
    depths = [0] * len(code)
    depth = 0
    offset = 0
    for line in code.splitlines(keepends=True):
        stripped = line.lstrip()
        directive = stripped.split(maxsplit=1)[0] if stripped.startswith("#") else ""
        if directive == "#if":
            line_depth = depth + 1
            depth += 1
        elif directive in {"#elseif", "#else"}:
            if depth == 0:
                return None
            line_depth = depth
        elif directive == "#endif":
            if depth == 0:
                return None
            line_depth = depth
            depth -= 1
        else:
            line_depth = depth
        depths[offset:offset + len(line)] = [line_depth] * len(line)
        offset += len(line)
    return depths if depth == 0 else None


def _is_standalone_statement(code: str, start: int, end: int) -> bool:
    line_start = code.rfind("\n", 0, start) + 1
    line_end = code.find("\n", end)
    if line_end < 0:
        line_end = len(code)
    return not code[line_start:start].strip() and not code[end:line_end].strip()


def _unique_direct_call_span(body: str, callee: str) -> tuple[int, int] | None:
    code = swift_code_only(body)
    pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(callee)}\s*\(")
    matches = list(pattern.finditer(code))
    if len(matches) != 1:
        return None
    call_start = matches[0].start()
    brace_depths = _brace_depths(code)
    if call_start >= len(brace_depths) or brace_depths[call_start] != 0:
        return None
    opening_parenthesis = code.find("(", call_start)
    call_end = _balanced_delimiter_end(code, opening_parenthesis, "(", ")")
    if call_end is None or not _is_standalone_statement(code, call_start, call_end):
        return None
    return call_start, call_end


def _span_has_conditional_compilation(
    conditional_depths: Sequence[int],
    start: int,
    end: int,
) -> bool:
    if start < 0 or end > len(conditional_depths) or start >= end:
        return True
    return any(depth > 0 for depth in conditional_depths[start:end])


def _has_top_level_terminator_before(
    body_code: str,
    body_start: int,
    consumer_start: int,
    conditional_depths: Sequence[int],
) -> bool:
    brace_depths = _brace_depths(body_code)
    for terminator in re.finditer(r"\b(?:return|throw)\b", body_code[:consumer_start]):
        local_start = terminator.start()
        absolute_start = body_start + local_start
        if (
            local_start < len(brace_depths)
            and brace_depths[local_start] == 0
            and absolute_start < len(conditional_depths)
            and conditional_depths[absolute_start] == 0
        ):
            return True
    return False


def exact_method_direct_bound_initializer_call(
    source: str,
    type_signature: str,
    method_signature: str,
    binding_name: str,
    initializer_callee: str,
    consumer_callee: str,
    consumer_argument_label: str,
) -> str:
    """Return a direct immutable initializer consumed by one direct call."""
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", binding_name):
        return ""
    body_span = _exact_method_body_span(source, type_signature, method_signature)
    conditional_depths = _conditional_compilation_depths(source)
    if body_span is None or conditional_depths is None:
        return ""
    body_start, body_end = body_span
    body = source[body_start:body_end]
    code = swift_code_only(body)
    consumer_span = _unique_direct_call_span(body, consumer_callee)
    if consumer_span is None:
        return ""
    consumer_start, consumer_end = consumer_span
    consumer_call = body[consumer_start:consumer_end]
    consumed_expression = " ".join(
        swift_code_only(swift_call_argument(consumer_call, consumer_argument_label)).split()
    )
    if consumed_expression != binding_name:
        return ""

    callee_pattern = re.escape(initializer_callee)
    declaration_pattern = re.compile(
        rf"\blet[ \t]+(?P<binding>{re.escape(binding_name)})[ \t]*=[ \t]*"
        rf"(?P<callee>{callee_pattern})\s*\("
    )
    declarations = list(declaration_pattern.finditer(code))
    if len(declarations) != 1:
        return ""
    declaration = declarations[0]
    brace_depths = _brace_depths(code)
    if declaration.start() >= len(brace_depths) or brace_depths[declaration.start()] != 0:
        return ""
    callee_start = declaration.start("callee")
    opening_parenthesis = code.find("(", callee_start)
    call_end = _balanced_delimiter_end(code, opening_parenthesis, "(", ")")
    if (
        call_end is None
        or not _is_standalone_statement(code, declaration.start(), call_end)
        or call_end >= consumer_start
    ):
        return ""

    declaration_absolute_start = body_start + declaration.start()
    initializer_absolute_end = body_start + call_end
    consumer_absolute_start = body_start + consumer_start
    consumer_absolute_end = body_start + consumer_end
    if (
        _span_has_conditional_compilation(
            conditional_depths,
            declaration_absolute_start,
            initializer_absolute_end,
        )
        or _span_has_conditional_compilation(
            conditional_depths,
            consumer_absolute_start,
            consumer_absolute_end,
        )
        or _has_top_level_terminator_before(
            code,
            body_start,
            consumer_start,
            conditional_depths,
        )
    ):
        return ""

    identifier_pattern = re.compile(
        rf"(?<![A-Za-z0-9_]){re.escape(binding_name)}(?![A-Za-z0-9_])"
    )
    expected_identifier_count = 2 + int(consumer_argument_label == binding_name)
    if len(list(identifier_pattern.finditer(code))) != expected_identifier_count:
        return ""
    return body[callee_start:call_end]


def _code_token_spans(source: str, token: str) -> list[tuple[int, int]]:
    stripped = token.strip()
    if not stripped:
        return []
    pattern_parts = [r"\s+" if part.isspace() else re.escape(part) for part in re.split(r"(\s+)", stripped) if part]
    pattern = re.compile("".join(pattern_parts))
    code = swift_code_only(source)
    return [
        (match.start(), match.end())
        for match in pattern.finditer(code)
    ]


def _code_token_present(source: str, token: str) -> bool:
    return bool(_code_token_spans(source, token))


def _top_level_reachable_code_token_present(method: str, token: str) -> bool:
    """Require one token occurrence in a method's reachable executable body.

    This is deliberately a small lexical guard, not a Swift parser.  It masks
    comments and literals, rejects closure-only text, conditionally compiled
    text, `if false`/`while false` blocks, and text following an unconditional
    top-level return or throw.  Structured control-flow bodies (for example a
    `do` or `if result.ok` body) remain valid executable code.
    """
    code = swift_code_only(method)
    opening_brace = code.find("{")
    if opening_brace < 0:
        return False
    body_end = _balanced_block_end(code, opening_brace)
    if body_end is None:
        return False
    body = method[opening_brace + 1:body_end - 1]
    body_code = code[opening_brace + 1:body_end - 1]
    depths = _brace_depths(body_code)
    conditional_depths = _conditional_compilation_depths(body)
    if conditional_depths is None:
        return False

    terminators = [
        match.start()
        for match in re.finditer(r"\b(?:return|throw|fatalError|preconditionFailure)\b", body_code)
        if match.start() < len(depths) and depths[match.start()] == 0
        and match.start() < len(conditional_depths) and conditional_depths[match.start()] == 0
    ]
    # These literal unconditional forms are deliberately rejected.  They are
    # common static-gate decoys and make every following statement unreachable.
    for match in re.finditer(r"\bguard\s+false\s+else\s*\{\s*(?:return|throw|fatalError|preconditionFailure)\b", body_code):
        if depths[match.start()] == 0:
            terminators.append(match.start())
    for match in re.finditer(r"\bif\s+true\s*\{", body_code):
        if depths[match.start()] != 0:
            continue
        opening = body_code.find("{", match.start())
        end = _balanced_block_end(body_code, opening)
        if end is None:
            return False
        inner = body_code[opening + 1:end - 1]
        if re.fullmatch(r"\s*(?:return|throw\b[^\n;]*|fatalError\s*\([^)]*\)|preconditionFailure\s*\([^)]*\))\s*", inner):
            terminators.append(match.start())
    unreachable_ranges: list[tuple[int, int]] = []
    unreachable_pattern = re.compile(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*\{")
    for match in unreachable_pattern.finditer(body_code):
        opening = body_code.find("{", match.start())
        end = _balanced_block_end(body_code, opening)
        if end is None:
            return False
        unreachable_ranges.append((opening, end))

    def is_closure_scope(position: int) -> bool:
        containing_openings: list[int] = []
        stack: list[int] = []
        for index, character in enumerate(body_code[:position]):
            if character == "{":
                stack.append(index)
            elif character == "}" and stack:
                stack.pop()
        containing_openings.extend(stack)
        control_scope_pattern = re.compile(
            r"\b(?:if|guard|else|switch|do|while|for|catch|repeat|defer)\b[^{}]*$"
        )
        for opening in containing_openings:
            previous_boundary = max(
                body_code.rfind("{", 0, opening),
                body_code.rfind("}", 0, opening),
                body_code.rfind(";", 0, opening),
            )
            header = body_code[previous_boundary + 1:opening]
            if not control_scope_pattern.search(header):
                return True
        return False

    for start, end in _code_token_spans(body, token):
        if (
            start < len(depths)
            and all(conditional_depths[index] == 0 for index in range(start, end))
            and not is_closure_scope(start)
            and not any(unreachable_start < start and end <= unreachable_end for unreachable_start, unreachable_end in unreachable_ranges)
            and not any(terminator < start for terminator in terminators)
        ):
            return True
    return False


def swift_declaration_task_action_contains_all(
    declaration: str,
    task_binding: str,
    required_task_tokens: Sequence[str],
    required_declaration_tokens: Sequence[str],
) -> bool:
    """Bind an async Task to a real Button action in a reachable declaration.

    This intentionally rejects token-only closures, literal-dead branches, and
    unconditional exits before the action.  It is lexical and conservative;
    callers should use it only for a concrete, exact UI declaration.
    """
    code = swift_code_only(declaration)
    task_pattern = re.compile(rf"\b{re.escape(task_binding)}\s*=\s*Task\s*\{{")
    matches = list(task_pattern.finditer(code))
    if len(matches) != 1:
        return False
    task_start = matches[0].start()
    task_opening = code.find("{", task_start)
    task_end = _balanced_block_end(code, task_opening)
    if task_end is None:
        return False
    task_block = declaration[task_start:task_end]
    if not all(_top_level_reachable_code_token_present(task_block, token) for token in required_task_tokens):
        return False

    brace_stack: list[int] = []
    for index, character in enumerate(code[:task_start]):
        if character == "{":
            brace_stack.append(index)
        elif character == "}" and brace_stack:
            brace_stack.pop()
    has_button_action = False
    for opening in brace_stack:
        header_start = max(code.rfind("{", 0, opening), code.rfind("}", 0, opening), code.rfind(";", 0, opening)) + 1
        header = code[header_start:opening]
        if re.search(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*$", header):
            return False
        if re.search(r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*$", header):
            return False
        if re.search(r"\bButton\s*$", header):
            has_button_action = True
        prefix = swift_code_only(declaration[opening + 1:task_start])
        prefix_depths = _brace_depths(prefix)
        if any(
            match.start() < len(prefix_depths) and prefix_depths[match.start()] == 0
            for match in re.finditer(r"\b(?:return|throw|fatalError|preconditionFailure)\b", prefix)
        ):
            return False
    if not has_button_action:
        return False

    for token in required_declaration_tokens:
        if not _declaration_reachable_code_token_present(declaration, token):
            return False
    return True


def _declaration_reachable_code_token_present(declaration: str, token: str) -> bool:
    """Reachability check for a ViewBuilder declaration, including view closures."""
    code = swift_code_only(declaration)
    for start, _ in _code_token_spans(declaration, token):
        stack: list[int] = []
        for index, character in enumerate(code[:start]):
            if character == "{":
                stack.append(index)
            elif character == "}" and stack:
                stack.pop()
        reachable = True
        for opening in stack:
            header_start = max(code.rfind("{", 0, opening), code.rfind("}", 0, opening), code.rfind(";", 0, opening)) + 1
            header = code[header_start:opening]
            if re.search(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*$", header):
                reachable = False
                break
            prefix = code[opening + 1:start]
            depths = _brace_depths(prefix)
            if any(
                match.start() < len(depths) and depths[match.start()] == 0
                for match in re.finditer(r"\b(?:return|throw|fatalError|preconditionFailure)\b", prefix)
            ):
                reachable = False
                break
        if reachable:
            return True
    return False


def _replace_in_exact_method(
    source: str,
    type_signature: str,
    method_signature: str,
    original: str,
    replacement: str,
) -> str | None:
    type_span = _swift_declaration_span(source, type_signature)
    if type_span is None:
        return None
    type_block = source[type_span[0]:type_span[1]]
    method_span = _method_span(type_block, method_signature)
    if method_span is None:
        return None
    method = type_block[method_span[0]:method_span[1]]
    occurrences = _code_token_spans(method, original)
    if len(occurrences) != 1:
        return None
    original_start, original_end = occurrences[0]
    mutated_method = method[:original_start] + replacement + method[original_end:]
    mutated_type = type_block[:method_span[0]] + mutated_method + type_block[method_span[1]:]
    return source[:type_span[0]] + mutated_type + source[type_span[1]:]


def mutate_exact_method(
    source: str,
    type_signature: str,
    method_signature: str,
    original: str,
    replacement: str,
) -> str | None:
    return _replace_in_exact_method(source, type_signature, method_signature, original, replacement)


def exact_method_if_branch_contains_only(
    source: str,
    type_signature: str,
    method_signature: str,
    condition: str,
    required_tokens: Sequence[str],
) -> bool:
    method = exact_method_block(source, type_signature, method_signature)
    if not method:
        return False
    code = swift_code_only(method)
    condition_pattern = re.compile(r"\bif\s+" + r"\s+".join(re.escape(part) for part in condition.split()) + r"\s*\{")
    matches = list(condition_pattern.finditer(code))
    if len(matches) != 1:
        return False
    opening_brace = code.find("{", matches[0].start())
    branch_end = _balanced_block_end(code, opening_brace)
    if branch_end is None:
        return False
    unreachable_ranges: list[tuple[int, int]] = []
    unreachable_pattern = re.compile(r"\b(?:if|while)\s*(?:\(\s*)?false(?:\s*\))?\s*\{")
    for unreachable_match in unreachable_pattern.finditer(code, opening_brace + 1, branch_end):
        unreachable_opening = code.find("{", unreachable_match.start())
        unreachable_end = _balanced_block_end(code, unreachable_opening)
        if unreachable_end is not None and unreachable_end <= branch_end:
            unreachable_ranges.append((unreachable_opening, unreachable_end))
    for token in required_tokens:
        spans = _code_token_spans(method, token)
        if not spans or any(start < opening_brace or end > branch_end for start, end in spans):
            return False
        if any(
            unreachable_start < start and end <= unreachable_end
            for start, end in spans
            for unreachable_start, unreachable_end in unreachable_ranges
        ):
            return False
    return True


def _insert_before_exact_method(
    source: str,
    type_signature: str,
    method_signature: str,
    injected_method: str,
) -> str | None:
    type_span = _swift_declaration_span(source, type_signature)
    if type_span is None:
        return None
    type_block = source[type_span[0]:type_span[1]]
    method_span = _method_span(type_block, method_signature)
    if method_span is None:
        return None
    absolute_method_start = type_span[0] + method_span[0]
    line_start = source.rfind("\n", 0, absolute_method_start) + 1
    indentation = source[line_start:absolute_method_start]
    insertion = "\n".join(
        indentation + line if line else ""
        for line in injected_method.strip().splitlines()
    ) + "\n\n"
    return source[:line_start] + insertion + source[line_start:]


def method_chain_checks(
    sources: Mapping[str, str],
    specs: Mapping[str, MethodSpec],
) -> dict[str, bool]:
    checks: dict[str, bool] = {}
    for check_name, (source_name, type_signature, method_signature, required, forbidden) in specs.items():
        block = exact_method_block(sources.get(source_name, ""), type_signature, method_signature)
        checks[check_name] = bool(block) and all(
            _top_level_reachable_code_token_present(block, token) for token in required
        ) and all(
            not _code_token_present(block, token) for token in forbidden
        )
    return checks


def method_chain_mutations_fail_closed(
    sources: Mapping[str, str],
    specs: Mapping[str, MethodSpec],
    mutations: Sequence[MutationSpec],
) -> dict[str, bool]:
    baseline = method_chain_checks(sources, specs)
    results: dict[str, bool] = {}
    for check_name, source_name, original, replacement in mutations:
        spec = specs.get(check_name)
        if spec is None or spec[0] != source_name or not baseline.get(check_name, False):
            results[check_name] = False
            continue
        mutated_source = _replace_in_exact_method(
            sources.get(source_name, ""),
            spec[1],
            spec[2],
            original,
            replacement,
        )
        if mutated_source is None:
            results[check_name] = False
            continue
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        results[check_name] = not method_chain_checks(mutated, specs).get(check_name, False)
    return results


def method_chain_overload_adversaries_fail_closed(
    sources: Mapping[str, str],
    specs: Mapping[str, MethodSpec],
    adversaries: Sequence[OverloadAdversarySpec],
) -> dict[str, bool]:
    results: dict[str, bool] = {}
    for result_name, check_name, overload_signature, overload_method, original, replacement in adversaries:
        spec = specs.get(check_name)
        if spec is None:
            results[result_name] = False
            continue
        source_name, type_signature, target_signature, _, _ = spec
        target_noop = _replace_in_exact_method(
            sources.get(source_name, ""),
            type_signature,
            target_signature,
            original,
            replacement,
        )
        if target_noop is None:
            results[result_name] = False
            continue
        adversarial_source = _insert_before_exact_method(
            target_noop,
            type_signature,
            target_signature,
            overload_method,
        )
        if adversarial_source is None:
            results[result_name] = False
            continue
        mutated = dict(sources)
        mutated[source_name] = adversarial_source
        overload_block = exact_method_block(adversarial_source, type_signature, overload_signature)
        target_block = exact_method_block(adversarial_source, type_signature, target_signature)
        results[result_name] = (
            _code_token_present(overload_block, original)
            and _code_token_present(target_block, replacement)
            and not _code_token_present(target_block, original)
            and not method_chain_checks(mutated, specs).get(check_name, False)
        )
    return results


def method_chain_noncode_adversaries_fail_closed(
    sources: Mapping[str, str],
    specs: Mapping[str, MethodSpec],
    adversaries: Sequence[NonCodeAdversarySpec],
) -> dict[str, bool]:
    results: dict[str, bool] = {}
    for result_name, check_name, original, replacement, noncode_decoy in adversaries:
        spec = specs.get(check_name)
        if spec is None:
            results[result_name] = False
            continue
        source_name, type_signature, method_signature, _, _ = spec
        mutated_source = _replace_in_exact_method(
            sources.get(source_name, ""),
            type_signature,
            method_signature,
            original,
            replacement + "\n" + noncode_decoy,
        )
        if mutated_source is None:
            results[result_name] = False
            continue
        mutated = dict(sources)
        mutated[source_name] = mutated_source
        results[result_name] = not method_chain_checks(mutated, specs).get(check_name, False)
    return results
