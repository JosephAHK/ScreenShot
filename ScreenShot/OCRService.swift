import Foundation
import Vision

enum OCRService {
    static func recognizeText(in cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        NSLog("ScreenShot: OCR raw observation count \(observations.count)")

        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        // #region agent log
        for (index, observation) in sorted.enumerated() {
            let text = observation.topCandidates(1).first?.string ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLog.write(
                hypothesisId: "A,B,D,F",
                location: "OCRService.swift:observation",
                message: "raw observation",
                data: [
                    "index": String(index),
                    "length": String(trimmed.count),
                    "fingerprint": DebugLog.fingerprint(String(trimmed.prefix(80))),
                    "normalized": DebugLog.normalize(trimmed),
                    "midY": String(format: "%.4f", observation.boundingBox.midY),
                ]
            )
        }
        // #endregion

        let deduped = lineBandText(from: sorted)
        NSLog("ScreenShot: OCR deduped (\(deduped.count) chars):\n\(deduped)")

        // #region agent log
        DebugLog.write(
            hypothesisId: "A,D,E,F",
            location: "OCRService.swift:result",
            message: "ocr result summary",
            data: [
                "observationCount": String(observations.count),
                "dedupedLineCount": String(deduped.components(separatedBy: "\n").count),
                "dedupedLength": String(deduped.count),
                "dedupedFingerprint": DebugLog.fingerprint(String(deduped.prefix(120))),
            ]
        )
        // #endregion

        return deduped
    }

    /// One line per vertical band: keep the longest candidate (full line beats word fragments).
    private static func lineBandText(from sorted: [VNRecognizedTextObservation]) -> String {
        let yThreshold: CGFloat = 0.02
        var bands: [[VNRecognizedTextObservation]] = []

        for observation in sorted {
            if var last = bands.last,
               abs(last[0].boundingBox.midY - observation.boundingBox.midY) <= yThreshold {
                last.append(observation)
                bands[bands.count - 1] = last
            } else {
                bands.append([observation])
            }
        }

        let lines = bands.compactMap { band -> String? in
            let candidates = band.compactMap { observation -> (String, Int, CGFloat)? in
                guard let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty else { return nil }
                let area = observation.boundingBox.width * observation.boundingBox.height
                return (text, text.count, area)
            }
            return candidates.max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 < rhs.2
            }?.0
        }

        var seen = Set<String>()
        let unique = lines.filter { line in
            let key = DebugLog.normalize(line)
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        let sublines = unique.flatMap { line -> [String] in
            line.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        var seenSub = Set<String>()
        let final = sublines.filter { line in
            let key = DebugLog.normalize(line)
            guard !seenSub.contains(key) else { return false }
            seenSub.insert(key)
            return true
        }

        // #region agent log
        DebugLog.write(
            hypothesisId: "D,M,F",
            location: "OCRService.swift:lineBandText",
            message: "line band merge",
            data: [
                "bandCount": String(bands.count),
                "linesBeforeUnique": String(lines.count),
                "linesAfterUnique": String(unique.count),
                "sublinesAfterSplit": String(sublines.count),
                "linesAfterFinalDedupe": String(final.count),
            ]
        )
        // #endregion

        return collapseRepeatedLines(final)
    }

    /// If every line is the same text (after normalize), return a single line.
    private static func collapseRepeatedLines(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let keys = lines.map { DebugLog.normalize($0) }
        if Set(keys).count == 1 { return lines[0] }
        return lines.joined(separator: "\n")
    }
}
