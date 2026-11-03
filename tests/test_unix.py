"""Run the Unix entry points against isolated service, cron, and network fakes."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.name == 'nt', 'Unix service scripts')
class UnixTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.home = self.directory / "home with 'quotes%"
        self.home.mkdir()
        self.tools = self.directory / 'tools'
        self.tools.mkdir()
        self.source = self.directory / 'source'
        self.source.mkdir()
        self.installation = self.home / '.local/share/magic-wrapper'
        self.environment = {
            **os.environ,
            'HOME': str(self.home),
            'PATH': str(self.tools) + os.pathsep + os.environ['PATH'],
            'MAGIC_TEST_DIRECTORY': str(self.directory),
            'LC_ALL': 'C',
        }
        for filename in release_files():
            shutil.copyfile(ROOT / filename, self.source / filename)
        self.configuration = self.directory / 'subscription.yaml'
        self.configuration.write_text('mixed-port: 7890\n', encoding='utf-8')
        self.make_tool('uname', 'print("Linux")')
        self.make_tool('id', 'print("4242")')
        self.make_tool('sleep', '')
        self.make_tool(
            'crontab',
            """
            path = directory / 'crontab'
            if (directory / 'cron-denied').exists():
                print('permission denied', file=sys.stderr)
                sys.exit(1)
            if sys.argv[1] == '-l':
                if not path.exists():
                    print('no crontab for test-user', file=sys.stderr)
                    sys.exit(1)
                print(path.read_text(), end='')
            else:
                path.write_bytes(Path(sys.argv[1]).read_bytes())
        """,
        )
        self.make_tool(
            'curl',
            """
            if (directory / 'download-failed').exists():
                print('sensitive URL should not reach logs', file=sys.stderr)
                sys.exit(1)
            if '--request' in sys.argv:
                if 'Linux' in (directory / 'tools/uname').read_text():
                    settings = Path(os.environ['HOME']) / '.local/share/magic-wrapper'
                else:
                    settings = Path(os.environ['HOME']) / 'Library/Application Support/magic-wrapper'
                credentials = dict(
                    line.split('=', 1)
                    for line in (settings / 'controller.env').read_text().splitlines()
                )
                header = sys.stdin.read()
                assert credentials['CLASH_OVERRIDE_SECRET'] in header
                assert credentials['CLASH_OVERRIDE_SECRET'] not in ' '.join(sys.argv)
                controller_url = 'http://' + credentials['CLASH_OVERRIDE_EXTERNAL_CONTROLLER']
                assert '--noproxy' in sys.argv
                assert sys.argv[-1] == controller_url + '/configs?force=true'
                with (directory / 'reload-calls').open('a') as output:
                    output.write('reload\\n')
                rejected = (
                    'fail-start' in (settings / 'config.yaml').read_text()
                    or (directory / 'reload-denied').exists()
                )
                print('400' if rejected else '204', end='')
                sys.exit(0)
            assert sys.argv[sys.argv.index('--noproxy') + 1] == '*'
            destination = Path(sys.argv[sys.argv.index('--output') + 1])
            destination.write_bytes((directory / 'subscription.yaml').read_bytes())
        """,
        )
        self.make_tool(
            'systemctl',
            """
            arguments = [argument for argument in sys.argv[1:] if argument != '--user']
            with (directory / 'service-calls').open('a') as output:
                output.write(' '.join(arguments) + '\\n')
            unit = Path(os.environ['HOME']) / '.config/systemd/user/magic-wrapper.service'
            active = directory / 'active'
            configuration = Path(os.environ['HOME']) / '.local/share/magic-wrapper/config.yaml'
            if arguments[0] == 'cat':
                sys.exit(0 if unit.exists() else 1)
            if arguments[0] in ('stop', 'disable'):
                active.unlink(missing_ok=True)
            if arguments[0] == 'restart':
                if 'fail-start' in configuration.read_text():
                    active.unlink(missing_ok=True)
                    sys.exit(1)
                active.touch()
            if arguments[0] == 'is-active':
                sys.exit(0 if active.exists() else 1)
        """,
        )
        binary = self.source / 'mihomo'
        binary.write_text(
            f'#!{sys.executable}\nimport sys\nfrom pathlib import Path\n'
            'configuration = Path(sys.argv[sys.argv.index("-f") + 1])\n'
            'sys.exit(1 if "invalid" in configuration.read_text() else 0)\n',
            encoding='utf-8',
        )
        binary.chmod(0o755)

    def make_tool(self, name, body):
        path = self.tools / name
        path.write_text(
            f'#!{sys.executable}\nimport os\nimport sys\nfrom pathlib import Path\n'
            'directory = Path(os.environ["MAGIC_TEST_DIRECTORY"])\n'
            + textwrap.dedent(body),
            encoding='utf-8',
        )
        path.chmod(0o755)

    def run_script(self, name, *arguments, answer='', succeeds=True):
        result = subprocess.run(
            ['bash', str(self.source / name), *arguments],
            input=answer,
            text=True,
            capture_output=True,
            env=self.environment,
            check=False,
        )
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def install(self):
        self.run_script(
            'install.sh', 'https://example.invalid/sub?token=secret', '0 */6 * * *'
        )

    def test_cron_validation_uses_the_shared_cases(self):
        cases = json.loads((ROOT / 'tests/cron_cases.json').read_text(encoding='utf-8'))
        for case in cases:
            with self.subTest(expression=case['expression']):
                result = subprocess.run(
                    [
                        'bash',
                        '-c',
                        'source "$1"\nvalidate_cron "$2"',
                        'test',
                        str(ROOT / 'common.sh'),
                        case['expression'],
                    ],
                    env=self.environment,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode == 0, case['valid'])

    def test_install_update_reinstall_and_uninstall_preserve_unrelated_cron(self):
        cron = self.directory / 'crontab'
        original = '15 7 * * * echo user-task\n'
        cron.write_text(original, encoding='utf-8')
        self.install()
        self.assertIn(original, cron.read_text())
        self.assertEqual(cron.read_text().count(' # magic-wrapper'), 1)
        settings = self.installation / 'subscription-url'
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
        result = self.run_script(
            'install.sh', 'https://other.invalid/', '* * * * *', answer='n\n'
        )
        self.assertIn('cancelled', result.stdout)
        self.assertIn('example.invalid', settings.read_text())
        self.run_script(
            'install.sh', 'https://other.invalid/', '* * * * *', answer='y\n'
        )
        self.assertEqual(cron.read_text().count(' # magic-wrapper'), 1)
        command = (
            cron.read_text()
            .splitlines()[-1]
            .split(' ', 5)[5]
            .removesuffix(' # magic-wrapper')
        )
        result = subprocess.run(
            ['/bin/sh', '-c', command.replace('\\%', '%')],
            env=self.environment,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.run_script('uninstall.sh')
        self.run_script('uninstall.sh')
        self.assertEqual(cron.read_text(), original)
        self.assertTrue((self.installation / 'config.yaml').exists())
        self.assertFalse(
            (self.home / '.config/systemd/user/magic-wrapper.service').exists()
        )

    def test_updates_keep_good_configuration_on_download_validation_and_startup_failures(
        self,
    ):
        self.install()
        active = self.installation / 'config.yaml'
        original = active.read_bytes()
        (self.directory / 'download-failed').touch()
        failed = self.run_script('update.sh', succeeds=False)
        self.assertNotIn('sensitive URL', failed.stderr)
        self.assertEqual(active.read_bytes(), original)
        (self.directory / 'download-failed').unlink()
        self.configuration.write_text('invalid yaml', encoding='utf-8')
        self.run_script('update.sh', succeeds=False)
        self.assertEqual(active.read_bytes(), original)
        calls_before_reload = (self.directory / 'service-calls').read_text()
        self.configuration.write_text('fail-start', encoding='utf-8')
        self.run_script('update.sh', succeeds=False)
        self.assertEqual(
            (self.directory / 'service-calls').read_text(), calls_before_reload
        )
        self.assertEqual(active.read_bytes(), original)
        self.assertTrue((self.directory / 'active').exists())
        self.configuration.write_text('mixed-port: 7891\n', encoding='utf-8')
        self.run_script('update.sh')
        self.assertEqual(active.read_bytes(), self.configuration.read_bytes())
        self.assertEqual(
            (self.installation / 'config.previous.yaml').read_bytes(), original
        )
        self.assertEqual(
            (self.directory / 'service-calls').read_text(), calls_before_reload
        )
        calls = (self.directory / 'service-calls').read_text()
        reloads = (self.directory / 'reload-calls').read_text()
        self.run_script('update.sh')
        self.assertEqual((self.directory / 'reload-calls').read_text(), reloads)
        self.assertEqual((self.directory / 'service-calls').read_text(), calls)

    def test_failed_reinstall_restores_settings_configuration_and_cron(self):
        self.install()
        original_cron = (self.directory / 'crontab').read_bytes()
        original_url = (self.installation / 'subscription-url').read_bytes()
        original_configuration = (self.installation / 'config.yaml').read_bytes()
        self.configuration.write_text('fail-start', encoding='utf-8')
        self.run_script(
            'install.sh',
            'https://other.invalid/',
            '* * * * *',
            answer='y\n',
            succeeds=False,
        )
        self.assertEqual((self.directory / 'crontab').read_bytes(), original_cron)
        self.assertEqual(
            (self.installation / 'subscription-url').read_bytes(), original_url
        )
        self.assertEqual(
            (self.installation / 'config.yaml').read_bytes(), original_configuration
        )
        self.assertTrue((self.directory / 'active').exists())

    def test_legacy_installation_requires_reinstall_without_changing_configuration(
        self,
    ):
        self.install()
        (self.installation / 'controller.env').unlink()
        original = (self.installation / 'config.yaml').read_bytes()
        self.configuration.write_text('mixed-port: 7891', encoding='utf-8')
        calls = (self.directory / 'service-calls').read_text()
        self.run_script('update.sh', succeeds=False)
        self.assertEqual((self.installation / 'config.yaml').read_bytes(), original)
        self.assertEqual((self.directory / 'service-calls').read_text(), calls)

    def test_failed_rollback_reload_preserves_previous_file_without_restart(self):
        self.install()
        original = (self.installation / 'config.yaml').read_bytes()
        calls = (self.directory / 'service-calls').read_text()
        (self.directory / 'reload-denied').touch()
        self.configuration.write_text('mixed-port: 7891', encoding='utf-8')
        result = self.run_script('update.sh', succeeds=False)
        self.assertIn('manual recovery', result.stderr)
        self.assertEqual((self.installation / 'config.yaml').read_bytes(), original)
        self.assertEqual((self.directory / 'service-calls').read_text(), calls)

    def test_lock_prevents_parallel_updates(self):
        self.install()
        lock = self.installation / '.lock'
        lock.mkdir()
        result = self.run_script('update.sh')
        self.assertIn('skipping update', result.stdout)
        self.assertTrue(lock.exists())

    def test_crontab_read_failure_does_not_overwrite_existing_entries(self):
        self.install()
        original = (self.directory / 'crontab').read_bytes()
        (self.directory / 'cron-denied').touch()
        self.run_script('uninstall.sh', succeeds=False)
        self.assertEqual((self.directory / 'crontab').read_bytes(), original)

    def test_macos_plist_lifecycle_and_update_rollback(self):
        self.make_tool('uname', 'print("Darwin")')
        self.installation = self.home / 'Library/Application Support/magic-wrapper'
        self.make_tool(
            'launchctl',
            """
            import plistlib
            loaded = directory / 'launch-loaded'
            active = directory / 'launch-active'
            arguments = sys.argv[1:]
            if arguments[0] == 'print':
                if not loaded.exists():
                    sys.exit(1)
                if active.exists():
                    print('pid = 4242')
            if arguments[0] == 'bootout':
                loaded.unlink(missing_ok=True)
                active.unlink(missing_ok=True)
            if arguments[0] == 'bootstrap':
                definition = plistlib.loads(Path(arguments[2]).read_bytes())
                configuration = Path(definition['ProgramArguments'][-1]).parent / 'config.yaml'
                (directory / 'launch-configuration').write_text(str(configuration))
                loaded.touch()
            if arguments[0] in ('bootstrap', 'kickstart'):
                configuration = Path((directory / 'launch-configuration').read_text())
                active.unlink(missing_ok=True)
                if 'fail-start' not in configuration.read_text():
                    active.touch()
        """,
        )
        self.install()
        plist = self.home / 'Library/LaunchAgents/one.metacubex.magic-wrapper.plist'
        self.assertTrue(plist.exists())
        original = (self.installation / 'config.yaml').read_bytes()
        self.configuration.write_text('fail-start', encoding='utf-8')
        self.run_script('update.sh', succeeds=False)
        self.assertEqual((self.installation / 'config.yaml').read_bytes(), original)
        self.assertTrue((self.directory / 'launch-active').exists())
        self.run_script('uninstall.sh')
        self.assertFalse(plist.exists())
        self.assertFalse((self.directory / 'launch-loaded').exists())


def release_files():
    return ('common.sh', 'run.sh', 'install.sh', 'update.sh', 'uninstall.sh')


if __name__ == '__main__':
    unittest.main()
