@echo off
setlocal
cd /d "%~dp0"
call "%~dp0server-config.cmd"
set "EXE=%~dp0server\ShooterGame\Binaries\Win64\ArkAscendedServer.exe"
if not exist "%EXE%" (
  echo ASA server is not installed yet. Run UpdateServer.bat first.
  pause
  exit /b 1
)
set "MOD_ARG="
if defined MODS set "MOD_ARG=-mods=%MODS%"
set "SPEED_ARG="
if /I "%ALLOW_SPEED_LEVELING%"=="True" set "SPEED_ARG=-AllowSpeedLeveling"
echo Starting %SERVER_NAME% on %MAP%...
"%EXE%" "%MAP%?listen?SessionName=%SERVER_NAME%?MultiHome=%SERVER_IP%" -MULTIHOME -Port=%GAME_PORT% -WinLiveMaxPlayers=%MAX_PLAYERS% -ServerPlatform=ALL %SPEED_ARG% %MOD_ARG% -log %*
endlocal
