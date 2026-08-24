@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0web-manager\local-service\Stop-ASA-WebManager.ps1"
if errorlevel 1 pause
