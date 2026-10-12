@echo off
rem Portable start (no installer). The app downloads its helper programs on first run.
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0YouTubeMP3.ps1"
