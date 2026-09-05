#!/usr/bin/env python3
"""Adversarial self-test for current architecture source helpers."""

from __future__ import annotations

import json

from current_architecture_gate_helpers import (
    exact_method_block,
    exact_method_call_argument,
    exact_method_direct_bound_initializer_call,
    exact_method_if_branch_contains_only,
    method_chain_checks,
    method_chain_noncode_adversaries_fail_closed,
    mutate_exact_method,
    swift_declaration_task_action_contains_all,
    swift_call_argument,
    swift_code_contains_all,
)


SOURCE = r'''
final class ProbeCoordinator {
    // func forward(flag: Bool) { sink(flag: flag) }
    let signatureDecoy = "func forward(flag: Bool) { sink(flag: flag) }"

    func forward(flag: Bool, overloadProbe: Bool) {
        sink(flag: flag)
    }

    func forward(flag: Bool) {
        sink(flag: flag)
    }

    func branch(result: ProbeResult) {
        if result == .missing {
            showAlert()
        }
    }
}
'''

LOCAL_FUNCTION_ONLY_SOURCE = r'''
final class LocalFunctionOnlyCoordinator {
    func wrapper() {
        func forward(flag: Bool) {
            sink(flag: flag)
        }
        forward(flag: true)
    }
}
'''

NESTED_TYPE_ONLY_SOURCE = r'''
final class NestedTypeOnlyCoordinator {
    struct NestedCoordinator {
        func forward(flag: Bool) {
            sink(flag: flag)
        }
    }
}
'''

UNREACHABLE_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        if false {
            sink(flag: flag)
        }
    }
}
'''

CLOSURE_ONLY_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        let work = {
            sink(flag: flag)
        }
        _ = work
    }
}
'''

EARLY_RETURN_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        return
        sink(flag: flag)
    }
}
'''

CONDITIONAL_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        #if ARCHITECTURE_GATE_PROBE
        sink(flag: flag)
        #endif
    }
}
'''

GUARD_FALSE_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        guard false else { return }
        sink(flag: flag)
    }
}
'''

IF_TRUE_RETURN_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        if true { return }
        sink(flag: flag)
    }
}
'''

