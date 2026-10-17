@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-hybrid-v3-demo.ps1" -Coordination %*
set "taskLaunchExit=%errorlevel%"
if not "%taskLaunchExit%"=="0" pause
exit /b %taskLaunchExit%
