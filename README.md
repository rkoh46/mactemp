# MacTemp

A lightweight macOS menu bar monitor for Apple Silicon Macs: live **CPU / GPU / SSD temperatures**, **RAM**, **swap**, **CPU load**, and **disk space** — with history graphs, no dependencies, and no sudo.

![MacTemp menu bar](assets/mactemp-bar.png)

## Features

- **Temps, RAM, swap, CPU load, disk** in your menu bar, refreshed every 2 s
- **Color-coded**: temps turn **yellow** ≥ 60 °C and **red** ≥ 80 °C; RAM/CPU/disk rows color on pressure, load, and free-space thresholds
- **History graphs** in the dropdown menu: 3-minute temperature and memory/swap sparklines
- **°C / °F toggle** and 3 menu-bar layouts (temps only / temps + RAM / compact)
- **No dependencies** — pure Swift + a small C helper, built with `swiftc`, no SPM/Xcode project
- **No sudo, no helper daemon** — reads SMC + IOHID + Mach VM stats directly

| Menu dropdown with live graphs |
|---|
| ![MacTemp dropdown](assets/mactemp-menu.png) |

## What's monitored

| Metric | Source |
|--------|--------|
| CPU temp | SMC — average of all `Tp*`, `Te*`, `Ts*` keys |
| GPU temp | SMC — average of all `Tg*` keys |
| SSD temp | IOHID — `NAND CH0` NVMe temperature sensor |
| RAM used | Mach `host_statistics64` (active + inactive + wired + compressed, like Activity Monitor) |
| Swap | `sysctl vm.swapusage` (`xsw_usage`) |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` |
| CPU load | Per-core `PROCESSOR_CPU_LOAD_INFO` tick deltas |
| Disk free | `statfs("/")` |

## Install

Download `MacTemp.dmg` from the [latest release](../../releases/latest), open it, and drag MacTemp to Applications. The app is ad-hoc signed (not notarized), so on first launch right-click → Open (or `xattr -d com.apple.quarantine /Applications/MacTemp.app`).

Or build from source:

```bash
git clone https://github.com/rkoh46/mactemp && cd mactemp
./build.sh install    # builds and installs to /Applications
./build.sh run        # or: build + launch locally
```

Requires Xcode Command Line Tools (`swiftc` + `clang`).

## Building a release DMG

```bash
./release.sh          # builds MacTemp.app and writes dist/MacTemp.dmg
```

## Platform notes

- Tested on: Mac Studio (Mac17,15), macOS Sequoia
- Supported (untested): Apple Silicon Macs that expose SMC temperature keys (M1 and later)
- Intel Macs are not supported (different SMC keys; SMC reads require root there)
- The NVMe sensor is found via the HID event system on usage page `0xFF00` (product name contains "NAND")

## Architecture

- **main.swift** — SMC client (`IOServiceOpen("AppleSMC")`), Mach/sysctl samplers, `NSStatusItem` UI, colored menu rows, history graphs
- **hid_temp.c** → `libhidtemp.dylib` — IOHID reader for the NVMe NAND temperature sensor
- **hidtemp.h** — Swift bridging header for the IOHID library
- **icon_draw.swift** — generates the app icon programmatically (→ `MacTemp.icns`)
- **tools/click_status.swift** — QA helper that clicks the status item via the Accessibility API

## Credits

Thermal key enumeration strategy adapted from [vladkens/macmon](https://github.com/vladkens/macmon).
SMC protocol layout from [exelban/stats](https://github.com/exelban/stats).

## License

MIT
