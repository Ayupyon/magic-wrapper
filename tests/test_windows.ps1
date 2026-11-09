[CmdletBinding()]
param([switch]$Lifecycle)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$root/common.ps1"
$scriptFiles = @(
    'common.ps1', 'run.ps1', 'install.ps1', 'update.ps1', 'uninstall.ps1',
    'tests/test_windows.ps1'
)
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) {
        throw ($parseErrors | Out-String)
    }
}

$cases = Get-Content "$PSScriptRoot/cron_cases.json" -Raw | ConvertFrom-Json
foreach ($case in $cases) {
    $cron = $null
    try {
        $cron = ConvertFrom-CronExpression $case.expression
    } catch {
        if ($case.valid) {
            throw
        }
        continue
    }
    if (-not $case.valid) {
        throw "Invalid expression accepted: $($case.expression)"
    }
    foreach ($property in @('match', 'miss')) {
        if ($case.PSObject.Properties.Name -notcontains $property) {
            continue
        }
        foreach ($time in $case.$property) {
            $actual = Test-CronMatch $cron ([datetime]::Parse($time))
            if ($actual -ne ($property -eq 'match')) {
                throw "Incorrect cron match: $($case.expression), $time"
            }
        }
    }
}
Write-Output 'PowerShell parsing and cron checks passed.'

foreach ($url in @('http://example.invalid/', 'https://example.invalid/')) {
    Assert-SubscriptionUrl $url
}
foreach ($url in @('ftp://example.invalid/', 'file:///tmp/sub', 'example.invalid/sub',
    'http://', 'https://', "http://example.invalid/`nother", "https://example.invalid/`rother")) {
    $rejected = $false
    try {
        Assert-SubscriptionUrl $url
    } catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Invalid subscription URL accepted: $url"
    }
}

