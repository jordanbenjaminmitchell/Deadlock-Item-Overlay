@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect.ps1" %*
pause
