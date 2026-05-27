import AppKit
import Vision

@main
struct OCRTestRunner {
    static func main() {
        var failed = 0

        failed += testSingleLine()
        failed += testMultiLine()
        failed += testDedupeConsecutiveObservations()
        failed += testDedupeLogic()

        if failed == 0 {
            print("All OCR tests passed.")
        } else {
            print("\(failed) test(s) failed.")
            exit(1)
        }
    }

    static func testSingleLine() -> Int {
        let image = renderImage(size: NSSize(width: 640, height: 80)) { _ in
            drawText("ScreenShot OCR single line test", at: NSPoint(x: 20, y: 22), size: 28)
        }
        return assertOCR(
            name: "single line",
            image: image,
            contains: "ScreenShot OCR single line test",
            mustNotContainRepeatedBlock: "ScreenShot OCR single line test"
        )
    }

    static func testMultiLine() -> Int {
        let image = renderImage(size: NSSize(width: 640, height: 140)) { _ in
            drawText("First line of text", at: NSPoint(x: 20, y: 80), size: 24)
            drawText("Second line here", at: NSPoint(x: 20, y: 30), size: 24)
        }
        return assertOCR(
            name: "multi line",
            image: image,
            contains: "First line of text",
            alsoContains: "Second line here",
            mustNotContainRepeatedBlock: "First line of text"
        )
    }

    /// Vision often emits duplicate observations for the same line; verify our dedupe collapses them.
    static func testDedupeConsecutiveObservations() -> Int {
        let image = renderImage(size: NSSize(width: 640, height: 80)) { _ in
            drawText("Duplicate guard phrase", at: NSPoint(x: 20, y: 22), size: 28)
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("FAIL dedupe setup: no cgImage")
            return 1
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            print("FAIL dedupe setup: Vision error \(error)")
            return 1
        }

        let raw = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "|")
        print("Raw Vision observations: \(raw)")

        do {
            let text = try OCRService.recognizeText(in: cgImage)
            let occurrences = text.components(separatedBy: "Duplicate guard phrase").count - 1
            if occurrences != 1 {
                print("FAIL dedupe: expected phrase once, got \(occurrences) in '\(text)'")
                return 1
            }
            if text.contains("Duplicate guard phrase\nDuplicate guard phrase") {
                print("FAIL dedupe: consecutive duplicate lines in '\(text)'")
                return 1
            }
            print("PASS dedupe")
            return 0
        } catch {
            print("FAIL dedupe: \(error)")
            return 1
        }
    }

    static func testDedupeLogic() -> Int {
        let cases: [(input: [String], want: String)] = [
            (["hello", "hello"], "hello"),
            (["hello", "world", "hello"], "hello\nworld"),
            (["a", "b", "a"], "a\nb"),
        ]
        for (input, want) in cases {
            var lines: [String] = []
            for line in input {
                if lines.contains(line) { continue }
                lines.append(line)
            }
            let got = lines.joined(separator: "\n")
            if got != want {
                print("FAIL dedupe logic: input=\(input) want='\(want)' got='\(got)'")
                return 1
            }
        }
        print("PASS dedupe logic")
        return 0
    }

    static func assertOCR(
        name: String,
        image: NSImage,
        contains: String,
        alsoContains: String? = nil,
        mustNotContainRepeatedBlock: String? = nil
    ) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("FAIL \(name): no cgImage")
            return 1
        }
        do {
            let text = try OCRService.recognizeText(in: cgImage)
            print("\(name) OCR: '\(text)'")
            guard text.contains(contains) else {
                print("FAIL \(name): missing '\(contains)'")
                return 1
            }
            if let alsoContains, !text.contains(alsoContains) {
                print("FAIL \(name): missing '\(alsoContains)'")
                return 1
            }
            if let block = mustNotContainRepeatedBlock {
                let doubled = block + "\n" + block
                if text == doubled || text == block + block {
                    print("FAIL \(name): duplicated block '\(text)'")
                    return 1
                }
                let count = text.components(separatedBy: block).count - 1
                if count > 1 && text.components(separatedBy: "\n").filter({ $0 == block }).count > 1 {
                    print("FAIL \(name): block appears \(count) times in '\(text)'")
                    return 1
                }
            }
            print("PASS \(name)")
            return 0
        } catch {
            print("FAIL \(name): \(error)")
            return 1
        }
    }

    static func renderImage(size: NSSize, draw: (NSBitmapImageRep) -> Void) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        draw(rep)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func drawText(_ string: String, at point: NSPoint, size: CGFloat) {
        string.draw(
            at: point,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.black
            ]
        )
    }
}
