# MacTemp

A lightweight macOS menu bar temperature monitor for Apple Silicon Macs (M1/M2/M3/M4).

Displays live CPU, GPU, and SSD temperatures in your menu bar, updated every 2 seconds.

## Features

- **No dependencies** — pure Swift + small C helper, no SPM/Xcode project
- **No sudo required** — reads SMC temperature keys directly
- **Accurate** — uses all available thermal sensors per component (macmon-style)
- **Live sparklines** — 3-minute history of CPU/GPU/SSD temps in the menu
- **Celsius/Fahrenheit toggle** — persistent via UserDefaults
- **LSUIElement** — menu bar only, no Dock icon

## What's monitored

| Component | Source | Keys |
|-----------|--------|------|
| CPU | SMC (AppleSMC) | Average of `Tp*`, `Te*`, `Ts*` keys |
| GPU | SMC (AppleSMC) | Average of all `Tg*` keys |
| SSD | IOHID | `AppleEmbeddedNVMeTemperatureSensor` via `IOHIDEventSystemClient` |

## Building

```bash
./build.sh          # build MacTemp.app in this directory
./build.sh install  # build and copy to /Applications/
./build.sh run      # build and launch
./build.sh quit     # stop the running app
```

Requires Xcode Command Line Tools (`swiftc` and `clang`).

## Architecture

- **main.swift** — SMC client (in-process `IOServiceOpen("AppleSMC")`) + NSStatusItem UI + sparkline
- **hid_temp.c** — IOHID reader for NVMe SSD temperature (built as `libhidtemp.dylib`)
- **hidtemp.h** — Swift bridging header for the IOHID library
- **MacTemp.icns** — generated app icon (thermometer)

## Platform notes

- Verified on: Mac Studio (M5 Ultra, Mac17,15), macOS Sequoia (15.x)
- Works on any Apple Silicon Mac that exposes SMC temperature keys (M1 and later)
- The NVMe temperature sensor is found via HID event system page `0xFF00` (product name contains "NAND")

## Credits

Thermal key enumeration strategy adapted from [vladkens/macmon](https://github.com/vladkens/macmon).
SMC protocol layout from [exelban/stats](https://github.com/exelban/stats).

## License

MIT
