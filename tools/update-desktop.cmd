@echo off
rem Unzips the newest Windows build over Desktop\BeDeReader (see update-desktop.ps1).
rem Runs the script with the execution policy bypassed for this one run - Windows blocks .ps1 files by default -
rem without changing any setting. Works from a prompt or by double-clicking.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-desktop.ps1" %*
set code=%errorlevel%
rem not updated (the app is open there, say): wait, so a double-clicked window stays open long enough to read why
if not %code%==0 pause
exit /b %code%