& {
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('magic prompt test-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporaryDirectory
    try {
        Copy-Item "$root/common.ps1", "$root/install.ps1" $temporaryDirectory
        $overrides = @'
function Get-MagicContext {
    param([switch]$System)
    [pscustomobject]@{ SettingsPath = Join-Path $PSScriptRoot 'settings.json' }
}
function Read-Host {
    param([string]$Prompt)
    if ($Prompt -ne 'Install using this HTTP subscription anyway? [y/N]') {
        throw "Unexpected prompt: $Prompt"
    }
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'answer'))
}
'@
        Add-Content -LiteralPath "$temporaryDirectory/common.ps1" -Value $overrides
        foreach ($answer in @('', 'n', 'yes', 'y', 'Y')) {
            [IO.File]::WriteAllText("$temporaryDirectory/answer", $answer)
            $output = $null
            $failure = $null
            try {
                $output = & "$temporaryDirectory/install.ps1" -SubscriptionUrl 'http://example.invalid/' -Schedule '* * * * *' 3>&1
            } catch {
                $failure = $_
            }
            if ($answer -cin @('y', 'Y')) {
                if (-not $failure -or $failure.Exception.Message -ne 'Place mihomo.exe beside install.ps1.') {
                    throw "HTTP consent did not reach the installer prerequisite check: $failure"
                }
            } elseif ($failure -or ($output | Out-String) -notmatch 'Installation cancelled\.') {
                throw "HTTP install proceeded without explicit consent: $answer, $failure"
            } elseif (($output | Out-String) -notmatch 'HTTP is unencrypted') {
                throw 'HTTP install did not warn about unencrypted transport.'
            }
        }
        if (Test-Path -LiteralPath "$temporaryDirectory/settings.json") {
            throw 'HTTP prompt checks changed installation settings.'
        }
        Write-Output 'PowerShell HTTP confirmation checks passed.'
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

& {
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('magic update test-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporaryDirectory
    try {
        Copy-Item "$root/common.ps1", "$root/update.ps1" $temporaryDirectory
        $overrides = @'
function Get-MagicContext {
    param([switch]$System)
    [pscustomobject]@{
        Directory = $PSScriptRoot
        SettingsPath = Join-Path $PSScriptRoot 'settings.json'
        System = [bool]$System
    }
}
function Save-Subscription {
    param([string]$Url, [string]$Destination)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'subscription.yaml') -Destination $Destination
}
function Assert-MagicConfiguration {
    param($Context, [string]$Binary, [string]$Configuration)
    if ([IO.File]::ReadAllText($Configuration).Contains('invalid')) {
        throw 'Invalid fixture configuration.'
    }
}
function Reload-MagicConfiguration {
    param($Context)
    $configuration = [IO.File]::ReadAllText((Join-Path $Context.Directory 'config.yaml'))
    Add-Content -LiteralPath (Join-Path $Context.Directory 'reload.log') -Value $configuration
    if ($configuration.Contains('fail-start')) {
        throw 'Fixture rejected the reload.'
    }
}
'@
        Add-Content -LiteralPath "$temporaryDirectory/common.ps1" -Value $overrides
        @{ SubscriptionUrl = 'http://example.invalid/'; Schedule = '* * * * *'; System = $false } |
            ConvertTo-Json | Set-Content "$temporaryDirectory/settings.json"
        @{ Address = '127.0.0.1:12345'; Secret = ('a' * 64) } |
            ConvertTo-Json | Set-Content "$temporaryDirectory/controller.json"
        $configuration = Join-Path $temporaryDirectory 'config.yaml'
        $subscription = Join-Path $temporaryDirectory 'subscription.yaml'
        $reloadLog = Join-Path $temporaryDirectory 'reload.log'
        $original = "mixed-port: 7890`n"
        [IO.File]::WriteAllText($configuration, $original)
        foreach ($badConfiguration in @('invalid', 'fail-start')) {
            [IO.File]::WriteAllText($subscription, $badConfiguration)
            $failure = $null
            try {
                & "$temporaryDirectory/update.ps1"
            } catch {
                $failure = $_
            }
            $expectedError = 'Invalid fixture configuration.'
            if ($badConfiguration -eq 'fail-start') {
                $expectedError = 'Mihomo reload failed; restored the previous configuration.'
            }
            if (-not $failure -or $failure.Exception.Message -ne $expectedError) {
                throw "Unexpected update result for '$badConfiguration': $failure"
            }
            if ([IO.File]::ReadAllText($configuration) -cne $original) {
                throw "Update did not preserve the original file for '$badConfiguration'."
            }
        }
        if ([IO.File]::ReadAllText("$temporaryDirectory/config.previous.yaml") -cne $original -or
            (Get-Content $reloadLog -Raw) -cne ("fail-start" + [Environment]::NewLine + $original + [Environment]::NewLine)) {
            throw 'Rollback did not preserve the backup and reload the restored configuration.'
        }
        [IO.File]::WriteAllText($subscription, "mixed-port: 7891`n")
        & "$temporaryDirectory/update.ps1"
        if ([IO.File]::ReadAllText($configuration) -cne [IO.File]::ReadAllText($subscription)) {
            throw 'Successful update did not activate the downloaded configuration.'
        }
        $reloads = [IO.File]::ReadAllText($reloadLog)
        & "$temporaryDirectory/update.ps1"
        if ([IO.File]::ReadAllText($reloadLog) -cne $reloads -or
            @(Get-ChildItem $temporaryDirectory -Filter '.update-*.yaml' -Force).Count -ne 0) {
            throw 'Unchanged update reloaded the configuration or left temporary files.'
        }
        Write-Output 'PowerShell update rollback checks passed.'
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
if (-not $Lifecycle) {
    return
}
if ($env:OS -ne 'Windows_NT') {
    throw 'Lifecycle checks require Windows.'
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('magic-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$env:MAGIC_TEST_DIRECTORY = Join-Path $env:ProgramFiles ('MagicWrapperTest-' + [Guid]::NewGuid().ToString('N'))
$env:MAGIC_TEST_SUBSCRIPTION = Join-Path $temporaryDirectory 'subscription.yaml'
$env:MAGIC_TEST_ANSWER = 'n'
foreach ($file in @('common.ps1', 'run.ps1', 'install.ps1', 'update.ps1', 'uninstall.ps1')) {
    Copy-Item (Join-Path $root $file) $temporaryDirectory
}
$overrides = @'
$script:RealGetMagicContext = ${function:Get-MagicContext}
function Get-MagicContext {
    param([switch]$System)
    $context = & $script:RealGetMagicContext -System:$System
    $context.Directory = $env:MAGIC_TEST_DIRECTORY
    $context.SettingsPath = Join-Path $context.Directory 'settings.json'
    $context
}
function Save-Subscription {
    param([string]$Url, [string]$Destination)
    Copy-Item -LiteralPath $env:MAGIC_TEST_SUBSCRIPTION -Destination $Destination
}
function Read-Host {
    param([string]$Prompt)
    $env:MAGIC_TEST_ANSWER
}
'@
Add-Content -LiteralPath "$temporaryDirectory/common.ps1" -Value $overrides
$source = @'
using System;
using System.IO;
using System.Net;
public class MihomoFixture {
    public static int Main(string[] arguments) {
        if (Array.IndexOf(arguments, "-t") >= 0) {
            string directory = arguments[Array.IndexOf(arguments, "-d") + 1];
            foreach (string filename in new[] { "Country.mmdb", "GeoIP.dat", "GeoSite.dat" }) {
                if (!File.Exists(Path.Combine(directory, filename))) {
                    return 1;
                }
            }
            int configurationIndex = Array.IndexOf(arguments, "-f");
            return File.ReadAllText(arguments[configurationIndex + 1]).Contains("invalid") ? 1 : 0;
        }
        string configuration = arguments[Array.IndexOf(arguments, "-f") + 1];
        if (File.ReadAllText(configuration).Contains("fail-start")) {
            return 1;
        }
        HttpListener listener = new HttpListener();
        listener.Prefixes.Add(
            "http://" + Environment.GetEnvironmentVariable("CLASH_OVERRIDE_EXTERNAL_CONTROLLER") + "/");
        listener.Start();
        while (true) {
            HttpListenerContext request = listener.GetContext();
            request.Request.InputStream.CopyTo(Stream.Null);
            bool authenticated = request.Request.Headers["Authorization"] ==
                "Bearer " + Environment.GetEnvironmentVariable("CLASH_OVERRIDE_SECRET");
            bool reload = request.Request.HttpMethod == "PUT" &&
                request.Request.RawUrl == "/configs?force=true";
            if (!authenticated) {
                request.Response.StatusCode = 401;
            } else if (!reload) {
                request.Response.StatusCode = 404;
            } else if (File.ReadAllText(configuration).Contains("fail-start")) {
                request.Response.StatusCode = 400;
            } else {
                request.Response.StatusCode = 204;
            }
            request.Response.Close();
        }
    }
}
'@
try {
    $geodataFiles = @('Country.mmdb', 'GeoIP.dat', 'GeoSite.dat')
    foreach ($filename in $geodataFiles) {
        [IO.File]::WriteAllText((Join-Path $temporaryDirectory $filename), 'original')
    }
    Add-Type -TypeDefinition $source -OutputAssembly "$temporaryDirectory/mihomo.exe" -OutputType ConsoleApplication
    $upstream = Invoke-RestMethod 'https://api.github.com/repos/winsw/winsw/releases/latest'
    $asset = @($upstream.assets | Where-Object { $_.name -eq 'WinSW-x64.exe' })
    if ($asset.Count -ne 1) {
        throw 'Missing WinSW x64 asset.'
    }
    Invoke-WebRequest -UseBasicParsing $asset[0].browser_download_url -OutFile "$temporaryDirectory/winsw.exe"
    Set-Content $env:MAGIC_TEST_SUBSCRIPTION 'mixed-port: 7890'
    & "$temporaryDirectory/install.ps1" -System -SubscriptionUrl 'https://example.invalid/first' -Schedule '0 */6 * * *'
    $configuration = Join-Path $env:MAGIC_TEST_DIRECTORY 'config.yaml'
    $original = [IO.File]::ReadAllText($configuration)
    $processIdBeforeUpdate = (Get-CimInstance Win32_Service -Filter "Name='MagicWrapper'").ProcessId
    & "$temporaryDirectory/install.ps1" -System -SubscriptionUrl 'https://example.invalid/second' -Schedule '* * * * *'
    $settings = Get-Content (Join-Path $env:MAGIC_TEST_DIRECTORY 'settings.json') -Raw | ConvertFrom-Json
    if ($settings.SubscriptionUrl -ne 'https://example.invalid/first') {
        throw 'Reinstall refusal changed settings.'
    }
    foreach ($badConfiguration in @('invalid', 'fail-start')) {
        Set-Content $env:MAGIC_TEST_SUBSCRIPTION $badConfiguration
        $failure = $null
        try {
            & "$temporaryDirectory/update.ps1" -System
        } catch {
            $failure = $_
        }
        if (-not $failure -or [IO.File]::ReadAllText($configuration) -ne $original) {
            throw "Update rollback failed for '$badConfiguration': $failure"
        }
    }
    Set-Content $env:MAGIC_TEST_SUBSCRIPTION 'mixed-port: 7891'
    & "$temporaryDirectory/update.ps1" -System
    if ([IO.File]::ReadAllText($configuration) -eq $original) {
        throw 'Update did not change configuration.'
    }
    if ((Get-CimInstance Win32_Service -Filter "Name='MagicWrapper'").ProcessId -ne $processIdBeforeUpdate) {
        throw 'Configuration update restarted the service.'
    }
    $env:MAGIC_TEST_ANSWER = 'y'
    foreach ($filename in $geodataFiles) {
        if ([IO.File]::ReadAllText((Join-Path $env:MAGIC_TEST_DIRECTORY $filename)) -cne 'original') {
            throw "Bundled database was not installed: $filename"
        }
        [IO.File]::WriteAllText((Join-Path $temporaryDirectory $filename), 'new')
    }
    foreach ($badConfiguration in @('invalid', 'fail-start')) {
        Set-Content $env:MAGIC_TEST_SUBSCRIPTION $badConfiguration
        $failure = $null
        try {
            & "$temporaryDirectory/install.ps1" -System -SubscriptionUrl 'https://example.invalid/second' -Schedule '* * * * *'
        } catch {
            $failure = $_
        }
        if (-not $failure) {
            throw "Reinstall unexpectedly succeeded for '$badConfiguration'."
        }
        foreach ($filename in $geodataFiles) {
            if ([IO.File]::ReadAllText((Join-Path $env:MAGIC_TEST_DIRECTORY $filename)) -cne 'original') {
                throw "Reinstall did not restore database: $filename"
            }
        }
        if ((Get-Service -Name 'MagicWrapper').Status -ne 'Running') {
            throw 'Failed reinstall did not restore the previous service.'
        }
    }
    Set-Content $env:MAGIC_TEST_SUBSCRIPTION 'mixed-port: 7891'
    & "$temporaryDirectory/install.ps1" -System -SubscriptionUrl 'http://example.invalid/second' -Schedule '* * * * *'
    $settings = Get-Content (Join-Path $env:MAGIC_TEST_DIRECTORY 'settings.json') -Raw | ConvertFrom-Json
    if ($settings.SubscriptionUrl -ne 'http://example.invalid/second') {
        throw 'HTTP reinstall did not save the subscription URL.'
    }
    & "$temporaryDirectory/update.ps1" -System
    & "$temporaryDirectory/uninstall.ps1" -System
    & "$temporaryDirectory/uninstall.ps1" -System
    if (Get-Service MagicWrapper -ErrorAction SilentlyContinue) {
        throw 'Service was not removed.'
    }
    if (Get-MagicTask 'MagicWrapper-Update') {
        throw 'Update task was not removed.'
    }
    if (-not (Test-Path $configuration)) {
        throw 'Uninstall removed configuration.'
    }
    foreach ($filename in $geodataFiles) {
        if ([IO.File]::ReadAllText((Join-Path $env:MAGIC_TEST_DIRECTORY $filename)) -cne 'new') {
            throw "Reinstall or uninstall did not preserve the new database: $filename"
        }
    }
    Write-Output 'Windows WinSW lifecycle checks passed.'
} finally {
    if (Test-Path "$env:MAGIC_TEST_DIRECTORY/common.ps1") {
        . "$env:MAGIC_TEST_DIRECTORY/common.ps1"
        try {
            Remove-MagicTasks (Get-MagicContext -System)
        } catch {
            Write-Warning $_
        }
    }
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    if (Test-Path -LiteralPath $env:MAGIC_TEST_DIRECTORY) {
        Remove-Item -LiteralPath $env:MAGIC_TEST_DIRECTORY -Recurse -Force
    }
}
