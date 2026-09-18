"""Machine-local signing pin. Stores public identity metadata, never private keys."""
from functools import lru_cache
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess


def configuration_path() -> Path:
    return Path(pwd.getpwuid(os.getuid()).pw_dir) / '.config/blocks/development-signing.json'


def read_configuration(path: Path) -> dict:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if path.is_symlink():
            raise RuntimeError('Signing configuration must not be a symlink.')
        return {'schemaVersion': 1, 'mode': 'adhoc'}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 8192:
            raise RuntimeError('Signing configuration must be a private, owned regular file (0600).')
        for parent in (path.parent, path.parent.parent):
            metadata = parent.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
                raise RuntimeError('Signing configuration directory must be owned and not group/world writable.')
        try:
            data = json.loads(os.read(fd, 8193))
        except (ValueError, UnicodeError) as error:
            raise RuntimeError('Invalid signing configuration JSON.') from error
    finally:
        os.close(fd)
    if not isinstance(data, dict) or data.get('schemaVersion') != 1 or data.get('mode') not in ('adhoc', 'certificate'):
        raise RuntimeError('Unsupported signing configuration.')
    if data['mode'] == 'certificate':
        fingerprint, team = data.get('identity'), data.get('teamIdentifier', '')
        if not isinstance(fingerprint, str) or not re.fullmatch(r'[0-9A-F]{40}', fingerprint):
            raise RuntimeError('Certificate signing requires an exact 40-character uppercase SHA-1 identity.')
        if not isinstance(team, str) or (team and not re.fullmatch(r'[A-Z0-9]{10}', team)):
            raise RuntimeError('Team ID must be 10 uppercase letters/digits, or omitted/empty for a certificate without a subject OU.')
    return data


@lru_cache(maxsize=1)
def configuration() -> dict:
    data = read_configuration(configuration_path())
    if data['mode'] == 'certificate':
        result = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                                check=True, capture_output=True, text=True)
        identities = re.findall(r'^\s*\d+\) ([0-9A-F]{40}) ', result.stdout, re.MULTILINE)
        if data['identity'] not in identities:
            raise RuntimeError('Pinned signing certificate is unavailable. Restore it; refusing ad-hoc fallback.')
    return data


def identity() -> str:
    data = configuration()
    return data['identity'] if data['mode'] == 'certificate' else '-'


def verify_pinned_certificate(path: Path) -> None:
    """Authenticate the actual signer, never a display name or missing Team ID."""
    data = configuration()
    if data['mode'] != 'certificate':
        return
    requirement = 'certificate leaf = H"' + data['identity'] + '"'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, str(path)],
                   check=True, capture_output=True, text=True)


def validate_metadata(values: dict[str, str], path: Path) -> None:
    data = configuration()
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', values.get('CDHash', '')):
        raise RuntimeError('Invalid local build code hash.')
    if data['mode'] == 'adhoc':
        if values.get('Signature') != 'adhoc':
            raise RuntimeError('Expected an ad-hoc signature for this machine configuration.')
    else:
        team = data.get('teamIdentifier', '')
        actual_team = values.get('TeamIdentifier')
        if values.get('Signature') == 'adhoc':
            raise RuntimeError('Expected the pinned certificate, not an ad-hoc signature.')
        if (team and actual_team != team) or (not team and actual_team not in (None, 'not set')):
            raise RuntimeError('Installed component Team ID differs from the signing configuration.')
        # A matching (or absent) Team ID alone does not prove the certificate.
        verify_pinned_certificate(path)


def designated_requirement(path: Path) -> str:
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(path)],
                            check=True, capture_output=True, text=True)
    for line in (result.stdout + '\n' + result.stderr).splitlines():
        if 'designated => ' in line:
            return line.split('designated => ', 1)[1]
    raise RuntimeError('Could not read designated code requirement.')


def is_adhoc(path: Path) -> bool:
    result = subprocess.run(['/usr/bin/codesign', '-dvvv', str(path)],
                            check=True, capture_output=True, text=True)
    values = dict(line.split('=', 1) for line in result.stderr.splitlines() if '=' in line)
    return values.get('Signature') == 'adhoc' and values.get('TeamIdentifier') in (None, 'not set') and 'Authority' not in values


def verify_stable_upgrade(previous: Path, staged: Path) -> None:
    old = designated_requirement(previous)
    new = designated_requirement(staged)
    if is_adhoc(previous):
        # Explicit one-time migration away from the old certificate-free build.
        verify_pinned_certificate(staged)
        return
    if configuration()['mode'] != 'certificate' or old != new:
        raise RuntimeError('Upgrade would change the existing signing identity; refusing replacement.')
    verify_pinned_certificate(staged)
    verify_pinned_certificate(previous)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + old, str(staged)], check=True)
