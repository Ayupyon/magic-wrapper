Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MagicController {
    param([string]$Directory)
    $controllerPath = Join-Path $Directory 'controller.json'
    if (-not (Test-Path -LiteralPath $controllerPath)) {
        throw 'Reinstall the wrapper to enable configuration reload.'
    }
    $controller = Get-Content -LiteralPath $controllerPath -Raw | ConvertFrom-Json
    if ($controller.Address -notmatch '^127\.0\.0\.1:([0-9]{4,5})$' -or
        [int]$Matches[1] -lt 1024 -or [int]$Matches[1] -gt 65535 -or
        $controller.Secret -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Invalid controller settings.'
    }
    $controller
}

function Initialize-MagicController {
    param($Context)
    $controllerPath = Join-Path $Context.Directory 'controller.json'
    if (-not (Test-Path -LiteralPath $controllerPath)) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
        } finally {
            $listener.Stop()
        }
        $secretBytes = [byte[]]::new(32)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $random.GetBytes($secretBytes)
        } finally {
            $random.Dispose()
        }
        @{
            Address = "127.0.0.1:$port"
            Secret = [BitConverter]::ToString($secretBytes).Replace('-', '').ToLowerInvariant()
        } | ConvertTo-Json | Set-Content -LiteralPath $controllerPath -Encoding UTF8
    }
    $null = Get-MagicController $Context.Directory
}

