@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WarnPlayers-And-Wait.ps1"
if errorlevel 1 exit /b 1
call "%~dp0StopServer.bat"
if errorlevel 1 exit /b 1
timeout /t 3 /nobreak >nul
call "%~dp0StartServer.bat"
