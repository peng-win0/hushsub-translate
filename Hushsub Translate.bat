@echo off
rem Opens the Hushsub Translate window (Install the first time, then Start; Auto picks the mode for your GPU).
rem Hushsub Translate.exe: the app builds it on its first start (launcher.cs); until then the script runs directly.
if not exist "%~dp0Hushsub Translate.exe" goto script
start "" "%~dp0Hushsub Translate.exe"
exit /b
:script
rem conhost --headless: no PowerShell window (Windows Terminal would ignore -WindowStyle Hidden)
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CaptionsApp.ps1"