function Reload-MagicConfiguration {
    param($Context)
    $controller = Get-MagicController $Context.Directory
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $content = [Net.Http.StringContent]::new('{"path":""}', [Text.Encoding]::UTF8, 'application/json')
    try {
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer', $controller.Secret)
        $response = $client.PutAsync(
            "http://$($controller.Address)/configs?force=true", $content).GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -ne 204) {
                throw 'Mihomo rejected the configuration reload.'
            }
        } finally {
            $response.Dispose()
        }
    } finally {
        $content.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-MagicContext {
    param([switch]$System)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdministrator = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($System -and -not $isAdministrator) {
        throw 'Run PowerShell as Administrator to use -System.'
    }
    $directory = Join-Path $env:LOCALAPPDATA 'MagicWrapper'
    $taskName = "MagicWrapper-$($identity.User.Value)"
    if ($System) {
        $directory = Join-Path $env:ProgramFiles 'MagicWrapper'
        $taskName = 'MagicWrapper'
    }
    [pscustomobject]@{
        Directory = $directory
        System = [bool]$System
        TaskName = $taskName
        UpdateTaskName = "$taskName-Update"
        Account = $identity.Name
        SettingsPath = Join-Path $directory 'settings.json'
    }
}

function Protect-MagicDirectory {
    param($Context)
    if (Test-Path -LiteralPath $Context.Directory) {
        if ((Get-Item -LiteralPath $Context.Directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The installation directory cannot be a symbolic link or junction.'
        }
    } else {
        $null = New-Item -ItemType Directory -Path $Context.Directory
    }
    $permissions = [Security.AccessControl.DirectorySecurity]::new()
    $permissions.SetAccessRuleProtection($true, $false)
    $identifiers = @('S-1-5-18', 'S-1-5-32-544')
    if (-not $Context.System) {
        $identifiers += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    foreach ($identifier in $identifiers) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($identifier), 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $permissions.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Context.Directory -AclObject $permissions
}

function Get-MagicSettings {
    param($Context)
    $settings = Get-Content -LiteralPath $Context.SettingsPath -Raw | ConvertFrom-Json
    if ([bool]$settings.System -ne $Context.System) {
        throw 'Installation scope does not match the settings.'
    }
    $settings
}

function Assert-SubscriptionUrl {
    param([string]$Url)
    $address = $null
    if ($Url -match '[\r\n]' -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$address) -or
        $address.Scheme -ne 'https' -or -not $address.Host) {
        throw 'The subscription URL must be an absolute HTTPS URL without newlines.'
    }
}

function ConvertFrom-CronExpression {
    param([string]$Expression)
    if ($Expression -match '[\r\n]') {
        throw 'Cron expressions cannot contain newlines.'
    }
    $fields = @($Expression.Trim() -split '\s+')
    if ($fields.Count -ne 5) {
        throw 'Cron requires five numeric fields: minute hour day month weekday.'
    }
    $minimums = @(0, 0, 1, 1, 0)
    $maximums = @(59, 23, 31, 12, 7)
    $parsedFields = @()
    for ($fieldIndex = 0; $fieldIndex -lt 5; $fieldIndex++) {
        $values = [Collections.Generic.HashSet[int]]::new()
        foreach ($part in $fields[$fieldIndex].Split(',')) {
            if ($part -notmatch '^(?<range>\*|[0-9]{1,2}(?:-[0-9]{1,2})?)(?:/(?<step>[0-9]{1,9}))?$') {
                throw "Invalid cron field: $($fields[$fieldIndex])"
            }
            $range = $Matches['range']
            $step = 1
            if ($Matches.ContainsKey('step')) {
                $step = [int]$Matches['step']
                if ($step -le 0 -or ($range -ne '*' -and -not $range.Contains('-'))) {
                    throw 'Invalid cron step.'
                }
            }
            $start = $minimums[$fieldIndex]
            $end = $maximums[$fieldIndex]
            if ($range -ne '*') {
                $bounds = $range.Split('-')
                $start = [int]$bounds[0]
                $end = $start
                if ($bounds.Count -eq 2) {
                    $end = [int]$bounds[1]
                }
            }
            if ($start -lt $minimums[$fieldIndex] -or $end -gt $maximums[$fieldIndex] -or $start -gt $end) {
                throw 'Cron value is outside the allowed range.'
            }
            for ($value = $start; $value -le $end; $value += $step) {
                if ($fieldIndex -eq 4 -and $value -eq 7) {
                    $null = $values.Add(0)
                } else {
                    $null = $values.Add($value)
                }
            }
        }
        $parsedFields += [pscustomobject]@{ Values = $values }
    }
    [pscustomobject]@{
        Fields = $parsedFields
        DayWildcard = $fields[2].StartsWith('*')
        WeekdayWildcard = $fields[4].StartsWith('*')
    }
}

function Test-CronMatch {
    param($Cron, [datetime]$Time = (Get-Date))
    $dayMatches = $Cron.Fields[2].Values.Contains($Time.Day)
    $weekdayMatches = $Cron.Fields[4].Values.Contains([int]$Time.DayOfWeek)
    $dateMatches = $dayMatches -or $weekdayMatches
    if ($Cron.DayWildcard -or $Cron.WeekdayWildcard) {
        $dateMatches = $dayMatches -and $weekdayMatches
    }
    $Cron.Fields[0].Values.Contains($Time.Minute) -and $Cron.Fields[1].Values.Contains($Time.Hour) -and
        $Cron.Fields[3].Values.Contains($Time.Month) -and $dateMatches
}

function Enter-MagicLock {
    param($Context)
    try {
        [IO.File]::Open((Join-Path $Context.Directory '.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another wrapper operation is running.'
    }
}

function Save-Subscription {
    param([string]$Url, [string]$Destination)
    Assert-SubscriptionUrl $Url
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $address = [Uri]$Url
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            if ($address.Scheme -ne 'https') {
                throw 'HTTPS is required for every redirect.'
            }
            $response = $client.GetAsync($address).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                    if (-not $response.Headers.Location) {
                        throw 'Missing redirect location.'
                    }
                    $address = [Uri]::new($address, $response.Headers.Location)
                    continue
                }
                $null = $response.EnsureSuccessStatusCode()
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ($bytes.Length -eq 0) {
                    throw 'Empty subscription.'
                }
                [IO.File]::WriteAllBytes($Destination, $bytes)
                return
            } finally {
                $response.Dispose()
            }
        }
        throw 'Too many redirects.'
    } catch {
        throw 'Subscription download failed; the active configuration was preserved.'
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Assert-MagicConfiguration {
    param($Context, [string]$Binary, [string]$Configuration)
    & $Binary -t -d $Context.Directory -f $Configuration *> (Join-Path $Context.Directory 'validation.log')
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid Mihomo configuration; see $($Context.Directory)\validation.log."
    }
}

function Invoke-WinSW {
    param($Context, [string]$Command)
    & (Join-Path $Context.Directory 'winsw.exe') $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WinSW $Command failed (exit $LASTEXITCODE)."
    }
}

