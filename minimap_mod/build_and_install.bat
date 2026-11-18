@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_and_install.ps1" %*
echo.
pause
