@echo off
rem ==========================================================================
rem build.bat -- run vivado/build.tcl in batch mode from any directory.
rem   vivado\build.bat                           (125 MHz, default strategy)
rem   vivado\build.bat tag end place_directive ExtraNetDelay_high lint 0
rem   vivado\build.bat tag p9p50 period 9.5 lint 0
rem Arguments are the <key> <value> pairs documented in build.tcl.
rem The Vivado log is kept next to the reports (vivado/reports[/<tag>]/vivado.log).
rem Override the tool location with the VIVADO environment variable.
rem ==========================================================================
setlocal
if "%VIVADO%"=="" set "VIVADO=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set "HERE=%~dp0"
set "TAG="
set "PREV="
for %%A in (%*) do call :arg %%A
set "RPT=%HERE%reports"
set "BLD=%HERE%build"
if not "%TAG%"=="" set "RPT=%RPT%\%TAG%" & set "BLD=%BLD%\%TAG%"
if not exist "%RPT%" mkdir "%RPT%"
if not exist "%BLD%" mkdir "%BLD%"
pushd "%BLD%"
call "%VIVADO%" -mode batch -notrace -log "%RPT%\vivado.log" -journal "%BLD%\vivado.jou" -source "%HERE%build.tcl" -tclargs %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%

:arg
if /i "%PREV%"=="tag" set "TAG=%1"
set "PREV=%1"
exit /b 0
