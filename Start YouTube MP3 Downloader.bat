@echo off
cd /d "%~dp0"
rem First run: download the helper programs (visible window so you can see progress).
if not exist "tools\yt-dlp.exe" goto setup
if not exist "tools\ffmpeg.exe" goto setup
goto run
:setup
echo Setting up YouTube MP3 Downloader - this only happens once...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0YouTubeMP3.ps1" -SetupOnly
if errorlevel 1 (
  echo.
  pause
  exit /b 1
)
:run
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0YouTubeMP3.ps1"
