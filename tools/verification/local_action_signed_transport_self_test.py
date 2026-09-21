#!/usr/bin/env python3
"""Real audit-token/Security.framework integration; no trust stub or Apple key.

Only a temporary source COPY redirects the two home-derived trust locations to
an embedded compile-time fixture home. Production source, installed binaries and
the login user's manifest are never modified. All authentication code, manifest
validation, role layout, hash and executable-path checks remain the real code.
"""
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksCore"


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True,
                          timeout=30, **kwargs)


def signature(executable, identifier):
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier, executable)
    run("/usr/bin/codesign", "--verify", "--strict", executable)
    details = run("/usr/bin/codesign", "-dvvv", executable).stderr
    metadata = dict(line.split("=", 1) for line in details.splitlines() if "=" in line)
    assert metadata["Identifier"] == identifier
    assert metadata.get("TeamIdentifier") == "not set"
    assert metadata.get("Signature") == "adhoc"
    return metadata["CDHash"]


def start(executable, endpoint):
    process = subprocess.Popen([str(executable), "server", str(endpoint)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    assert process.stdout.readline().strip() == "ready"
    return process


def client(executable, endpoint):
    return subprocess.run([str(executable), "client", str(endpoint), "signed-roundtrip"],
                          capture_output=True, text=True, timeout=8)


def main():
    with tempfile.TemporaryDirectory(prefix=".bacts-", dir=pwd.getpwuid(os.getuid()).pw_dir) as temporary:
        home = Path(temporary)
        # Deliberately no environment override. Guard the generated source so
        # it cannot accidentally compile as ordinary production source.
        source = (CORE / "BlocksLocalBuildTrust.swift").read_text()
        for original in ("String(cString: directory)", "String(cString: home)"):
            assert source.count(original) == 1, "Trust path expression changed; review fixture adaptation"
            source = source.replace(original, json.dumps(str(home)))
        source = '#if !LOCAL_ACTION_SIGNED_FIXTURE\n#error("isolated signed fixture only")\n#endif\n' + source
        trust = home / "FixtureBlocksLocalBuildTrust.swift"
        trust.write_text(source)
        binary = home / "fixture"
        run("xcrun", "swiftc", "-swift-version", "6", "-D", "BLOCKS_LOCAL_DEVELOPMENT",
            "-D", "LOCAL_ACTION_TRANSPORT_FIXTURE", "-D", "LOCAL_ACTION_SIGNED_FIXTURE",
            CORE / "LocalActionTransport.swift", trust,
            ROOT / "tools/verification/fixtures/LocalActionTransportFixture.swift", "-o", binary)
        app = home / "Applications/Blocks.app"
        layout = [
            ("app", "app.blocks.dev", "Contents/MacOS/Blocks"),
            ("cli", "app.blocks.dev.cli", "Contents/Resources/CLI/blocks"),
            ("broker", "app.blocks.dev.action-broker", "Contents/MacOS/BlocksActionBroker"),
            ("helper", "app.blocks.dev.selection-helper", "Contents/Helpers/blocksHelper.app/Contents/MacOS/blocksHelper"),
        ]
        peers = []
        paths = {}
        for role, identifier, relative in layout:
            executable = app / relative
            executable.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary, executable)
            paths[role] = executable
            peers.append(dict(role=role, identifier=identifier, relativeExecutablePath=relative,
                              cdHash=signature(executable, identifier)))
        installation = home / "Library/Application Support/Blocks Dev/Installation"
        installation.mkdir(parents=True, mode=0o700)
        os.chmod(installation.parent, 0o700)
        manifest = installation / "peers.json"
        manifest.write_text(json.dumps(dict(schemaVersion=1, appBundlePath=str(app), peers=peers)))
        os.chmod(manifest, 0o600)
        endpoint = home / "Actions"
        server = start(paths["app"], endpoint)
        try:
            result = client(paths["cli"], endpoint)
            assert result.returncode == 0 and result.stdout.strip() == "signed-roundtrip", result
            # Keep actual role, identifier and executable path intact, changing
            # only the pin in this private fixture manifest.
            original_hash = peers[1]["cdHash"]
            peers[1]["cdHash"] = "0" * 40
            manifest.write_text(json.dumps(dict(schemaVersion=1, appBundlePath=str(app), peers=peers)))
            result = client(paths["cli"], endpoint)
            assert result.returncode != 0 and "signed-roundtrip" not in result.stdout, result
            peers[1]["cdHash"] = original_hash
            manifest.write_text(json.dumps(dict(schemaVersion=1, appBundlePath=str(app), peers=peers)))
            # Real registered wrong-role process: app is not an authorized CLI.
            result = client(paths["app"], endpoint)
            assert result.returncode != 0 and "signed-roundtrip" not in result.stdout, result
            # Same identifier + same cdhash at an unregistered executable path.
            outsider = home / "unregistered-cli"
            shutil.copy2(paths["cli"], outsider)
            result = client(outsider, endpoint)
            assert result.returncode != 0 and "signed-roundtrip" not in result.stdout, result
            # A newly signed unrelated identity is equally rejected.
            signature(outsider, "app.blocks.fixture.unregistered")
            result = client(outsider, endpoint)
            assert result.returncode != 0 and "signed-roundtrip" not in result.stdout, result
        finally:
            server.terminate(); server.wait(timeout=5)
        outsider_app = home / "unregistered-app"
        shutil.copy2(paths["app"], outsider_app)
        server = start(outsider_app, home / "OtherActions")
        try:
            result = client(paths["cli"], home / "OtherActions")
            assert result.returncode != 0 and result.stdout.strip() == "untrustedPeer", result
        finally:
            server.terminate(); server.wait(timeout=5)
        print("PASS: actual ad-hoc signatures, mutual audit-token authentication, wrong-role rejection, "
              "unregistered path/hash rejection, unregistered server rejection; isolated compile-time home only")


if __name__ == "__main__":
    main()
