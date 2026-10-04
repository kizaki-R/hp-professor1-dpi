# DPI Peek: macOS DPI HUD & Controller for HP Professor 1

**English** | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

---

A native macOS menu-bar utility and on-screen HUD for the **HP Professor 1** wireless mouse (`3151:4027` 2.4 GHz receiver / `3151:4028` Bluetooth).

Whenever you press the physical DPI button, a translucent HUD appears at the top of your screen showing the active level and real hardware DPI. When connected via the 2.4 GHz USB receiver, you can also switch DPI stages directly by clicking buttons in the menu-bar panel.

Values are read directly from the vendor HID feature channel, not estimated.

---

## Why this exists

DPI measures the optical sensor's physical resolution. The operating system receives only raw relative displacement counts, so macOS has no native way of knowing your mouse's hardware DPI. The HP Professor 1 mouse lacks official Mac software, leaving users with no on-screen indication when cycling through DPI stages.

This project reverse-engineered both communication channels exposed by the mouse hardware:

| Mode | HID Interface | Capabilities |
|---|---|---|
| **2.4 GHz Receiver / Wired** | usage page `0xFFFF` / usage `0x0002`<br>64-byte feature report | **Full Vendor API**: reads the hardware DPI table via opcode `0xD4`; actively switches sensor resolution via opcode `0x54`. |
| **Bluetooth (BLE)** | usage page `0xFF55` / usage `0x0202`<br>Report ID 6, 65 bytes | **Event-driven Notifications**: emits `66 0C <stage>` on every DPI button click; unidirectional broadcast from mouse firmware. |

The factory DPI stages discovered on the device:

| Stage | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| **DPI** | **800** | **1000** | **1200** | **1600** | **2400** | **3200** | **4000** |

Complete protocol details (checksum algorithm, receiver relay sequence, opcode tables, packet layouts, and edge cases) are documented in [docs/VENDOR-API.md](docs/VENDOR-API.md).

---

## Features

- **Non-intrusive Overlay HUD**: Displays the current level (e.g. `3200 DPI  Stage 6 / 7`) on button press, fading out smoothly after 1.5 seconds without stealing window focus.
- **Menu-bar Attached Popover**:
  - Drops down directly beneath the menu-bar `DPI` icon. Auto-dismisses on click-outside, with `Esc` key support and a `📌 Pin` toggle to keep it open during measurement.
  - **One-click DPI Switching (2.4 GHz mode)**: Click any stage pill (`800` through `4000`) in the panel to instruct the mouse hardware to update its optical sensor resolution immediately.
  - **Dynamic Link Detection**: Detects USB receiver hotplugging and bottom switch toggles, transitioning between `2.4G` and `Bluetooth` modes automatically.
- **Native Appearance Customization**:
  - Supports `💻 Auto` (system appearance), `☀️ Light`, and `🌙 Dark` modes. Rendered with native frosted glass (`NSVisualEffectMaterialPopover`) and high-contrast semantic typography.
- **Power & App Nap Hardening**:
  - Configured with `NSAppSleepDisabled` and `NSProcessInfo` activity assertions to prevent macOS from throttling background polling when windows are hidden.
- **Bundled Diagnostic CLIs**:
  - `probe`: Raw HID packet monitoring, report descriptor inspection, and physical sensor distance measurement.
  - `royuan`: Protocol explorer with generic device discovery (`./royuan auto`).

---

## Hardware Support

| Device | Support Status | Notes |
|---|---|---|
| **HP Professor 1** (`3151:4027` 2.4G, `3151:4028` BLE) | **Fully Supported** | Verified against physical hardware. |
| Other ROYUAN / Compx vendor devices (64-byte feature report) | Experimental | Run `./royuan auto` to probe compatibility. |
| Other vendors (Logitech HID++, Razer, Sinowealth `258A`, etc.) | Unsupported | Requires vendor-specific protocol implementations. |

*Note: This software uses only non-destructive read and level-switching opcodes. It avoids flash erase and sensor calibration commands (`0xAC`, `0x1C/0x1E`, `0x7F`).*

---

## Installation

