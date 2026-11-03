#!/usr/bin/env python3
"""Check upstream releases and prepare the four distributable archives."""

import argparse
import gzip
import hashlib
import io
import json
import os
import shutil
import subprocess
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.release'
OUTPUT = ROOT / 'dist'
UNIX_FILES = ('common.sh', 'run.sh', 'install.sh', 'update.sh', 'uninstall.sh')
WINDOWS_FILES = ('common.ps1', 'run.ps1', 'install.ps1', 'update.ps1', 'uninstall.ps1')
PACKAGE_FILES = (
    *UNIX_FILES,
    *WINDOWS_FILES,
    'README.md',
    'scripts/release.py',
    '.github/workflows/nightly.yml',
)
PLATFORMS = {
    'linux-x86_64': ('linux-amd64-v1', '.gz'),
    'linux-arm64': ('linux-arm64', '.gz'),
    'windows-x86_64': ('windows-amd64-v1', '.zip'),
    'macos-arm64': ('darwin-arm64', '.gz'),
}


def fetch(url: str) -> bytes:
    """Download public upstream data without sending repository credentials."""
    if urllib.parse.urlparse(url).scheme != 'https':
        raise ValueError('Downloads must use HTTPS.')
    request = urllib.request.Request(url, headers={'User-Agent': 'magic-wrapper'})
    with urllib.request.urlopen(request, timeout=120) as response:
        if urllib.parse.urlparse(response.url).scheme != 'https':
            raise ValueError('Download redirected away from HTTPS.')
        return response.read()


