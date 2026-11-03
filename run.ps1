$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$controller = Get-MagicController $PSScriptRoot
$env:CLASH_OVERRIDE_EXTERNAL_CONTROLLER = $controller.Address
$env:CLASH_OVERRIDE_SECRET = $controller.Secret

& "$PSScriptRoot\mihomo.exe" -d $PSScriptRoot -f "$PSScriptRoot\config.yaml"
exit $LASTEXITCODE
