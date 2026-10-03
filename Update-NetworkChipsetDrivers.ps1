<#
.SYNOPSIS
    Fetches and installs the latest NETWORK and CHIPSET drivers for this laptop.

.DESCRIPTION
    1. Detects the manufacturer (Dell / Lenovo / HP / other).
    2. Uses the vendor's own update tooling when possible:
         Dell   -> Dell Command | Update CLI (if installed)
         Lenovo -> LSUClient PowerShell module (from PowerShell Gallery)
         HP     -> HP Client Management Script Library (HPCMSL, from PowerShell Gallery)
    3. Always also runs Windows Update (driver updates only), filtered to the
       Net (Ethernet/Wi-Fi) and System (chipset) driver classes. This is the
       fallback for any brand, and it fills gaps left by the vendor tools.

    With -Source Catalog the steps above are skipped. Instead, each network and
    chipset device is looked up by its hardware ID (e.g. PCI\VEN_8086&DEV_51F1 for
    an Intel Wi-Fi card) in the Microsoft Update Catalog, where Intel, Realtek, AMD,
    etc. publish their drivers. The newest driver that fits this Windows version and
    is newer than the installed one is downloaded, its Microsoft signature checked,
    and installed with pnputil.

    Must be run as Administrator (except -Source Catalog -ListOnly). Writes a log
    next to the script.

.PARAMETER Source
    Auto    (default) Laptop maker's tool + Windows Update.
    Catalog Look up each device's own chip maker driver by hardware ID in the
            Microsoft Update Catalog.

.PARAMETER ListOnly
    Only show which drivers would be installed; install nothing.

.PARAMETER SkipVendorTools
    Skip Dell/Lenovo/HP tooling and use Windows Update only.

.PARAMETER IncludeBluetooth
    Also include Bluetooth drivers (often bundled with Wi-Fi cards).

.PARAMETER Reboot
    Reboot automatically at the end if any installed driver requires it.

.EXAMPLE
    .\Update-NetworkChipsetDrivers.ps1 -ListOnly
    .\Update-NetworkChipsetDrivers.ps1
    .\Update-NetworkChipsetDrivers.ps1 -IncludeBluetooth -Reboot
    .\Update-NetworkChipsetDrivers.ps1 -Source Catalog -ListOnly
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Catalog')]
    [string]$Source = 'Auto',
    [switch]$ListOnly,
    [switch]$SkipVendorTools,
    [switch]$IncludeBluetooth,
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow in PS 5.1 with the progress bar on
$script:RebootNeeded = $false
$LogFile = Join-Path $PSScriptRoot ("DriverUpdate_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')]$Level = 'INFO')
    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}

# ---------------------------------------------------------------- pre-checks
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not ($ListOnly -and $Source -eq 'Catalog')) {
    Write-Host "Please run this script as Administrator." -ForegroundColor Red
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$cs    = Get-CimInstance Win32_ComputerSystem
$make  = $cs.Manufacturer.Trim()
$model = $cs.Model.Trim()
if ($make -match 'LENOVO') { $model = (Get-CimInstance Win32_ComputerSystemProduct).Version }  # friendly name

Write-Log "Device: $make $model"
Write-Log "OS:     $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Log "Mode:   $(if ($ListOnly) {'LIST ONLY (no changes)'} else {'INSTALL'}), source: $Source"

if (-not (Test-Connection -ComputerName 'www.microsoft.com' -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    # ICMP may be blocked; try HTTPS before giving up
    try { Invoke-WebRequest 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Log "No internet connection detected. Aborting." 'ERROR'; exit 1 }
}

if (-not $ListOnly) {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Before network/chipset driver update" -RestorePointType MODIFY_SETTINGS
        Write-Log "System restore point created." 'OK'
    } catch {
        Write-Log "Could not create restore point (continuing): $($_.Exception.Message)" 'WARN'
    }
}

function Ensure-GalleryModule {
    param([string]$Name)
    if (Get-Module -ListAvailable -Name $Name) { Import-Module $Name -Force; return }
    Write-Log "Installing PowerShell module '$Name' from PowerShell Gallery..."
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    }
    $installArgs = @{ Name = $Name; Force = $true; Scope = 'AllUsers'; AllowClobber = $true; ErrorAction = 'Stop' }
    # -AcceptLicense only exists in newer PowerShellGet; Windows PowerShell 5.1 ships 1.0.0.1 without it
    if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) { $installArgs.AcceptLicense = $true }
    Install-Module @installArgs
    Import-Module $Name -Force
}

