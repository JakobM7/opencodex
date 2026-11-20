[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Dev', 'Stable', 'Status')][string]$Action = 'Status')

$ErrorActionPreference = 'Stop'
$stableState = Join-Path $env:USERPROFILE '.opencodex'
$devRoot = Join-Path $env:LOCALAPPDATA 'OpenCodex-dev'
$seedState = Join-Path $devRoot '10101'
$devState = Join-Path $devRoot '10100'
$repo = Split-Path -Parent $PSScriptRoot
$bun = Join-Path $repo 'node_modules\bun\bin\bun.exe'
$entry = Join-Path $repo 'src\cli\index.ts'
$stablePackage = Join-Path $env:APPDATA 'npm\node_modules\@bitkyc08\opencodex'
$stableBun = Join-Path $stablePackage 'node_modules\bun\bin\bun.exe'
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
    $kind = if ($owner -eq (Read-ProxyPid $stableState)) { 'Stable' }
        elseif ($owner -eq (Read-ProxyPid $devState)) { 'Dev' }
        else { 'Unknown' }
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

function Set-DevEnvironment {
    $env:OPENCODEX_HOME = $devState
    $env:CODEX_HOME = Join-Path $devState 'codex-client'
    $env:GROK_HOME = Join-Path $devState 'grok-client'
    $env:CLAUDE_CONFIG_DIR = Join-Path $devState 'claude-code'
    $env:OPENCODEX_CLAUDE_DESKTOP_CONFIG_DIR = Join-Path $devState 'claude-desktop\configLibrary'
}

function Assert-LocalPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Der Dev-Pfad ist ein Link: $Path"
    }
}

