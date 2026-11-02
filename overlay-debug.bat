@echo off
rem Same as overlay.bat but keeps a console open so errors are visible.
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0overlay.ps1"
pause
