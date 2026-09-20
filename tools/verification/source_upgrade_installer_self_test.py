#!/usr/bin/env python3
"""Isolated installer-control fixtures. No real processes, signing, or SM changes."""
import importlib.util
import json
import os
import plistlib
import subprocess
import shutil
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch
from contextlib import ExitStack

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("source_upgrade_dev", ROOT / "script/development.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


def transaction_case(fail_promotion):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary).resolve()
        installed = root / "Applications/Blocks.app"
        manifest = root / "Support/peers.json"
        products = root / "Products"

        def app(path, marker):
            for relative in ["Contents/MacOS/Blocks", "Contents/MacOS/BlocksActionBroker",
                             "Contents/MacOS/BlocksClipboardBroker", "Contents/Resources/CLI/blocks"]:
                file = path / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(marker)
                file.chmod(0o755)
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "app.blocks.dev", "BlocksSourceUpgradeProtocolVersion": 1}))
            agent = path / "Contents/Library/LaunchAgents/app.blocks.action-broker.plist"
            agent.parent.mkdir(parents=True)
            agent.write_bytes(plistlib.dumps({}))

        app(installed, "old")
        app(products / "Blocks.app", "new")
        helper = products / "blocksHelper.app/Contents/MacOS/blocksHelper"
        helper.parent.mkdir(parents=True)
        helper.write_text("new")
        helper.chmod(0o755)
        (helper.parent.parent / "Info.plist").write_bytes(plistlib.dumps({}))
        (products / "blocks").write_text("new")
        (products / "blocks").chmod(0o755)
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"schemaVersion": 1, "appBundlePath": str(installed), "peers": [{
            "role": "cli", "identifier": "app.blocks.dev.cli",
            "relativeExecutablePath": "Contents/Resources/CLI/blocks", "cdHash": "a" * 40}]}))
        manifest.chmod(0o600)
        original_manifest = manifest.read_bytes()
        active = [True]
        opened = []
        prepared = []
        def no_job():
            if active[0]: raise RuntimeError("registered")
        def run(command, **kwargs):
            if command[0] == "/usr/bin/ditto": shutil.copytree(command[1], command[2])
            elif command[0] == "/usr/bin/open": opened.append(command)
            return ""
        def signature(path):
            role = "selection-helper" if path.name == "blocksHelper" else "cli" if path.name == "blocks" else "action-broker" if path.name == "BlocksActionBroker" else None
            return {"Identifier": "app.blocks.dev" + ("." + role if role else ""),
                    "CDHash": ("a" if path.read_text() == "old" else "b") * 40}
        def control(command, **kwargs):
            assert command == [str(installed / "Contents/Resources/CLI/blocks"), "source-upgrade", "--json"]
            assert (installed / "Contents/MacOS/Blocks").read_text() == "old"
            assert manifest.read_bytes() == original_manifest
            prepared.append(True)
            active[0] = False
            return subprocess.CompletedProcess(command, 0, json.dumps({"version": 1, "status": "committed", "token": str(uuid.uuid4())}), "")
        def update(path, change):
            data = plistlib.loads(path.read_bytes()); change(data); path.write_bytes(plistlib.dumps(data))
        real_replace = os.replace
        injected = [False]
        def replace(source, destination):
            if fail_promotion and Path(destination) == manifest and not injected[0]:
                injected[0] = True
                raise OSError("fixture promotion failure")
            return real_replace(source, destination)
        values = dict(HOME=root, DESTINATION=installed, LEGACY_DESTINATION=root / "Legacy.app", MANIFEST=manifest,
                      run=run, sign=lambda *_: None, signature=signature, update_plist=update,
                      rename_display=lambda *_: None, verify_upgrade_identity=lambda *_: None,
                      resign_nested_code=lambda *_: None,
                      running_local_processes=lambda: [123] if active[0] else [], ensure_action_broker_unregistered=no_job)
        with ExitStack() as stack:
            for key, value in values.items(): stack.enter_context(patch.object(dev, key, value))
            stack.enter_context(patch.object(dev.subprocess, "run", control))
            stack.enter_context(patch.object(dev.os, "replace", replace))
            try: dev.install_development(products)
            except OSError: assert fail_promotion
            else: assert not fail_promotion
        assert prepared == [True]
        assert len(opened) == (2 if fail_promotion else 1)
        assert (installed / "Contents/MacOS/Blocks").read_text() == ("old" if fail_promotion else "new")
        if fail_promotion: assert manifest.read_bytes() == original_manifest
        else: assert all(peer["cdHash"] == "b" * 40 for peer in json.loads(manifest.read_bytes())["peers"])


