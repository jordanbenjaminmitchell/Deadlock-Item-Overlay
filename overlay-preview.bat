@echo off
rem Opens the overlay visible to screenshots, with screen reading off (for checking the look).
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0overlay.ps1" -Preview