# ---------------------------------------------------------------- Dell
function Update-Dell {
    $dcu = @(
        "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $dcu) {
        Write-Log "Dell Command | Update not installed; relying on Windows Update. (Install it from dell.com for best results.)" 'WARN'
        return
    }
    Write-Log "Using Dell Command | Update: $dcu"
    $categories = 'network,chipset'
    $action = if ($ListOnly) { '/scan' } else { '/applyUpdates' }
    $dcuArgs = @($action, '-updateType=driver', "-updateDeviceCategory=$categories", '-silent')
    if (-not $ListOnly) { $dcuArgs += '-reboot=disable' }

    $p = Start-Process -FilePath $dcu -ArgumentList $dcuArgs -Wait -PassThru -NoNewWindow
    switch ($p.ExitCode) {
        0       { Write-Log "Dell Command | Update finished successfully." 'OK' }
        1       { Write-Log "Dell updates installed; reboot required." 'OK'; $script:RebootNeeded = $true }
        5       { Write-Log "Dell updates installed; reboot required." 'OK'; $script:RebootNeeded = $true }
        500     { Write-Log "Dell: no applicable network/chipset updates found." 'OK' }
        default { Write-Log "Dell Command | Update exit code $($p.ExitCode) (see Dell docs)." 'WARN' }
    }
}

# ---------------------------------------------------------------- Lenovo
function Update-Lenovo {
    Ensure-GalleryModule -Name 'LSUClient'
    Write-Log "Querying Lenovo for available updates..."
    $pattern = 'Network|Networking|LAN|WLAN|Wireless|Ethernet|Chipset'
    if ($IncludeBluetooth) { $pattern += '|Bluetooth' }

    $updates = Get-LSUpdate | Where-Object {
        $_.Category -match $pattern -and $_.Installer.Unattended
    }
    if (-not $updates) { Write-Log "Lenovo: no applicable network/chipset updates found." 'OK'; return }

    $updates | ForEach-Object { Write-Log "  Lenovo: [$($_.Category)] $($_.Title) $($_.Version)" }
    if ($ListOnly) { return }

    $updates | Save-LSUpdate -ShowProgress
    $results = $updates | Install-LSUpdate -Verbose
    foreach ($r in $results) {
        Write-Log "  $($r.Title): $($r.Success) $($r.PendingAction)" $(if ($r.Success) {'OK'} else {'WARN'})
        if ($r.PendingAction -match 'REBOOT') { $script:RebootNeeded = $true }
    }
}

