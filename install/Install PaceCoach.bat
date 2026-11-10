@echo off
rem Installs PaceCoach into Assetto Corsa. install.ps1 next to this file says exactly what it does.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
