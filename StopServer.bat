@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StopServer.ps1"
if errorlevel 1 (
  echo.
  echo Safe shutdown did not complete. The server was NOT force-killed.
  pause
  exit /b 1
)
