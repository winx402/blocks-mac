#!/usr/bin/env python3
"""Signing-policy tests use only synthetic public metadata and temporary files."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'script'))
import development_signing as signing


def rejected(action):
    try:
        action()
    except (RuntimeError, OSError):
        return
    raise AssertionError('unsafe signing configuration accepted')


with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / '.config/blocks/development-signing.json'
    path.parent.mkdir(parents=True)
    profile = {'schemaVersion': 1, 'mode': 'certificate', 'identity': 'A' * 40, 'teamIdentifier': 'TESTTEAM01'}
    assert signing.read_configuration(path)['mode'] == 'adhoc'
    path.write_text(json.dumps(profile)); path.chmod(0o600)
    assert signing.read_configuration(path) == profile
    path.chmod(0o644); rejected(lambda: signing.read_configuration(path)); path.chmod(0o600)
    link = path.with_name('link.json'); link.symlink_to(path)
    rejected(lambda: signing.read_configuration(link))
    for invalid in ({}, {'schemaVersion': 1, 'mode': 'unknown'}, {**profile, 'identity': 'name'}, {**profile, 'teamIdentifier': ''}):
        path.write_text(json.dumps(invalid))
        rejected(lambda: signing.read_configuration(path))
    path.write_text(json.dumps(profile))
    with patch.object(signing, 'configuration_path', lambda: path):
        signing.configuration.cache_clear()
        with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='0 valid identities found', stderr='')):
            rejected(signing.configuration)
        signing.configuration.cache_clear()
        with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='  1) ' + 'A' * 40 + ' "fixture"', stderr='')):
            assert signing.identity() == 'A' * 40
        signing.validate_metadata({'CDHash': 'a' * 40, 'TeamIdentifier': 'TESTTEAM01'})
        rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40, 'Signature': 'adhoc'}))
        rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40, 'TeamIdentifier': 'OTHERTEAM1'}))
        previous, staged = Path('previous.app'), Path('staged.app')
        requirement = 'identifier "app.blocks.dev" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01"'
        with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', return_value=requirement), patch.object(signing.subprocess, 'run') as run:
            signing.verify_stable_upgrade(previous, staged)
            assert run.call_args.args[0][-2:] == ['=' + requirement, str(staged)]
        with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', side_effect=[requirement, 'cdhash H"' + 'a' * 40 + '"']):
            rejected(lambda: signing.verify_stable_upgrade(previous, staged))
        with patch.object(signing, 'is_adhoc', return_value=True), patch.object(signing, 'designated_requirement', side_effect=['cdhash H"' + 'a' * 40 + '"', requirement]):
            signing.verify_stable_upgrade(previous, staged)
        with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', side_effect=['cdhash H"' + 'a' * 40 + '"', requirement]):
            rejected(lambda: signing.verify_stable_upgrade(previous, staged))
        signing.configuration.cache_clear()
print('PASS: signing pin, no fallback, stable requirement, and one-time legacy migration')
