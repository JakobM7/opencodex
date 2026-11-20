[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Dev', 'Stable', 'Status')][string]$Action = 'Status')

$ErrorActionPreference = 'Stop'
$stableState = Join-Path $env:USERPROFILE '.opencodex'
$legacyDevState = Join-Path $env:LOCALAPPDATA 'OpenCodex-dev\10100'
$sharedConfig = Join-Path $stableState 'config.json'
$repo = Split-Path -Parent $PSScriptRoot
$bun = Join-Path $repo 'node_modules\bun\bin\bun.exe'
$entry = Join-Path $repo 'src\cli\index.ts'
$devProcessHelper = Join-Path $PSScriptRoot 'dev-switch-process.ts'
$devLog = Join-Path $stableState 'dev-switch.stderr.log'
$stablePackage = Join-Path $env:APPDATA 'npm\node_modules\@bitkyc08\opencodex'
$stableBun = Join-Path $stablePackage 'node_modules\bun\bin\bun.exe'
$stableEntry = Join-Path $stablePackage 'src\cli\index.ts'
$stableStopModule = Join-Path $stablePackage 'src\service\cli-windows-stop.ts'
$port = 10100
$taskName = 'opencodex-proxy'
$taskPath = '\'

function Get-ListenerOwner([int]$ListenPort) {
    $owners = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq $ListenPort |
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
        else { 'Starting' }
    } elseif ($process.ExecutablePath -eq $stableBun -and $process.CommandLine -like "*$stableEntry*") {
        if ($owner -eq $sharedOwner) { 'Stable' } else { 'Starting' }
    } else {
        'Unknown'
    }
    if ($kind -in @('Unknown', 'Starting')) { return $kind }
    try {
        $health = Invoke-RestMethod "http://127.0.0.1:$port/healthz" -TimeoutSec 2
        if ($health.status -eq 'ok' -and $health.pid -eq $owner -and $health.port -eq $port) { return $kind }
    } catch {}
    return 'Starting'
}

function Wait-PortState([string]$Expected, [int]$ClaudePort = 0, [Diagnostics.Process]$Launched = $null) {
    $deadline = [datetime]::UtcNow.AddSeconds(25)
    do {
        if ($Launched -and $Launched.HasExited) {
            throw "Dev wurde mit Exitcode $($Launched.ExitCode) beendet. Details in $devLog"
        }
        $state = Get-PortState
        if ($state -eq 'Unknown') {
            $owner = Get-ListenerOwner $port
            if ($owner -and (!$Launched -or $owner -ne $Launched.Id)) {
                throw "Ein anderer Prozess belegt Port $port (PID $owner)."
            }
        }
        if ($state -eq $Expected) {
            if (!$Launched -and !$ClaudePort) { return }
            $owner = Get-ListenerOwner $port
            if ($Launched -and $owner -ne $Launched.Id) { throw "Ein anderer Dev-Prozess belegt Port $port." }
            if (!$ClaudePort -or ($owner -and (Get-ListenerOwner $ClaudePort) -eq $owner)) { return }
        }
        Start-Sleep -Milliseconds 400
    } while ([datetime]::UtcNow -lt $deadline)
    if ($state -eq $Expected -and $ClaudePort) { throw "$Expected hat den Claude-Proxyport $ClaudePort nicht rechtzeitig uebernommen." }
    throw "Port $port hat den erwarteten Zustand $Expected nicht rechtzeitig erreicht."
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
    if ($LASTEXITCODE) { throw 'Die Zielversion hat die gemeinsame Konfiguration abgelehnt.' }

    if ($config.claudeCode.enabled -eq $false -or $config.claudeCode.intercept.enabled -eq $false) { return 0 }
    if ($config.claudeCode.intercept.port) { return [int]$config.claudeCode.intercept.port }
    return ($port + 100)
}

function Start-Stable([int]$ClaudePort) {
    $current = Get-PortState
    $task = Get-StableTask
    if ($current -eq 'Free' -and $task.State -eq 'Ready') { $task | Start-ScheduledTask }
    elseif ($task.State -ne 'Running' -or $current -notin @('Free', 'Starting', 'Stable')) {
        throw "Port $port oder der Stable-Dienst ist nicht zum Start bereit."
    }
    Wait-PortState 'Stable' $ClaudePort
}

function Stop-SharedProxy {
    # Use the installed release's checked stop for either process using the service home.
    # Both versions serve the same endpoint, so keep the clients pointed at it.
    Push-Location -LiteralPath $stablePackage
    try {
        @'
import { windowsServiceStopBeforeRestore, completeWindowsServiceStopReceipt } from "./src/service/cli-windows-stop.ts";
try {
    const result = await windowsServiceStopBeforeRestore();
    if (result.ok) completeWindowsServiceStopReceipt(result.nonce);
    else process.exitCode = 1;
} catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
}
'@ | & $stableBun run -
        if ($LASTEXITCODE) { throw 'Der laufende Proxy konnte nicht sicher angehalten werden.' }
    } finally {
        Pop-Location
    }
    Wait-PortState 'Free'
}

function Invoke-DevProcessHelper([string]$Mode, [int]$ProcessId, [long]$StartTime = 0) {
    & $bun run $devProcessHelper $Mode $ProcessId $StartTime
    if ($LASTEXITCODE) { throw "Dev-Prozessaktion fuer PID $ProcessId fehlgeschlagen." }
}

