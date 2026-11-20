[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Dev', 'Stable', 'Status')][string]$Action = 'Status')

$ErrorActionPreference = 'Stop'
$stableState = Join-Path $env:USERPROFILE '.opencodex'
$legacyDevState = Join-Path $env:LOCALAPPDATA 'OpenCodex-dev\10100'
$sharedConfig = Join-Path $stableState 'config.json'
$repo = Split-Path -Parent $PSScriptRoot
$bun = Join-Path $repo 'node_modules\bun\bin\bun.exe'
$entry = Join-Path $repo 'src\cli\index.ts'
$stablePackage = Join-Path $env:APPDATA 'npm\node_modules\@bitkyc08\opencodex'
$stableBun = Join-Path $stablePackage 'node_modules\bun\bin\bun.exe'
$stableEntry = Join-Path $stablePackage 'src\cli\index.ts'
$stableStopModule = Join-Path $stablePackage 'src\service\cli-windows-stop.ts'
$port = 10100
$taskName = 'opencodex-proxy'
$taskPath = '\'

function Get-ListenerOwner([int]$ListenPort) {
    $owners = @(Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    if ($owners.Count -gt 1) { throw "Mehrere Prozesse lauschen auf Port $ListenPort." }
    if ($owners.Count) { return $owners[0] }
    return 0
}

function Read-ProxyPid([string]$State) {
    $file = Join-Path $State 'ocx.pid'
    if (!(Test-Path -LiteralPath $file)) { return 0 }
    $text = (Get-Content -LiteralPath $file -Raw).Trim()
    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }
    return 0
}

function Get-PortState {
    $owner = Get-ListenerOwner $port
    if (!$owner) { return 'Free' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $owner"
    $sharedOwner = Read-ProxyPid $stableState
    $legacyOwner = Read-ProxyPid $legacyDevState
    $kind = if ($process.ExecutablePath -eq $bun -and $process.CommandLine -like "*$entry*") {
        if ($owner -eq $sharedOwner) { 'Dev' }
        elseif ($owner -eq $legacyOwner) { 'LegacyDev' }
        else { 'Unknown' }
    } elseif ($owner -eq $sharedOwner -and $process.ExecutablePath -eq $stableBun -and $process.CommandLine -like "*$stableEntry*") {
        'Stable'
    } else {
        'Unknown'
    }
    if ($kind -eq 'Unknown') { return $kind }
    try {
        $health = Invoke-RestMethod "http://127.0.0.1:$port/healthz" -TimeoutSec 2
        if ($health.status -eq 'ok' -and $health.pid -eq $owner -and $health.port -eq $port) { return $kind }
    } catch {}
    return 'Starting'
}

function Wait-PortState([string]$Expected) {
    $deadline = [datetime]::UtcNow.AddSeconds(25)
    do {
        if ((Get-PortState) -eq $Expected) { return }
        Start-Sleep -Milliseconds 400
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Port $port hat den erwarteten Zustand $Expected nicht erreicht."
}

function Get-StableTask {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath
    $launcher = Join-Path $stableState 'opencodex-service-launcher.vbs'
    if ($task.Actions.Count -ne 1 -or $task.Actions[0].Arguments -notlike "*$launcher*") {
        throw 'Der Task Scheduler verweist nicht auf den erwarteten Stable-Launcher.'
    }
    return $task
}

function Set-SharedEnvironment {
    $state = Get-Content -LiteralPath (Join-Path $stableState 'service-state.json') -Raw | ConvertFrom-Json
    if ($state.opencodexHome -ne $stableState -or $state.cliPath -ne $stableEntry -or
        $state.bunPath -ne $stableBun -or $state.backend -ne 'scheduler' -or !$state.codexHome) {
        throw 'Der installierte Dienst verweist auf eine andere OpenCodex- oder Codex-Installation.'
    }
    $env:OPENCODEX_HOME = $state.opencodexHome
    $env:CODEX_HOME = $state.codexHome
    $env:CODEX_SQLITE_HOME = $state.codexSqliteHome
    $env:OCX_SERVICE_MANAGED = $null
    $env:OCX_WINDOWS_WRAPPER_PROTOCOL = $null
}

function Confirm-SharedConfig([string]$Runtime, [string]$Cli) {
    $config = Get-Content -LiteralPath $sharedConfig -Raw | ConvertFrom-Json
    if ($config.runtimeRole -ne 'standalone' -or $config.port -ne $port) {
        throw 'Die gemeinsame Konfiguration muss ein eigenstaendiger Proxy auf Port 10100 sein.'
    }
    & $Runtime $Cli config validate $sharedConfig --json | Out-Null
    if ($LASTEXITCODE) { throw "Die Zielversion hat die gemeinsame Konfiguration abgelehnt. Der laufende Proxy bleibt aktiv." }

    if ($config.claudeCode.enabled -eq $false -or $config.claudeCode.intercept.enabled -eq $false) { return 0 }
    if ($config.claudeCode.intercept.port) { return [int]$config.claudeCode.intercept.port }
    return ($port + 100)
}

function Start-Stable {
    $current = Get-PortState
    if ($current -eq 'Stable' -and (Get-StableTask).State -eq 'Running') { return }
    if ($current -ne 'Free') { throw "Port $port ist belegt. Stable wurde nicht gestartet." }
    Get-StableTask | Start-ScheduledTask
    Wait-PortState 'Stable'
}

function Stop-SharedProxy {
    # Use the installed release's checked stop for either process using the service home.
    # Both versions serve the same endpoint, so keep the clients pointed at it.
    Push-Location -LiteralPath $stablePackage
    try {
        @'
import { windowsServiceStopBeforeRestore, completeWindowsServiceStopReceipt } from "./src/service/cli-windows-stop.ts";
const result = await windowsServiceStopBeforeRestore();
if (!result.ok) process.exit(1);
completeWindowsServiceStopReceipt(result.nonce);
'@ | & $stableBun run -
        if ($LASTEXITCODE) { throw 'Der laufende Proxy konnte nicht sicher angehalten werden.' }
    } finally {
        Pop-Location
    }
    Wait-PortState 'Free'
}

if ($Action -eq 'Status') {
    $current = Get-PortState
    $description = switch ($current) {
        'Dev' { 'Dev (gemeinsame Konfiguration)' }
        'Stable' { 'Stable (gemeinsame Konfiguration)' }
        'LegacyDev' { 'Dev (bisherige separate Konfiguration)' }
        default { $current }
    }
    Write-Host "Port ${port}: $description"
    return
}

$mutex = New-Object Threading.Mutex($false, 'Local\JakobM7.OpenCodexSwitch10100')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Ein Proxy-Wechsel laeuft bereits.' }
    $current = Get-PortState
    if ($current -eq $Action) { Write-Host "$Action laeuft bereits auf Port $port."; return }
    if ($current -notin @('Free', 'Stable', 'Dev', 'LegacyDev')) { throw "Port $port hat keinen verifizierten OpenCodex-Prozess ($current)." }
    $task = Get-StableTask
    if ($Action -eq 'Dev' -and $current -eq 'Free' -and $task.State -eq 'Running') {
        throw 'Der Stable-Dienst startet gerade. Warte auf Port 10100 und versuche es erneut.'
    }
    if ($current -eq 'Stable' -and $task.State -ne 'Running') {
        throw 'Der installierte Stable-Dienst ist nicht fuer den Wechsel verfuegbar.'
    }
    foreach ($file in $stableBun, $stableEntry, $stableStopModule) {
        if (!(Test-Path -LiteralPath $file)) { throw 'Die installierte Stable-Version ist nicht vollstaendig.' }
    }
    if (($Action -eq 'Dev') -and (!(Test-Path -LiteralPath $bun) -or !(Test-Path -LiteralPath $entry))) {
        throw 'Bun oder der Dev-Checkout fehlt.'
    }
    Set-SharedEnvironment
    $interceptPort = if ($Action -eq 'Dev') { Confirm-SharedConfig $bun $entry }
        else { Confirm-SharedConfig $stableBun $stableEntry }
    if ($interceptPort -and (Get-ListenerOwner $interceptPort) -notin @(0, (Get-ListenerOwner $port))) {
        throw "Claude-Proxyport $interceptPort ist von einem anderen Prozess belegt."
    }
    if (!$PSCmdlet.ShouldProcess("OpenCodex auf Port $port", "Auf $Action wechseln")) { return }
    if ($current -eq 'LegacyDev') {
        $oldOwner = Get-ListenerOwner $port
        throw "Beende vor dem ersten Wechsel die bisherige separate Dev-Instanz (PID $oldOwner). Ihre Konfiguration bleibt erhalten."
    }

    $devProcess = $null
    try {
        if ($current -ne 'Free') { Stop-SharedProxy }
        Wait-PortState 'Free'
        if ($Action -eq 'Stable') {
            Start-Stable
            Write-Host "Stable laeuft auf Port $port."
            return
        }
        $env:OCX_SERVICE = '1'
        $devProcess = Start-Process -FilePath $bun -WorkingDirectory $repo -ArgumentList @('run', ('"' + $entry + '"'), 'start', '--port', $port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stableState 'dev-switch.stdout.log') -RedirectStandardError (Join-Path $stableState 'dev-switch.stderr.log')
        Wait-PortState 'Dev'
        if ($interceptPort -and (Get-ListenerOwner $interceptPort) -ne (Read-ProxyPid $stableState)) {
            throw "Dev hat den Claude-Proxy auf Port $interceptPort nicht uebernommen."
        }
        Write-Host "Dev laeuft auf Port $port."
    } catch {
        if ($Action -eq 'Stable') { throw }
        $failure = $_.Exception.Message
        try {
            if ($devProcess) {
                $devProcess.Refresh()
                if (!$devProcess.HasExited -and (Get-PortState) -eq 'Dev' -and (Get-ListenerOwner $port) -eq $devProcess.Id) {
                    Stop-SharedProxy
                    $devProcess.Refresh()
                }
                if (!$devProcess.HasExited) { throw 'Der gestartete Dev-Prozess antwortet noch nicht oder wird gerade beendet.' }
            }
            Start-Stable
        } catch {
            throw "$failure Stable konnte nicht wiederhergestellt werden. $($_.Exception.Message)"
        }
        throw "$failure Stable laeuft auf Port $port."
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
