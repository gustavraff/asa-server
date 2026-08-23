@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0web-manager\local-service\Start-ASA-WebManager.ps1" -Lan
if errorlevel 1 pause
