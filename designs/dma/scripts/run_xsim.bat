@echo off
rem run_xsim.bat -- wrapper for scripts/run_xsim.ps1 (see that file for usage)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_xsim.ps1" %*
exit /b %ERRORLEVEL%
