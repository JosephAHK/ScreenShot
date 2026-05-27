import AppKit
import CoreGraphics
import SwiftUI

@main
struct ScreenShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var hotkey: HotkeyManager?
    private var overlay: SelectionOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if !CGPreflightScreenCaptureAccess() {
            NSApp.activate(ignoringOtherApps: true)
            CGRequestScreenCaptureAccess()
        }

        let overlay = SelectionOverlayController()
        self.overlay = overlay

        self.hotkey = HotkeyManager { [weak overlay] in
            overlay?.begin()
        }
        overlay.setHotkeyManager(hotkey!)

        self.statusBar = StatusBarController(onCapture: { [weak overlay] in
            overlay?.begin()
        })

        do {
            try hotkey?.register()
        } catch {
            NSLog("ScreenShot: failed to register hotkey: \(error)")
        }
    }
}
