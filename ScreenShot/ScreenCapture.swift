import AppKit
import ScreenCaptureKit
import CoreGraphics
import CoreVideo

@MainActor
final class ScreenCapture {
    static let shared = ScreenCapture()

    enum CaptureError: LocalizedError {
        case noDisplay
        case permissionDenied
        case emptyRegion
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available for capture."
            case .permissionDenied: return "Screen Recording permission denied. Enable it under System Settings → Privacy & Security → Screen Recording, then try again."
            case .emptyRegion: return "Selected region is empty."
            }
        }
    }

    private func isTCCError(_ error: Error) -> Bool {
        let ns = error as NSError
        let desc = ns.localizedDescription.lowercased()
        return desc.contains("tcc") || desc.contains("declined") || desc.contains("not authorized") || ns.code == -3801
    }

    /// `globalRect` is in AppKit global screen coordinates (origin at bottom-left of
    /// the primary display, Y-up). Returns a CGImage of just that rectangle.
    func captureRect(_ globalRect: CGRect) async throws -> CGImage {
        guard globalRect.width >= 1, globalRect.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            var waited: Double = 0
            while !CGPreflightScreenCaptureAccess() {
                if waited > 60 { throw CaptureError.permissionDenied }
                try await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
        }

        let mid = CGPoint(x: globalRect.midX, y: globalRect.midY)
        guard let nsScreen = NSScreen.screens.first(where: { $0.frame.contains(mid) }) ?? NSScreen.main else {
            throw CaptureError.noDisplay
        }
        let screenFrame = nsScreen.frame
        let clipped = globalRect.intersection(screenFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        // Convert AppKit (Y-up, origin bottom-left of that screen) to
        // ScreenCaptureKit's display-local CG coords (Y-down, origin top-left).
        let localX = clipped.origin.x - screenFrame.origin.x
        let localY = (screenFrame.origin.y + screenFrame.height) - (clipped.origin.y + clipped.height)
        let localRect = CGRect(x: localX, y: localY, width: clipped.width, height: clipped.height)

        let displayID = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()

        var content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if isTCCError(error) {
                var waited: Double = 0
                while !CGPreflightScreenCaptureAccess() {
                    if waited > 60 { throw CaptureError.permissionDenied }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                }
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } else {
                throw error
            }
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let scale = nsScreen.backingScaleFactor

        // Snap the rect to the display's physical pixel grid so SCScreenshotManager
        // copies whole pixels (no resampling, no half-pixel blur on Retina).
        let pxX = (localRect.origin.x * scale).rounded()
        let pxY = (localRect.origin.y * scale).rounded()
        let pxW = max(1, (localRect.width * scale).rounded())
        let pxH = max(1, (localRect.height * scale).rounded())
        let snappedLocal = CGRect(
            x: pxX / scale,
            y: pxY / scale,
            width: pxW / scale,
            height: pxH / scale
        )

        let config = SCStreamConfiguration()
        config.sourceRect = snappedLocal
        config.width = Int(pxW)
        config.height = Int(pxH)
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = false
        config.preservesAspectRatio = true
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }
        config.colorSpaceName = CGColorSpace.displayP3
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            if isTCCError(error) {
                var waited: Double = 0
                while !CGPreflightScreenCaptureAccess() {
                    if waited > 60 { throw CaptureError.permissionDenied }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                }
                cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
            } else {
                throw error
            }
        }

        return cgImage
    }
}
