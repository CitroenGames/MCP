@echo off
setlocal

set "SETUP_SCRIPT=%~dp0Setup-Visual-Studio-MCP.ps1"
if not exist "%SETUP_SCRIPT%" (
  echo ERROR: Setup-Visual-Studio-MCP.ps1 was not found next to this CMD file.
  pause
  exit /b 1
)

echo VS IDE Bridge setup for Codex and Antigravity CLI
echo Close Visual Studio before continuing. A Windows UAC prompt will appear.
echo.

echo Choose the MCP client to configure:
echo   1. Codex
echo   2. Antigravity CLI
echo   3. Both Codex and Antigravity CLI
echo.
choice /C 123 /N /M "Enter 1, 2, or 3: "
if errorlevel 3 (
  set "SETUP_CLIENT=Both"
) else if errorlevel 2 (
  set "SETUP_CLIENT=Antigravity"
) else (
  set "SETUP_CLIENT=Codex"
)
echo.
echo Selected: %SETUP_CLIENT%
echo.

:CHECK_VISUAL_STUDIO
tasklist /FI "IMAGENAME eq devenv.exe" /NH 2>nul | find /I "devenv.exe" >nul
if not errorlevel 1 (
  echo Visual Studio is still running.
  echo Close every Visual Studio window before installation.
  echo If all windows are closed, check Task Manager for a remaining devenv.exe process.
  echo.
  choice /C RC /N /M "Press R to recheck or C to cancel: "
  if errorlevel 2 exit /b 1
  echo.
  goto CHECK_VISUAL_STUDIO
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SETUP_SCRIPT%" -Client "%SETUP_CLIENT%" %*
set "SETUP_EXIT=%ERRORLEVEL%"

echo.
if "%SETUP_EXIT%"=="0" (
  echo Setup finished successfully.
) else (
  echo Setup failed with exit code %SETUP_EXIT%.
)

pause
exit /b %SETUP_EXIT%
