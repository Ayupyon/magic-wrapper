[CmdletBinding()]
param([switch]$System)

. "$PSScriptRoot\common.ps1"
$context = Get-MagicContext -System:$System
if (-not (Test-Path -LiteralPath $context.SettingsPath)) {
    Write-Output 'No wrapper installation found for this scope.'
    return
}
$settings = Get-MagicSettings $context
if ($settings.PSObject.Properties.Name -contains 'Uninstalled' -and $settings.Uninstalled) {
    Write-Output 'The wrapper is already uninstalled.'
    return
}
$lock = Enter-MagicLock $context
try {
    Remove-MagicTasks $context
    $settings | Add-Member -NotePropertyName Uninstalled -NotePropertyValue $true -Force
    $settings | ConvertTo-Json | Set-Content -LiteralPath $context.SettingsPath -Encoding UTF8
    Write-Output "Removed the service and update task. Files are preserved in $($context.Directory)"
} finally {
    $lock.Dispose()
}
