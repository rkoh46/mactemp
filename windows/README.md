# MacTemp for Windows 11

Menu bar (system tray) temperature + load monitor — the Windows counterpart of MacTemp.

- CPU / GPU temperature via **LibreHardwareMonitor** (kernel sensor driver — the app
  manifest requests administrator, so UAC prompts once on launch)
- Fallback to WMI ACPI thermal zones (`root\WMI`, `MSAcpi_ThermalZoneTemperature`)
  when LibreHardwareMonitor exposes no CPU temperature sensor
- CPU load + RAM usage, live in the tray menu
- "Run at login" toggle (HKCU `...\CurrentVersion\Run`)
- No fan control on Windows: unlike AppleSMC on Apple Silicon, fan control is
  vendor-specific and out of scope. This is a monitor only.

## Run

Unzip `MacTempWin.zip`, run `MacTempWin.exe` (UAC prompt). Self-contained —
no .NET runtime needed on the target machine. Icon lives in the tray;
click it for CPU/GPU temps and load.

## Build

From Windows (`build.cmd`) or from the Mac (cross-compiles via
`EnableWindowsTargeting`):

```
dotnet publish MacTempWin.csproj -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true -o ../dist/win
```

Requires .NET 8 SDK. Built and compile-verified on macOS (arm64 host →
win-x64 target); first real execution test happens on actual Windows hardware.