function Get-MagicTask {
    param([string]$Name)
    Get-ScheduledTask -TaskPath '\' | Where-Object { $_.TaskName -eq $Name }
}

function Stop-MagicService {
    param($Context)
    if ($Context.System) {
        $service = Get-Service -Name 'MagicWrapper' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') {
            Invoke-WinSW $Context stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
    } elseif (Get-MagicTask $Context.TaskName) {
        Stop-ScheduledTask -TaskPath '\' -TaskName $Context.TaskName
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ((Get-MagicTask $Context.TaskName).State -ne 'Running') {
                return
            }
            Start-Sleep -Seconds 1
        }
        throw 'Timed out stopping the Mihomo task.'
    }
}

function Restart-MagicService {
    param($Context)
    Stop-MagicService $Context
    if ($Context.System) {
        Invoke-WinSW $Context start
    } else {
        Start-ScheduledTask -TaskPath '\' -TaskName $Context.TaskName
    }
    Start-Sleep -Seconds 2
    if ($Context.System) {
        if ((Get-Service -Name 'MagicWrapper').Status -ne 'Running') {
            throw 'Mihomo service did not stay running.'
        }
    } elseif ((Get-MagicTask $Context.TaskName).State -ne 'Running') {
        throw 'Mihomo task did not stay running.'
    }
}

function Register-MagicTasks {
    param($Context)
    $directory = $Context.Directory
    $powershellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $controller = $null
    if (Test-Path -LiteralPath (Join-Path $directory 'controller.json')) {
        $controller = Get-MagicController $directory
    }
    $principal = New-ScheduledTaskPrincipal -UserId $Context.Account -LogonType Interactive -RunLevel Limited
    if ($Context.System) {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $definition = @'
<service>
  <id>MagicWrapper</id><name>Magic Mihomo wrapper</name>
  <executable>%BASE%\mihomo.exe</executable>
  <arguments>-d "%BASE%" -f "%BASE%\config.yaml"</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <log mode="roll"/>
</service>
'@
        if ($controller) {
            $controllerEnvironment = @(
                "<env name=`"CLASH_OVERRIDE_EXTERNAL_CONTROLLER`" value=`"$($controller.Address)`"/>"
                "<env name=`"CLASH_OVERRIDE_SECRET`" value=`"$($controller.Secret)`"/>"
            ) -join ''
            $definition = $definition.Replace('</service>', "$controllerEnvironment</service>")
        }
        $definition | Set-Content -LiteralPath (Join-Path $directory 'winsw.xml') -Encoding UTF8
        if (-not (Get-Service -Name 'MagicWrapper' -ErrorAction SilentlyContinue)) {
            Invoke-WinSW $Context install
        }
    } else {
        $action = New-ScheduledTaskAction `
            -Execute (Join-Path $directory 'mihomo.exe') `
            -Argument "-d `"$directory`" -f `"$directory\config.yaml`"" `
            -WorkingDirectory $directory
        if ($controller) {
            $action = New-ScheduledTaskAction `
                -Execute $powershellExecutable `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$directory\run.ps1`"" `
                -WorkingDirectory $directory
        }
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Context.Account
        $options = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskPath '\' -TaskName $Context.TaskName `
            -Action $action -Trigger $trigger -Settings $options -Principal $principal -Force
    }
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$directory\update.ps1`" -Scheduled"
    if ($Context.System) {
        $arguments += ' -System'
    }
    $action = New-ScheduledTaskAction -Execute $powershellExecutable -Argument $arguments -WorkingDirectory $directory
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $options = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $null = Register-ScheduledTask -TaskPath '\' -TaskName $Context.UpdateTaskName `
        -Action $action -Trigger $trigger -Settings $options -Principal $principal -Force
}

function Remove-MagicTasks {
    param($Context)
    foreach ($name in @($Context.UpdateTaskName, $Context.TaskName)) {
        if (Get-MagicTask $name) {
            Stop-ScheduledTask -TaskPath '\' -TaskName $name
            Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false
        }
    }
    if ($Context.System -and (Get-Service -Name 'MagicWrapper' -ErrorAction SilentlyContinue)) {
        Stop-MagicService $Context
        Invoke-WinSW $Context uninstall
    }
}
