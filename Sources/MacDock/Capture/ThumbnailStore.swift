import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// A bounded, local-only cache of the last successful frame for app windows.
/// Disk reads and image encoding stay off the main thread.
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    struct Result {
        let image: CGImage
        let capturedAt: Date
    }

    private struct Entry: Codable {
        let filename: String
        let bundleID: String
        let windowID: CGWindowID
        let title: String
        let capturedAt: Date
        let byteCount: Int
    }

    private let queue = DispatchQueue(label: "MacDock.ThumbnailStore", qos: .utility)
    private let directory: URL
    private let indexURL: URL
    private var entries: [Entry]
    private let maxEntries = 80
    private let maxBytes = 80 * 1024 * 1024
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private let minimumWriteInterval: TimeInterval = 8

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        directory = applicationSupport
            .appendingPathComponent("MacDock", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        queue.async { [weak self] in self?.pruneAndSave() }
    }

    func store(_ image: CGImage, bundleID: String, window: WindowInfo) {
        guard !bundleID.isEmpty, image.width >= 32, image.height >= 32 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if let recent = self.entries.first(where: {
                $0.bundleID == bundleID && $0.windowID == window.id
            }), Date().timeIntervalSince(recent.capturedAt) < self.minimumWriteInterval {
                return
            }
            guard let data = Self.jpegData(for: image) else { return }
            let filename = UUID().uuidString + ".jpg"
            let fileURL = self.directory.appendingPathComponent(filename)
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Logger.log("thumbnail cache write failed: \(error)")
                return
            }

            let normalizedTitle = Self.normalizedTitle(window.title)
            let replaced = self.entries.filter {
                $0.bundleID == bundleID && $0.windowID == window.id
            }
            self.entries.removeAll {
                $0.bundleID == bundleID && $0.windowID == window.id
            }
            for old in replaced {
                try? FileManager.default.removeItem(
                    at: self.directory.appendingPathComponent(old.filename)
                )
            }
            self.entries.append(Entry(
                filename: filename,
                bundleID: bundleID,
                windowID: window.id,
                title: normalizedTitle,
                capturedAt: Date(),
                byteCount: data.count
            ))
            self.pruneAndSave()
        }
    }

    /// Exact WindowServer IDs are preferred. Title/app fallbacks are only
    /// enabled by the caller when the current window list is unambiguous.
    func load(
        bundleID: String,
        window: WindowInfo,
        allowTitleFallback: Bool,
        allowAppFallback: Bool,
        completion: @escaping (Result?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let title = Self.normalizedTitle(window.title)
            let valid = self.entries.filter {
                $0.bundleID == bundleID && Date().timeIntervalSince($0.capturedAt) <= self.maxAge
            }
            let exact = valid
                .filter { $0.windowID == window.id && (title.isEmpty || $0.title == title) }
                .max { $0.capturedAt < $1.capturedAt }
            let titleMatch = allowTitleFallback && !title.isEmpty
                ? valid.filter { $0.title == title }.max { $0.capturedAt < $1.capturedAt }
                : nil
            let appMatch = allowAppFallback
                ? valid.max { $0.capturedAt < $1.capturedAt }
                : nil
            guard let entry = exact ?? titleMatch ?? appMatch,
                  let data = try? Data(
                    contentsOf: self.directory.appendingPathComponent(entry.filename)
                  ),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = Result(image: image, capturedAt: entry.capturedAt)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func pruneAndSave() {
        let now = Date()
        var removed = entries.filter { now.timeIntervalSince($0.capturedAt) > maxAge }
        entries.removeAll { now.timeIntervalSince($0.capturedAt) > maxAge }
        entries.sort { $0.capturedAt > $1.capturedAt }

        var byteCount = entries.reduce(0) { $0 + $1.byteCount }
        while entries.count > maxEntries || byteCount > maxBytes {
            guard let entry = entries.popLast() else { break }
            removed.append(entry)
            byteCount -= entry.byteCount
        }
        for entry in removed {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(entry.filename)
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func jpegData(for image: CGImage) -> Data? {
        let maxWidth: CGFloat = 1200
        let maxHeight: CGFloat = 800
        let scale = min(1, min(maxWidth / CGFloat(image.width), maxHeight / CGFloat(image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: scaled)
        return representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.72]
        )
    }
}

/// Captures a small set of visible windows when application focus changes.
/// This fills the cache without running a permanent screenshot loop.
final class BackgroundThumbnailRecorder {
    static let shared = BackgroundThumbnailRecorder()

    private var lastCaptureByPID: [pid_t: Date] = [:]
    private let minimumInterval: TimeInterval = 2

    private init() {}

    func captureVisibleWindows(of app: NSRunningApplication, after delay: TimeInterval = 0) {
        guard app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleID = app.bundleIdentifier,
              ScreenCapture.isAuthorized else { return }
        let pid = app.processIdentifier
        let now = Date()
        if let last = lastCaptureByPID[pid], now.timeIntervalSince(last) < minimumInterval {
            return
        }
        lastCaptureByPID[pid] = now

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !app.isTerminated else { return }
            let appName = app.localizedName ?? bundleID
            let windows = WindowEnumerator.previewWindows(
                forOwnerPID: pid,
                ownerName: appName
            ).filter {
                $0.isOnScreen && $0.bounds.width > 2 && $0.bounds.height > 2
            }
            for window in windows.prefix(5) {
                ScreenCapture.captureWindow(window) { image in
                    guard let image else { return }
                    ThumbnailStore.shared.store(image, bundleID: bundleID, window: window)
                }
            }
        }
    }
}
