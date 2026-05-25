import AppKit
import Combine
import SwiftUI

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

enum AnnotationTool: String { case arrow, rectangle }

struct Annotation {
    enum Kind { case arrow, rectangle }
    let kind: Kind
    /// Local view coords (Y-up), relative to the SelectionView the annotation lives in.
    var start: CGPoint
    var end: CGPoint
    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

@MainActor
final class ToolbarState: ObservableObject {
    @Published var tool: AnnotationTool? = nil
}

@MainActor
final class SelectionOverlayController {
    private var windows: [NSWindow] = []
    private var views: [SelectionView] = []
    private var isActive = false
    private var debugAutoKill: DispatchWorkItem?
    private static let debugTimeout: TimeInterval = 30

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleScreenChange() {
        guard isActive else { return }
        dismiss()
    }

    func begin() {
        if isActive {
            dismiss()
            return
        }
        isActive = true
        windows.removeAll()
        views.removeAll()

        for screen in NSScreen.screens {
            let w = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            w.isOpaque = false
            w.hasShadow = false
            w.backgroundColor = .clear
            w.alphaValue = 1
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
            w.setFrame(screen.frame, display: false)

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.screenOrigin = screen.frame.origin
            w.contentView = view
            w.initialFirstResponder = view
            views.append(view)
            windows.append(w)

            w.orderFrontRegardless()
            w.makeFirstResponder(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        if let key = windows.first {
            key.makeKeyAndOrderFront(nil)
            key.makeFirstResponder(key.contentView)
        }

        scheduleAutoKill()
    }

    func bumpAutoKill() {
        guard isActive else { return }
        scheduleAutoKill()
    }

    private func scheduleAutoKill() {
        debugAutoKill?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            NSLog("ScreenShot: debug auto-kill firing after \(Self.debugTimeout)s of inactivity")
            self.dismiss()
        }
        debugAutoKill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debugTimeout, execute: work)
    }

