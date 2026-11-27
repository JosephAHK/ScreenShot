import Foundation

enum DebugLog {
    private static let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenShot/debug.log").path
    private static var ocrCopyCount = 0

    static func nextOcrCopyId() -> Int {
        ocrCopyCount += 1
        return ocrCopyCount
    }

    static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String] = [:]
    ) {
        // Opt-in only: these entries include OCR'd screen text. Enable with SCREENSHOT_DEBUG=1.
        guard ProcessInfo.processInfo.environment["SCREENSHOT_DEBUG"] != nil else { return }
        var payload: [String: Any] = [
            "sessionId": "db6400",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "runId": "post-fix",
        ]
        if !data.isEmpty { payload["data"] = data }

        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }

        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bytes = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forUpdatingAtPath: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
            try? handle.synchronize()
        } else {
            FileManager.default.createFile(atPath: path, contents: bytes)
        }
    }

    static func fingerprint(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
