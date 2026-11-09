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
                secret = credentials['CLASH_OVERRIDE_SECRET']
                if secret:
                    assert header.strip() == 'header = "Authorization: Bearer ' + secret + '"'
                    assert not any(argument.startswith('Authorization:') for argument in sys.argv)
                else:
                    assert header == ''
                host, port = credentials['CLASH_OVERRIDE_EXTERNAL_CONTROLLER'].split(':')
                if host == '0.0.0.0':
                    host = '127.0.0.1'
                controller_url = 'http://' + host + ':' + port
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
            assert sys.argv[sys.argv.index('--user-agent') + 1] == 'clash.meta'
            assert sys.argv[sys.argv.index('--proto') + 1] == '=http,https'
            assert sys.argv[sys.argv.index('--proto-redir') + 1] == '=http,https'
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

    def read_controller(self):
        return dict(
            line.split('=', 1)
            for line in (self.installation / 'controller.env').read_text().splitlines()
        )

    def test_controller_address_validation_uses_the_shared_cases(self):
        cases = json.loads(
            (ROOT / 'tests/controller_address_cases.json').read_text(encoding='utf-8')
        )
        for case in cases:
            with self.subTest(address=case['address']):
                result = subprocess.run(
                    [
                        'bash',
                        '-c',
                        'source "$1"\nvalidate_controller_address "$2"',
                        'test',
                        str(ROOT / 'common.sh'),
                        case['address'],
                    ],
                    env=self.environment,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode == 0, case['valid'], result.stderr)

    def test_network_controller_addresses_survive_updates_reinstalls_and_rollback(self):
        arguments = ('install.sh', 'https://example.invalid/', '* * * * *')
        for address in ('192.168.1.10:9090', '0.0.0.0:9090'):
            with self.subTest(address=address):
                self.run_script(
                    *arguments, '--controller-address', address, answer='y\n'
                )
                controller = self.read_controller()
                self.assertEqual(
                    controller['CLASH_OVERRIDE_EXTERNAL_CONTROLLER'], address
                )
                self.configuration.write_text('mixed-port: 7891\n', encoding='utf-8')
                self.run_script('update.sh')
                self.assertEqual(self.read_controller(), controller)
                self.run_script(*arguments, answer='y\n')
                self.assertEqual(self.read_controller(), controller)
                configuration = self.installation / 'config.yaml'
                original = configuration.read_bytes()
                self.configuration.write_text('fail-start', encoding='utf-8')
                self.run_script('update.sh', succeeds=False)
                self.assertEqual(configuration.read_bytes(), original)
                self.assertEqual(self.read_controller(), controller)
                self.run_script(
                    *arguments,
                    '--controller-address',
                    '192.168.1.20:9090',
                    answer='y\n',
                    succeeds=False,
                )
                self.assertEqual(configuration.read_bytes(), original)
                self.assertEqual(self.read_controller(), controller)
                self.assertTrue((self.directory / 'active').exists())
                self.configuration.write_text('mixed-port: 7890\n', encoding='utf-8')
                self.run_script('update.sh')
                self.assertEqual(self.read_controller(), controller)

    def test_custom_controller_is_used_preserved_and_independently_overridden(self):
        address = '127.0.0.1:9090'
        secret = 'a1' * 32
        arguments = ('install.sh', 'https://example.invalid/', '* * * * *')
        self.run_script(
            *arguments,
            '--controller-address',
            address,
            '--controller-secret',
            secret,
        )
        expected = {
            'CLASH_OVERRIDE_EXTERNAL_CONTROLLER': address,
            'CLASH_OVERRIDE_SECRET': secret,
        }
        self.assertEqual(self.read_controller(), expected)
        self.assertEqual(
            (self.installation / 'controller.env').stat().st_mode & 0o777, 0o600
        )
        binary = self.installation / 'mihomo'
        binary.write_text(
            f'#!{sys.executable}\nimport os\n'
            f'assert os.environ["CLASH_OVERRIDE_EXTERNAL_CONTROLLER"] == {address!r}\n'
            f'assert os.environ["CLASH_OVERRIDE_SECRET"] == {secret!r}\n',
            encoding='utf-8',
        )
        self.run_script(str(self.installation / 'run.sh'))
        self.run_script(*arguments, answer='y\n')
        self.assertEqual(self.read_controller(), expected)
        self.run_script(
            *arguments, '--controller-address', '127.0.0.1:1024', answer='y\n'
        )
        expected['CLASH_OVERRIDE_EXTERNAL_CONTROLLER'] = '127.0.0.1:1024'
        self.assertEqual(self.read_controller(), expected)
        self.run_script(*arguments, '--controller-secret', 'b2' * 32, answer='y\n')
        expected['CLASH_OVERRIDE_SECRET'] = 'b2' * 32
        self.assertEqual(self.read_controller(), expected)
        self.configuration.write_text('mixed-port: 7891\n', encoding='utf-8')
        self.run_script('update.sh')
        self.assertEqual(self.read_controller(), expected)
        commands = (self.directory / 'crontab').read_text() + (
            self.home / '.config/systemd/user/magic-wrapper.service'
        ).read_text()
        self.assertNotIn(secret, commands)
        self.assertNotIn(expected['CLASH_OVERRIDE_SECRET'], commands)

    def test_address_only_install_generates_a_secret(self):
        self.run_script(
            'install.sh',
            'https://example.invalid/',
            '* * * * *',
            '--controller-address',
            '127.0.0.1:65535',
        )
        controller = self.read_controller()
        self.assertEqual(
            controller['CLASH_OVERRIDE_EXTERNAL_CONTROLLER'], '127.0.0.1:65535'
        )
        self.assertRegex(controller['CLASH_OVERRIDE_SECRET'], r'^[0-9a-f]{64}$')

    def test_secret_only_install_generates_an_address(self):
        self.run_script(
            'install.sh',
            'https://example.invalid/',
            '* * * * *',
            '--controller-secret',
            'c3' * 32,
        )
        controller = self.read_controller()
        self.assertEqual(controller['CLASH_OVERRIDE_SECRET'], 'c3' * 32)
        port = int(controller['CLASH_OVERRIDE_EXTERNAL_CONTROLLER'].split(':')[1])
        self.assertGreaterEqual(port, 49152)
        self.assertLessEqual(port, 65535)

    def test_alphanumeric_secrets_have_no_length_limit(self):
        for secret in ('0', 'aZ09', 'a' * 63, 'A' * 65, 'Az09' * 1024):
            with self.subTest(length=len(secret)):
                self.run_script(
                    'install.sh',
                    'https://example.invalid/',
                    '* * * * *',
                    '--controller-secret',
                    secret,
                    answer='y\n',
                )
                self.assertEqual(
                    self.read_controller()['CLASH_OVERRIDE_SECRET'], secret
                )

    def test_empty_secret_warns_and_survives_updates_reinstalls_and_rollback(self):
        arguments = ('install.sh', 'https://example.invalid/', '* * * * *')
        result = self.run_script(*arguments, '--controller-secret', '')
        self.assertIn('Warning: Empty controller secret', result.stderr)
        self.assertEqual(self.read_controller()['CLASH_OVERRIDE_SECRET'], '')
        self.configuration.write_text('mixed-port: 7891\n', encoding='utf-8')
        self.run_script('update.sh')
        self.assertEqual(self.read_controller()['CLASH_OVERRIDE_SECRET'], '')
        result = self.run_script(*arguments, answer='y\n')
        self.assertIn('Warning: Empty controller secret', result.stderr)
        self.assertEqual(self.read_controller()['CLASH_OVERRIDE_SECRET'], '')
        self.configuration.write_text('fail-start', encoding='utf-8')
        self.run_script(
            *arguments, '--controller-secret', 'Ab9', answer='y\n', succeeds=False
        )
        self.assertEqual(self.read_controller()['CLASH_OVERRIDE_SECRET'], '')
        self.configuration.write_text('mixed-port: 7890\n', encoding='utf-8')
        self.run_script(*arguments, '--controller-secret', 'Ab9', answer='y\n')
        self.assertEqual(self.read_controller()['CLASH_OVERRIDE_SECRET'], 'Ab9')
        self.run_script(*arguments, '--controller-secret', '', answer='y\n')
        self.assertEqual(self.read_controller()['CLASH_OVERRIDE_SECRET'], '')

    def test_missing_saved_secret_is_rejected(self):
        self.install()
        controller_path = self.installation / 'controller.env'
        address = self.read_controller()['CLASH_OVERRIDE_EXTERNAL_CONTROLLER']
        controller_path.write_text(
            f'CLASH_OVERRIDE_EXTERNAL_CONTROLLER={address}\n', encoding='utf-8'
        )
        result = self.run_script('update.sh', succeeds=False)
        self.assertIn('Controller settings are missing or invalid', result.stderr)

    def test_invalid_controller_arguments_leave_installation_unchanged(self):
        secret = 'a1' * 32
        cases = [
            ('--unknown', secret),
            (secret,),
            ('--controller-address',),
            ('--controller-secret',),
            (
                '--controller-address',
                '127.0.0.1:9090',
                '--controller-address',
                '127.0.0.1:9091',
            ),
            ('--controller-secret', secret, '--controller-secret', secret),
            ('--controller-secret', '', '--controller-secret', secret),
        ]
        cases.extend(
            ('--controller-address', case['address'])
            for case in json.loads(
                (ROOT / 'tests/controller_address_cases.json').read_text(
                    encoding='utf-8'
                )
            )
            if not case['valid']
        )
        cases.extend(
            ('--controller-secret', value)
            for value in (
                'with space',
                'with-hyphen',
                'with_underscore',
                'é',
                secret + '\n',
                secret + '\r',
            )
        )
        for installed in (False, True):
            if installed:
                self.install()
            paths = (
                self.installation / 'controller.env',
                self.installation / 'config.yaml',
                self.directory / 'service-calls',
                self.directory / 'crontab',
            )
            original = [path.read_bytes() if path.exists() else None for path in paths]
            for arguments in cases:
                with self.subTest(installed=installed, arguments=arguments):
                    result = self.run_script(
                        'install.sh',
                        'https://example.invalid/',
                        '* * * * *',
                        *arguments,
                        succeeds=False,
                    )
                    self.assertNotIn(secret, result.stdout + result.stderr)
                    self.assertEqual(
                        [
                            path.read_bytes() if path.exists() else None
                            for path in paths
                        ],
                        original,
                    )
                    self.assertEqual(self.installation.exists(), installed)

    def test_subscription_urls_require_http_or_https_without_newlines(self):
        cases = (
            ('http://example.invalid/sub?token=secret', True),
            ('https://example.invalid/sub?token=secret', True),
            ('ftp://example.invalid/sub', False),
            ('file:///tmp/sub', False),
            ('example.invalid/sub', False),
            ('http://', False),
            ('https://', False),
            ('http://example.invalid/\nother', False),
            ('https://example.invalid/\rother', False),
        )
        for url, valid in cases:
            with self.subTest(url=url):
                result = subprocess.run(
                    [
                        'bash',
                        '-c',
                        'source "$1"\nvalidate_url "$2"',
                        'test',
                        str(ROOT / 'common.sh'),
                        url,
                    ],
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode == 0, valid)

    def test_http_install_requires_explicit_confirmation_and_updates_without_prompting(
        self,
    ):
        url = 'http://example.invalid/sub?token=secret'
        for answer in ('', '\n', 'n\n', 'yes\n'):
            with self.subTest(answer=answer):
                result = self.run_script('install.sh', url, '* * * * *', answer=answer)
                self.assertIn('HTTP is unencrypted', result.stdout)
                self.assertIn('cancelled', result.stdout)
                self.assertNotIn('token=secret', result.stdout + result.stderr)
                self.assertFalse(self.installation.exists())
                self.assertFalse((self.directory / 'service-calls').exists())
                self.assertFalse((self.directory / 'crontab').exists())
        self.run_script('install.sh', url, '* * * * *', answer='Y\n')
        self.assertEqual(
            (self.installation / 'subscription-url').read_text(), url + '\n'
        )
        self.assertTrue((self.directory / 'active').exists())
        self.configuration.write_text('mixed-port: 7891\n', encoding='utf-8')
        result = self.run_script('update.sh')
        self.assertNotIn('[y/N]', result.stdout)
        self.assertEqual(
            (self.installation / 'config.yaml').read_bytes(),
            self.configuration.read_bytes(),
        )

    def test_http_reinstall_refusal_preserves_existing_installation(self):
        self.install()
        paths = (
            self.installation / 'subscription-url',
            self.installation / 'config.yaml',
            self.directory / 'crontab',
            self.directory / 'service-calls',
        )
        original = [path.read_bytes() for path in paths]
        for answer in ('n\n', 'y\nn\n'):
            with self.subTest(answer=answer):
                result = self.run_script(
                    'install.sh', 'http://other.invalid/', '* * * * *', answer=answer
                )
                self.assertIn('cancelled', result.stdout)
                self.assertEqual([path.read_bytes() for path in paths], original)

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

    def test_shell_quote_round_trips_with_bash_32_compatibility(self):
        values = (
            '',
            'plain',
            'with spaces',
            "home with 'quotes%",
            "''",
            r"""$HOME `id` $(id) "quoted" \path & * ;""",
        )
        for value in values:
            with self.subTest(value=value):
                quoted = subprocess.run(
                    [
                        'bash',
                        '-c',
                        'source "$1"\nshell_quote "$2"',
                        'test',
                        str(ROOT / 'common.sh'),
                        value,
                    ],
                    env={**self.environment, 'BASH_COMPAT': '3.2'},
                    capture_output=True,
                    text=True,
                    check=True,
                )
                result = subprocess.run(
                    ['/bin/sh', '-c', 'printf "%s" ' + quoted.stdout],
                    env=self.environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, value)

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
        original_controller = (self.installation / 'controller.env').read_bytes()
        self.configuration.write_text('fail-start', encoding='utf-8')
        self.run_script(
            'install.sh',
            'https://other.invalid/',
            '* * * * *',
            '--controller-address',
            '127.0.0.1:9090',
            '--controller-secret',
            'd4' * 32,
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
        self.assertEqual(
            (self.installation / 'controller.env').read_bytes(), original_controller
        )
        self.assertTrue((self.directory / 'active').exists())

    def test_bundled_geodata_is_available_during_validation_and_is_rolled_back(self):
        filenames = ('Country.mmdb', 'GeoIP.dat', 'GeoSite.dat')
        for filename in filenames:
            (self.source / filename).write_text('original', encoding='utf-8')
        binary = self.source / 'mihomo'
        binary.write_text(
            f'#!{sys.executable}\nimport sys\nfrom pathlib import Path\n'
            'directory = Path(sys.argv[sys.argv.index("-d") + 1])\n'
            f'for filename in {filenames!r}:\n'
            '    assert (directory / filename).read_text() in ("original", "new")\n'
            'configuration = Path(sys.argv[sys.argv.index("-f") + 1])\n'
            'sys.exit(1 if "invalid" in configuration.read_text() else 0)\n',
            encoding='utf-8',
        )
        self.install()
        for filename in filenames:
            self.assertEqual((self.installation / filename).read_text(), 'original')
            (self.source / filename).write_text('new', encoding='utf-8')
        for bad_configuration in ('invalid', 'fail-start'):
            with self.subTest(configuration=bad_configuration):
                self.configuration.write_text(bad_configuration, encoding='utf-8')
                self.run_script(
                    'install.sh',
                    'https://other.invalid/',
                    '* * * * *',
                    answer='y\n',
                    succeeds=False,
                )
                for filename in filenames:
                    self.assertEqual(
                        (self.installation / filename).read_text(), 'original'
                    )
                self.assertTrue((self.directory / 'active').exists())
        self.configuration.write_text('mixed-port: 7890\n', encoding='utf-8')
        self.run_script(
            'install.sh', 'https://other.invalid/', '* * * * *', answer='y\n'
        )
        self.run_script('uninstall.sh')
        for filename in filenames:
            self.assertEqual((self.installation / filename).read_text(), 'new')

    def test_failed_initial_install_removes_bundled_geodata(self):
        for filename in ('Country.mmdb', 'GeoIP.dat', 'GeoSite.dat'):
            (self.source / filename).write_text('data', encoding='utf-8')
        self.configuration.write_text('invalid', encoding='utf-8')
        self.run_script(
            'install.sh', 'https://example.invalid/', '* * * * *', succeeds=False
        )
        for filename in ('Country.mmdb', 'GeoIP.dat', 'GeoSite.dat'):
            self.assertFalse((self.installation / filename).exists())

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
