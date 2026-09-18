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
    for valid in ({**profile, 'teamIdentifier': ''}, {k: v for k, v in profile.items() if k != 'teamIdentifier'}):
        path.write_text(json.dumps(valid))
        assert signing.read_configuration(path) == valid
    for invalid in ({}, {'schemaVersion': 1, 'mode': 'unknown'}, {**profile, 'identity': 'name'},
                    {**profile, 'identity': 'a' * 40}, {**profile, 'identity': None},
                    {**profile, 'teamIdentifier': None}, {**profile, 'teamIdentifier': 'not set'}):
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
        component = Path('component')
        pin = '=certificate leaf = H"' + 'A' * 40 + '"'
        with patch.object(signing.subprocess, 'run') as run:
            signing.validate_metadata({'CDHash': 'a' * 40, 'TeamIdentifier': 'TESTTEAM01'}, component)
            assert run.call_args.args[0] == ['/usr/bin/codesign', '--verify', '--strict', '-R', pin, str(component)]
            assert run.call_args.kwargs['check'] is True
        rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40, 'Signature': 'adhoc'}, component))
        rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40, 'TeamIdentifier': 'OTHERTEAM1'}, component))
        previous, staged = Path('previous.app'), Path('staged.app')
        requirement = 'identifier "app.blocks.dev" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01"'
        with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', return_value=requirement), patch.object(signing.subprocess, 'run') as run:
            signing.verify_stable_upgrade(previous, staged)
            assert run.call_args.args[0][-2:] == ['=' + requirement, str(staged)]
        with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', side_effect=[requirement, 'cdhash H"' + 'a' * 40 + '"']):
            rejected(lambda: signing.verify_stable_upgrade(previous, staged))
        with patch.object(signing, 'is_adhoc', return_value=True), patch.object(signing, 'designated_requirement', side_effect=['cdhash H"' + 'a' * 40 + '"', requirement]), patch.object(signing.subprocess, 'run') as run:
            signing.verify_stable_upgrade(previous, staged)
            assert run.call_args.args[0][-2:] == [pin, str(staged)]
        with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', side_effect=['cdhash H"' + 'a' * 40 + '"', requirement]):
            rejected(lambda: signing.verify_stable_upgrade(previous, staged))
        signing.configuration.cache_clear()

# Every certificate mode authenticates the actual leaf, including a same-Team
# impostor. Missing Team metadata/configuration never substitutes for that check.
for team in ('TESTTEAM01', ''):
    profile = {'schemaVersion': 1, 'mode': 'certificate', 'identity': 'A' * 40, 'teamIdentifier': team}
    metadata = {'CDHash': 'a' * 40, 'TeamIdentifier': team or 'not set'}
    with patch.object(signing, 'configuration', return_value=profile), patch.object(signing.subprocess, 'run') as run:
        signing.validate_metadata(metadata, component)
        assert run.call_args.args[0][-2:] == [pin, str(component)]
        run.side_effect = subprocess.CalledProcessError(3, 'codesign')
        try:
            signing.validate_metadata(metadata, component)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError('failed certificate pin accepted')

profile.pop('teamIdentifier')
with patch.object(signing, 'configuration', return_value=profile), patch.object(signing.subprocess, 'run') as run:
    signing.validate_metadata({'CDHash': 'a' * 64}, component)
    assert run.call_args.args[0][-2:] == [pin, str(component)]
    rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40, 'TeamIdentifier': 'TESTTEAM01'}, component))
    rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40, 'Signature': 'adhoc'}, component))
    rejected(lambda: signing.validate_metadata({'CDHash': 'invalid'}, component))

requirement = 'identifier "app.blocks.dev" and anchor H"' + 'A' * 40 + '"'
with patch.object(signing, 'configuration', return_value=profile), patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', return_value=requirement), patch.object(signing.subprocess, 'run') as run:
    signing.verify_stable_upgrade(previous, staged)
    assert [call.args[0][-2:] for call in run.call_args_list] == [
        [pin, str(staged)], [pin, str(previous)], ['=' + requirement, str(staged)]]
    for failure_at in range(3):
        results = [None] * 3
        results[failure_at] = subprocess.CalledProcessError(3, 'codesign')
        run.side_effect = results
        try:
            signing.verify_stable_upgrade(previous, staged)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError('failed upgrade signature verification accepted')

with patch.object(signing, 'configuration', return_value={'mode': 'adhoc'}), patch.object(signing.subprocess, 'run') as run:
    signing.validate_metadata({'CDHash': 'a' * 40, 'Signature': 'adhoc'}, component)
    rejected(lambda: signing.validate_metadata({'CDHash': 'a' * 40}, component))
    run.assert_not_called()
    with patch.object(signing, 'is_adhoc', return_value=False), patch.object(signing, 'designated_requirement', return_value=requirement):
        rejected(lambda: signing.verify_stable_upgrade(previous, staged))

print('PASS: exact leaf pin, optional Team ID, no fallback, stable DR, and legacy migration')
