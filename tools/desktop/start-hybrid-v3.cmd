@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-hybrid-v3-demo.ps1" %*
if errorlevel 1 pause
