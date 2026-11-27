# ScreenShot

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows 10 | 11" />
  <img src="https://img.shields.io/badge/Swift-5.9-FA7343?style=for-the-badge&logo=swift&logoColor=white" alt="Swift" />
  <img src="https://img.shields.io/badge/C%23-.NET%2010-512BD4?style=for-the-badge&logo=dotnet&logoColor=white" alt=".NET 10" />
  <img src="https://img.shields.io/badge/License-MIT-2EA44F?style=for-the-badge" alt="MIT" />
</p>

<p align="center">
  A tiny, fast region-screenshot tool for <b>macOS</b> and <b>Windows</b>. Press <b>F4</b>, drag a box, optionally mark it up, hit <b>Enter</b>, and it's on your clipboard <i>and</i> saved to <code>Desktop/ScreenShot Captures</code>.
</p>

## Download

Grab the latest build from **[Releases](../../releases/latest)**:

| Platform | File | First run |
| --- | --- | --- |
| macOS 14+ (Apple Silicon & Intel) | `ScreenShot-macOS-*.zip` | Unzip, move to Applications. It's not notarized, so right-click → **Open** the first time (or `xattr -cr /Applications/ScreenShot.app`), then allow **Screen Recording**. |
| Windows 10/11 x64 | `ScreenShot-Windows-x64-*.zip` | Unzip and run `ScreenShot.exe`. No installer or .NET needed. If SmartScreen warns, click **More info → Run anyway**. |

## Features

- **Global hotkey:** F4 on both platforms. macOS also takes ⌃P / ⌘P; Windows also takes Ctrl+P, and PrtSc when Windows isn't using it.
- **Drag to select** with the rest of every display dimmed and a live `W × H` badge.
- **Pixel-perfect capture:** ScreenCaptureKit on macOS, Per-Monitor-V2 DPI-aware GDI capture on Windows. No resampling or blur on HiDPI screens.
- **Annotation toolbar** under the selection:
  - Select / move / resize (V)
  - Arrow (A)
  - Rectangle (R)
  - Focus dim (F): darkens everything except the area you drag
  - Undo (⌘Z / Ctrl+Z)
- **Copy text (OCR)** from the selected region, using Apple Vision on macOS and `Windows.Media.Ocr` on Windows. Everything runs on-device.
- **Timed capture:** a 5-second countdown with the live screen visible so you can open menus or hover states first.
- **Auto-save** every capture to `Desktop/ScreenShot Captures/Screenshot YYYY-MM-DD at HH.MM.SS.png`.
- **Recent captures flyout** from the menu-bar / tray icon:
  - 3-column thumbnail grid
  - Hover to copy or delete
  - Double-click to open
  - Drag a thumbnail out as a file
- **Launch at login** toggle in the icon's right-click menu.

## Keyboard

| Key | Action |
| --- | --- |
| **F4** (also ⌃P / ⌘P on Mac, Ctrl+P on Windows) | Start a region capture |
| Drag | Select the region |
| **Enter** / **⌘C** / **Ctrl+C** | Copy + save |
| **V / A / R / F** | Select / Arrow / Rectangle / Focus-dim tool |
| **⌘Z** / **Ctrl+Z** | Undo the last annotation |
| **Delete** | Remove the selected annotation |
| **Esc** | Cancel (or cancel the countdown) |

## Build from source

### macOS

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./install.sh            # build, install to /Applications, launch
# or just build:
./build.sh              # → build/ScreenShot.app
UNIVERSAL=1 ./build.sh  # arm64 + x86_64
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

Builds a single self-contained `ScreenShot.exe` into `%LOCALAPPDATA%\Programs\ScreenShot`, adds a Start Menu shortcut, turns on launch at login and starts it. If no .NET SDK is found, it installs one locally for your user first; no admin rights are needed.

### Releases

Push a tag such as `v1.0.0` (or run the **Release** workflow manually). GitHub Actions builds the universal macOS app and the Windows exe and attaches both to a GitHub Release.

## Project layout

| Path | What |
| --- | --- |
| `ScreenShot/` | macOS app: SwiftUI + AppKit, ScreenCaptureKit, Carbon hotkeys, Vision OCR |
| `windows/src/` | Windows app: C# WinForms, `RegisterHotKey`, layered windows, Windows.Media.Ocr |
| `tools/` | macOS icon generator and OCR tests |
| `.github/workflows/release.yml` | CI release build for both platforms |

## Privacy

Nothing leaves your machine. Captures go to your clipboard and Desktop folder, and OCR runs locally. On macOS, verbose debug logging (which can include OCR'd text) is off unless you launch with `SCREENSHOT_DEBUG=1`.

## License

MIT
