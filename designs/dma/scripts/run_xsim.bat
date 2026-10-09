@echo off
rem run_xsim.bat -- wrapper for scriptsun_xsim.ps1 (xsim AXI4 / AXI4+STALLS regression)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_xsim.ps1" %*
exit /b %ERRORLEVEL%