def main():
    cases = []
    for case in ("idle", "legacy", "success", "bad-identity", "bad-receipt", "timeout", "new-job", "changed-app", "changed-manifest"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / "Blocks.app"
            cli = app / "Contents/Resources/CLI/blocks"
            cli.parent.mkdir(parents=True)
            cli.write_text("fixture")
            cli.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "BlocksSourceUpgradeProtocolVersion": 0 if case == "legacy" else 1,
            }))
            manifest = root / "peers.json"
            manifest.write_text(json.dumps({"schemaVersion": 1, "appBundlePath": str(app), "peers": [{
                "role": "cli", "identifier": "app.blocks.dev.cli",
                "relativeExecutablePath": "Contents/Resources/CLI/blocks", "cdHash": "a" * 40,
            }]}))
            manifest.chmod(0o600)
            busy = [case != "idle"]
            calls = []

            def require_unregistered():
                if busy[0]:
                    raise RuntimeError("fixture active job")

            def run(command, **kwargs):
                calls.append(command)
                return ""

            def control(command, **kwargs):
                assert command == [str(cli), "source-upgrade", "--json"]
                assert kwargs["timeout"] == 45
                assert not any(key.startswith(("DYLD_", "BLOCKS_")) for key in kwargs["env"])
                calls.append(command)
                if case == "timeout":
                    busy[0] = False
                    raise subprocess.TimeoutExpired(command, 45)
                busy[0] = case == "new-job"
                body = "not JSON" if case == "bad-receipt" else json.dumps({
                    "version": 1, "status": "committed", "token": str(uuid.uuid4()),
                })
                return subprocess.CompletedProcess(command, 0, body, "")

            with patch.object(dev, "MANIFEST", manifest), patch.object(dev, "run", run), \
                 patch.object(dev, "signature", lambda _: {"Identifier": "app.blocks.dev.cli", "CDHash": ("b" if case == "bad-identity" else "a") * 40}), \
                 patch.object(dev, "ensure_action_broker_unregistered", require_unregistered), \
                 patch.object(dev, "running_local_processes", lambda: [123] if busy[0] else []), \
                 patch.object(dev.subprocess, "run", control), \
                 patch.object(dev.time, "monotonic", side_effect=[0, 30]), \
                 patch.object(dev.time, "sleep", lambda _: None):
                preparation = dev.SourceUpgradePreparation(app)
                failed = False
                try:
                    preparation.prepare_if_needed()
                except (RuntimeError, subprocess.TimeoutExpired):
                    failed = True
                assert failed == (case in {"legacy", "bad-identity", "bad-receipt", "timeout", "new-job"}), case
                control_calls = [call for call in calls if call[0] == str(cli)]
                assert bool(control_calls) == (case not in {"idle", "legacy", "bad-identity"}), case
                assert app.exists() and manifest.exists()
                if case in {"bad-receipt", "timeout", "changed-app", "changed-manifest"}:
                    if case == "changed-app":
                        app.rename(root / "previous.app")
                        app.mkdir()
                    if case == "changed-manifest":
                        manifest.write_text("changed")
                    before = len(calls)
                    preparation.restore_after_failure()
                    opened = any(call[:2] == ["/usr/bin/open", "-g"] for call in calls[before:])
                    assert opened == (case in {"bad-receipt", "timeout"}), case
            cases.append(case)
    transaction_case(False)
    transaction_case(True)
    print(json.dumps({"ok": True, "cases": cases + ["prepared-before-swap", "prepared-promotion-failure-restores-and-reopens"]}))


if __name__ == "__main__":
    main()
