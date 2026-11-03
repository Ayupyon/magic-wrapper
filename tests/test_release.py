"""Exercise release change detection and downloaded archive handling offline."""

import gzip
import hashlib
import io
import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from scripts import release


class ReleaseTest(unittest.TestCase):
    def test_version_and_wrapper_changes_require_packaging(self):
        inputs = {'mihomo': 'v1', 'winsw': 'v2', 'wrapper_sha256': 'abc'}
        self.assertTrue(release.needs_build(None, inputs, False))
        self.assertFalse(release.needs_build({'inputs': inputs}, inputs, False))
        self.assertTrue(release.needs_build({'inputs': inputs}, inputs, True))
        for name in inputs:
            changed = {**inputs, name: 'new'}
            self.assertTrue(release.needs_build({'inputs': inputs}, changed, False))

    def test_exact_asset_selection_does_not_select_a_different_cpu_level(self):
        upstream = {
            'assets': [
                {'name': 'mihomo-linux-amd64-v3-v1.gz'},
                {'name': 'mihomo-linux-amd64-v1-v1.gz'},
            ]
        }
        self.assertEqual(
            release.select_asset(upstream, 'mihomo-linux-amd64-v1-v1.gz'),
            upstream['assets'][1],
        )
        with self.assertRaises(ValueError):
            release.select_asset(upstream, 'absent.gz')

    def test_download_checks_size_and_upstream_digest(self):
        asset = {
            'name': 'binary',
            'browser_download_url': 'https://example.invalid/binary',
            'size': 6,
            'digest': 'sha256:' + hashlib.sha256(b'binary').hexdigest(),
        }
        with mock.patch.object(release, 'fetch', return_value=b'binary'):
            self.assertEqual(release.download_asset(asset), b'binary')
            with self.assertRaises(ValueError):
                release.download_asset({**asset, 'size': 7})
            with self.assertRaises(ValueError):
                release.download_asset({**asset, 'digest': 'sha256:wrong'})

    def test_unpacking_selects_only_the_binary_without_extracting_paths(self):
        self.assertEqual(
            release.unpack_mihomo(gzip.compress(b'binary'), '.gz'), b'binary'
        )
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('../mihomo-windows-amd64.exe', b'binary')
            archive.writestr('../../unwanted', b'other')
        self.assertEqual(release.unpack_mihomo(data.getvalue(), '.zip'), b'binary')

    def test_missing_release_is_distinct_from_api_failure(self):
        missing = subprocess.CompletedProcess(
            [], 1, 'HTTP/2.0 404 Not Found\n\n{}', 'not found'
        )
        denied = subprocess.CompletedProcess(
            [], 1, 'HTTP/2.0 403 Forbidden\n\n{}', 'denied'
        )
        with mock.patch.object(release.subprocess, 'run', return_value=missing):
            self.assertIsNone(
                release.github_json(
                    'repos/example/releases/tags/nightly', missing_ok=True
                )
            )
        with (
            mock.patch.object(release.subprocess, 'run', return_value=denied),
            self.assertRaises(RuntimeError),
        ):
            release.github_json('repos/example/releases/tags/nightly', missing_ok=True)

    def test_manifest_upload_happens_after_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / 'inputs.json').write_text(
                json.dumps({'release_exists': True}), encoding='utf-8'
            )
            with (
                mock.patch.object(release, 'STATE', state),
                mock.patch.dict(
                    release.os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}
                ),
                mock.patch.object(release.subprocess, 'run') as run,
            ):
                release.publish()
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(
                {
                    Path(argument).name
                    for argument in commands[0]
                    if argument.endswith('.zip')
                },
                {f'magic-{platform}.zip' for platform in release.PLATFORMS},
            )
            self.assertTrue(
                any(argument.endswith('manifest.json') for argument in commands[1])
            )

    def test_failed_archive_upload_does_not_publish_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / 'inputs.json').write_text(
                json.dumps({'release_exists': True}), encoding='utf-8'
            )
            with (
                mock.patch.object(release, 'STATE', state),
                mock.patch.dict(
                    release.os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}
                ),
                mock.patch.object(
                    release.subprocess,
                    'run',
                    side_effect=subprocess.CalledProcessError(1, 'gh'),
                ) as run,
                self.assertRaises(subprocess.CalledProcessError),
            ):
                release.publish()
            self.assertEqual(run.call_count, 1)

    def test_build_creates_all_four_valid_archives_offline(self):
        binary = b'fixture mihomo binary'
        zipped = io.BytesIO()
        with zipfile.ZipFile(zipped, 'w') as archive:
            archive.writestr('mihomo-windows-amd64.exe', binary)
        downloads = {}
        assets = []
        for architecture, suffix in release.PLATFORMS.values():
            name = f'mihomo-{architecture}-v1{suffix}'
            content = zipped.getvalue() if suffix == '.zip' else gzip.compress(binary)
            url = f'https://example.invalid/{name}'
            downloads[url] = content
            assets.append(
                {'name': name, 'browser_download_url': url, 'size': len(content)}
            )
        winsw_asset = {
            'name': 'WinSW-x64.exe',
            'browser_download_url': 'https://example.invalid/winsw',
            'size': 5,
        }
        downloads[winsw_asset['browser_download_url']] = b'winsw'
        downloads['https://raw.githubusercontent.com/MetaCubeX/mihomo/v1/LICENSE'] = (
            b'mihomo license'
        )
        downloads['https://raw.githubusercontent.com/winsw/winsw/v2/LICENSE.txt'] = (
            b'winsw license'
        )
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state'
            state.mkdir()
            output = Path(directory) / 'dist'
            release.write_json(
                state / 'inputs.json',
                {
                    'mihomo': {'tag_name': 'v1', 'assets': assets},
                    'winsw': {'tag_name': 'v2', 'assets': [winsw_asset]},
                    'inputs': {},
                },
            )
            with (
                mock.patch.object(release, 'STATE', state),
                mock.patch.object(release, 'OUTPUT', output),
                mock.patch.object(release, 'fetch', side_effect=downloads.__getitem__),
            ):
                release.build()
            self.assertEqual(len(list(output.glob('*.zip'))), 4)
            checksums = []
            for platform in release.PLATFORMS:
                archive_path = output / f'magic-{platform}.zip'
                with zipfile.ZipFile(archive_path) as archive:
                    self.assertIsNone(archive.testzip())
                    is_windows = platform.startswith('windows')
                    binary_name = 'mihomo.exe' if is_windows else 'mihomo'
                    self.assertEqual(archive.read(binary_name), binary)
                    if is_windows:
                        self.assertEqual(archive.read('winsw.exe'), b'winsw')
                checksums.append(
                    f'{hashlib.sha256(archive_path.read_bytes()).hexdigest()}  {archive_path.name}'
                )
            self.assertEqual(
                (output / 'SHA256SUMS').read_text().splitlines(), checksums
            )
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(set(manifest['binaries']), set(release.PLATFORMS))
            self.assertEqual(
                (state / 'windows-x86_64/winsw.exe').read_bytes(), b'winsw'
            )


if __name__ == '__main__':
    unittest.main()
