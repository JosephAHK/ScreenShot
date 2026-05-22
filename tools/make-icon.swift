import AppKit
import CoreGraphics

let symbolName = "camera.viewfinder"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let bytesPerRow = px * 4
    guard let context = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create CGContext for size \(px)")
    }

    let cornerRadius = CGFloat(px) * 0.2237
    let rect = CGRect(x: 0, y: 0, width: px, height: px)
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(backgroundPath)

    let colors = [
        CGColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1.0),
        CGColor(red: 0.95, green: 0.18, blue: 0.30, alpha: 1.0),
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0.0, 1.0]
    )!
    context.saveGState()
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(px)),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    context.restoreGState()

    let symbolPointSize = CGFloat(px) * 0.62
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("Missing SF Symbol \(symbolName)")
    }

    let tinted = NSImage(size: symbol.size, flipped: false) { _ in
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: symbol.size)
        r.fill()
        symbol.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
        return true
    }

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    let drawSize = tinted.size
    let drawRect = NSRect(
        x: (CGFloat(px) - drawSize.width) / 2,
        y: (CGFloat(px) - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = context.makeImage() else { fatalError("makeImage failed") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: px, height: px)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(name)")
    }
    let outPath = (outDir as NSString).appendingPathComponent(name)
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(px)x\(px))")
}
