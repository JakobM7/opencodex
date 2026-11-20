@echo off
setlocal
echo Waehle eine Desktop-App. Der aktive OpenCodex-Proxy laeuft auf Port 10100.
echo.
echo 1. Codex Desktop
echo 2. Claude Desktop
choice /c 12 /n /m "Auswahl [1-2]: "
set "selection=%errorlevel%"
if "%selection%"=="1" (
    set "OCX_DESKTOP_PACKAGE=OpenAI.Codex"
    set "OCX_DESKTOP_APP=App"
) else if "%selection%"=="2" (
    set "OCX_DESKTOP_PACKAGE=Claude"
    set "OCX_DESKTOP_APP=Claude"
) else (
    exit /b 1
)
curl.exe --noproxy 127.0.0.1 --fail --silent --max-time 3 --output NUL "http://127.0.0.1:10100/healthz"
if errorlevel 1 (
    echo OpenCodex ist auf Port 10100 nicht erreichbar. Nutze OpenCodex-Proxy.bat.
    pause
    exit /b 1
)
set "appId="
for /f "delims=" %%A in ('powershell.exe -NoProfile -NonInteractive -Command "$p = Get-AppxPackage -Name $env:OCX_DESKTOP_PACKAGE; if ($p) { $p.PackageFamilyName + '!' + $env:OCX_DESKTOP_APP }"') do set "appId=%%A"
if not defined appId (
    echo Die Desktop-App ist nicht installiert.
    pause
    exit /b 1
)
start "" explorer.exe "shell:AppsFolder\%appId%"
exit /b %errorlevel%
