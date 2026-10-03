# driver-update

Finds and installs the latest **network** (Wi-Fi, Ethernet) and **chipset** drivers on a Windows 10/11 laptop.

## Quick start

Open PowerShell on the laptop and run:

```powershell
irm fassysam.github.io/driver-update | iex
```

It asks for administrator rights, then updates the drivers. Logs are saved in `C:\ProgramData\DriverUpdate`.

To preview without installing anything:

```powershell
& ([scriptblock]::Create((irm fassysam.github.io/driver-update))) -ListOnly
```

## How it finds drivers

**`-Source Catalog` (default with `run.ps1`)** looks up each device by its hardware ID (for example `PCI\VEN_8086&DEV_51F1` for an Intel Wi-Fi card) in the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com), where Intel, Realtek, AMD and others publish their drivers. For each device it picks the newest driver that:

- fits this Windows version and CPU architecture,
- is newer than the installed driver,
- is signed by Microsoft and lists the device's exact hardware ID.

Only network devices and true chipset devices (bridges, LPC, SMBus, SPI, Serial IO, Management Engine, platform monitoring) are touched. Camera, audio, sensor and VPN/virtual adapters are skipped.

**`-Source Auto`** uses the laptop maker's own tool (Dell Command | Update, Lenovo `LSUClient`, HP `HPCMSL`) plus Windows Update.

## Options

| Option | What it does |
|---|---|
| `-Source Catalog` / `-Source Auto` | Where drivers come from (see above) |
| `-ListOnly` | Show what would be installed; change nothing |
| `-IncludeBluetooth` | Also update Bluetooth drivers |
| `-Reboot` | Restart automatically if a driver needs it |
| `-SkipVendorTools` | With `-Source Auto`: Windows Update only |

A system restore point is created before anything is installed.

## Offline / USB use

Copy `Update-NetworkChipsetDrivers.ps1` together with `Update-Drivers-Catalog.cmd` (catalog mode) or `Run-DriverUpdate.bat` (auto mode) to any folder or USB stick and double-click the `.cmd`/`.bat`.
