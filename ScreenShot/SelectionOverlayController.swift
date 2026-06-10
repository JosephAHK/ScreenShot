import AppKit
import Combine
import SwiftUI

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

enum AnnotationTool: String { case pointer, arrow, rectangle, focusBlur }

extension AnnotationTool {
    var isDrawingTool: Bool {
        switch self {
        case .pointer: return false
        case .arrow, .rectangle, .focusBlur: return true
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .pointer: return nil
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .focusBlur: return .focusBlur
        }
    }
}

struct Annotation {
    enum Kind { case arrow, rectangle, focusBlur }
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

private enum FocusDimStyle {
    /// Opacity of the black overlay applied outside the focus rectangle.
    static let dimOpacity: CGFloat = 0.48
}

private enum AnnotationStrokeStyle {
    static let rectangleLineWidth: CGFloat = 6
    static let arrowShaftLineWidth: CGFloat = 7
}

private enum ActiveControlPoint {
    case rectCorner(Int)
    case arrowStart
    case arrowEnd
    case move
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
        let strokeAnnotations = annotations.filter { $0.kind != .focusBlur }
        let focusBlurAnnotations = annotations.filter { $0.kind == .focusBlur }

        var workingImage = cgImage
        for ann in focusBlurAnnotations {
            if let updated = applyFocusDim(
                to: workingImage,
                focusRectPoints: ann.rect,
                selectionSizePoints: selectionSizePoints
            ) {
                workingImage = updated
            }
        }

        if strokeAnnotations.isEmpty, focusBlurAnnotations.isEmpty {
            return NSBitmapImageRep(cgImage: cgImage)
        }

        let pxW = workingImage.width
        let pxH = workingImage.height
        let colorSpace = workingImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
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
            return NSBitmapImageRep(cgImage: workingImage)
        }

        ctx.interpolationQuality = .high
        ctx.draw(workingImage, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        guard !strokeAnnotations.isEmpty else {
            guard let result = ctx.makeImage() else {
                return NSBitmapImageRep(cgImage: workingImage)
            }
            NSLog("ScreenShot: composited \(focusBlurAnnotations.count) focus dim(s) into \(pxW)x\(pxH)")
            return NSBitmapImageRep(cgImage: result)
        }

        // Scale so we can draw annotations using selection-relative POINT coords.
        let scaleX = CGFloat(pxW) / selectionSizePoints.width
        let scaleY = CGFloat(pxH) / selectionSizePoints.height
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        for ann in strokeAnnotations { drawAnnotation(ann) }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard let result = ctx.makeImage() else {
            NSLog("ScreenShot: composite makeImage failed; falling back to raw image")
            return NSBitmapImageRep(cgImage: workingImage)
        }
        NSLog("ScreenShot: composited \(annotations.count) annotation(s) into \(pxW)x\(pxH)")
        return NSBitmapImageRep(cgImage: result)
    }

