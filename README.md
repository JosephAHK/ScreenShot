# ScreenShot

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-FA7343?style=for-the-badge&logo=swift&logoColor=white" alt="Swift" />
  <img src="https://img.shields.io/badge/SwiftUI-Popover%20%2B%20Hosting-007AFF?style=for-the-badge&logo=swift&logoColor=white" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/AppKit-NSStatusItem%20%2B%20NSPopover-1E88E5?style=for-the-badge&logo=apple&logoColor=white" alt="AppKit" />
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS" />
  <img src="https://img.shields.io/badge/ScreenCaptureKit-Pixel%20Perfect%20Region-FF6F00?style=for-the-badge&logo=apple&logoColor=white" alt="ScreenCaptureKit" />
  <img src="https://img.shields.io/badge/Carbon-Global%20Hotkey%20F4-555555?style=for-the-badge&logo=apple&logoColor=white" alt="Carbon" />
  <img src="https://img.shields.io/badge/ServiceManagement-Launch%20at%20Login-34C759?style=for-the-badge&logo=apple&logoColor=white" alt="ServiceManagement" />
  <img src="https://img.shields.io/badge/CoreGraphics-Bitmap%20Compositing-9333EA?style=for-the-badge" alt="CoreGraphics" />
  <img src="https://img.shields.io/badge/License-MIT-2EA44F?style=for-the-badge" alt="License" />
</p>

<p align="center">
  Press <b>F4</b> anywhere on macOS to dim the screen, drag-select a region, optionally annotate it with arrows or rectangles, then hit <b>↵</b> or <b>⌘C</b> to copy it to the clipboard <i>and</i> save it to <code>~/Desktop/ScreenShot Captures/</code>.
</p>

## Features

- **Global F4 hotkey** via Carbon `RegisterEventHotKey` (no Accessibility permission required).
- **Drag-to-select with live dim cutout** — the rest of every display fades to ~55 % black while the selection rectangle stays bright, with a `W × H` badge near it.
- **Pixel-perfect capture** via `ScreenCaptureKit` (`SCScreenshotManager` + `sourceRect`). The selection is snapped to the display's physical pixel grid so the captured bitmap is byte-identical 1:1 to what was on screen — no resampling, no half-pixel blur on Retina.
- **In-overlay annotation toolbar** appears under the selection after mouse-up — Arrow, Rectangle, Undo (⌘Z), Copy, **Timed capture (5s)**. Annotations are composited onto the screenshot in a `CGBitmapContext` at native pixel density before clipboard / save.
- **Timed capture** — tap the timer button to count down from 5 under the selection (mouse passes through the bright cutout so you can hover menus); then capture runs like an instant copy.
- **Auto-save** to `~/Desktop/ScreenShot Captures/Screenshot YYYY-MM-DD at HH.MM.SS.png` on every copy.
- **Menu bar flyout** (left-click the camera icon) — `NSPopover` hosting a SwiftUI 3-column 1:1 grid of every screenshot in the folder, sorted newest-first. Hover a thumb to reveal Copy / Open-in-Preview buttons; clicking Copy plays a Tink and shows a spring-animated "Copied" check overlay.
- **Right-click status item menu** — Capture, Open Captures Folder, Launch at Login toggle (`SMAppService.mainApp.register()`), Quit.
- **Multi-display aware**: dim overlays span every `NSScreen`; selections that cross displays are clipped to the display containing the midpoint.
- **Action sound** — `Glass` system sound on successful capture, Tink on thumb copy, `NSSound.beep()` on failure.

## Architecture

| File | Role |
| --- | --- |
| `ScreenShotApp.swift` | `@main` SwiftUI app + `AppDelegate` wiring; pre-prompts Screen Recording on launch. |
| `HotkeyManager.swift` | Carbon `RegisterEventHotKey` for `kVK_F4`, no modifiers. |
| `StatusBarController.swift` | `NSStatusItem` + `NSPopover`; SwiftUI `CapturesPopoverView` / `ThumbView` / `HoverIconButton`; `LaunchAtLogin` wrapper around `SMAppService`. |
| `SelectionOverlayController.swift` | Per-screen borderless `OverlayWindow` (`canBecomeKey = true`) at `.screenSaver` level. `SelectionView` draws the dim + cutout, runs the selection / annotation state machine, hosts the SwiftUI `AnnotationToolbar` via `NSHostingView`. Final image is composited from the captured `CGImage` + annotations in a `CGBitmapContext`. |
| `ScreenCapture.swift` | Maps a global AppKit rect to the right `SCDisplay`, snaps to the pixel grid, configures `SCStreamConfiguration` (`sourceRect`, exact pixel `width`/`height`, `scalesToFit = false`, `captureResolution = .best`, Display P3). |
| `CapturesStore.swift` | `ObservableObject` listing `.png`/`.jpg` files in `~/Desktop/ScreenShot Captures/`, sorted by modification date; PNG encode from `NSBitmapImageRep`. |

## Build & run

```bash
chmod +x build.sh install.sh
./build.sh
open build/ScreenShot.app
```

## Install to /Applications

```bash
./install.sh
```

`install.sh` builds, kills any running instance, runs `tccutil reset ScreenCapture com.screenshot.app` for a clean permission prompt, `ditto`s to `/Applications/ScreenShot.app` (falls back to `~/Applications`), removes any stale duplicate in the other location, then opens it.

## Keyboard

| Key | Action |
| --- | --- |
| **F4** | Begin region selection |
| Drag | Define the region (kept bright, rest dimmed) |
| **↵ / ⌘C** | Capture, annotate-composite, copy + save |
| **Timer (toolbar)** | 5-second countdown, then capture (hover inside selection during countdown) |
| **A / R** | Arrow / Rectangle annotation tool (with selection) |
| **⌘Z** | Undo last annotation |
| **Esc** | Cancel countdown if active; otherwise cancel overlay |

## Permissions

On first capture you'll be prompted for **Screen Recording** under System Settings → Privacy & Security → Screen Recording. No Accessibility permission is required.

## Icon

The app icon is generated from an SF Symbol via [`tools/make-icon.swift`](tools/make-icon.swift) (camera.viewfinder on an orange→red gradient squircle):

```bash
swift tools/make-icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset -o ScreenShot/AppIcon.icns
```

## Requirements

- macOS 14 (Sonoma) or later — `SCScreenshotManager` is 14+
- Xcode Command Line Tools (`xcode-select --install`)

## License

MIT
