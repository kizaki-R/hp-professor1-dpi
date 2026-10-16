# DPI Peek for the HP Professor 1

**English** | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

macOS gets a menu-bar app. Windows gets a tray app whose Start menu name is **HP Professor 1 DPI**.

The mouse is the ROYUAN OEM unit: `3151:4027` on the 2.4 GHz receiver, `3151:4028` on Bluetooth.

## Download

Grab the file for your system from [Releases](https://github.com/kizaki-R/hp-professor1-dpi/releases). The Windows file is `HP-Professor-1-DPI-windows.exe`. Do not look for `DPIPeek.exe`. The name survives only in the Windows install folder `%LOCALAPPDATA%\DPIPeek\` and in some source file names.

| System | File | First launch |
|---|---|---|
| Windows 10 / 11 | `HP-Professor-1-DPI-windows.exe` | Double-click. It copies itself to `%LOCALAPPDATA%\DPIPeek\`, then adds a startup shortcut and a Start menu entry for the current user. No admin prompt. |
| macOS 11+ | `HP-Professor-1-DPI-macOS.dmg` (or the `.zip`) | Open the dmg and drag **HP Professor 1 DPI** into Applications, then right-click the app and choose Open the first time. |

The Windows build is unsigned. SmartScreen shows only "Don't run" until you click "More info", then "Run anyway". That choice sticks on that PC.

The Windows UI follows the Windows display language. Right-click the tray icon to switch among Traditional Chinese, Simplified Chinese, and English. Click-to-switch works on 2.4 GHz only. Bluetooth can show the overlay when you press the mouse DPI button; the firmware does not take write commands.

The full brand pack lives in `assets/logo/velocity/`, with the Mac build taking its icns and MenuBar templates from there.

The Windows bars are redrawn from the VELOCITY SVG coordinates rather than traced by eye: seven ascending bars, pitch 44, width 29, a constant 0.24 slant. Mac and Windows therefore render the same shape, with the same three-state palette — `#39D5FF` for the active stage, `#F3F7FF` for earlier ones, `#3B4658` for later ones. The tray icon in `windows/dpi-peek/assets/DPIPeek.ico` is generated from those same numbers.

Pressing the physical DPI button shows an on-screen overlay with the active stage and exact hardware DPI. When connected through the 2.4 GHz USB receiver, you can also change DPI stages directly from the menu-bar popover.

Values are read straight from the vendor HID feature report, not calculated from cursor movement.

---

## The Problem

Operating systems receive relative displacement counts from mice, not physical sensor resolutions. macOS has no native way to know what DPI a mouse is running at. The HP Professor 1 mouse ships with no Mac software, giving users no visual feedback when switching stages.

Reverse engineering the mouse revealed two separate communication channels:

| Mode | HID Interface | Behaviour |
|---|---|---|
| **2.4 GHz Dongle / Wired** | usage page `0xFFFF` / usage `0x0002`<br>64-byte feature report | **Full Vendor Protocol**: opcode `0xD4` returns the factory DPI table and active index; opcode `0x54` writes active stages directly to sensor registers. |
| **Bluetooth (BLE)** | usage page `0xFF55` / usage `0x0202`<br>Report ID 6, 65 bytes | **Unidirectional Notifications**: emits `66 0C <stage>` on physical button presses. The BLE firmware ignores host-initiated output reports. |

Factory preset table discovered on the sensor:

| Stage | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| **DPI** | **800** | **1000** | **1200** | **1600** | **2400** | **3200** | **4000** |

Protocol internals (checksum byte formula, receiver relay sequence, opcode tables, and packet timing) are documented in [docs/VENDOR-API.md](docs/VENDOR-API.md).

---

## Features

- **Translucent HUD Overlay**: Displays current status (e.g. `3200 DPI  Stage 6 / 7`) on button press, fading out after 1.5 seconds without taking keyboard focus.
- **Menu-bar Attached Popover**:
  - Anchored directly under the `DPI` icon. Dismisses when clicking outside; `Esc` closes it.
  - **Click-to-Switch (2.4 GHz)**: Click any stage pill (`800` through `4000`) in the panel to update sensor resolution immediately via vendor opcode `0x54`.
  - **Dynamic Connection Tracking**: Handles USB dongle hotplugging and bottom switch toggles, automatically switching between `2.4G` and `Bluetooth` modes.
- **Theme Selection**:
  - `💻 Auto` (inherits macOS appearance), `☀️ Light`, and `🌙 Dark`. Built with frosted glass (`NSVisualEffectMaterialPopover`) and system typography to avoid washed-out text.
- **Battery Read-out**:
  - The panel and the menu-bar icon show the mouse's remaining charge, swapping to 🪫 below 20%. The 2.4 GHz channel reads it from the vendor protocol; Bluetooth reads it over BLE GATT (`0x180F`).
- **Interface Language**:
  - Traditional Chinese, Simplified Chinese, and English, switchable inside the panel and remembered across launches.
- **App Nap Prevention**:
  - Bundles `NSAppSleepDisabled` and `NSProcessInfo` activity assertions so background polling is not throttled when the popover is closed.
- **Diagnostic CLI Tools**:
  - `probe`: Raw HID packet monitoring, report descriptor dumping, and physical sensor distance calibration.
  - `royuan`: Protocol inspector with auto-detection for compatible mice (`./royuan auto`).

The Windows build lives in `windows/dpi-peek/` and does the same job from the system tray:

- **Tray Icon**: Seven VELOCITY bars, recoloured to the current stage.
- **Panel from the Taskbar**: Left-click the tray icon for the stage list. Chips switch DPI directly over 2.4 GHz. Right-click for language, launch-at-login, and Quit.
- **Link Status and Battery**: The panel reads `2.4G`, `Bluetooth`, `2.4G asleep`, or `Offline` and shows a percentage. Battery comes over the 2.4 GHz relay only; Bluetooth does not expose it.
- **Overlay at the Top Centre**: Pressing the mouse's DPI button shows the stage and exact DPI. On Bluetooth this is the only live signal, since the firmware ignores host writes.
- **Three Languages**: Follows the Windows display language; the tray menu overrides it.

---

## Supported Hardware

| Hardware | Status | Notes |
|---|---|---|
| **HP Professor 1** (`3151:4027` 2.4G, `3151:4028` BLE) | **Verified** | Tested on physical hardware. |
| ROYUAN / Compx vendor mice (64-byte feature reports) | Experimental | Run `./royuan auto` to probe compatibility. |
| Other vendors (Logitech HID++, Razer, Sinowealth `258A`) | Unsupported | Use different vendor-specific protocols. |

*Safety note: This utility only issues read and stage-switching opcodes. It does not send flash erase or sensor calibration commands (`0xAC`, `0x1C/0x1E`, `0x7F`).*

---

## Installation

### Option A: Build from Source (Recommended)

Requires macOS 11+ and Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

```sh
git clone https://github.com/kizaki-R/hp-professor1-dpi.git
cd hp-professor1-dpi
./make-identity.sh      # Creates a local signing certificate (keeps TCC permissions valid across builds)
./build.sh              # Builds HP Professor 1 DPI.app, probe, and royuan
./install.sh            # Installs to /Applications and opens the app
```

After installing, go to **System Settings → Privacy & Security → Input Monitoring** and enable **HP Professor 1 DPI**. macOS requires explicit user approval before an app can read raw HID streams.

For the Windows app, install a Rust toolchain and build it in place:

```sh
cd windows/dpi-peek
cargo build --release
python stamp_resources.py target/release/dpi-peek.exe HP-Professor-1-DPI-windows.exe
```

The stamp step attaches the icon and version info through the Windows SDK's `rc.exe`. Without that tool it copies the binary through unchanged, so `cargo build` alone stays usable. More in [windows/dpi-peek/README.md](windows/dpi-peek/README.md).

### Option B: Download Release Binary

1. Grab `HP-Professor-1-DPI-macOS.dmg` (or the `.zip`) from [Releases](https://github.com/kizaki-R/hp-professor1-dpi/releases).
2. Open the dmg and drag **HP Professor 1 DPI** into `/Applications`. The zip works too: unzip it and copy the app across.
3. On first run, **right-click → Open** (needed because this binary is self-signed rather than notarized through a paid Apple Developer account).
4. Enable Input Monitoring in System Settings.

---

## Usage

1. **Hardware Button**: Press the DPI button behind the scroll wheel. The HUD pops up over the active display.
2. **Menu-bar Panel**:
   - Left-click the `DPI` icon to open the controls.
   - Right-click the icon for quick actions (Test HUD, Appearance theme, Privacy settings, Quit).
3. **Switching DPI via Software**:
   - In 2.4 GHz mode, click any stage pill (`800`–`4000`) to change sensor speed on the mouse.
   - In Bluetooth mode, clicking a stage pill pops a notice telling you to use the mouse's physical DPI button; the firmware does not accept host writes.
4. **Launch at Login**: To keep it running in the background, add **HP Professor 1 DPI** under **System Settings → General → Login Items**.

---

## Repository Layout

```text
src/HIDWatcher.{h,m}    IOKit HID monitoring, hotplug callbacks, BLE input stream
src/DPIMapper.{h,m}     Stage-to-DPI mappings, persistence, HUD string formatting
src/VendorChannel.{h,m} 2.4 GHz feature channel: relay handshake, 0xD4 read, 0x54 write, link tracking
src/DPIPeek.m           Menu-bar popover, HUD panel, theme rendering, selftest runner
src/probe.m             CLI diagnostic: descriptor dumper, packet streamer, distance calibration
src/royuan.m            CLI tool: generic device discovery, vendor register operations
build.sh                Compile, assemble .app bundle, and sign
make-identity.sh        Generate persistent local self-signed certificate
make-release.sh         Package release archives
windows/dpi-peek/       Windows tray app: Rust + Win32, no GUI framework
```

Verification commands:

```sh
./HP\ Professor\ 1\ DPI.app/Contents/MacOS/HPProfessor1DPI --selftest   # Runs 12 automated test assertions
./royuan auto                                     # Generic device discovery probe
./royuan status                                   # Check receiver health, battery, and relay status
./probe list                                      # Dump raw HID report descriptors
```

---

## Troubleshooting

| Issue | Resolution |
|---|---|
| Permission shows "Denied" | Open **System Settings → Privacy & Security → Input Monitoring** and toggle HP Professor 1 DPI on. If duplicate entries appear, remove the old one with `-` and re-add. |
| Clicking stage buttons does not change speed in Bluetooth | The mouse Bluetooth firmware operates strictly as a one-way broadcaster and drops host-sent write reports. Plug in the 2.4 GHz USB receiver to enable software switching. |
| Permission reset after rebuild | Run `./make-identity.sh` once. A consistent local signing identity keeps TCC permissions intact across rebuilds. |
| Status shows "2.4G Vendor Channel Offline" | If the mouse switched to Bluetooth or entered sleep mode, the receiver relay stops answering. Move the mouse to wake it up. |

---

## Acknowledgements

- Vendor communication conventions (`0xFFFF` usage page, byte 7 checksum format, `GET = SET | 0x80`, and receiver relay handshake) were confirmed using reference notes from [dniminenn/sharkfin](https://github.com/dniminenn/sharkfin).

---

## License

[MIT License](LICENSE) © KizakiWorks
