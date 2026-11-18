@echo off
rem Starter oppsettet for foreldrekontroll som administrator.
rem fltmc virker bare med administratorrettigheter (ogsaa naar Server-tjenesten er av).
fltmc >nul 2>&1
if %errorlevel% equ 0 goto :run
rem Sti og argumenter sendes via miljoevariabler, saa apostrof i mappenavnet ikke gjoer noe.
set "FK_SELF=%~f0"
set "FK_ARGS=%*"
if "%~1"=="" (
    powershell.exe -NoProfile -Command "Start-Process -FilePath $env:FK_SELF -Verb RunAs"
) else (
    powershell.exe -NoProfile -Command "Start-Process -FilePath $env:FK_SELF -ArgumentList $env:FK_ARGS -Verb RunAs"
)
exit /b

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Foreldrekontroll.ps1" %*
pause
