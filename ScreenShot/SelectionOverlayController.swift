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
    @Published var undoFlash = false
}

@MainActor
final class SelectionOverlayController {
    private var windows: [NSWindow] = []
    private var views: [SelectionView] = []
    private var isActive = false
    private var captureInProgress = false
    private(set) var countdownActive = false
    var isCaptureInProgress: Bool { captureInProgress }
    private weak var countdownSourceView: SelectionView?
    private weak var hotkeyManager: HotkeyManager?
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
        Task { @MainActor in
            let granted = await ScreenCapture.shared.ensureAccess()
            guard granted else {
                self.promptForScreenRecordingAccess()
                return
            }
            self.startOverlay()
        }
    }

    private func startOverlay() {
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
        cancelCountdown()
        isActive = false
        captureInProgress = false
        countdownActive = false
        debugAutoKill?.cancel()
        debugAutoKill = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    func cancelCountdown() {
        countdownActive = false
        endCountdownInteraction(restoreKey: false)
        for v in views {
            v.cancelCountdownIfNeeded()
        }
    }

    func setCountdownActive(_ active: Bool) {
        countdownActive = active
    }

    func setHotkeyManager(_ hotkey: HotkeyManager) {
        hotkeyManager = hotkey
    }

    func beginCountdownInteraction(from view: SelectionView) {
        countdownSourceView = view
        for w in windows {
            w.ignoresMouseEvents = true
        }
        do {
            try hotkeyManager?.registerEscapeHotkey { [weak self] in
                self?.handleCountdownEscapeHotkey()
            }
        } catch {
            NSLog("ScreenShot: failed to register countdown Esc hotkey: \(error)")
        }
    }

    func endCountdownInteraction(restoreKey: Bool = true) {
        for w in windows {
            w.ignoresMouseEvents = false
        }
        hotkeyManager?.unregisterEscapeHotkey()
        countdownSourceView = nil
        guard restoreKey, isActive, let key = windows.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        key.makeKeyAndOrderFront(nil)
        key.makeFirstResponder(key.contentView)
    }

    private func handleCountdownEscapeHotkey() {
        guard countdownActive, let source = countdownSourceView else { return }
        source.cancelCountdownAndRestoreToolbar()
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
        if countdownActive {
            NSSound.beep()
            return
        }
        guard let prepared = prepareCapture(
            globalRect: globalRect,
            annotations: annotations,
            annotationOriginGlobal: annotationOriginGlobal
        ) else { return }

        NSLog("ScreenShot: copying region \(prepared.captureRect) with \(annotations.count) annotation(s)")

        Task { @MainActor in
            do {
                let cgImage = try await self.captureAfterOverlayHidden(prepared.captureRect, ocrId: 0)
                let composited = self.composite(
                    cgImage: cgImage,
                    selectionSizePoints: prepared.captureRect.size,
                    annotations: prepared.annotationsInSelectionSpace
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
                if case ScreenCapture.CaptureError.permissionDenied = error {
                    self.promptForScreenRecordingAccess()
                } else {
                    NSSound.beep()
                }
            }
            self.finishCaptureSession()
        }
    }

    func copyTextSelection(globalRect: CGRect, annotations: [Annotation], annotationOriginGlobal: CGPoint) {
        // #region agent log
        let ocrId = DebugLog.nextOcrCopyId()
        DebugLog.write(
            hypothesisId: "C",
            location: "SelectionOverlayController.swift:copyTextSelection",
            message: "copyTextSelection called",
            data: [
                "ocrId": String(ocrId),
                "captureInProgress": String(captureInProgress),
                "rect": NSStringFromRect(globalRect),
            ]
        )
        // #endregion
        guard !captureInProgress else {
            // #region agent log
            DebugLog.write(
                hypothesisId: "C",
                location: "SelectionOverlayController.swift:copyTextSelection",
                message: "blocked duplicate capture",
                data: ["ocrId": String(ocrId)]
            )
            // #endregion
            return
        }
        if countdownActive {
            NSSound.beep()
            return
        }
        guard let prepared = prepareCapture(
            globalRect: globalRect,
            annotations: annotations,
            annotationOriginGlobal: annotationOriginGlobal
        ) else { return }

        NSLog("ScreenShot: OCR copy region \(prepared.captureRect)")

        Task { @MainActor in
            // #region agent log
            DebugLog.write(
                hypothesisId: "task",
                location: "SelectionOverlayController.swift:task",
                message: "ocr task started",
                data: ["ocrId": String(ocrId)]
            )
            // #endregion
            do {
                let cgImage = try await self.captureAfterOverlayHidden(prepared.captureRect, ocrId: ocrId)
                // #region agent log
                DebugLog.write(
                    hypothesisId: "task",
                    location: "SelectionOverlayController.swift:capture",
                    message: "capture complete",
                    data: [
                        "ocrId": String(ocrId),
                        "width": String(cgImage.width),
                        "height": String(cgImage.height),
                    ]
                )
                // #endregion
                let text = try await Task.detached(priority: .userInitiated) {
                    try OCRService.recognizeText(in: cgImage)
                }.value
                guard !text.isEmpty else {
                    NSLog("ScreenShot: OCR found no text in \(cgImage.width)x\(cgImage.height) image")
                    NSSound.beep()
                    self.finishCaptureSession()
                    return
                }

                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                // #region agent log
                DebugLog.write(
                    hypothesisId: "C,E",
                    location: "SelectionOverlayController.swift:pasteboard",
                    message: "pasteboard written",
                    data: [
                        "ocrId": String(ocrId),
                        "lineCount": String(text.components(separatedBy: "\n").count),
                        "charCount": String(text.count),
                        "clipboardFingerprint": DebugLog.fingerprint(String(text.prefix(120))),
                    ]
                )
                // #endregion
                NSLog("ScreenShot: copied OCR text to clipboard (\(text.count) chars): \(text.prefix(80))")
                NSSound(named: "Tink")?.play()
            } catch {
                NSLog("ScreenShot: OCR copy failed: \(error.localizedDescription)")
                // #region agent log
                DebugLog.write(
                    hypothesisId: "task",
                    location: "SelectionOverlayController.swift:error",
                    message: "ocr task failed",
                    data: [
                        "ocrId": String(ocrId),
                        "error": error.localizedDescription,
                    ]
                )
                // #endregion
                if case ScreenCapture.CaptureError.permissionDenied = error {
                    self.promptForScreenRecordingAccess()
                } else {
                    NSSound.beep()
                }
            }
            self.finishCaptureSession()
        }
    }

    private struct PreparedCapture {
        let captureRect: CGRect
        let annotationsInSelectionSpace: [Annotation]
    }

    private func prepareCapture(
        globalRect: CGRect,
        annotations: [Annotation],
        annotationOriginGlobal: CGPoint
    ) -> PreparedCapture? {
        guard !captureInProgress else { return nil }
        guard globalRect.width >= 4, globalRect.height >= 4 else {
            NSSound.beep()
            return nil
        }
        captureInProgress = true
        debugAutoKill?.cancel()
        debugAutoKill = nil
        for w in windows { w.orderOut(nil) }

        let dx = annotationOriginGlobal.x - globalRect.origin.x
        let dy = annotationOriginGlobal.y - globalRect.origin.y
        let annotationsInSelectionSpace: [Annotation] = annotations.map { ann in
            var a = ann
            a.start = CGPoint(x: ann.start.x + dx, y: ann.start.y + dy)
            a.end = CGPoint(x: ann.end.x + dx, y: ann.end.y + dy)
            return a
        }
        return PreparedCapture(
            captureRect: globalRect,
            annotationsInSelectionSpace: annotationsInSelectionSpace
        )
    }

    private func captureAfterOverlayHidden(_ captureRect: CGRect, ocrId: Int) async throws -> CGImage {
        // #region agent log
        DebugLog.write(
            hypothesisId: "task",
            location: "SelectionOverlayController.swift:capture",
            message: "capture sleep start",
            data: ["ocrId": String(ocrId)]
        )
        // #endregion
        try await Task.sleep(nanoseconds: 120_000_000)
        // #region agent log
        DebugLog.write(
            hypothesisId: "task",
            location: "SelectionOverlayController.swift:capture",
            message: "capture screencapture start",
            data: ["ocrId": String(ocrId)]
        )
        // #endregion
        let cgImage = try await ScreenCapture.shared.captureRect(captureRect)
        NSLog("ScreenShot: capture ok \(cgImage.width)x\(cgImage.height)")
        return cgImage
    }

    private func finishCaptureSession() {
        captureInProgress = false
        isActive = false
        windows.removeAll()
        views.removeAll()
    }

    private func promptForScreenRecordingAccess() {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = """
        ScreenShot needs Screen Recording access to capture your screen and save screenshots.

        Open System Settings → Privacy & Security → Screen Recording, enable ScreenShot, \
        then press F4 to try again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
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

    private var countdownRemaining: Int?
    private var countdownTask: Task<Void, Never>?
    private static let countdownSeconds = 5

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    func allowsMousePassThrough(at localPoint: NSPoint) -> Bool {
        countdownRemaining != nil && localSelection?.contains(localPoint) == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if allowsMousePassThrough(at: point) {
            return nil
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        if usesEditingCursor, let sel = localSelection {
            addCursorRect(bounds, cursor: .arrow)
            addCursorRect(sel, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    private var usesEditingCursor: Bool {
        (phase == .idle || phase == .annotating) && localSelection != nil
    }

    private func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if toolbarHost == nil {
            let root = AnnotationToolbar(
                state: toolbarState,
                onUndo: { [weak self] in self?.undoLastAnnotation() },
                onCopy: { [weak self] in self?.commitCopy() },
                onTimedCopy: { [weak self] in self?.commitTimedCopy() },
                onCopyText: { [weak self] in self?.commitCopyText() }
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
            if let remaining = countdownRemaining {
                drawCountdown(remaining, below: sel)
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

    private func drawCountdown(_ value: Int, below selection: CGRect) {
        let text = "\(value)"
        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let boxSide: CGFloat = max(44, max(textSize.width, textSize.height) + 14)
        var x = selection.midX - boxSide / 2
        var y = selection.minY - boxSide - 12
        if y < bounds.minY + 4 {
            y = selection.maxY + 12
            if y + boxSide > bounds.maxY - 4 {
                y = max(bounds.minY + 4, selection.maxY - boxSide - 12)
            }
        }
        x = min(max(x, bounds.minX + 4), bounds.maxX - boxSide - 4)

        let box = CGRect(x: x, y: y, width: boxSide, height: boxSide)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(rect: box).fill()
        let textOrigin = CGPoint(
            x: x + (boxSide - textSize.width) / 2,
            y: y + (boxSide - textSize.height) / 2
        )
        attr.draw(at: textOrigin)
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
        if countdownRemaining != nil { return }
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
        refreshCursorRects()
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
            refreshCursorRects()
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
            refreshCursorRects()
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

    @discardableResult
    private func undoLastAnnotation() -> Bool {
        guard !annotations.isEmpty else { return false }
        annotations.removeLast()
        needsDisplay = true
        return true
    }

    private func flashUndoButton() {
        toolbarState.undoFlash = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.toolbarState.undoFlash = false
        }
    }

    func cancelCountdownIfNeeded() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        needsDisplay = true
    }

    fileprivate func commitTimedCopy() {
        guard localSelection != nil else {
            NSSound.beep()
            return
        }
        guard countdownRemaining == nil else {
            NSSound.beep()
            return
        }
        guard let controller, !controller.countdownActive, !controller.isCaptureInProgress else {
            NSSound.beep()
            return
        }

        hideToolbar()
        toolbarState.tool = nil
        controller.setCountdownActive(true)
        controller.beginCountdownInteraction(from: self)
        controller.bumpAutoKill()

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if Task.isCancelled {
                    self.countdownRemaining = nil
                    self.countdownTask = nil
                    self.controller?.setCountdownActive(false)
                    self.controller?.endCountdownInteraction()
                    self.needsDisplay = true
                }
            }
            for remaining in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.countdownRemaining = remaining
                self.needsDisplay = true
                self.controller?.bumpAutoKill()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            self.countdownRemaining = nil
            self.countdownTask = nil
            self.controller?.setCountdownActive(false)
            self.controller?.endCountdownInteraction(restoreKey: false)
            self.commitCopy()
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

    fileprivate func commitCopyText() {
        // #region agent log
        DebugLog.write(
            hypothesisId: "C",
            location: "SelectionOverlayController.swift:commitCopyText",
            message: "commitCopyText button action"
        )
        // #endregion
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
        controller?.copyTextSelection(
            globalRect: global,
            annotations: annotations,
            annotationOriginGlobal: originGlobal
        )
    }

    // MARK: - Keys

    func cancelCountdownAndRestoreToolbar() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        controller?.setCountdownActive(false)
        controller?.endCountdownInteraction()
        if let sel = localSelection {
            positionToolbar(for: sel)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        controller?.bumpAutoKill()
        let chars = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 53 { // Esc
            if countdownRemaining != nil {
                cancelCountdownAndRestoreToolbar()
                return
            }
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
            if undoLastAnnotation() {
                flashUndoButton()
            }
            return
        }
        if countdownRemaining == nil,
           localSelection != nil,
           phase == .idle || phase == .annotating,
           !event.modifierFlags.contains(.command) {
            switch chars.lowercased() {
            case "a":
                toolbarState.tool = .arrow
                refreshCursorRects()
                needsDisplay = true
                return
            case "r":
                toolbarState.tool = .rectangle
                refreshCursorRects()
                needsDisplay = true
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - SwiftUI toolbar

private struct AnnotationToolbar: View {
    @ObservedObject var state: ToolbarState
    let onUndo: () -> Void
    let onCopy: () -> Void
    let onTimedCopy: () -> Void
    let onCopyText: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ToolbarBlob {
                ToolButton(systemName: "arrow.up.right", help: "Arrow (A)", isOn: state.tool == .arrow) {
                    state.tool = state.tool == .arrow ? nil : .arrow
                }
                ToolButton(systemName: "rectangle", help: "Rectangle (R)", isOn: state.tool == .rectangle) {
                    state.tool = state.tool == .rectangle ? nil : .rectangle
                }
                ToolButton(
                    systemName: "arrow.uturn.backward",
                    help: "Undo (⌘Z)",
                    isOn: false,
                    isFlashing: state.undoFlash,
                    action: onUndo
                )
            }
            ToolbarBlob {
                ToolButton(systemName: "doc.on.clipboard.fill", help: "Copy (⌘C / ↵)", isOn: false, action: onCopy)
                ToolButton(systemName: "timer", help: "Timed capture (5s)", isOn: false, action: onTimedCopy)
                ToolButton(systemName: "text.viewfinder", help: "Copy text (OCR)", isOn: false, action: onCopyText)
            }
        }
        .fixedSize()
    }
}

private struct ToolbarBlob<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
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
    }
}

private struct ToolButton: View {
    let systemName: String
    let help: String
    let isOn: Bool
    var isFlashing: Bool = false
    let action: () -> Void
    @State private var hovering = false

    private var highlighted: Bool { isOn || isFlashing }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(highlighted ? Color.accentColor : (hovering ? Color.primary.opacity(0.12) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if hovering {
                TooltipLabel(text: help)
                    .fixedSize()
                    .offset(y: -30)
                    .zIndex(1)
            }
        }
    }
}

private struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .allowsHitTesting(false)
    }
}
