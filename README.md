# Magic wrapper

Magic wrapper installs Mihomo as a background service and keeps its configuration
up to date from an HTTP or HTTPS subscription URL. Linux and macOS use Bash and
native cron. Windows uses Windows PowerShell 5.1, Task Scheduler, and WinSW for
system services. Installed machines do not need Python.

The subscription must return a **complete Mihomo YAML configuration**. Proxy lists
and base64 subscriptions need conversion before use. The wrapper manages the
service and configuration; system proxy settings and TUN permissions remain the
operator's responsibility. Configurations using privileged ports or TUN generally
require a system installation.

## Requirements

Extract the package for your platform and keep its scripts together with the
Mihomo executable and bundled `Country.mmdb`, `GeoIP.dat`, and `GeoSite.dat`
databases. Windows packages also include the self-contained WinSW x64 executable
needed for system services.

| Platform | Required tools and services |
| --- | --- |
| Linux | systemd, Bash, curl, and an installed, running cron daemon with `crontab` |
| macOS | Bash, curl, crontab, and launchd |
| Windows | Windows 10 / Server 2016 or newer, Windows PowerShell 5.1, and Task Scheduler |

## Installation

Run these commands from the extracted package directory. Replace the example URL
with your subscription URL. The example schedule updates every six hours.

HTTPS is recommended. For an `http://` subscription URL, the installer warns that
tokens and configuration can be read or modified in transit and requires `y` or
`Y` to continue. Pressing Enter or providing no input cancels before downloading
or changing the installation. Reinstalling with HTTP requires confirmation again;
configuration updates use the saved URL without prompting.

### Linux and macOS

For the current user:

```sh
chmod +x mihomo
bash install.sh 'https://provider.example/subscription?token=YOUR_TOKEN' '0 */6 * * *'
```

For a system service:

```sh
chmod +x mihomo
sudo bash install.sh 'https://provider.example/subscription?token=YOUR_TOKEN' '0 */6 * * *'
```

### Windows

For the current user, from Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -SubscriptionUrl 'https://provider.example/subscription?token=YOUR_TOKEN' -Schedule '0 */6 * * *'
```

For a system service, from an **Administrator** PowerShell window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -System -SubscriptionUrl 'https://provider.example/subscription?token=YOUR_TOKEN' -Schedule '0 */6 * * *'
```

### Controller arguments

Both installers accept optional controller settings:

```sh
bash install.sh 'https://provider.example/subscription?token=YOUR_TOKEN' '0 */6 * * *' \
  --controller-address '0.0.0.0:9090' \
  --controller-secret "$CONTROLLER_SECRET"
```

```powershell
.\install.ps1 -SubscriptionUrl 'https://provider.example/subscription?token=YOUR_TOKEN' `
  -Schedule '0 */6 * * *' `
  -ControllerAddress '0.0.0.0:9090' `
  -ControllerSecret $ControllerSecret
```

Set the secret variable to your chosen value before running these examples. The
address must be an IPv4 literal followed by a port from 1024 to 65535, without a
URL scheme or path. Each IPv4 octet must be from 0 to 255 without leading zeros;
hostnames and IPv6 are not supported. Use `127.0.0.1:9090` for local access,
`192.168.1.10:9090` to bind to that address on the Mihomo machine, or
`0.0.0.0:9090` to listen on all IPv4 interfaces. The default remains localhost.
The secret must contain exactly 64 lowercase hexadecimal characters (`0-9`,
`a-f`). Invalid values are rejected before downloads or installation changes.
Unix options follow the subscription URL and schedule.

Each setting is independent: an explicit argument replaces that setting; an
omitted argument preserves its saved value, or generates one if none exists.
Reinstallation uses the existing confirmation prompt, restarts Mihomo, and
regenerates service settings, including Windows `winsw.xml`. A failed installation
attempts to restore the previous credentials and service settings. Subscription
updates preserve controller settings.

Connect MetaCubeXD using the saved secret and the Mihomo machine's reachable
address, for example `http://192.168.1.10:9090` for a dashboard on another machine.
`0.0.0.0` is a listening wildcard; use the machine's LAN IP in the dashboard. A
localhost controller can also be reached through SSH port forwarding.

