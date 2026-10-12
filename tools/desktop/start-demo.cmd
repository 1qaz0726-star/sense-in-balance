@echo off
chcp 65001 >nul
rem ProcessOnly: Bypass applies only to this reviewed local helper process.
rem No persistent execution policy, registry, or environment changes.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-demo.ps1" %*
set "DEMO_EXIT=%ERRORLEVEL%"
if not "%DEMO_EXIT%"=="0" pause
exit /b %DEMO_EXIT%