### Method A: Build from Source (Recommended)

Requires macOS 11+ and Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```sh
git clone https://github.com/kizaki-R/hp-professor1-dpi.git
cd hp-professor1-dpi
./make-identity.sh      # Creates a local code-signing identity (persists TCC permissions across builds)
./build.sh              # Compiles DPIPeek.app, probe, and royuan
./install.sh            # Installs to /Applications and launches
```

After installation, navigate to **System Settings → Privacy & Security → Input Monitoring** and toggle **DPIPeek** on. macOS requires explicit user authorization to read raw HID inputs; the app begins monitoring as soon as permission is granted.

### Method B: Download Pre-built Release

1. Download the latest `DPIPeek-*.zip` from [Releases](https://github.com/kizaki-R/hp-professor1-dpi/releases).
2. Extract the archive and move `DPIPeek.app` to `/Applications`.
3. On first launch, **right-click → Open** (required because this open-source build is not notarized with a commercial Apple Developer account).
4. Grant Input Monitoring access in System Settings when prompted.

---

## Usage

1. **Physical Button**: Press the DPI button behind the scroll wheel. The HUD pops up at the top of the active display.
2. **Menu-bar Panel**:
   - Left-click the `DPI` menu-bar icon to open or close the control popover.
   - Right-click the icon for a quick context menu (Test HUD, Theme selector, Privacy settings, Quit).
3. **Software DPI Switching**:
   - When connected via the 2.4 GHz USB receiver, click any stage button (`800` to `4000`) to switch the hardware DPI instantly.
   - When in Bluetooth mode, stage buttons serve as active status indicators (Bluetooth firmware does not accept host-initiated sensor writes).
4. **Launch at Login**: To run automatically in the background, add `DPIPeek` under **System Settings → General → Login Items**.

---

## Project Structure

```text
src/HIDWatcher.{h,m}    Low-level HID device monitoring, hotplug lifecycle, BLE input reports
src/DPIMapper.{h,m}     DPI stage mapping, user presets, HUD title formatting
src/VendorChannel.{h,m} Vendor feature transport: relay handshake, 0xD4 read, 0x54 write, link detection
src/DPIPeek.m           Menu-bar popover UI, HUD window, theme rendering, unit test runner
src/probe.m             Diagnostic CLI: descriptor dumper, live report streaming, physical ruler measurement
src/royuan.m            ROYUAN protocol CLI: device scanner, register read/write
build.sh                Compilation, app assembly, and code-signing script
make-identity.sh        Creates a persistent local code-signing certificate
make-release.sh         Packages release zip archives
```

Validation commands:

```sh
./DPIPeek.app/Contents/MacOS/DPIPeek --selftest   # Runs 12 automated test assertions
./royuan auto                                     # Generic device discovery probe
./royuan status                                   # Checks 2.4G receiver status, battery, and relay health
./probe list                                      # Dumps complete HID report descriptors
```

---

## Troubleshooting

| Symptom | Cause / Resolution |
|---|---|
| Permission shows "Denied" | Open **System Settings → Privacy & Security → Input Monitoring** and enable DPIPeek. If duplicate entries appear, remove the old one with `-` and re-add. |
| Cannot switch DPI by clicking in Bluetooth mode | The mouse's Bluetooth firmware operates as a one-way notification channel and rejects host write commands. Connect via the 2.4 GHz USB receiver to enable software switching. |
| Permission lost after recompilation | Run `./make-identity.sh` once. Rebuilding with the stable local signing identity preserves TCC permission grants across builds. |
| Status shows "2.4G Vendor Channel Offline" | If the mouse switched to Bluetooth or entered sleep mode, the receiver relay goes offline. Move the mouse to wake it, or toggle the connection switch. |

---

## Acknowledgements

- Protocol mechanics for the ROYUAN family (`0xFFFF` vendor usage page, checksum format, `GET = SET | 0x80` convention, receiver relay handshake) were referenced from [dniminenn/sharkfin](https://github.com/dniminenn/sharkfin) and verified on this hardware.

---

## License

[MIT License](LICENSE) © KizakiWorks