function New-PrivateDirectory([string]$Path) {
    Assert-LocalPath $Path
    if (!(Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Prepare-Dev {
    $stable = Get-Content -LiteralPath (Join-Path $stableState 'config.json') -Raw | ConvertFrom-Json
    $interceptPort = if ($stable.claudeCode.intercept.port) { [int]$stable.claudeCode.intercept.port } else { $port + 100 }
    $interceptOn = $stable.claudeCode.enabled -ne $false -and $stable.claudeCode.intercept.enabled -ne $false
    Assert-LocalPath $devRoot
    New-PrivateDirectory $devState
    foreach ($file in 'config.json', 'config.switch.tmp', 'config.before-switch.json', 'service-api-token', 'switch.stdout.log', 'switch.stderr.log') {
        Assert-LocalPath (Join-Path $devState $file)
    }
    $target = Join-Path $devState 'config.json'
    $template = if (Test-Path -LiteralPath $target) { $target } else { Join-Path $seedState 'config.json' }
    $config = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
    if ($config.runtimeRole -ne 'standalone' -or $stable.runtimeRole -ne 'standalone' -or $stable.port -ne $port) {
        throw 'Stable und Dev muessen eigenstaendige lokale Proxys sein.'
    }
    $config.port = $port
    $config.hostname = '127.0.0.1'
    $config | Add-Member -NotePropertyName apiKeys -NotePropertyValue $stable.apiKeys -Force
    if (!$config.claudeCode) { $config | Add-Member -NotePropertyName claudeCode -NotePropertyValue ([pscustomobject]@{}) -Force }
    $config.claudeCode | Add-Member -NotePropertyName enabled -NotePropertyValue $stable.claudeCode.enabled -Force
    $config.claudeCode | Add-Member -NotePropertyName desktopMode -NotePropertyValue $stable.claudeCode.desktopMode -Force
    $config.claudeCode | Add-Member -NotePropertyName intercept -NotePropertyValue ([pscustomobject]@{ enabled = $interceptOn; port = $interceptPort }) -Force
    if ($interceptOn) {
        $destination = Join-Path $devState 'claude-intercept'
        New-PrivateDirectory $destination
        foreach ($file in 'ca.key', 'ca.pem', 'proxy-token') {
            $identityFile = Join-Path $destination $file
            Assert-LocalPath $identityFile
            Copy-Item -LiteralPath (Join-Path $stableState "claude-intercept\$file") -Destination $identityFile -Force
        }
    }
    $token = Join-Path $stableState 'service-api-token'
    if (Test-Path -LiteralPath $token) {
        Copy-Item -LiteralPath $token -Destination (Join-Path $devState 'service-api-token') -Force
    }

    Set-DevEnvironment
    $payload = $config | ConvertTo-Json -Depth 100
    $payload | & $bun run $entry config validate - --json | Out-Null
    if ($LASTEXITCODE) { throw 'Der Dev-Checkout hat die vorbereitete Konfiguration abgelehnt.' }
    $staged = Join-Path $devState 'config.switch.tmp'
    [IO.File]::WriteAllText($staged, $payload, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $target) {
        [IO.File]::Replace($staged, $target, (Join-Path $devState 'config.before-switch.json'))
    } else {
        [IO.File]::Move($staged, $target)
    }
    if ($interceptOn) { return $interceptPort }
    return 0
}

function Start-Stable {
    $current = Get-PortState
    if ($current -eq 'Stable' -and (Get-StableTask).State -eq 'Running') { return }
    if ($current -ne 'Free') { throw "Port $port ist belegt. Stable wurde nicht gestartet." }
    Get-StableTask | Start-ScheduledTask
    Wait-PortState 'Stable'
}

function Stop-Stable {
    # Reuse the installed release's checked stop, including any surviving Scheduler wrapper.
    # Both clients keep the same endpoint, so release its receipt without restoring native routing.
    $previousHome = $env:OPENCODEX_HOME
    $env:OPENCODEX_HOME = $stableState
    Push-Location -LiteralPath $stablePackage
    try {
        @'
import { windowsServiceStopBeforeRestore, completeWindowsServiceStopReceipt } from "./src/service/cli-windows-stop.ts";
const result = await windowsServiceStopBeforeRestore();
if (!result.ok) process.exit(1);
completeWindowsServiceStopReceipt(result.nonce);
'@ | & $stableBun run -
        if ($LASTEXITCODE) { throw 'Der installierte Stable-Dienst konnte nicht sicher angehalten werden.' }
    } finally {
        Pop-Location
        $env:OPENCODEX_HOME = $previousHome
    }
    Wait-PortState 'Free'
}

function Stop-Dev {
    $owner = Get-ListenerOwner $port
    if (!$owner -or $owner -ne (Read-ProxyPid $devState)) {
        throw 'Der Prozess auf Port 10100 gehoert nicht zur Dev-Instanz.'
    }
    Set-DevEnvironment
    $env:OCX_SWITCH_DEV_PID = "$owner"
    Push-Location -LiteralPath $repo
    try {
        @'
import { resolveTrackedProxyTarget, stopTrackedProxyIfRunning } from "./src/service/orchestration.ts";
const target = await resolveTrackedProxyTarget();
if (!target || target.pid !== Number(process.env.OCX_SWITCH_DEV_PID) || target.endpoint?.port !== 10100) process.exit(1);
await stopTrackedProxyIfRunning({ target });
'@ | & $bun run -
        if ($LASTEXITCODE) { throw 'Dev konnte nicht sauber beendet werden.' }
    } finally {
        Pop-Location
    }
    Wait-PortState 'Free'
}

if ($Action -eq 'Status') {
    Write-Host "Port ${port}: $(Get-PortState)"
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
    if ($current -notin @('Free', 'Stable', 'Dev')) { throw "Port $port hat keinen verifizierten OpenCodex-Prozess ($current)." }
    $task = Get-StableTask
    if ($Action -eq 'Dev' -and $current -eq 'Free' -and $task.State -eq 'Running') {
        throw 'Der Stable-Dienst startet gerade. Warte auf Port 10100 und versuche es erneut.'
    }
    if ($current -eq 'Stable' -and ($task.State -ne 'Running' -or !(Test-Path -LiteralPath $stableBun) -or !(Test-Path -LiteralPath $stableStopModule))) {
        throw 'Der installierte Stable-Dienst ist nicht fuer den Wechsel verfuegbar.'
    }
    if (($Action -eq 'Dev' -or $current -eq 'Dev') -and (!(Test-Path -LiteralPath $bun) -or !(Test-Path -LiteralPath $entry))) {
        throw 'Bun oder der Dev-Checkout fehlt.'
    }
    if (!$PSCmdlet.ShouldProcess("OpenCodex auf Port $port", "Auf $Action wechseln")) { return }

    if ($Action -eq 'Stable') {
        if ($current -eq 'Dev') { Stop-Dev }
        Start-Stable
        Write-Host "Stable laeuft auf Port $port."
        return
    }

    $interceptPort = Prepare-Dev
    $stableOwner = Read-ProxyPid $stableState
    if ($interceptPort -and (Get-ListenerOwner $interceptPort) -notin @(0, $stableOwner)) {
        throw "Claude-Proxyport $interceptPort ist von einem anderen Prozess belegt."
    }
    $devProcess = $null
    try {
        if ($current -eq 'Stable') { Stop-Stable }
        Wait-PortState 'Free'
        $devProcess = Start-Process -FilePath $bun -WorkingDirectory $repo -ArgumentList @('run', ('"' + $entry + '"'), 'start', '--port', $port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $devState 'switch.stdout.log') -RedirectStandardError (Join-Path $devState 'switch.stderr.log')
        Wait-PortState 'Dev'
        if ($interceptPort -and (Get-ListenerOwner $interceptPort) -ne (Read-ProxyPid $devState)) {
            throw "Dev hat den Claude-Proxy auf Port $interceptPort nicht uebernommen."
        }
        Write-Host "Dev laeuft auf Port $port."
    } catch {
        $failure = $_.Exception.Message
        try {
            if ($devProcess) {
                # Stop only the process created by this attempt if startup did not finish.
                $devProcess.Refresh()
                if (!$devProcess.HasExited) {
                    $devProcess.Kill()
                    if (!$devProcess.WaitForExit(5000)) { throw 'Der Dev-Startprozess konnte nicht beendet werden.' }
                }
            }
            Wait-PortState $(if ((Get-PortState) -eq 'Stable') { 'Stable' } else { 'Free' })
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
