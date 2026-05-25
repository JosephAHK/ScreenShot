import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                NSLog("ScreenShot: launch-at-login toggle failed: \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let popover = NSPopover()

    init(onCapture: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onCapture = onCapture
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ScreenShot")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 440)
        let root = CapturesPopoverView(
            onCapture: { [weak self] in
                self?.popover.performClose(nil)
                self?.onCapture()
            },
            onOpenFolder: { [weak self] in
                NSWorkspace.shared.open(CapturesStore.shared.folderURL)
                self?.popover.performClose(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            CapturesStore.shared.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let capture = NSMenuItem(title: "Capture Region   F4", action: #selector(captureAction), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit ScreenShot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func captureAction() { onCapture() }
    @objc private func openFolder() { NSWorkspace.shared.open(CapturesStore.shared.folderURL) }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.isEnabled.toggle() }
}

private struct CapturesPopoverView: View {
    @ObservedObject private var store = CapturesStore.shared
    let onCapture: () -> Void
    let onOpenFolder: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCapture) {
                    Label("Capture (F4)", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(action: onOpenFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No screenshots yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Press F4 anywhere to capture")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.items, id: \.self) { url in
                            ThumbView(url: url)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(10)
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.items)
                }
            }
        }
        .frame(width: 360, height: 440)
        .onAppear { store.refresh() }
    }
}

private struct ThumbView: View {
    let url: URL
    @State private var hovering = false
    @State private var justCopied = false
    @State private var pressed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(NSColor.controlBackgroundColor)
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                // Hover toolbar at bottom edge
                VStack {
                    Spacer()
                    if hovering || justCopied {
                        HStack(spacing: 6) {
                            HoverIconButton(systemName: "doc.on.clipboard.fill", tint: .white) {
                                handleCopy()
                            }
                            .help("Copy to clipboard")
                            HoverIconButton(systemName: "trash.fill", tint: .white) {
                                handleDelete()
                            }
                            .help("Delete")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0.0), Color.black.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: hovering || justCopied)

                if justCopied {
                    ZStack {
                        Color.black.opacity(0.4)
                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: min(geo.size.width, geo.size.height) * 0.32,
                                              weight: .semibold))
                                .foregroundStyle(Color.white)
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            Text("Copied")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    justCopied
                        ? Color.green
                        : (hovering ? Color.accentColor : Color.black.opacity(0.12)),
                    lineWidth: justCopied ? 2 : (hovering ? 2 : 1)
                )
                .animation(.easeOut(duration: 0.18), value: justCopied)
                .animation(.easeOut(duration: 0.12), value: hovering)
        )
        .scaleEffect(pressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onHover { hovering = $0 }
        .onDrag {
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            return provider
        }
        .contextMenu {
            Button("Open in Preview") { NSWorkspace.shared.open(url) }
            Button("Copy") { handleCopy() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Delete", role: .destructive) {
                handleDelete()
            }
        }
        .help(url.lastPathComponent)
    }

    private func handleCopy() {
        copyToClipboard()
        NSSound(named: "Tink")?.play()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) {
            pressed = true
            justCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                pressed = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                justCopied = false
            }
        }
    }

    private func handleDelete() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            CapturesStore.shared.delete(url)
        }
        Self.playTrashSound()
    }

    private static let trashSoundURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")

    /// Plays only the initial crumple; the full .aif has a second sfx ~1s later.
    private static func playTrashSound() {
        guard let sound = NSSound(contentsOf: trashSoundURL, byReference: false) else {
            NSSound(named: "Pop")?.play()
            return
        }
        sound.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            sound.stop()
        }
    }

    private func copyToClipboard() {
        guard let img = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }
}

private struct HoverIconButton: View {
    let systemName: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.white.opacity(0.22) : Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
