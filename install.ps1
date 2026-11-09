[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionUrl,
    [Parameter(Mandatory = $true)][string]$Schedule,
    [switch]$System,
    [string]$ControllerAddress,
    [string]$ControllerSecret
)

. "$PSScriptRoot\common.ps1"
$controllerArguments = @{}
if ($PSBoundParameters.ContainsKey('ControllerAddress')) {
    Assert-MagicControllerAddress $ControllerAddress
    $controllerArguments.Address = $ControllerAddress
}
if ($PSBoundParameters.ContainsKey('ControllerSecret')) {
    Assert-MagicControllerSecret $ControllerSecret
    $controllerArguments.Secret = $ControllerSecret
}
$context = Get-MagicContext -System:$System

Assert-SubscriptionUrl $SubscriptionUrl
$null = ConvertFrom-CronExpression $Schedule
if (([Uri]$SubscriptionUrl).Scheme -eq 'http') {
    Write-Warning 'HTTP is unencrypted. Subscription tokens and configuration can be read or modified in transit.'
    if ((Read-Host 'Install using this HTTP subscription anyway? [y/N]') -cnotin @('y', 'Y')) {
        Write-Output 'Installation cancelled.'
        return
    }
}
if (-not (Test-Path -LiteralPath "$PSScriptRoot\mihomo.exe" -PathType Leaf)) {
    throw 'Place mihomo.exe beside install.ps1.'
}
if ($System -and -not (Test-Path -LiteralPath "$PSScriptRoot\winsw.exe" -PathType Leaf)) {
    throw 'Place winsw.exe beside install.ps1.'
}
$previousSettings = $null
$previousInstallation = $false
if (Test-Path -LiteralPath $context.SettingsPath) {
    if ((Read-Host 'Replace existing installation settings? [y/N]') -cnotin @('y', 'Y')) {
        Write-Output 'Installation cancelled.'
        return
    }
    $previousSettings = Get-MagicSettings $context
    $previousInstallation = -not (
        $previousSettings.PSObject.Properties.Name -contains 'Uninstalled' -and $previousSettings.Uninstalled
    )
}
if (-not $previousInstallation -and ((Get-MagicTask $context.UpdateTaskName) -or (Get-MagicTask $context.TaskName) -or
    ($System -and (Get-Service -Name 'MagicWrapper' -ErrorAction SilentlyContinue)))) {
    throw 'A service/task with the wrapper name already exists without wrapper settings; refusing to overwrite it.'
}
Protect-MagicDirectory $context
$lock = Enter-MagicLock $context
$temporaryDirectory = Join-Path $context.Directory ('.install-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$managedFiles = @(
    'common.ps1', 'run.ps1', 'install.ps1', 'update.ps1', 'uninstall.ps1', 'mihomo.exe',
    'settings.json', 'config.yaml', 'controller.json'
)
foreach ($filename in @('Country.mmdb', 'GeoIP.dat', 'GeoSite.dat')) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot $filename) -PathType Leaf) {
        $managedFiles += $filename
    }
}
if ($System) {
    $managedFiles += @('winsw.exe', 'winsw.xml')
}
$installationChanged = $false
$preserveBackup = $false
try {
    $configuration = Join-Path $temporaryDirectory 'config.yaml'
    Save-Subscription $SubscriptionUrl $configuration
    $backupDirectory = Join-Path $temporaryDirectory 'previous'
    $null = New-Item -ItemType Directory -Path $backupDirectory
    foreach ($filename in $managedFiles) {
        $path = Join-Path $context.Directory $filename
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Managed files cannot be symbolic links.'
            }
            Copy-Item -LiteralPath $path -Destination $backupDirectory
        }
    }
    $installationChanged = $true
    if ($previousInstallation) {
        Stop-MagicService $context
    }
    $settings = [pscustomobject]@{
        SubscriptionUrl = $SubscriptionUrl
        Schedule = $Schedule
        System = [bool]$System
    }
    foreach ($filename in $managedFiles) {
        if ($filename -in @('settings.json', 'config.yaml', 'winsw.xml', 'controller.json')) {
            continue
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $filename) `
            -Destination (Join-Path $temporaryDirectory $filename)
        Copy-Item -LiteralPath (Join-Path $temporaryDirectory $filename) `
            -Destination (Join-Path $context.Directory $filename) -Force
    }
    Assert-MagicConfiguration $context (Join-Path $context.Directory 'mihomo.exe') $configuration
    $settings | ConvertTo-Json | Set-Content -LiteralPath $context.SettingsPath -Encoding UTF8
    Copy-Item -LiteralPath $configuration -Destination (Join-Path $context.Directory 'config.yaml') -Force
    Initialize-MagicController $context @controllerArguments
    Register-MagicTasks $context
    Restart-MagicService $context
    Reload-MagicConfiguration $context
    Write-Output "Installed Mihomo in $($context.Directory)"
} catch {
    $failure = $_
    if ($installationChanged) {
        Write-Warning 'Installation failed; restoring the previous installation.'
        try {
            Remove-MagicTasks $context
            foreach ($filename in $managedFiles) {
                $path = Join-Path $context.Directory $filename
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force
                }
                $backup = Join-Path $backupDirectory $filename
                if (Test-Path -LiteralPath $backup) {
                    Copy-Item -LiteralPath $backup -Destination $path
                }
            }
            if ($previousInstallation) {
                Register-MagicTasks $context
                Restart-MagicService $context
            }
        } catch {
            $preserveBackup = $true
            Write-Warning "Manual recovery is required: $_"
        }
    }
    throw $failure
} finally {
    try {
        if ($preserveBackup) {
            Write-Warning "Previous files are preserved in $temporaryDirectory\previous"
        } else {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    } finally {
        $lock.Dispose()
    }
}
