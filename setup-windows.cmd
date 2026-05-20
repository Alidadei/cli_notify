@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

set "_CMDLINE=%CMDCMDLINE%"
echo(%_CMDLINE% | findstr /I /C:" /c " >nul
if not errorlevel 1 (
  echo.
  if "%EXITCODE%"=="0" (
    echo setup-windows completed successfully. Press any key to close.
  ) else (
    echo setup-windows failed with exit code %EXITCODE%. Press any key to close.
  )
  pause >nul
)
endlocal
exit /b %EXITCODE%
