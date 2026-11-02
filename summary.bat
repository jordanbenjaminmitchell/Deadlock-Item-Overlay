@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0summary.ps1" %*
if errorlevel 1 pause