The controller is shared with automatic updates. Reload requests use the saved
address directly, except that `0.0.0.0:PORT` is reached through
`http://127.0.0.1:PORT`. Fixed addresses must be available on the Mihomo machine;
startup or controller verification failure triggers an installation rollback
attempt.

Installer arguments can appear in shell history and process listings, even when
the secret is passed through a variable. The wrapper keeps the secret out of
generated scheduled commands and Mihomo command arguments.

### Installation scope and files

| Platform | User installation | System installation |
| --- | --- | --- |
| Linux | `~/.local/share/magic-wrapper` | `/var/lib/magic-wrapper` |
| macOS | `~/Library/Application Support/magic-wrapper` | `/Library/PrivilegedHelperTools/magic-wrapper` |
| Windows | `%LOCALAPPDATA%\MagicWrapper` | `%ProgramFiles%\MagicWrapper` |

User installations run as the current user. Windows user mode uses a login task
because registering a WinSW service requires Administrator privileges. Windows
system services run as LocalSystem; Linux system services and macOS LaunchDaemons
run as root. Use one installation per machine unless the configurations use
different listening ports.

User mode on macOS and Windows runs while the user is logged in. Linux user
services normally follow the user session. To start at boot and survive logout,
an administrator can enable lingering for the intended account:

```sh
sudo loginctl enable-linger YOUR_USERNAME
```

Installation downloads the initial configuration, copies the executable, scripts,
and bundled databases into the selected location, validates the configuration,
registers the service and update schedule, and starts Mihomo. Success requires
both a process startup check and a controller reload check. The extracted package
directory can then be removed.

The bundled databases support both GeoIP modes and GEOSITE rules without an
initial geodata download. Reinstallation replaces bundled databases and restores
the previous files if installation fails. Manually assembled installations can
omit these files and let Mihomo download missing databases. ASN data and external
rule providers are not bundled. Packages contain a data snapshot; subscription
updates do not replace it. Use Mihomo's `geo-auto-update: true` setting to keep
installed databases current, or reinstall from a newer package.

Reinstallation asks before replacing settings; pressing Enter or providing no
input cancels. It stops and starts the service to replace executables and service
definitions. A failed reinstall attempts to restore the previous files, service,
and schedule, including installations without controller settings. An installation
without controller settings requires reinstallation before configuration updates
can run.

Installation directories protect settings and configurations for the installing
user or administrators/System. Subscription URLs are stored in settings and kept
out of service definitions and scheduled commands. URLs supplied as arguments
can remain in shell history.

## Schedules

The schedule uses five numeric fields:

```text
minute hour day-of-month month weekday
```

Supported syntax includes `*`, comma-separated lists, inclusive ranges, and
positive steps on `*` or a range. Sunday is `0` or `7`. Numeric values have at most
two digits; steps have at most nine digits. Names, macros, seconds, and Quartz
extensions are rejected to keep schedule parsing consistent across platforms.

| Expression | Update time |
| --- | --- |
| `0 */6 * * *` | Every six hours |
| `30 3 * * 1-5` | At 03:30 on weekdays |

When both day-of-month and weekday are restricted, either can match, following
traditional cron semantics. All schedules use the machine's local time.

Unix installs one marked entry in the current user's crontab, or root's crontab
when installed with sudo. Unrelated entries are preserved. Windows runs a check
every minute and updates when the expression matches. Missed executions while
asleep or logged out are not replayed. Daylight-saving transitions follow the
underlying scheduler's behavior.

## Configuration updates and design

An update holds the installation lock throughout validation, file replacement,
reload, and rollback:

