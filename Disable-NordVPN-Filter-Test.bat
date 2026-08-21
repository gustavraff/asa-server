@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Disable-NordVPN-Filter-Test.ps1"
if errorlevel 1 pause
