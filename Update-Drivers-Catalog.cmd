@echo off
:: Updates network + chipset drivers from the Microsoft Update Catalog (by each device's hardware ID).
:: Runs Update-NetworkChipsetDrivers.ps1 from the same folder as this file, so the pair can be copied
:: anywhere (USB stick, network share) and double-clicked. Asks for administrator rights itself.
:: Extra arguments are passed through, e.g.  Update-Drivers-Catalog.cmd -ListOnly
setlocal
set "SCRIPT=%~dp0Update-NetworkChipsetDrivers.ps1"

if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%".
    echo Keep this file in the same folder as Update-NetworkChipsetDrivers.ps1.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

:: An elevated window starts in System32; switch to this file's folder
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Source Catalog %*
echo.
pause
