@echo off
setlocal
cd /d "%~dp0"
set "STEAMCMD=%~dp0steamcmd\steamcmd.exe"
if not exist "%STEAMCMD%" (
  echo Missing: %STEAMCMD%
  echo Download the official SteamCMD ZIP and extract it into the steamcmd folder.
  pause
  exit /b 1
)
tasklist /FI "IMAGENAME eq ArkAscendedServer.exe" | find /I "ArkAscendedServer.exe" >nul
if not errorlevel 1 (
  echo Stop the ASA server safely with Ctrl+C in its console before updating.
  pause
  exit /b 2
)
"%STEAMCMD%" +force_install_dir "%~dp0server" +login anonymous +app_info_update 1 +app_update 2430930 validate +quit
if errorlevel 1 (
  echo Update failed. Review the SteamCMD output above.
  pause
  exit /b 3
)
echo ASA Dedicated Server App 2430930 is installed and validated.
pause
endlocal
