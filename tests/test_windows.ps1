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
        $failed = $false
        try {
            & "$temporaryDirectory/update.ps1" -System
        } catch {
            $failed = $true
        }
        if (-not $failed -or [IO.File]::ReadAllText($configuration) -ne $original) {
            throw 'Update rollback failed.'
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
    & "$temporaryDirectory/install.ps1" -System -SubscriptionUrl 'https://example.invalid/second' -Schedule '* * * * *'
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