1. Download the subscription to a temporary file and validate it with `mihomo -t`.
2. Skip unchanged content without issuing a reload request.
3. Save the previous configuration and atomically replace `config.yaml`.
4. Reload Mihomo through its authenticated controller.
5. If reload fails or times out, restore the previous file and attempt another
   reload. If that request also fails, report that runtime state needs manual
   recovery; the previous file remains on disk.

Download or validation failures leave the active configuration unchanged.
Configuration updates keep the process running and do not fall back to a restart.
Subscription downloads during installation and updates send `User-Agent: clash.meta`,
bypass proxy settings, and connect directly to the subscription server, including
after redirects. Redirect following is delegated to curl or .NET.

### Reload protocol and guarantees

Updates and rollback both send `PUT /configs?force=true` with the JSON body
`{"path":""}`. The empty path reloads the configuration selected at startup, and
only HTTP 204 counts as success. The API provides a synchronous acknowledgement
across all supported platforms; Unix signals do not provide a synchronous reload
result. The force parameter allows listener configuration changes to take effect.

API success acknowledges configuration application. It does not verify proxy
connectivity or every listener's health. Listener, DNS, or TUN changes can affect
connections even while the process stays alive.

The upstream implementation is documented by Mihomo's
[reload handler](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/hub/route/configs.go)
and [environment overrides](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/main.go).

### Controller credentials and security

The installer creates an installation-specific controller, defaulting to
`127.0.0.1` unless an address is supplied or already saved. When not supplied or
already saved, it generates a random 256-bit authentication secret and selects a
port in 49152–65535 on Unix or an available ephemeral port on Windows. Port
selection does not reserve the port until startup. A collision causes the
installation's controller check to fail and triggers a rollback attempt.

LAN and wildcard listening addresses require the same authentication secret as
localhost. HTTP controller traffic, including the secret, is unencrypted. Limit
network access to trusted clients with your firewall, and use SSH forwarding or
another encrypted transport across untrusted networks. The wrapper does not
configure firewall rules or TLS.

Credentials persist in `controller.env` on Unix and `controller.json` on Windows.
Reinstalls preserve them unless controller arguments override them. These files
inherit the installation's access restrictions; access to them grants controller
API access.

Mihomo receives `CLASH_OVERRIDE_EXTERNAL_CONTROLLER` and `CLASH_OVERRIDE_SECRET`
through its environment. These override the subscription's HTTP controller and
secret while preserving the downloaded YAML. Other subscription settings remain
in effect. Unix services use `run.sh`; Windows login tasks use `run.ps1`; WinSW
supplies the environment directly. Credentials stay out of process command lines.
Local API requests bypass HTTP proxies, refuse redirects, and use bounded
timeouts.

### Manual updates

Run the command for the installation's scope from the extracted or installed
scripts:

```sh
bash update.sh
# For a system installation:
sudo bash update.sh
```

```powershell
.\update.ps1
# From Administrator PowerShell for a system installation:
.\update.ps1 -System
```

Manual updates run regardless of the current schedule match. Windows scheduled
checks additionally pass `-Scheduled`.

## Logs and recovery

| Output | Location |
| --- | --- |
| Unix scheduled updates | `update.log` in the installation directory |
| Configuration validation | `validation.log` in the installation directory on every platform |
| Linux service | `journalctl --user -u magic-wrapper.service`; omit `--user` for system mode |
| macOS service | `mihomo.log` in the installation directory |
| Windows system service | WinSW rolling logs beside its executable |
| Windows user-mode update failures | Task Scheduler's last-run result |

Unix logs are ordinary files; manage their retention as needed.

A Unix process killed with SIGKILL or a power loss can leave the `.lock` directory
behind. Check its `pid` file and confirm that no wrapper operation is running
before removing it. Windows locks are released when the process exits. After a
power loss during installation, inspect any retained `.install.*` or `.install-*`
backup directory before reinstalling.

## Uninstallation

Use the same scope as installation:

```sh
bash uninstall.sh
# For a system installation:
sudo bash uninstall.sh
```