# ---------------------------------------------------------------- HP
function Update-HP {
    Ensure-GalleryModule -Name 'HPCMSL'
    Write-Log "Querying HP for available SoftPaqs..."
    $pattern = 'Network|Chipset'
    if ($IncludeBluetooth) { $pattern += '|Bluetooth' }

    $softpaqs = Get-SoftpaqList -Category Driver -ErrorAction Stop |
                Where-Object { $_.Category -match $pattern }
    if (-not $softpaqs) { Write-Log "HP: no network/chipset SoftPaqs found." 'OK'; return }

    $work = Join-Path $env:TEMP 'HP_SoftPaqs'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Push-Location $work
    try {
        foreach ($sp in $softpaqs) {
            Write-Log "  HP: [$($sp.Category)] $($sp.Name) $($sp.Version) ($($sp.Id))"
            if ($ListOnly) { continue }
            try {
                Get-Softpaq -Number $sp.Id -Action silentinstall -Overwrite yes
                Write-Log "    Installed $($sp.Id)" 'OK'
                $script:RebootNeeded = $true   # HP SoftPaqs rarely report this reliably
            } catch {
                Write-Log "    Failed $($sp.Id): $($_.Exception.Message)" 'WARN'
            }
        }
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- Windows Update
function Update-ViaWindowsUpdate {
    Write-Log "Searching Windows Update for driver updates (this can take a few minutes)..."
    $classes = @('Net', 'System')       # Net = Ethernet/Wi-Fi, System = chipset
    if ($IncludeBluetooth) { $classes += 'Bluetooth' }

    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2      # ssWindowsUpdate: bypass WSUS, which usually has no drivers
    $searcher.Online = $true

    try {
        $result = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    } catch {
        Write-Log "Windows Update search failed: $($_.Exception.Message)" 'ERROR'
        return
    }

    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $result.Updates) {
        if ($classes -contains $u.DriverClass) {
            Write-Log "  WU: [$($u.DriverClass)] $($u.Title)"
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$toInstall.Add($u)
        }
    }

    if ($toInstall.Count -eq 0) { Write-Log "Windows Update: network/chipset drivers are up to date." 'OK'; return }
    if ($ListOnly) { return }

    Write-Log "Downloading $($toInstall.Count) driver(s)..."
    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $toInstall
    [void]$dl.Download()

    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $toInstall) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
    if ($ready.Count -eq 0) { Write-Log "Nothing downloaded successfully." 'ERROR'; return }

    Write-Log "Installing $($ready.Count) driver(s)..."
    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $ready
    $res = $inst.Install()

    for ($i = 0; $i -lt $ready.Count; $i++) {
        $code = $res.GetUpdateResult($i).ResultCode   # 2 = succeeded, 3 = succeeded w/ errors
        $lvl  = if ($code -in 2,3) {'OK'} else {'WARN'}
        Write-Log "  $($ready.Item($i).Title) -> result code $code" $lvl
    }
    if ($res.RebootRequired) { $script:RebootNeeded = $true }
}

# ---------------------------------------------------------------- Microsoft Update Catalog (by hardware ID)
$CatalogBase = 'https://www.catalog.update.microsoft.com'
$script:CatalogCache = @{}

function ConvertTo-ReleaseNumber {
    # Windows release names to comparable numbers: '22H2' -> 22.2, '1903' -> 19.1, '1909' -> 19.2
    param([string]$Release)
    if ($Release -match '^(\d{2})H([12])$') { return [double]"$($Matches[1]).$($Matches[2])" }
    if ($Release -match '^(\d{2})(\d{2})$') { return [double]("$($Matches[1])." + $(if ([int]$Matches[2] -le 6) { 1 } else { 2 })) }
    $null
}

function ConvertTo-DriverVersion {
    param([string]$Text)
    if ($Text -match '(\d+(\.\d+){1,3})') { try { return [version]$Matches[1] } catch {} }
    $null
}

function Test-CatalogProductMatch {
    # True if any entry in the catalog's "Products" column applies to this PC's Windows version, e.g.
    # "Windows 11 Client, version 25H2 and later, Servicing Drivers, Windows 11 Client S, version 25H2 and later, ..."
    param([string]$Products)
    foreach ($p in ($Products -split ',\s*(?=Windows)')) {
        if ($p -match 'Server' -or $p -notmatch 'Windows (10|11)') { continue }
        $isWin11Product = $p -match 'Windows 11'
        if ($isWin11Product -and -not $script:OsIsWin11) { continue }
        # Windows 10 drivers also run on Windows 11, but release numbers only compare within the same OS
        if ($p -match 'version\s+(\w+)' -and $isWin11Product -eq $script:OsIsWin11) {
            $min = ConvertTo-ReleaseNumber $Matches[1]
            if ($min -and $script:OsRelease -and $min -gt $script:OsRelease) { continue }
        }
        return $true
    }
    $false
}