    private func applyFocusDim(
        to image: CGImage,
        focusRectPoints: CGRect,
        selectionSizePoints: CGSize,
        dimOpacity: CGFloat = FocusDimStyle.dimOpacity
    ) -> CGImage? {
        let pxW = image.width
        let pxH = image.height
        let scaleX = CGFloat(pxW) / selectionSizePoints.width
        let scaleY = CGFloat(pxH) / selectionSizePoints.height

        let focusPx = CGRect(
            x: focusRectPoints.origin.x * scaleX,
            y: focusRectPoints.origin.y * scaleY,
            width: focusRectPoints.width * scaleX,
            height: focusRectPoints.height * scaleY
        ).integral

        guard focusPx.width >= 2, focusPx.height >= 2 else { return image }

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        ctx.setFillColor(CGColor(gray: 0, alpha: dimOpacity))
        let dimPath = CGMutablePath()
        dimPath.addRect(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        dimPath.addRect(focusPx)
        ctx.addPath(dimPath)
        ctx.fillPath(using: .evenOdd)

        return ctx.makeImage()
    }

    private func drawAnnotation(_ a: Annotation) {
        let color = NSColor.systemRed
        color.setStroke()
        color.setFill()

        switch a.kind {
        case .rectangle:
            let path = NSBezierPath(rect: a.rect)
            path.lineWidth = AnnotationStrokeStyle.rectangleLineWidth
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
            shaft.lineWidth = AnnotationStrokeStyle.arrowShaftLineWidth
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
        case .focusBlur:
            break
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
        case editingAnnotation
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

    private var selectedAnnotationIndex: Int?
    private var activeControlPoint: ActiveControlPoint?
    private var moveDragLastPoint: CGPoint?

    /// Snapshot of the previous committed selection (and its annotations),
    /// captured when the user starts a fresh selection drag from `.idle`.
    /// Used to restore the previous edit if the new selection is too small.
    private var pendingRestoreSelection: CGRect?
    private var pendingRestoreAnnotations: [Annotation] = []

    /// Minimum width/height (in points) for a committed selection.
    private static let minSelectionSide: CGFloat = 20
    private static let controlPointHitRadius: CGFloat = 9
    private static let controlPointDrawRadius: CGFloat = 5

    private let toolbarState = ToolbarState()
    private var toolbarHost: NSHostingView<AnnotationToolbar>?
    private var toolbarCancellable: AnyCancellable?

    private var countdownRemaining: Int?
    private var countdownTask: Task<Void, Never>?
    private var undoFlashTask: Task<Void, Never>?
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
            addCursorRect(bounds, cursor: .crosshair)
            addCursorRect(sel, cursor: cursorInsideSelection())
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    private var usesEditingCursor: Bool {
        (phase == .idle || phase == .annotating || phase == .editingAnnotation) && localSelection != nil
    }

    private var isPointerToolActive: Bool {
        toolbarState.tool == .pointer
    }

    private func cursorInsideSelection() -> NSCursor {
        isPointerToolActive ? .arrow : .crosshair
    }

    private func updateCursor(at p: CGPoint) {
        guard usesEditingCursor, let sel = localSelection else {
            NSCursor.crosshair.set()
            return
        }
        if sel.contains(p), isPointerToolActive {
            NSCursor.arrow.set()
        } else if sel.contains(p) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
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
        toolbarCancellable = toolbarState.$tool.sink { [weak self] tool in
            self?.controller?.bumpAutoKill()
            if tool != .pointer {
                self?.selectedAnnotationIndex = nil
                self?.needsDisplay = true
            }
            self?.refreshCursorRects()
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
                drawAnnotation(ann, in: sel, ctx: ctx)
            }
            if let idx = selectedAnnotationIndex, idx < annotations.count {
                drawSelectionHandles(for: annotations[idx])
            }
            if let s = annDragStart, let c = annDragCurrent, let tool = toolbarState.tool,
               let kind = tool.annotationKind {
                let preview = Annotation(kind: kind, start: s, end: c)
                drawAnnotation(preview, in: sel, ctx: ctx)
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

    private func drawAnnotation(_ a: Annotation, in selection: CGRect, ctx: CGContext) {
        switch a.kind {
        case .focusBlur:
            drawFocusBlurPreview(ctx: ctx, selection: selection, focus: a.rect)
        case .rectangle, .arrow:
            drawStrokeAnnotation(a)
        }
    }

    private func drawStrokeAnnotation(_ a: Annotation) {
        let color = NSColor.systemRed
        color.setStroke()
        color.setFill()

        switch a.kind {
        case .rectangle:
            let path = NSBezierPath(rect: a.rect)
            path.lineWidth = AnnotationStrokeStyle.rectangleLineWidth
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
            shaft.lineWidth = AnnotationStrokeStyle.arrowShaftLineWidth
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
        case .focusBlur:
            break
        }
    }

    private func drawFocusBlurPreview(ctx: CGContext, selection: CGRect, focus: CGRect) {
        ctx.saveGState()
        ctx.clip(to: selection)

        ctx.setFillColor(NSColor.black.withAlphaComponent(FocusDimStyle.dimOpacity).cgColor)
        let outer = CGMutablePath()
        outer.addRect(selection)
        outer.addRect(focus)
        ctx.addPath(outer)
        ctx.fillPath(using: .evenOdd)

        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(focus.insetBy(dx: 0.5, dy: 0.5))
    }

    private func controlPoints(for ann: Annotation) -> [(ActiveControlPoint, CGPoint)] {
        switch ann.kind {
        case .arrow:
            return [(.arrowStart, ann.start), (.arrowEnd, ann.end)]
        case .rectangle, .focusBlur:
            let r = ann.rect
            return [
                (.rectCorner(0), CGPoint(x: r.minX, y: r.minY)),
                (.rectCorner(1), CGPoint(x: r.maxX, y: r.minY)),
                (.rectCorner(2), CGPoint(x: r.maxX, y: r.maxY)),
                (.rectCorner(3), CGPoint(x: r.minX, y: r.maxY)),
            ]
        }
    }

    private func rectCorners(for ann: Annotation) -> [CGPoint] {
        controlPoints(for: ann).map(\.1)
    }

    private func drawSelectionHandles(for ann: Annotation) {
        let r = Self.controlPointDrawRadius
        for (_, pt) in controlPoints(for: ann) {
            let handle = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handle).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(ovalIn: handle)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    private func controlPointHit(at p: CGPoint, for ann: Annotation) -> ActiveControlPoint? {
        let hitR = Self.controlPointHitRadius
        for (cp, pt) in controlPoints(for: ann) {
            let dx = p.x - pt.x
            let dy = p.y - pt.y
            if dx * dx + dy * dy <= hitR * hitR {
                return cp
            }
        }
        return nil
    }

    private func annotationIndex(at p: CGPoint) -> Int? {
        for idx in annotations.indices.reversed() {
            if hitTestAnnotation(annotations[idx], at: p) {
                return idx
            }
        }
        return nil
    }

    private func hitTestAnnotation(_ ann: Annotation, at p: CGPoint) -> Bool {
        switch ann.kind {
        case .rectangle, .focusBlur:
            return ann.rect.insetBy(dx: -6, dy: -6).contains(p)
        case .arrow:
            return distanceToSegment(p, ann.start, ann.end) <= 10
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.001 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
    }

    private func applyControlPointDrag(to p: CGPoint) {
        guard let idx = selectedAnnotationIndex, idx < annotations.count,
              let cp = activeControlPoint else { return }
        var ann = annotations[idx]
        switch cp {
        case .move:
            guard let last = moveDragLastPoint else { return }
            let dx = p.x - last.x
            let dy = p.y - last.y
            if abs(dx) > 0.001 || abs(dy) > 0.001 {
                if let sel = localSelection {
                    ann = translateAnnotation(ann, by: dx, dy: dy, constrainedTo: sel)
                } else {
                    ann.start = CGPoint(x: ann.start.x + dx, y: ann.start.y + dy)
                    ann.end = CGPoint(x: ann.end.x + dx, y: ann.end.y + dy)
                }
                annotations[idx] = ann
            }
            moveDragLastPoint = p
        case .arrowStart:
            ann.start = p
            annotations[idx] = ann
        case .arrowEnd:
            ann.end = p
            annotations[idx] = ann
        case .rectCorner(let corner):
            let corners = rectCorners(for: ann)
            let opposite = corners[(corner + 2) % 4]
            ann.start = p
            ann.end = opposite
            annotations[idx] = ann
        }
    }

    private func annotationBounds(_ ann: Annotation) -> CGRect {
        switch ann.kind {
        case .rectangle, .focusBlur:
            return ann.rect
        case .arrow:
            let pad: CGFloat = 22
            let r = ann.rect
            return r.insetBy(dx: -pad, dy: -pad)
        }
    }

    private func translateAnnotation(
        _ ann: Annotation,
        by dx: CGFloat,
        dy: CGFloat,
        constrainedTo selection: CGRect
    ) -> Annotation {
        var a = ann
        a.start = CGPoint(x: a.start.x + dx, y: a.start.y + dy)
        a.end = CGPoint(x: a.end.x + dx, y: a.end.y + dy)

        let bounds = annotationBounds(a)
        var fixX: CGFloat = 0
        var fixY: CGFloat = 0
        if bounds.minX < selection.minX { fixX = selection.minX - bounds.minX }
        if bounds.maxX > selection.maxX { fixX = selection.maxX - bounds.maxX }
        if bounds.minY < selection.minY { fixY = selection.minY - bounds.minY }
        if bounds.maxY > selection.maxY { fixY = selection.maxY - bounds.maxY }
        if fixX != 0 || fixY != 0 {
            a.start.x += fixX
            a.start.y += fixY
            a.end.x += fixX
            a.end.y += fixY
        }
        return a
    }

    @discardableResult
    private func handlePointerMouseDown(at p: CGPoint) -> Bool {
        if let idx = selectedAnnotationIndex, idx < annotations.count {
            if let cp = controlPointHit(at: p, for: annotations[idx]) {
                activeControlPoint = cp
                moveDragLastPoint = nil
                phase = .editingAnnotation
                needsDisplay = true
                return true
            }
        }

        if let idx = annotationIndex(at: p) {
            selectedAnnotationIndex = idx
            activeControlPoint = .move
            moveDragLastPoint = p
            phase = .editingAnnotation
            needsDisplay = true
            return true
        }

        selectedAnnotationIndex = nil
        activeControlPoint = nil
        moveDragLastPoint = nil
        needsDisplay = true
        return true
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
        toolbarState.tool = .pointer
        selectedAnnotationIndex = nil
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
        refreshCursorRects()
    }

    private func hideToolbar() {
        toolbarHost?.isHidden = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if countdownRemaining != nil { return }
        let p = convert(event.locationInWindow, from: nil)
        controller?.bumpAutoKill()
        updateCursor(at: p)

        switch phase {
        case .awaitingSelection, .selecting:
            startNewSelection(at: p)
        case .idle, .annotating, .editingAnnotation:
            if toolbarState.tool == .pointer, let sel = localSelection, sel.contains(p) {
                _ = handlePointerMouseDown(at: p)
            } else if let sel = localSelection, sel.contains(p),
                      let tool = toolbarState.tool, tool.isDrawingTool {
                selectedAnnotationIndex = nil
                phase = .annotating
                annDragStart = p
                annDragCurrent = p
                needsDisplay = true
            } else if let sel = localSelection, sel.contains(p) {
                break
            } else {
                selectedAnnotationIndex = nil
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
        selectedAnnotationIndex = nil
        hideToolbar()
        broadcastInProgress()
        refreshCursorRects()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controller?.bumpAutoKill()
        updateCursor(at: p)

        switch phase {
        case .selecting:
            selDragCurrent = p
            broadcastInProgress()
            needsDisplay = true
        case .annotating:
            annDragCurrent = p
            needsDisplay = true
        case .editingAnnotation:
            applyControlPointDrag(to: p)
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
            if let s = annDragStart, let c = annDragCurrent, let tool = toolbarState.tool,
               let kind = tool.annotationKind {
                let dx = c.x - s.x
                let dy = c.y - s.y
                let shouldAdd: Bool
                switch tool {
                case .pointer:
                    shouldAdd = false
                case .arrow:
                    shouldAdd = sqrt(dx * dx + dy * dy) >= 3
                case .rectangle, .focusBlur:
                    shouldAdd = abs(dx) >= 8 && abs(dy) >= 8
                }
                if shouldAdd {
                    annotations.append(Annotation(kind: kind, start: s, end: c))
                }
            }
            annDragStart = nil
            annDragCurrent = nil
            phase = .idle
            refreshCursorRects()
            needsDisplay = true

        case .editingAnnotation:
            activeControlPoint = nil
            moveDragLastPoint = nil
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
        let removedIndex = annotations.count - 1
        annotations.removeLast()
        if selectedAnnotationIndex == removedIndex {
            selectedAnnotationIndex = nil
        } else if let idx = selectedAnnotationIndex, idx > removedIndex {
            selectedAnnotationIndex = idx - 1
        }
        needsDisplay = true
        return true
    }

    @discardableResult
    private func deleteSelectedAnnotation() -> Bool {
        guard let idx = selectedAnnotationIndex, idx < annotations.count else { return false }
        annotations.remove(at: idx)
        selectedAnnotationIndex = nil
        needsDisplay = true
        return true
    }

    private func flashUndoButton() {
        undoFlashTask?.cancel()
        toolbarState.undoFlash = true
        undoFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
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
           toolbarState.tool == .pointer,
           (event.keyCode == 51 || event.keyCode == 117) {
            if deleteSelectedAnnotation() {
                return
            }
        }
        if countdownRemaining == nil,
           localSelection != nil,
           phase == .idle || phase == .annotating || phase == .editingAnnotation,
           !event.modifierFlags.contains(.command) {
            switch chars.lowercased() {
            case "v":
                toolbarState.tool = .pointer
                selectedAnnotationIndex = nil
                refreshCursorRects()
                needsDisplay = true
                return
            case "a":
                toolbarState.tool = .arrow
                selectedAnnotationIndex = nil
                refreshCursorRects()
                needsDisplay = true
                return
            case "r":
                toolbarState.tool = .rectangle
                selectedAnnotationIndex = nil
                refreshCursorRects()
                needsDisplay = true
                return
            case "f":
                toolbarState.tool = .focusBlur
                selectedAnnotationIndex = nil
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
                ToolButton(systemName: "cursorarrow", help: "Select (V)", isOn: state.tool == .pointer) {
                    state.tool = state.tool == .pointer ? nil : .pointer
                }
                ToolButton(systemName: "arrow.up.right", help: "Arrow (A)", isOn: state.tool == .arrow) {
                    state.tool = state.tool == .arrow ? nil : .arrow
                }
                ToolButton(systemName: "rectangle", help: "Rectangle (R)", isOn: state.tool == .rectangle) {
                    state.tool = state.tool == .rectangle ? nil : .rectangle
                }
                ToolButton(systemName: "viewfinder", help: "Focus dim (F)", isOn: state.tool == .focusBlur) {
                    state.tool = state.tool == .focusBlur ? nil : .focusBlur
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
                .animation(isFlashing ? .easeOut(duration: 0.05) : nil, value: isFlashing)
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
