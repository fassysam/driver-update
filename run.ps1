<#
    One-line launcher for Update-NetworkChipsetDrivers.ps1 (network + chipset drivers).

    Run in PowerShell on any laptop (admin or not; it asks for admin rights itself):
        irm https://raw.githubusercontent.com/fassysam/driver-update/main/run.ps1 | iex

    With options, e.g. preview only, or use the laptop maker's tool + Windows Update instead:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/fassysam/driver-update/main/run.ps1))) -ListOnly
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/fassysam/driver-update/main/run.ps1))) -Source Auto

    Defaults to -Source Catalog. The script and its logs are kept in C:\ProgramData\DriverUpdate.
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ScriptArgs)

# Everything runs in a child scope so nothing leaks into the caller's session when used with iex
& {
    param([string[]]$ScriptArgs)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $repo = 'https://raw.githubusercontent.com/fassysam/driver-update/main'

    $ScriptArgs = @($ScriptArgs | Where-Object { $_ })
    if ($ScriptArgs -notcontains '-Source') { $ScriptArgs = @('-Source', 'Catalog') + $ScriptArgs }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        # Re-run this launcher in an elevated window. The elevated copy downloads the script itself,
        # so nothing a standard user could modify is ever run as admin.
        Write-Host "Opening an administrator PowerShell window..." -ForegroundColor Cyan
        $command = "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; " +
                   "& ([scriptblock]::Create((irm '$repo/run.ps1'))) $($ScriptArgs -join ' ')"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        return
    }

    $dir  = Join-Path $env:ProgramData 'DriverUpdate'
    $file = Join-Path $dir 'Update-NetworkChipsetDrivers.ps1'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host "Downloading the latest Update-NetworkChipsetDrivers.ps1..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$repo/Update-NetworkChipsetDrivers.ps1" -OutFile $file -UseBasicParsing

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file @ScriptArgs
} $ScriptArgs
