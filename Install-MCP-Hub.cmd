@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MCP-Installer.ps1"
exit /b %ERRORLEVEL%
