[CmdletBinding()]
param(
    [switch]$System,
    [switch]$Scheduled
)

. "$PSScriptRoot\common.ps1"
$context = Get-MagicContext -System:$System
if (-not (Test-Path -LiteralPath $context.SettingsPath)) {
    throw 'No wrapper installation found for this scope.'
}
$settings = Get-MagicSettings $context
Assert-SubscriptionUrl $settings.SubscriptionUrl
$cron = ConvertFrom-CronExpression $settings.Schedule
if ($settings.PSObject.Properties.Name -contains 'Uninstalled' -and $settings.Uninstalled) {
    throw 'This wrapper installation has been uninstalled.'
}
if ($Scheduled -and -not (Test-CronMatch $cron)) {
    return
}

$lock = Enter-MagicLock $context
$temporaryConfiguration = Join-Path $context.Directory ('.update-' + [Guid]::NewGuid().ToString('N') + '.yaml')
$activeConfiguration = Join-Path $context.Directory 'config.yaml'
$previousConfiguration = Join-Path $context.Directory 'config.previous.yaml'
try {
    $null = Get-MagicController $context.Directory
    Save-Subscription $settings.SubscriptionUrl $temporaryConfiguration
    Assert-MagicConfiguration $context (Join-Path $context.Directory 'mihomo.exe') $temporaryConfiguration
    $downloadedHash = (Get-FileHash -LiteralPath $temporaryConfiguration).Hash
    $activeHash = (Get-FileHash -LiteralPath $activeConfiguration).Hash
    if ($downloadedHash -eq $activeHash) {
        Write-Output 'Configuration unchanged.'
        return
    }
    [IO.File]::Replace($temporaryConfiguration, $activeConfiguration, $previousConfiguration)
    try {
        Reload-MagicConfiguration $context
    } catch {
        Copy-Item -LiteralPath $previousConfiguration -Destination $temporaryConfiguration -Force
        [IO.File]::Replace($temporaryConfiguration, $activeConfiguration, [NullString]::Value)
        try {
            Reload-MagicConfiguration $context
        } catch {
            Write-Warning 'The previous file was restored, but its reload failed; manual recovery is required.'
        }
        throw 'Mihomo reload failed; restored the previous configuration.'
    }
    Write-Output 'Configuration updated and Mihomo reloaded.'
} finally {
    try {
        if (Test-Path -LiteralPath $temporaryConfiguration) {
            Remove-Item -LiteralPath $temporaryConfiguration -Force
        }
    } finally {
        $lock.Dispose()
    }
}