FATAL_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        fatalError("decoy")
        sink(flag: flag)
    }
}
'''

PRECONDITION_METHOD_CHAIN_SOURCE = r'''
final class ReachabilityCoordinator {
    func forward(flag: Bool) {
        preconditionFailure("decoy")
        sink(flag: flag)
    }
}
'''

UI_TASK_SOURCE = r'''
@ViewBuilder
private var content: some View {
    if route == .details {
        Button {
            connectionTestTask = Task { @MainActor in
                await appModel.runOpenAIConnectionTest()
                guard !Task.isCancelled else { return }
            }
        } label: { Text("Run") }
        SettingsFeedbackSlot(feedback: connectionFeedback)
    }
}
'''

BOUND_INITIALIZER_SOURCE = r'''
final class BindingCoordinator {
    func wire() {
        let actions = ActionBundle(
            run: { value in sink(value: value) },
            cancel: { cancel() }
        )
        presenter.present(actions: actions)
    }
}
'''

REBOUND_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "if false { let actions = ActionBundle(run: { _ in }, cancel: {}) ; _ = actions }\n"
    "        presenter.present(actions: actions)",
)

REASSIGNED_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace("let actions =", "var actions =").replace(
    "presenter.present(actions: actions)",
    "actions = ActionBundle(run: { _ in }, cancel: {})\n        presenter.present(actions: actions)",
)

CLOSURE_SHADOW_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "let probe: (ActionBundle) -> Void = { actions in _ = actions }\n"
    "        _ = probe\n"
    "        presenter.present(actions: actions)",
)

LOCAL_PARAMETER_SHADOW_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "func probe(actions: ActionBundle) { _ = actions }\n"
    "        presenter.present(actions: actions)",
)

NESTED_PRESENT_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "if true {\n            presenter.present(actions: actions)\n        }",
)

VAR_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace("let actions =", "var actions =")

SWAPPED_INITIALIZER_SOURCE = VAR_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "let alternate = ActionBundle(run: { _ in }, cancel: {})\n"
    "        swap(&actions, &alternate)\n"
    "        presenter.present(actions: actions)",
)

EARLY_RETURN_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "let actions = ActionBundle(",
    "return\n        let actions = ActionBundle(",
)

THROW_BETWEEN_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "throw ProbeError.stop\n        presenter.present(actions: actions)",
)

CONDITIONAL_INITIALIZER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "let actions = ActionBundle(",
    "#if ARCHITECTURE_GATE_PROBE\n        let actions = ActionBundle(",
).replace(
    "presenter.present(actions: actions)",
    "#endif\n        presenter.present(actions: actions)",
)

CONDITIONAL_ELSE_CONSUMER_SOURCE = BOUND_INITIALIZER_SOURCE.replace(
    "presenter.present(actions: actions)",
    "#if ARCHITECTURE_GATE_PROBE\n"
    "        _ = 0\n"
    "        #else\n"
    "        presenter.present(actions: actions)\n"
    "        #endif",
)

SPECS = {
    "forward": (
        "coordinator",
        "final class ProbeCoordinator",
        "func forward(flag: Bool)",
        ["sink(flag: flag)"],
        [],
    )
}


def main() -> int:
    sources = {"coordinator": SOURCE}
    baseline = method_chain_checks(sources, SPECS)["forward"]
    target = exact_method_block(SOURCE, "final class ProbeCoordinator", "func forward(flag: Bool)")
    overload = exact_method_block(
        SOURCE,
        "final class ProbeCoordinator",
        "func forward(flag: Bool, overloadProbe: Bool)",
    )
    hardcoded = mutate_exact_method(
        SOURCE,
        "final class ProbeCoordinator",
        "func forward(flag: Bool)",
        "sink(flag: flag)",
        "sink(flag: true)",
    )
    moved_alert = mutate_exact_method(
        SOURCE,
        "final class ProbeCoordinator",
        "func branch(result: ProbeResult)",
        """
if result == .missing {
            showAlert()
        }
""",
        """
showAlert()
        if result == .missing {
            _ = result
        }
""",
    )
    noncode = method_chain_noncode_adversaries_fail_closed(
        sources,
        SPECS,
        [
            ("comment_decoy", "forward", "sink(flag: flag)", "_ = flag", "// sink(flag: flag)"),
            ("string_decoy", "forward", "sink(flag: flag)", "_ = flag", 'let decoy = "sink(flag: flag)"'),
        ],
    )
    presented_binding = exact_method_call_argument(
        BOUND_INITIALIZER_SOURCE,
        "final class BindingCoordinator",
        "func wire()",
        "presenter.present",
        "actions",
    )
    bound_initializer = exact_method_direct_bound_initializer_call(
        BOUND_INITIALIZER_SOURCE,
        "final class BindingCoordinator",
        "func wire()",
        presented_binding,
        "ActionBundle",
        "presenter.present",
        "actions",
    )
    run_action = swift_call_argument(bound_initializer, "run")

    def initializer_rejected(source: str) -> bool:
        return not exact_method_direct_bound_initializer_call(
            source,
            "final class BindingCoordinator",
            "func wire()",
            "actions",
            "ActionBundle",
            "presenter.present",
            "actions",
        )

    checks = {
        "baseline": baseline,
        "commented_and_string_signatures_ignored": target.count("func forward(flag: Bool)") == 1,
        "overload_remains_distinct": "sink(flag: flag)" in overload,
        "local_function_not_direct_member": not exact_method_block(
            LOCAL_FUNCTION_ONLY_SOURCE,
            "final class LocalFunctionOnlyCoordinator",
            "func forward(flag: Bool)",
        ),
        "nested_type_method_not_direct_member": not exact_method_block(
            NESTED_TYPE_ONLY_SOURCE,
            "final class NestedTypeOnlyCoordinator",
            "func forward(flag: Bool)",
        ),
        "hardcoded_argument_fails": bool(hardcoded)
        and not method_chain_checks({"coordinator": hardcoded or ""}, SPECS)["forward"],
        "comment_decoy_fails": noncode["comment_decoy"],
        "string_decoy_fails": noncode["string_decoy"],
        "required_call_in_if_false_fails": not method_chain_checks(
            {"coordinator": UNREACHABLE_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_only_in_closure_fails": not method_chain_checks(
            {"coordinator": CLOSURE_ONLY_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_after_top_level_return_fails": not method_chain_checks(
            {"coordinator": EARLY_RETURN_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_in_conditional_compilation_fails": not method_chain_checks(
            {"coordinator": CONDITIONAL_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_after_guard_false_return_fails": not method_chain_checks(
            {"coordinator": GUARD_FALSE_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_after_if_true_return_fails": not method_chain_checks(
            {"coordinator": IF_TRUE_RETURN_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_after_fatal_error_fails": not method_chain_checks(
            {"coordinator": FATAL_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "required_call_after_precondition_failure_fails": not method_chain_checks(
            {"coordinator": PRECONDITION_METHOD_CHAIN_SOURCE},
            {"forward": ("coordinator", "final class ReachabilityCoordinator", "func forward(flag: Bool)", ["sink(flag: flag)"], [])},
        )["forward"],
        "ui_task_is_bound_to_reachable_button": swift_declaration_task_action_contains_all(
            UI_TASK_SOURCE,
            "connectionTestTask",
            ["await appModel.runOpenAIConnectionTest()"],
            ["SettingsFeedbackSlot(feedback: connectionFeedback)"],
        ),
        "ui_task_if_false_decoy_fails": not swift_declaration_task_action_contains_all(
            UI_TASK_SOURCE.replace("if route == .details", "if false"),
            "connectionTestTask",
            ["await appModel.runOpenAIConnectionTest()"],
            ["SettingsFeedbackSlot(feedback: connectionFeedback)"],
        ),
        "ui_task_closure_only_decoy_fails": not swift_declaration_task_action_contains_all(
            UI_TASK_SOURCE.replace("connectionTestTask = Task", "let decoy = { connectionTestTask = Task", 1),
            "connectionTestTask",
            ["await appModel.runOpenAIConnectionTest()"],
            ["SettingsFeedbackSlot(feedback: connectionFeedback)"],
        ),
        "presented_argument_resolves_exact_binding": presented_binding == "actions" and bool(bound_initializer),
        "required_closure_is_inside_bound_initializer": swift_code_contains_all(
            run_action,
            ["sink(value: value)"],
        ),
        "same_name_rebinding_fails": initializer_rejected(REBOUND_INITIALIZER_SOURCE),
        "same_name_reassignment_fails": initializer_rejected(REASSIGNED_INITIALIZER_SOURCE),
        "same_name_closure_shadow_fails": initializer_rejected(CLOSURE_SHADOW_INITIALIZER_SOURCE),
        "same_name_local_parameter_shadow_fails": initializer_rejected(LOCAL_PARAMETER_SHADOW_INITIALIZER_SOURCE),
        "nested_present_is_not_a_direct_statement": initializer_rejected(NESTED_PRESENT_INITIALIZER_SOURCE),
        "mutable_var_binding_fails": initializer_rejected(VAR_INITIALIZER_SOURCE),
        "mutable_swap_risk_fails": initializer_rejected(SWAPPED_INITIALIZER_SOURCE),
        "top_level_early_return_fails": initializer_rejected(EARLY_RETURN_INITIALIZER_SOURCE),
        "top_level_throw_between_binding_and_consumer_fails": initializer_rejected(
            THROW_BETWEEN_INITIALIZER_SOURCE
        ),
        "conditional_initializer_fails": initializer_rejected(CONDITIONAL_INITIALIZER_SOURCE),
        "conditional_else_consumer_fails": initializer_rejected(CONDITIONAL_ELSE_CONSUMER_SOURCE),
        "branch_baseline": exact_method_if_branch_contains_only(
            SOURCE,
            "final class ProbeCoordinator",
            "func branch(result: ProbeResult)",
            "result == .missing",
            ["showAlert()"],
        ),
        "alert_before_branch_fails": bool(moved_alert)
        and not exact_method_if_branch_contains_only(
            moved_alert or "",
            "final class ProbeCoordinator",
            "func branch(result: ProbeResult)",
            "result == .missing",
            ["showAlert()"],
        ),
    }
    failures = [name for name, ok in checks.items() if not ok]
    print(json.dumps({"ok": not failures, "checks": checks, "failures": failures}, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
