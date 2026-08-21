@echo off
setlocal
cd /d "%~dp0"
tasklist /FI "IMAGENAME eq ArkAscendedServer.exe" | find /I "ArkAscendedServer.exe" >nul
if not errorlevel 1 (
  echo For a consistent backup, first run admin command: cheat SaveWorld
  echo Then stop the server safely with Ctrl+C.
  pause
  exit /b 2
)
for /f "tokens=1-4 delims=/ " %%a in ("%date%") do set "DATESTAMP=%%d-%%b-%%c"
set "TIMESTAMP=%time: =0%"
set "TIMESTAMP=%TIMESTAMP::=-%"
set "DEST=%~dp0backups\ASA_%DATESTAMP%_%TIMESTAMP:~0,8%"
mkdir "%DEST%"
robocopy "%~dp0server\ShooterGame\Saved" "%DEST%\Saved" /E /R:1 /W:1
echo Backup saved to: %DEST%
pause
endlocal
