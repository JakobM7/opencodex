@echo off
setlocal DisableDelayedExpansion
echo Waehle Desktop-App und Proxy. Stable = installiert, Dev = aus dem Checkout.
echo.
echo 1. Codex Desktop - Stable
echo 2. Codex Desktop - Dev
echo 3. Claude Desktop - Stable
echo 4. Claude Desktop - Dev (Gateway)
choice /c 1234 /n /m "Auswahl [1-4]: "
set "selection=%errorlevel%"
if "%selection%"=="0" exit /b 1
if "%selection%"=="255" exit /b 1

set "port=10100"
set "OPENCODEX_HOME=%USERPROFILE%\.opencodex"
if "%selection%"=="2" goto dev
if "%selection%"=="4" goto dev
goto selectApp
:dev
set "port=10101"
set "OPENCODEX_HOME=%LOCALAPPDATA%\OpenCodex-dev\10101"
if not exist "%~dp0..\node_modules\bun\bin\bun.exe" (
    echo Bun fuer den Entwicklungs-Checkout fehlt. Fuehre dort zuerst bun install aus.
    goto failed
)

:selectApp
set "OCX_DESKTOP_PACKAGE=OpenAI.Codex"
set "OCX_DESKTOP_APP=App"
set "OCX_DESKTOP_NAME=Codex Desktop"
if %selection% geq 3 (
    set "OCX_DESKTOP_PACKAGE=Claude"
    set "OCX_DESKTOP_APP=Claude"
    set "OCX_DESKTOP_NAME=Claude Desktop"
)
set "OCX_DESKTOP_URL=http://127.0.0.1:%port%"
curl.exe --noproxy 127.0.0.1 --fail --silent --max-time 3 --output NUL "%OCX_DESKTOP_URL%/healthz"
if errorlevel 1 (
    echo Starte zuerst den OpenCodex-Proxy auf Port %port%.
    goto failed
)

set "appId="
for /f "delims=" %%A in ('powershell.exe -NoProfile -NonInteractive -Command "$p = Get-AppxPackage -Name $env:OCX_DESKTOP_PACKAGE; if (-not $p) { [Console]::Error.WriteLine($env:OCX_DESKTOP_NAME + ' ist als Windows-App nicht installiert.'); exit 1 }; $a = (Get-AppxPackageManifest -Package $p).Package.Applications.Application | Where-Object { $_.Id -eq $env:OCX_DESKTOP_APP }; if (-not $a.Executable) { [Console]::Error.WriteLine('Windows-App konnte nicht ermittelt werden.'); exit 1 }; $exe = [IO.Path]::GetFullPath((Join-Path $p.InstallLocation $a.Executable)); if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -ieq $exe }) { [Console]::Error.WriteLine('Bitte ' + $env:OCX_DESKTOP_NAME + ' vollstaendig beenden und die BAT erneut starten.'); exit 1 }; $p.PackageFamilyName + '!' + $a.Id"') do set "appId=%%A"
if not defined appId goto failed

echo Richte %OCX_DESKTOP_NAME% fuer Port %port% ein ...
if %selection% geq 3 goto claude

call :ocx sync --local-only
if errorlevel 1 goto failed
powershell.exe -NoProfile -NonInteractive -Command "$homeDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }; $expected = 'openai_base_url = ' + [char]34 + $env:OCX_DESKTOP_URL + '/v1' + [char]34; foreach ($line in Get-Content -LiteralPath (Join-Path $homeDir 'config.toml')) { if ($line.TrimStart().StartsWith('[')) { break }; if ($line.Trim() -eq $expected) { exit 0 } }; [Console]::Error.WriteLine('Codex-Konfiguration zeigt nicht auf den gewaehlten Proxy.'); exit 1"
if errorlevel 1 goto failed
goto launch

:claude
if "%selection%"=="4" goto gateway
call :ocx claude desktop apply
if errorlevel 1 goto failed
goto launch

:gateway
call :ocx claude desktop apply --gateway
if errorlevel 1 goto failed

:launch
start "" explorer.exe "shell:AppsFolder\%appId%"
exit /b %errorlevel%

:ocx
if "%port%"=="10100" goto installed
"%~dp0..\node_modules\bun\bin\bun.exe" run "%~dp0..\src\cli\index.ts" %*
exit /b %errorlevel%

:installed
call ocx %*
exit /b %errorlevel%

:failed
pause
exit /b 1