function Search-Catalog {
    param([string]$Query)
    if ($script:CatalogCache.ContainsKey($Query)) { return $script:CatalogCache[$Query] }

    # Retry: the connection drops for a few seconds whenever a network driver is replaced
    for ($attempt = 1; ; $attempt++) {
        try {
            $html = (Invoke-WebRequest -Uri "$CatalogBase/Search.aspx?q=$([uri]::EscapeDataString($Query))" `
                                       -UseBasicParsing -TimeoutSec 60).Content
            break
        } catch {
            if ($attempt -ge 4) { throw }
            Start-Sleep -Seconds 15
        }
    }
    $enUS = [Globalization.CultureInfo]'en-US'
    $results = @(foreach ($row in [regex]::Matches($html, '<tr id="([0-9a-f-]{36})_R\d+".*?</tr>', 'Singleline')) {
        $id = $row.Groups[1].Value
        $cell = @{}
        foreach ($c in [regex]::Matches($row.Value, "id=""${id}_C(\d)_R\d+"">(.*?)</td>", 'Singleline')) {
            $text = [Net.WebUtility]::HtmlDecode(($c.Groups[2].Value -replace '<[^>]+>', ' '))
            $cell[[int]$c.Groups[1].Value] = ($text -replace '\s+', ' ').Trim()
        }
        $version = ConvertTo-DriverVersion $cell[5]
        if (-not $version) { $version = ConvertTo-DriverVersion ($cell[1] -replace '^.*\(', '') }   # "Intel net Driver Update (24.40.0.4)"
        $date = $null
        try { $date = [datetime]::Parse($cell[4], $enUS) } catch {}
        [pscustomobject]@{
            Id       = $id
            Title    = $cell[1]
            Products = $cell[2]
            Class    = $cell[3]
            Date     = $date
            Version  = $version
            Size     = $cell[6] -replace '\s+\d+$', ''   # drop the hidden byte count
        }
    })
    $script:CatalogCache[$Query] = $results
    $results
}

function Wait-ForCatalog {
    # After a network driver install the adapter restarts; wait (up to 2 min) until the catalog answers again
    $deadline = (Get-Date).AddMinutes(2)
    do {
        try { Invoke-WebRequest -Uri $CatalogBase -UseBasicParsing -TimeoutSec 15 -Method Head | Out-Null; return }
        catch { Start-Sleep -Seconds 5 }
    } while ((Get-Date) -lt $deadline)
    Write-Log "    Network is still down 2 minutes after the driver install; continuing anyway." 'WARN'
}

function Install-CatalogDriver {
    param($Update, [string[]]$MatchIds)

    $body = @{ updateIDs = '[{"size":0,"languages":"","uidInfo":"' + $Update.Id + '","updateID":"' + $Update.Id + '"}]' }
    $dialog = (Invoke-WebRequest -Uri "$CatalogBase/DownloadDialog.aspx" -Method Post -Body $body `
                                 -UseBasicParsing -TimeoutSec 60).Content
    $urls = @([regex]::Matches($dialog, "files\[\d+\]\.url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if (-not $urls) { throw "the catalog returned no download link" }

    $work    = Join-Path $env:TEMP "CatalogDrivers\$($Update.Id)"
    $extract = Join-Path $work 'extracted'
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $extract -Force | Out-Null

    foreach ($url in $urls) {
        if ($url -notmatch '^https?://[^/]+\.windowsupdate\.com/') { throw "unexpected download host: $url" }
        $file = Join-Path $work ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
        Write-Log "    Downloading $([IO.Path]::GetFileName($file))"
        Invoke-WebRequest -Uri ($url -replace '^http:', 'https:') -OutFile $file -UseBasicParsing -TimeoutSec 900

        $sig = Get-AuthenticodeSignature -FilePath $file
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "download is not validly signed by Microsoft (signature status: $($sig.Status))"
        }
        $null = & "$env:SystemRoot\System32\expand.exe" $file -F:* $extract
        if ($LASTEXITCODE -ne 0) { throw "expand.exe failed with exit code $LASTEXITCODE" }
    }

    # Only use INFs that are built for this CPU architecture and list this device's hardware ID
    $archTag = @{ AMD64 = 'NTamd64'; ARM64 = 'NTarm64'; x86 = 'NTx86' }[$env:PROCESSOR_ARCHITECTURE]
    $infs = @(Get-ChildItem $extract -Filter *.inf -Recurse | Where-Object {
        $text = Get-Content $_.FullName -Raw
        $text -match $archTag -and @($MatchIds | Where-Object { $text -match [regex]::Escape($_) }).Count
    })
    if (-not $infs) { throw "package has no $archTag .inf that lists $($MatchIds -join ', ')" }

    foreach ($inf in $infs) {
        $out = & "$env:SystemRoot\System32\pnputil.exe" /add-driver $inf.FullName /install 2>&1 | Out-String
        switch ($LASTEXITCODE) {
            0       { Write-Log "    Installed $($inf.Name)" 'OK' }
            3010    { Write-Log "    Installed $($inf.Name) (restart required)" 'OK'; $script:RebootNeeded = $true }
            259     { Write-Log "    $($inf.Name) added to the driver store, but Windows kept the current driver (it ranks higher)." 'WARN' }
            default { Write-Log "    pnputil exit code $LASTEXITCODE for $($inf.Name): $($out.Trim())" 'WARN' }
        }
    }
}

function Update-ViaCatalog {
    $osKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $release = if ($osKey.DisplayVersion) { $osKey.DisplayVersion } else { $osKey.ReleaseId }
    $script:OsIsWin11 = [int]$osKey.CurrentBuild -ge 22000   # ProductName still says "Windows 10" on Windows 11
    $script:OsRelease = ConvertTo-ReleaseNumber $release
    Write-Log ("Catalog: matching drivers for Windows {0} {1} (build {2}, {3})" -f `
               $(if ($script:OsIsWin11) { 11 } else { 10 }), $release, $osKey.CurrentBuild, $env:PROCESSOR_ARCHITECTURE)

    $classes = @('Net', 'System')       # Net = Ethernet/Wi-Fi, System = chipset
    if ($IncludeBluetooth) { $classes += 'Bluetooth' }

    $installed = @{}
    Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceID | ForEach-Object { $installed[$_.DeviceID] = $_ }

    # Physical PCI/USB devices only (skips VPN and virtual adapters). Devices with no driver at all
    # (error code 28) have no class yet, so those are kept and checked by PCI class code below.
    $devices = @(Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -match '^(PCI|USB)\\' -and ($classes -contains $_.Class -or $_.ConfigManagerErrorCode -eq 28)
    } | Sort-Object { $_.Class -eq 'Net' }, Class, FriendlyName)   # network last: its install drops the connection
    Write-Log "Checking $($devices.Count) device(s) against the Microsoft Update Catalog..."

    $handled = @{}   # update ID -> device it was installed for (one package often covers many chipset devices)
    $found = 0
    foreach ($dev in $devices) {
        $props  = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -ErrorAction SilentlyContinue `
                      -KeyName DEVPKEY_Device_HardwareIds, DEVPKEY_Device_CompatibleIds
        $hwIds  = @(($props | Where-Object KeyName -eq 'DEVPKEY_Device_HardwareIds').Data | Where-Object { $_ })
        $allIds = $hwIds + @(($props | Where-Object KeyName -eq 'DEVPKEY_Device_CompatibleIds').Data | Where-Object { $_ })

        # The System class also holds camera, audio, sensor and AI devices, so chipset is narrowed by PCI
        # class code: 05 = shared SRAM, 06 = bridges/root ports/LPC, 0780 = Management Engine,
        # 0C05 = SMBus, 0C80 = Serial IO/SPI, 1180 = platform monitoring/power
        $isChipset = [bool]($allIds -match '&CC_(05|06|0780|0C05|0C80|1180)')
        $isNetwork = [bool]($allIds -match '&CC_02')
        $name = if ($dev.FriendlyName) { $dev.FriendlyName } else { $dev.InstanceId }
        if ($classes -notcontains $dev.Class) {
            if (-not ($isChipset -or $isNetwork)) { continue }   # driverless device that isn't network/chipset
            $name = "$name (no driver installed)"
        } elseif ($dev.Class -eq 'System' -and -not $isChipset) {
            continue
        }

        # Search by the most specific ID (with SUBSYS, the laptop's own board) and by the plain chip ID
        $searchIds = @($hwIds | Where-Object { $_ -match '^(PCI\\VEN_\w{4}&DEV_\w{4}|USB\\VID_\w{4}&PID_\w{4})' } |
                       ForEach-Object { $_ -replace '&(REV|CC)_\w+$', '' } | Select-Object -Unique)
        $chipIds   = @($searchIds | ForEach-Object { if ($_ -match '^(PCI\\VEN_\w{4}&DEV_\w{4}|USB\\VID_\w{4}&PID_\w{4})') { $Matches[1] } } |
                       Select-Object -Unique)
        if (-not $searchIds) { continue }

        $current = if ($installed[$dev.InstanceId]) { ConvertTo-DriverVersion $installed[$dev.InstanceId].DriverVersion }
        $searchFailed = $false
        $results = foreach ($q in $searchIds) {
            try { Search-Catalog $q }
            catch { $searchFailed = $true; Write-Log "  Catalog search failed for ${q}: $($_.Exception.Message)" 'WARN' }
        }
        # Intel chipset INFs carry a placeholder 1968 date on purpose so they never outrank a real driver;
        # Windows always keeps its own built-in driver over them, so offering one there is pointless
        # (Third-party drivers are always renamed oemNN.inf when installed; built-in ones keep their name.)
        $inf = $installed[$dev.InstanceId].InfName
        $usesInbox = $inf -and $inf -notmatch '^oem\d+\.inf$'
        $best = $results |
                Where-Object { $_.Version -and (Test-CatalogProductMatch $_.Products) -and (-not $current -or $_.Version -gt $current) } |
                Where-Object { -not ($usesInbox -and $_.Date -and $_.Date.Year -lt 2000) } |
                Sort-Object Version, Date -Descending | Select-Object -First 1

        $currentText = if ($current) { "$current$(if ($usesInbox) { ', Windows built-in' })" } else { 'none' }
        if (-not $best) {
            if ($searchFailed) { Write-Log "  ? $name [$($chipIds[0])]: could not check, catalog unreachable ($currentText)" 'WARN' }
            else               { Write-Log "  = $name [$($chipIds[0])]: up to date ($currentText)" }
            continue
        }
        $found++
        Write-Log ("  + $name [$($chipIds[0])]: $currentText -> $($best.Version)   " +
                   "($($best.Title), $(if ($best.Date) { $best.Date.ToString('yyyy-MM-dd') }), $($best.Size))") 'OK'
        if ($ListOnly) { continue }

        if ($handled.ContainsKey($best.Id)) {
            Write-Log "    Same package was already installed for '$($handled[$best.Id])'; skipping."
            continue
        }
        # One driver package often covers several devices (e.g. all Serial IO controllers), so an
        # earlier install in this run may already have updated this one
        $wqlId = $dev.InstanceId -replace '\\', '\\' -replace "'", "\'"
        $now = Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceID='$wqlId'" -ErrorAction SilentlyContinue
        $nowVer = if ($now) { ConvertTo-DriverVersion $now.DriverVersion }
        if ($nowVer -and $nowVer -ge $best.Version) {
            Write-Log "    Already updated to $nowVer by an earlier package in this run."
            continue
        }

        $handled[$best.Id] = $name
        try   { Install-CatalogDriver -Update $best -MatchIds $chipIds }
        catch { Write-Log "    Install failed: $($_.Exception.Message)" 'WARN' }
        if ($dev.Class -eq 'Net' -or $isNetwork) { Wait-ForCatalog }
    }

    if ($found -eq 0) { Write-Log "Catalog: all network/chipset drivers are up to date." 'OK' }
    else { Write-Log "Catalog: $found device(s) have a newer driver$(if ($ListOnly) { ' (list only, nothing installed)' })." 'OK' }
}

# ---------------------------------------------------------------- main
if ($Source -eq 'Catalog') {
    Update-ViaCatalog
} else {
    if (-not $SkipVendorTools) {
        try {
            switch -Regex ($make) {
                'Dell'           { Update-Dell }
                'LENOVO'         { Update-Lenovo }
                'HP|Hewlett'     { Update-HP }
                default          { Write-Log "No vendor tool for '$make'; using Windows Update only." }
            }
        } catch {
            Write-Log "Vendor tool step failed: $($_.Exception.Message). Falling back to Windows Update." 'WARN'
        }
    }
    Update-ViaWindowsUpdate
}

Write-Log "Log saved to: $LogFile"
if ($script:RebootNeeded -and -not $ListOnly) {
    if ($Reboot) {
        Write-Log "Rebooting in 60 seconds..." 'WARN'
        shutdown.exe /r /t 60 /c "Restarting to finish driver installation."
    } else {
        Write-Log "A restart is required to finish installing drivers." 'WARN'
    }
}
Write-Log "Done." 'OK'