$mutex = $null
$locked = $false
try {
    if ($Action -eq 'Status') {
        $description = switch (Get-PortState) {
            'Dev' { 'Dev (gemeinsame Konfiguration)' }
            'Stable' { 'Stable (gemeinsame Konfiguration)' }
            'LegacyDev' { 'Dev (bisherige separate Konfiguration)' }
            'Starting' { 'OpenCodex antwortet noch nicht' }
            'Free' { 'frei' }
            default { "belegt durch einen unbekannten Prozess (PID $(Get-ListenerOwner $port))" }
        }
        Write-Host "Port ${port}: $description"
        return
    }
    $mutex = New-Object Threading.Mutex($false, 'Local\JakobM7.OpenCodexSwitch10100')
    try { $locked = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Ein Proxy-Wechsel laeuft bereits.' }
    $task = Get-StableTask
    $current = Get-PortState
    if ($task.State -eq 'Running' -and $current -in @('Free', 'Starting')) {
        Wait-PortState 'Stable'
        $current = Get-PortState
    }
    if ($current -eq $Action) { Write-Host "$Action laeuft bereits auf Port $port."; return }
    if ($current -eq 'Starting') { throw "OpenCodex auf Port $port antwortet noch nicht. Warte kurz und waehle erneut." }
    if ($current -eq 'Unknown') { throw "Port $port ist durch einen unbekannten Prozess belegt (PID $(Get-ListenerOwner $port))." }
    if ($task.State -notin @('Ready', 'Running')) { throw 'Der installierte Stable-Dienst ist deaktiviert oder nicht startbereit.' }
    if ($current -eq 'LegacyDev' -and $task.State -ne 'Ready') {
        throw 'Der Stable-Dienst ist aktiv. Die Migration kann erst bei inaktivem Dienst beginnen.'
    }
    if ($current -eq 'Stable' -and $task.State -ne 'Running') {
        throw 'Der installierte Stable-Dienst ist nicht fuer den Wechsel verfuegbar.'
    }
    foreach ($file in $stableBun, $stableEntry, $stableStopModule) {
        if (!(Test-Path -LiteralPath $file)) { throw 'Die installierte Stable-Version ist nicht vollstaendig.' }
    }
    if ($Action -eq 'Dev' -or $current -eq 'LegacyDev') {
        foreach ($file in $bun, $entry, $devProcessHelper) {
            if (!(Test-Path -LiteralPath $file)) { throw 'Bun oder der Dev-Checkout fehlt.' }
        }
    }
    Set-SharedEnvironment
    $stableClaudePort = Confirm-SharedConfig $stableBun $stableEntry
    $interceptPort = if ($Action -eq 'Dev') { Confirm-SharedConfig $bun $entry } else { $stableClaudePort }
    if ($interceptPort -and (Get-ListenerOwner $interceptPort) -notin @(0, (Get-ListenerOwner $port))) {
        throw "Claude-Proxyport $interceptPort ist von einem anderen Prozess belegt."
    }
    $legacyOwner = 0
    if ($current -eq 'LegacyDev') {
        $legacyOwner = Get-ListenerOwner $port
        Invoke-DevProcessHelper 'verify-legacy' $legacyOwner
    }
    if (!$PSCmdlet.ShouldProcess("OpenCodex auf Port $port", "Auf $Action wechseln")) { return }

    $devProcess = $null
    $devStartTime = 0
    try {
        if ($legacyOwner) {
            Write-Host 'Stelle die bisherige Dev-Instanz auf die gemeinsame Konfiguration um.'
            if ((Get-StableTask).State -ne 'Ready' -or (Get-PortState) -ne 'LegacyDev' -or (Get-ListenerOwner $port) -ne $legacyOwner) {
                throw 'Die Ausgangslage hat sich geaendert. Waehle den Wechsel erneut.'
            }
            Invoke-DevProcessHelper 'stop-legacy' $legacyOwner
        } elseif ($current -ne 'Free') { Stop-SharedProxy }
        Wait-PortState 'Free'
        if ($Action -eq 'Stable') {
            Start-Stable $stableClaudePort
            Write-Host "Stable laeuft auf Port $port."
            return
        }
        $env:OCX_SERVICE = '1'
        $devProcess = Start-Process -FilePath $bun -WorkingDirectory $repo -ArgumentList @('run', ('"' + $entry + '"'), 'start', '--port', $port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $stableState 'dev-switch.stdout.log') -RedirectStandardError $devLog
        try { $devStartTime = $devProcess.StartTime.ToUniversalTime().Ticks }
        catch { if (!$devProcess.HasExited) { throw } }
        Wait-PortState 'Dev' $interceptPort $devProcess
        Write-Host "Dev laeuft auf Port $port."
    } catch {
        if ($Action -eq 'Stable') { throw }
        $failure = $_.Exception.Message
        try {
            if ($devProcess -and !$devProcess.HasExited) {
                if (!$devStartTime) { throw 'Der Zeitpunkt des Dev-Starts konnte nicht verifiziert werden.' }
                Invoke-DevProcessHelper 'stop-attempt' $devProcess.Id $devStartTime
                if (!$devProcess.WaitForExit(5000)) { throw 'Der gestartete Dev-Prozess ist noch aktiv.' }
            }
            if ($legacyOwner -and (Get-ListenerOwner $port) -eq $legacyOwner -and (Get-PortState) -eq 'LegacyDev') {
                throw 'Die bisherige Dev-Instanz laeuft weiterhin.'
            }
            if ((Get-PortState) -eq 'Free') {
                $stableClaudePort = Confirm-SharedConfig $stableBun $stableEntry
            }
            Start-Stable $stableClaudePort
        } catch {
            throw "$failure Stable konnte nicht wiederhergestellt werden. $($_.Exception.Message)"
        }
        throw "$failure Stable laeuft auf Port $port."
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
