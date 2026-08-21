@echo off
cd /d "%~dp0"
start "ASA Server Manager" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ASA-Manager.ps1"