    func dismiss() {
        isActive = false
        debugAutoKill?.cancel()
        debugAutoKill = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    /// Broadcast the in-progress drag rect during a NEW selection (before mouse-up).
    func broadcastInProgressSelection(_ globalRect: CGRect?) {
        for v in views {
            v.applyGlobalInProgressSelection(globalRect)
        }
    }

    func cancel() {
        dismiss()
    }

    func copySelection(globalRect: CGRect, annotations: [Annotation], annotationOriginGlobal: CGPoint) {
        guard globalRect.width >= 4, globalRect.height >= 4 else {
            NSSound.beep()
            return
        }
        let captureRect = globalRect
        debugAutoKill?.cancel()
        debugAutoKill = nil
        for w in windows { w.orderOut(nil) }
        NSLog("ScreenShot: copying region \(captureRect) with \(annotations.count) annotation(s)")

        // Translate annotations from "local view coords" into "selection-relative
        // points" (origin at selection bottom-left). Both are in points and Y-up.
        let dx = annotationOriginGlobal.x - captureRect.origin.x
        let dy = annotationOriginGlobal.y - captureRect.origin.y
        let annotationsInSelectionSpace: [Annotation] = annotations.map { ann in
            var a = ann
            a.start = CGPoint(x: ann.start.x + dx, y: ann.start.y + dy)
            a.end = CGPoint(x: ann.end.x + dx, y: ann.end.y + dy)
            return a
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            do {
                let cgImage = try await ScreenCapture.shared.captureRect(captureRect)
                NSLog("ScreenShot: capture ok \(cgImage.width)x\(cgImage.height)")

                let composited = self.composite(
                    cgImage: cgImage,
                    selectionSizePoints: captureRect.size,
                    annotations: annotationsInSelectionSpace
                )

                let pb = NSPasteboard.general
                pb.clearContents()
                if let png = composited.representation(using: .png, properties: [:]) {
                    pb.setData(png, forType: .png)
                }
                if let tiff = composited.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
                NSLog("ScreenShot: copied to clipboard (\(pb.types?.map { $0.rawValue }.joined(separator: ", ") ?? "none"))")

                if let writeError = CapturesStore.shared.verifyWritable() {
                    NSLog("ScreenShot: folder not writable: \(writeError.localizedDescription)")
                    self.promptForFolderAccess(error: writeError)
                } else {
                    do {
                        let url = try CapturesStore.shared.save(bitmap: composited)
                        NSLog("ScreenShot: saved \(url.path)")
                    } catch {
                        NSLog("ScreenShot: save failed: \(error.localizedDescription)")
                        self.promptForFolderAccess(error: error)
                    }
                }

                NSSound(named: "Glass")?.play()
            } catch {
                NSLog("ScreenShot: capture failed: \(error.localizedDescription)")
                NSSound.beep()
            }
            self.isActive = false
            self.windows.removeAll()
            self.views.removeAll()
        }
    }

    private func promptForFolderAccess(error: Error) {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ScreenShot can't save to its captures folder"
        alert.informativeText = """
        \(CapturesStore.shared.folderURL.path)

        \(error.localizedDescription)

        macOS may be blocking access to your Desktop. Grant access in \
        System Settings -> Privacy & Security -> Files and Folders, then try again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Reveal Folder")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([CapturesStore.shared.folderURL])
        default:
            break
        }
    }

    private func composite(
        cgImage: CGImage,
        selectionSizePoints: CGSize,
        annotations: [Annotation]
    ) -> NSBitmapImageRep {
        if annotations.isEmpty {
            return NSBitmapImageRep(cgImage: cgImage)
        }

        let pxW = cgImage.width
        let pxH = cgImage.height
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            NSLog("ScreenShot: composite ctx failed; falling back to raw image")
            return NSBitmapImageRep(cgImage: cgImage)
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // Scale so we can draw annotations using selection-relative POINT coords.
        let scaleX = CGFloat(pxW) / selectionSizePoints.width
        let scaleY = CGFloat(pxH) / selectionSizePoints.height
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        for ann in annotations { drawAnnotation(ann) }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard let result = ctx.makeImage() else {
            NSLog("ScreenShot: composite makeImage failed; falling back to raw image")
            return NSBitmapImageRep(cgImage: cgImage)
        }
        NSLog("ScreenShot: composited \(annotations.count) annotation(s) into \(pxW)x\(pxH)")
        return NSBitmapImageRep(cgImage: result)
    }

    private func drawAnnotation(_ a: Annotation) {
        let color = NSColor.systemRed
        color.setStroke()
        color.setFill()

        switch a.kind {
        case .rectangle:
            let path = NSBezierPath(rect: a.rect)
            path.lineWidth = 3
            path.lineJoinStyle = .round
            path.stroke()
        case .arrow:
            let from = a.start
            let to = a.end
            let dx = to.x - from.x
            let dy = to.y - from.y
            let len = sqrt(dx * dx + dy * dy)
            guard len > 0.5 else { return }
            let headLen: CGFloat = min(22, max(10, len * 0.32))
            let ux = dx / len
            let uy = dy / len
            let baseX = to.x - ux * headLen
            let baseY = to.y - uy * headLen

            let shaft = NSBezierPath()
            shaft.lineWidth = 4
            shaft.lineCapStyle = .round
            shaft.move(to: from)
            shaft.line(to: NSPoint(x: baseX, y: baseY))
            shaft.stroke()

            let perpX = -uy
            let perpY = ux
            let halfW: CGFloat = headLen * 0.6
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: NSPoint(x: baseX + perpX * halfW, y: baseY + perpY * halfW))
            head.line(to: NSPoint(x: baseX - perpX * halfW, y: baseY - perpY * halfW))
            head.close()
            head.fill()
        }
    }
}

@MainActor
final class SelectionView: NSView {
    weak var controller: SelectionOverlayController?
    /// AppKit global origin (bottom-left in primary-display coords) of this view's screen.
    var screenOrigin: CGPoint = .zero

    private enum Phase {
        case awaitingSelection
        case selecting
        case idle
        case annotating
    }
    private var phase: Phase = .awaitingSelection

    /// In-progress new-selection drag (local coords).
    private var selDragStart: CGPoint?
    private var selDragCurrent: CGPoint?
    /// Committed selection rect, local coords.
    private var localSelection: CGRect?
    /// Mirrored in-progress selection from other screens during the initial drag.
    private var mirrorSelection: CGRect?

    /// Annotation list (local view coords).
    private var annotations: [Annotation] = []
    /// In-progress annotation while dragging.
    private var annDragStart: CGPoint?
    private var annDragCurrent: CGPoint?

    /// Snapshot of the previous committed selection (and its annotations),
    /// captured when the user starts a fresh selection drag from `.idle`.
    /// Used to restore the previous edit if the new selection is too small.
    private var pendingRestoreSelection: CGRect?
    private var pendingRestoreAnnotations: [Annotation] = []

    /// Minimum width/height (in points) for a committed selection.
    private static let minSelectionSide: CGFloat = 20

    private let toolbarState = ToolbarState()
    private var toolbarHost: NSHostingView<AnnotationToolbar>?
    private var toolbarCancellable: AnyCancellable?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if toolbarHost == nil {
            let root = AnnotationToolbar(
                state: toolbarState,
                onUndo: { [weak self] in self?.undoLastAnnotation() },
                onCopy: { [weak self] in self?.commitCopy() }
            )
            let host = NSHostingView(rootView: root)
            host.translatesAutoresizingMaskIntoConstraints = true
            host.isHidden = true
            addSubview(host)
            toolbarHost = host
        }
        toolbarCancellable = toolbarState.$tool.sink { [weak self] _ in
            self?.controller?.bumpAutoKill()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(bounds)

        let activeSel = currentSelection
        if let sel = activeSel, sel.width > 0, sel.height > 0 {
            ctx.clear(sel)

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))

            let label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
            drawBadge(label, near: sel)

            for ann in annotations {
                drawAnnotation(ann)
            }
            if let s = annDragStart, let c = annDragCurrent, let tool = toolbarState.tool {
                let preview = Annotation(
                    kind: tool == .arrow ? .arrow : .rectangle,
                    start: s, end: c
                )
                drawAnnotation(preview)
            }
        } else {
            drawCenteredHint("Drag to select  ·  ⌘C / ↵ to copy  ·  Esc to cancel")
        }
    }

    private var currentSelection: CGRect? {
        if let sel = localSelection { return sel }
        if let a = selDragStart, let b = selDragCurrent {
            return CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(a.x - b.x), height: abs(a.y - b.y)
            )
        }
        return mirrorSelection
    }

    private func drawAnnotation(_ a: Annotation) {
        let color = NSColor.systemRed
        color.setStroke()
        color.setFill()

        switch a.kind {
        case .rectangle:
            let path = NSBezierPath(rect: a.rect)
            path.lineWidth = 3
            path.lineJoinStyle = .round
            path.stroke()
        case .arrow:
            let from = a.start
            let to = a.end
            let dx = to.x - from.x
            let dy = to.y - from.y
            let len = sqrt(dx * dx + dy * dy)
            guard len > 0.5 else { return }
            let headLen: CGFloat = min(22, max(10, len * 0.32))
            let ux = dx / len
            let uy = dy / len
            let baseX = to.x - ux * headLen
            let baseY = to.y - uy * headLen

            let shaft = NSBezierPath()
            shaft.lineWidth = 4
            shaft.lineCapStyle = .round
            shaft.move(to: from)
            shaft.line(to: NSPoint(x: baseX, y: baseY))
            shaft.stroke()

            let perpX = -uy
            let perpY = ux
            let halfW: CGFloat = headLen * 0.6
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: NSPoint(x: baseX + perpX * halfW, y: baseY + perpY * halfW))
            head.line(to: NSPoint(x: baseX - perpX * halfW, y: baseY - perpY * halfW))
            head.close()
            head.fill()
        }
    }

    private func drawBadge(_ text: String, near rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let pad: CGFloat = 6
        let boxW = textSize.width + pad * 2
        let boxH = textSize.height + pad
        var x = rect.minX
        var y = rect.maxY + 4
        if y + boxH > bounds.maxY - 4 {
            y = rect.minY - boxH - 4
        }
        if x + boxW > bounds.maxX - 4 { x = bounds.maxX - 4 - boxW }
        if x < bounds.minX + 4 { x = bounds.minX + 4 }

        let box = CGRect(x: x, y: y, width: boxW, height: boxH)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        path.fill()
        attr.draw(at: CGPoint(x: x + pad, y: y + pad / 2))
    }

    private func drawCenteredHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let pad: CGFloat = 10
        let boxW = textSize.width + pad * 2
        let boxH = textSize.height + pad
        let box = CGRect(
            x: bounds.midX - boxW / 2,
            y: bounds.midY - boxH / 2,
            width: boxW,
            height: boxH
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        attr.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2))
    }

    // MARK: - Toolbar layout

    private func positionToolbar(for selection: CGRect) {
        guard let host = toolbarHost else { return }
        host.layout()
        let size = host.fittingSize
        var x = selection.midX - size.width / 2
        var y = selection.minY - size.height - 8
        if y < bounds.minY + 4 {
            y = selection.maxY + 8
            if y + size.height > bounds.maxY - 4 {
                y = max(bounds.minY + 4, selection.maxY - size.height - 8)
            }
        }
        x = min(max(x, bounds.minX + 4), bounds.maxX - size.width - 4)
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        host.isHidden = false
    }

    private func hideToolbar() {
        toolbarHost?.isHidden = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controller?.bumpAutoKill()

        switch phase {
        case .awaitingSelection, .selecting:
            startNewSelection(at: p)
        case .idle, .annotating:
            if let sel = localSelection, sel.contains(p), let _ = toolbarState.tool {
                phase = .annotating
                annDragStart = p
                annDragCurrent = p
                needsDisplay = true
            } else if let sel = localSelection, sel.contains(p) {
                break
            } else {
                pendingRestoreSelection = localSelection
                pendingRestoreAnnotations = annotations
                annotations.removeAll()
                localSelection = nil
                hideToolbar()
                toolbarState.tool = nil
                startNewSelection(at: p)
            }
        }
    }

    private func startNewSelection(at p: CGPoint) {
        phase = .selecting
        selDragStart = p
        selDragCurrent = p
        hideToolbar()
        broadcastInProgress()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controller?.bumpAutoKill()

        switch phase {
        case .selecting:
            selDragCurrent = p
            broadcastInProgress()
            needsDisplay = true
        case .annotating:
            annDragCurrent = p
            needsDisplay = true
        case .awaitingSelection, .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controller?.bumpAutoKill()

        switch phase {
        case .selecting:
            selDragCurrent = p
            if let a = selDragStart, let b = selDragCurrent {
                let rect = CGRect(
                    x: min(a.x, b.x), y: min(a.y, b.y),
                    width: abs(a.x - b.x), height: abs(a.y - b.y)
                )
                let minSide = Self.minSelectionSide
                if rect.width >= minSide, rect.height >= minSide {
                    localSelection = rect
                    annotations = []
                    phase = .idle
                    positionToolbar(for: rect)
                    pendingRestoreSelection = nil
                    pendingRestoreAnnotations = []
                } else if let restore = pendingRestoreSelection {
                    NSLog("ScreenShot: new selection \(rect.width)x\(rect.height) below \(minSide); restoring previous edit")
                    NSSound.beep()
                    localSelection = restore
                    annotations = pendingRestoreAnnotations
                    phase = .idle
                    positionToolbar(for: restore)
                    pendingRestoreSelection = nil
                    pendingRestoreAnnotations = []
                } else {
                    if rect.width > 0 || rect.height > 0 {
                        NSSound.beep()
                    }
                    localSelection = nil
                    phase = .awaitingSelection
                }
            }
            selDragStart = nil
            selDragCurrent = nil
            broadcastInProgress()
            needsDisplay = true

        case .annotating:
            annDragCurrent = p
            if let s = annDragStart, let c = annDragCurrent, let tool = toolbarState.tool {
                let dx = c.x - s.x
                let dy = c.y - s.y
                if sqrt(dx * dx + dy * dy) >= 3 {
                    annotations.append(Annotation(
                        kind: tool == .arrow ? .arrow : .rectangle,
                        start: s, end: c
                    ))
                }
            }
            annDragStart = nil
            annDragCurrent = nil
            phase = .idle
            needsDisplay = true

        case .awaitingSelection, .idle:
            break
        }
    }

    private func broadcastInProgress() {
        guard let a = selDragStart, let b = selDragCurrent else {
            controller?.broadcastInProgressSelection(nil)
            return
        }
        let local = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
        let global = CGRect(
            x: local.origin.x + screenOrigin.x,
            y: local.origin.y + screenOrigin.y,
            width: local.width, height: local.height
        )
        controller?.broadcastInProgressSelection(global)
    }

    func applyGlobalInProgressSelection(_ globalRect: CGRect?) {
        guard let g = globalRect else {
            if localSelection == nil { mirrorSelection = nil }
            needsDisplay = true
            return
        }
        // Don't overwrite our own selection drag for the originating view.
        if phase == .selecting { return }
        let local = CGRect(
            x: g.origin.x - screenOrigin.x,
            y: g.origin.y - screenOrigin.y,
            width: g.width, height: g.height
        )
        mirrorSelection = local.intersection(bounds).isNull ? nil : local
        needsDisplay = true
    }

    // MARK: - Toolbar actions

    private func undoLastAnnotation() {
        if !annotations.isEmpty {
            annotations.removeLast()
            needsDisplay = true
        }
    }

    fileprivate func commitCopy() {
        guard let sel = localSelection else {
            NSSound.beep()
            return
        }
        let global = CGRect(
            x: sel.origin.x + screenOrigin.x,
            y: sel.origin.y + screenOrigin.y,
            width: sel.width, height: sel.height
        )
        let originGlobal = CGPoint(x: screenOrigin.x, y: screenOrigin.y)
        controller?.copySelection(
            globalRect: global,
            annotations: annotations,
            annotationOriginGlobal: originGlobal
        )
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        controller?.bumpAutoKill()
        let chars = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 53 { // Esc
            controller?.cancel()
            return
        }
        let isCmdC = event.modifierFlags.contains(.command) && chars.lowercased() == "c"
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return / numpad Enter
        if isCmdC || isReturn {
            commitCopy()
            return
        }
        // Cmd+Z undo annotation
        if event.modifierFlags.contains(.command), chars.lowercased() == "z" {
            undoLastAnnotation()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - SwiftUI toolbar

private struct AnnotationToolbar: View {
    @ObservedObject var state: ToolbarState
    let onUndo: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ToolButton(systemName: "arrow.up.right", isOn: state.tool == .arrow) {
                state.tool = state.tool == .arrow ? nil : .arrow
            }
            .help("Arrow")
            ToolButton(systemName: "rectangle", isOn: state.tool == .rectangle) {
                state.tool = state.tool == .rectangle ? nil : .rectangle
            }
            .help("Rectangle")
            Divider().frame(height: 18)
            ToolButton(systemName: "arrow.uturn.backward", isOn: false, action: onUndo)
                .help("Undo (⌘Z)")
            ToolButton(systemName: "doc.on.clipboard.fill", isOn: false, action: onCopy)
                .help("Copy (⌘C / ↵)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .fixedSize()
    }
}

private struct ToolButton: View {
    let systemName: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor : (hovering ? Color.primary.opacity(0.12) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
