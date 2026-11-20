@echo off
setlocal DisableDelayedExpansion
echo Waehle das Programm und den OpenCodex-Proxy fuer diese Sitzung.
echo.
echo 1. Codex CLI mit installiertem OpenCodex starten [Port 10100]
echo 2. Codex CLI mit OpenCodex aus dem Entwicklungs-Checkout starten [Port 10101]
echo 3. Claude Code mit installiertem OpenCodex starten [Port 10100]
echo 4. Claude Code mit OpenCodex aus dem Entwicklungs-Checkout starten [Port 10101]
echo.
echo Normale Arbeit: 1 oder 3. OpenCodex-Code testen: 2 oder 4.
choice /c 1234 /n /m "Welche Sitzung starten? [1-4] "
set "selection=%errorlevel%"
if "%selection%"=="0" exit /b 1
if "%selection%"=="255" exit /b 1

set "port=10100"
if "%selection%"=="2" set "port=10101"
if "%selection%"=="4" set "port=10101"
set "endpoint=http://127.0.0.1:%port%"

curl.exe --fail --silent --max-time 3 --output NUL "%endpoint%/healthz"
if errorlevel 1 (
    echo Kein OpenCodex-Proxy erreichbar unter %endpoint%. Starte zuerst den gewaehlten Proxy.
    exit /b 1
)

echo OpenCodex-Proxy fuer diese Sitzung: %endpoint%
if "%selection%"=="1" goto codex
if "%selection%"=="2" goto codex

set "ANTHROPIC_BASE_URL=%endpoint%"
set "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1"
call claude
exit /b %errorlevel%

:codex
call codex -c "openai_base_url=%endpoint%/v1"
exit /b %errorlevel%