```powershell
.\uninstall.ps1
# From Administrator PowerShell for a system installation:
.\uninstall.ps1 -System
```

Uninstallation stops and removes the wrapper's service or login task and update
schedule. It preserves executables, scripts, settings, and configurations. Delete
the installation directory separately when those files are no longer needed.
Repeating uninstall is safe. Lingering remains enabled if configured separately,
because other user services may depend on it.

## Release packaging

The `Nightly packages` workflow checks daily at 19:00 UTC (03:00 UTC+8, Asia/Shanghai),
on relevant pushes to the default branch, and through manual dispatch. Enable
Actions and push the project files to the default branch to activate the
workflows. Packaging uses the latest stable releases of `MetaCubeX/mihomo` and
`winsw/winsw`, excluding upstream prereleases.
Geographic databases come from the rolling `latest` release of
`MetaCubeX/meta-rules-dat`.

The workflow compares upstream release IDs and tags and a digest of package
inputs with `manifest.json` attached to the rolling `nightly` prerelease. It also
compares the selected geodata assets' IDs, update times, sizes, and available
digests, so updates to the same upstream release tag trigger a rebuild.
Unchanged checks download no binaries and publish nothing. An upstream release,
geodata update, wrapper change, missing or incomplete release, or manual `force`
input rebuilds all four packages:

| Archive | Binary target |
| --- | --- |
| `magic-linux-x86_64.zip` | Linux amd64-v1 baseline |
| `magic-linux-arm64.zip` | Linux arm64 |
| `magic-windows-x86_64.zip` | Windows amd64-v1 baseline and self-contained WinSW x64 |
| `magic-macos-arm64.zip` | macOS arm64 |

Each archive contains a single top-level folder matching its filename without
`.zip` (for example, `magic-linux-x86_64/`). Run installation commands from that
folder. It contains platform scripts, the three databases, this README, upstream
licenses, and `versions.json` with source references. Release assets also include
`SHA256SUMS` and a manifest recording binary and geodata hashes and the wrapper
commit. Downloads use HTTPS and verify upstream digests when provided; some WinSW
releases provide no digest. Asset names must match the expected architecture and
CPU baseline; a naming change fails packaging rather than selecting another target.

All packages are built and their archives tested before upload. The manifest
uploads last so an incomplete publication is retried on the next run. GitHub
replaces release assets individually, so avoid downloads during publication and
verify archives against `SHA256SUMS`. The initial release remains a draft until
upload completes. The rolling tag identifies the initial publication;
`wrapper_commit` in the manifest and each archive records the exact source
revision for the current packages.

Publishing uses the repository's built-in token with `contents: write`. A separate
keepalive job uses `actions: write` to call the enable-workflow API on scheduled
runs, including when packaging is skipped. This is a best-effort workaround for
GitHub's scheduled-workflow inactivity cutoff. If the workflow is disabled,
enable it in Actions or run:

```sh
gh workflow enable nightly.yml --repo OWNER/REPO
```

Packaging requires Python 3.10+ and GitHub CLI; the workflow supplies these tools.
ZIP archives are created and validated with Python's standard library. Local tests
do not publish releases.

## Development checks

```sh
bash -n common.sh run.sh install.sh update.sh uninstall.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

```powershell
.\tests\test_windows.ps1
```

The `Checks` workflow runs on Linux, macOS, and Windows. Unix lifecycle tests use
isolated service, cron, and download fixtures without changing host registrations.
PowerShell checks cover parsing, URL validation, HTTP installation confirmation,
cron matching, and offline update rollback.
A Windows-only lifecycle test downloads WinSW and exercises an actual system
service using a fixture executable. Run it from Windows PowerShell as Administrator:

```powershell
.\tests\test_windows.ps1 -Lifecycle
```

The lifecycle test requires no existing `MagicWrapper` service and cleans up its
test service, tasks, and temporary installation. Real subscription endpoints,
proxy connectivity, macOS launchd integration, and logged-in Windows user tasks
require checks on the corresponding machines.
