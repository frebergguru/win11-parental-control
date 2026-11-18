@echo off
rem Starter oppsettet for foreldrekontroll som administrator.
rem fltmc virker bare med administratorrettigheter (ogsaa naar Server-tjenesten er av).
fltmc >nul 2>&1
if %errorlevel% equ 0 goto :run
if "%~1"=="" (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
)
exit /b

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Foreldrekontroll.ps1" %*
pause
