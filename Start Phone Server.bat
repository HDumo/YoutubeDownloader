@echo off
title YouTube Downloader - phone server
rem Starts the phone/tablet server in this window. Keep it open while you use your phone.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PhoneServer.ps1"
if errorlevel 1 pause
