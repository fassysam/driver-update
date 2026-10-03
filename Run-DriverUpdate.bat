@echo off
:: Double-click launcher: elevates to Administrator and runs the driver update script.
:: Any arguments are passed through, e.g.  Run-DriverUpdate.bat -ListOnly
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-NetworkChipsetDrivers.ps1" %*
pause
