@echo off
setlocal DisableDelayedExpansion
echo Waehle Client und Proxy: Stable = installiert, Dev = aus dem Checkout.
echo.
echo 1. Codex - Stable
echo 2. Codex - Dev
echo 3. Claude Code - Stable
echo 4. Claude Code - Dev
choice /c 1234 /n /m "Auswahl [1-4]: "
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
