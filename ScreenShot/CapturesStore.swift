import AppKit
import Combine

@MainActor
final class CapturesStore: ObservableObject {
    static let shared = CapturesStore()

    @Published private(set) var items: [URL] = []

    let folderURL: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        return desktop.appendingPathComponent("ScreenShot Captures", isDirectory: true)
    }()

    private init() {
        ensureFolder()
        refresh()
    }

    func ensureFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    /// Verifies the captures folder exists and is writable.
    /// Returns nil on success, otherwise a user-facing error describing the failure.
    func verifyWritable() -> Error? {
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            return error
        }
        let probe = folderURL.appendingPathComponent(".write_probe_\(UUID().uuidString)")
        do {
            try Data([0x00]).write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            return nil
        } catch {
            return error
        }
    }

    func refresh() {
        ensureFolder()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        items = urls
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    @discardableResult
    func save(bitmap: NSBitmapImageRep) throws -> URL {
        ensureFolder()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CapturesStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(df.string(from: Date())).png"
        let url = folderURL.appendingPathComponent(name)
        try png.write(to: url)
        refresh()
        return url
    }

    func delete(_ url: URL) {
        if let idx = items.firstIndex(of: url) {
            items.remove(at: idx)
        }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
