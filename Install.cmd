@echo off
setlocal
set "INSTALLER=%~dp0Install-Codex-Provider-Launcher.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" %*
set "INSTALL_RESULT=%ERRORLEVEL%"
if not "%INSTALL_RESULT%"=="0" (
    echo.
    echo Installation did not complete. Read the message above.
    pause
) else if "%~1"=="" (
    echo.
    pause
)
exit /b %INSTALL_RESULT%
