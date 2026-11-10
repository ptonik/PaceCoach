@echo off
rem Downloads the newest PaceCoach from GitHub and installs it. install.ps1 says exactly what it does.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Latest %*
echo.
pause