def github_json(endpoint: str, *, missing_ok: bool = False) -> dict[str, Any] | None:
    """Use gh for authenticated API access and reliable private-repo support."""
    result = subprocess.run(
        ['gh', 'api', '--include', endpoint],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        if (
            missing_ok
            and result.stdout.startswith('HTTP/')
            and ' 404 ' in result.stdout.splitlines()[0]
        ):
            return None
        raise RuntimeError(f'GitHub API request failed: {endpoint}\n{result.stderr}')
    # gh emits response headers before the JSON body when --include is used.
    _, separator, body = result.stdout.replace('\r\n', '\n').partition('\n\n')
    if not separator:
        raise ValueError('GitHub API response has no body.')
    return json.loads(body)


def select_asset(release: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [
        asset for asset in release['assets'] if asset['name'].lower() == name.lower()
    ]
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one upstream asset named {name}.')
    return matches[0]


def wrapper_digest() -> str:
    digest = hashlib.sha256()
    for filename in PACKAGE_FILES:
        digest.update(
            filename.encode() + b'\0' + (ROOT / filename).read_bytes() + b'\0'
        )
    return digest.hexdigest()


def release_inputs(mihomo: dict[str, Any], winsw: dict[str, Any]) -> dict[str, Any]:
    return {
        'mihomo': {'tag': mihomo['tag_name'], 'release_id': mihomo['id']},
        'winsw': {'tag': winsw['tag_name'], 'release_id': winsw['id']},
        'wrapper_sha256': wrapper_digest(),
    }


def needs_build(
    previous: dict[str, Any] | None, inputs: dict[str, Any], force: bool
) -> bool:
    return force or previous is None or previous.get('inputs') != inputs


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8'
    )


def check(force: bool) -> None:
    repository = os.environ['GITHUB_REPOSITORY']
    mihomo = github_json('repos/MetaCubeX/mihomo/releases/latest')
    winsw = github_json('repos/winsw/winsw/releases/latest')
    assert mihomo is not None and winsw is not None
    for release in (mihomo, winsw):
        if release['draft'] or release['prerelease']:
            raise ValueError('Expected a stable upstream release.')
    # Fail before publishing anything if upstream asset naming has changed.
    for architecture, suffix in PLATFORMS.values():
        select_asset(mihomo, f'mihomo-{architecture}-{mihomo["tag_name"]}{suffix}')
    select_asset(winsw, 'WinSW-x64.exe')
    current = github_json(f'repos/{repository}/releases/tags/nightly', missing_ok=True)
    previous = None
    if current and any(asset['name'] == 'manifest.json' for asset in current['assets']):
        result = subprocess.run(
            [
                'gh',
                'release',
                'download',
                'nightly',
                '--repo',
                repository,
                '--pattern',
                'manifest.json',
                '--output',
                '-',
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        previous = json.loads(result.stdout)
    inputs = release_inputs(mihomo, winsw)
    changed = needs_build(previous, inputs, force)
    # A draft or incomplete release must be retried even if its manifest exists.
    expected_assets = {f'magic-{platform}.zip' for platform in PLATFORMS} | {
        'SHA256SUMS',
        'manifest.json',
    }
    if current and (
        current['draft']
        or not expected_assets.issubset({asset['name'] for asset in current['assets']})
    ):
        changed = True
    STATE.mkdir(exist_ok=True)
    write_json(
        STATE / 'inputs.json',
        {
            'mihomo': mihomo,
            'winsw': winsw,
            'inputs': inputs,
            'release_exists': current is not None,
        },
    )
    if output_file := os.environ.get('GITHUB_OUTPUT'):
        with Path(output_file).open('a', encoding='utf-8') as output:
            output.write(f'changed={str(changed).lower()}\n')
    print(
        'Packaging required.'
        if changed
        else 'Upstream versions and wrapper contents are unchanged.'
    )


def download_asset(asset: dict[str, Any]) -> bytes:
    content = fetch(asset['browser_download_url'])
    if len(content) != asset['size']:
        raise ValueError(f'Incomplete download: {asset["name"]}')
    digest = 'sha256:' + hashlib.sha256(content).hexdigest()
    if asset.get('digest') and digest != asset['digest']:
        raise ValueError(f'Checksum mismatch: {asset["name"]}')
    return content


def unpack_mihomo(content: bytes, suffix: str) -> bytes:
    if suffix == '.gz':
        return gzip.decompress(content)
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        executables = [
            name
            for name in archive.namelist()
            if not name.endswith('/')
            and Path(name).name.lower().startswith('mihomo')
            and name.lower().endswith('.exe')
        ]
        if len(executables) != 1:
            raise ValueError(
                'Expected exactly one Mihomo executable in the Windows archive.'
            )
        return archive.read(executables[0])


def build() -> None:
    state = json.loads((STATE / 'inputs.json').read_text(encoding='utf-8'))
    mihomo = state['mihomo']
    winsw = state['winsw']
    OUTPUT.mkdir(exist_ok=True)
    mihomo_tag = urllib.parse.quote(mihomo['tag_name'], safe='')
    winsw_tag = urllib.parse.quote(winsw['tag_name'], safe='')
    mihomo_license = fetch(
        f'https://raw.githubusercontent.com/MetaCubeX/mihomo/{mihomo_tag}/LICENSE'
    )
    winsw_license = fetch(
        f'https://raw.githubusercontent.com/winsw/winsw/{winsw_tag}/LICENSE.txt'
    )
    winsw_asset = select_asset(winsw, 'WinSW-x64.exe')
    winsw_binary = download_asset(winsw_asset)
    manifest: dict[str, Any] = {
        'inputs': state['inputs'],
        'wrapper_commit': os.environ.get('GITHUB_SHA', 'local'),
        'sources': {
            'mihomo': f'https://github.com/MetaCubeX/mihomo/tree/{mihomo_tag}',
            'winsw': f'https://github.com/winsw/winsw/tree/{winsw_tag}',
        },
        'binaries': {},
    }
    for platform, (architecture, suffix) in PLATFORMS.items():
        bundle = STATE / f'magic-{platform}'
        if bundle.exists():
            shutil.rmtree(bundle)
        bundle.mkdir()
        is_windows = platform.startswith('windows')
        platform_files = WINDOWS_FILES if is_windows else UNIX_FILES
        for filename in (*platform_files, 'README.md'):
            shutil.copy2(ROOT / filename, bundle / filename)
        asset = select_asset(
            mihomo, f'mihomo-{architecture}-{mihomo["tag_name"]}{suffix}'
        )
        binary = unpack_mihomo(download_asset(asset), suffix)
        binary_path = bundle / ('mihomo.exe' if is_windows else 'mihomo')
        binary_path.write_bytes(binary)
        binary_path.chmod(0o755)
        (bundle / 'LICENSE-mihomo.txt').write_bytes(mihomo_license)
        manifest['binaries'][platform] = {
            'asset': asset['name'],
            'url': asset['browser_download_url'],
            'sha256': hashlib.sha256(binary).hexdigest(),
            'upstream_digest': asset.get('digest'),
        }
        if is_windows:
            (bundle / 'winsw.exe').write_bytes(winsw_binary)
            (bundle / 'LICENSE-winsw.txt').write_bytes(winsw_license)
            manifest['binaries'][platform]['winsw_sha256'] = hashlib.sha256(
                winsw_binary
            ).hexdigest()
        write_json(
            bundle / 'versions.json',
            {
                'inputs': state['inputs'],
                'sources': manifest['sources'],
                'wrapper_commit': manifest['wrapper_commit'],
            },
        )
        archive = OUTPUT / f'magic-{platform}.zip'
        shutil.make_archive(
            str(archive.with_suffix('')),
            'zip',
            root_dir=bundle.parent,
            base_dir=bundle.name,
        )
        with zipfile.ZipFile(archive) as package:
            if corrupted_file := package.testzip():
                raise ValueError(f'Corrupt file in {archive.name}: {corrupted_file}')
    checksums = []
    for platform in PLATFORMS:
        archive = OUTPUT / f'magic-{platform}.zip'
        checksums.append(
            f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}'
        )
    (OUTPUT / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n', encoding='utf-8')
    write_json(OUTPUT / 'manifest.json', manifest)
    (STATE / 'notes.md').write_text(
        f'Mihomo: **{mihomo["tag_name"]}**; WinSW: **{winsw["tag_name"]}**.\n\n'
        f'Wrapper commit: `{manifest["wrapper_commit"]}`.\n\n'
        'Packages are rebuilt only when upstream releases or wrapper contents change. '
        'See manifest.json for source references and SHA256SUMS for archive checksums.\n',
        encoding='utf-8',
    )


def publish() -> None:
    state = json.loads((STATE / 'inputs.json').read_text(encoding='utf-8'))
    repository = os.environ['GITHUB_REPOSITORY']
    common_arguments = ['--repo', repository]
    notes = str(STATE / 'notes.md')
    if not state['release_exists']:
        subprocess.run(
            [
                'gh',
                'release',
                'create',
                'nightly',
                *common_arguments,
                '--draft',
                '--prerelease',
                '--title',
                'Nightly',
                '--target',
                os.environ['GITHUB_SHA'],
                '--notes-file',
                notes,
                '--latest=false',
            ],
            check=True,
        )
    archives = [str(OUTPUT / f'magic-{platform}.zip') for platform in PLATFORMS]
    subprocess.run(
        [
            'gh',
            'release',
            'upload',
            'nightly',
            *common_arguments,
            *archives,
            str(OUTPUT / 'SHA256SUMS'),
            '--clobber',
        ],
        check=True,
    )
    # The manifest records success only after every archive has uploaded.
    subprocess.run(
        [
            'gh',
            'release',
            'upload',
            'nightly',
            *common_arguments,
            str(OUTPUT / 'manifest.json'),
            '--clobber',
        ],
        check=True,
    )
    subprocess.run(
        [
            'gh',
            'release',
            'edit',
            'nightly',
            *common_arguments,
            '--draft=false',
            '--prerelease',
            '--title',
            'Nightly',
            '--notes-file',
            notes,
            '--latest=false',
        ],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'build', 'publish'))
    parser.add_argument('--force', action='store_true')
    arguments = parser.parse_args()
    if arguments.command == 'check':
        check(arguments.force)
    elif arguments.command == 'build':
        build()
    else:
        publish()


if __name__ == '__main__':
    main()
