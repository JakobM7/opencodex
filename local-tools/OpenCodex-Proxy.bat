@echo off
setlocal
echo OpenCodex auf Port 10100. Der Wechsel unterbricht laufende Anfragen.
echo Stable und Dev nutzen dieselbe Konfiguration.
echo.
echo 1. Dev aktivieren
echo 2. Stable wiederherstellen
echo 3. Status anzeigen
choice /c 123 /n /m "Auswahl [1-3]: "
set "selection=%errorlevel%"
set "action="
if "%selection%"=="1" set "action=Dev"
if "%selection%"=="2" set "action=Stable"
if "%selection%"=="3" set "action=Status"
if not defined action exit /b 1
powershell.exe -NoProfile -File "%~dp0Switch-OpenCodex.ps1" -Action %action%
set "result=%errorlevel%"
pause
exit /b %result%
