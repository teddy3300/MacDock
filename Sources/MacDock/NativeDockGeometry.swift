import AppKit
import Foundation

/// Computes live Dock hit regions. Accessibility frames are preferred because
/// they follow magnification and the Dock's actual app/stack ordering; the
/// plist estimate remains a fallback when Accessibility is unavailable.
struct NativeDockGeometry {
    struct IconSlot {
        let index: Int
        let bundleID: String?
        let name: String
        let rect: CGRect
        let isRunning: Bool
        var key: String { "\(index)|\(bundleID ?? "")" }
    }

    private struct DockEntry {
        let bundleID: String?
        let name: String
    }

    let dockBarRect: CGRect
    let iconSlots: [IconSlot]
    let tileSize: CGFloat
    let cellWidth: CGFloat
    let magnificationEnabled: Bool
    let orientation: String

    private static var bundleIDCache: [String: String] = [:]
    private static var runningIDsCache = Set<String>()
    private static var runningIDsCacheDate = Date.distantPast

    static func bundleIDForAppURL(_ url: URL) -> String? {
        if let cached = bundleIDCache[url.path] { return cached }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
              as? [String: Any] else { return nil }
        guard let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        bundleIDCache[url.path] = bundleID
        return bundleID
    }

    private static func runningBundleIDs() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(runningIDsCacheDate) < 1.0 {
            return runningIDsCache
        }
        runningIDsCache = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        runningIDsCacheDate = now
        return runningIDsCache
    }

    static func current() -> NativeDockGeometry? {
        guard let screen = NSScreen.main else { return nil }
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = max(CGFloat(prefs?.double(forKey: "tilesize") ?? 44), 24)
        let magnification = prefs?.bool(forKey: "magnification") ?? false
        let orientation = prefs?.string(forKey: "orientation") ?? "bottom"
        guard orientation == "bottom" else { return nil }

        let entries = dockEntries(prefs: prefs)
        guard !entries.isEmpty else { return nil }

        let runningIDs = runningBundleIDs()
        let liveFrames = DockAccessibility.itemFrames()
        let appEntries = entries.filter { $0.bundleID != nil }
        var matchedFrames: [Int: DockAccessibility.ItemFrame] = [:]
        var unusedFrames = liveFrames
        for (index, entry) in entries.enumerated() where entry.bundleID != nil {
            let wanted = normalized(entry.name)
            guard let matchIndex = unusedFrames.firstIndex(where: { normalized($0.title) == wanted }) else { continue }
            matchedFrames[index] = unusedFrames.remove(at: matchIndex)
        }
        let hasReliableFrames = !liveFrames.isEmpty && matchedFrames.count >= max(1, appEntries.count - 2)

        let fallbackCell = tileSize + 14
        let fallbackWidth = CGFloat(entries.count) * fallbackCell + 20
        let fallbackRect = CGRect(x: screen.frame.midX - fallbackWidth / 2, y: 0,
                                  width: fallbackWidth, height: tileSize + 20)
        let barRect: CGRect
        let slots: [IconSlot]

        if hasReliableFrames {
            let frames = liveFrames.map(\.rect)
            let minX = frames.map(\.minX).min() ?? fallbackRect.minX
            let maxX = frames.map(\.maxX).max() ?? fallbackRect.maxX
            let minY = frames.map(\.minY).min() ?? fallbackRect.minY
            let maxY = frames.map(\.maxY).max() ?? fallbackRect.maxY
            barRect = CGRect(x: minX - 8, y: minY - 8, width: maxX - minX + 16, height: maxY - minY + 16)
            slots = entries.enumerated().compactMap { index, entry in
                guard let bundleID = entry.bundleID, let live = matchedFrames[index] else { return nil }
                let frame = live.rect
                return IconSlot(index: index, bundleID: bundleID, name: entry.name, rect: frame,
                                isRunning: runningIDs.contains(bundleID))
            }
        } else {
            barRect = fallbackRect
            slots = entries.enumerated().compactMap { index, entry in
                guard let bundleID = entry.bundleID else { return nil }
                let cx = fallbackRect.minX + 10 + (CGFloat(index) + 0.5) * fallbackCell
                let rect = CGRect(x: cx - tileSize / 2, y: fallbackRect.midY - tileSize / 2,
                                  width: tileSize, height: tileSize)
                return IconSlot(index: index, bundleID: bundleID, name: entry.name, rect: rect,
                                isRunning: runningIDs.contains(bundleID))
            }
        }

        return NativeDockGeometry(dockBarRect: barRect, iconSlots: slots, tileSize: tileSize,
                                  cellWidth: fallbackCell, magnificationEnabled: magnification,
                                  orientation: orientation)
    }

    private static func dockEntries(prefs: UserDefaults?) -> [DockEntry] {
        var apps: [DockEntry] = []
        if let raw = prefs?.array(forKey: "persistent-apps") as? [[String: Any]] {
            for entry in raw {
                guard let item = entryFromPlist(entry) else { continue }
                apps.append(item)
            }
        }

        let pinned = Set(apps.compactMap(\.bundleID))
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  !pinned.contains(bundleID), bundleID != Bundle.main.bundleIdentifier else { continue }
            apps.append(DockEntry(bundleID: bundleID, name: app.localizedName ?? bundleID))
        }

        // persistent-others is the right-side stack/file area. Preserve its
        // positions as non-interactive placeholders so an unpinned app can
        // never be assigned to a folder or Trash slot.
        if let raw = prefs?.array(forKey: "persistent-others") as? [[String: Any]] {
            for entry in raw {
                let label = ((entry["tile-data"] as? [String: Any])?["file-label"] as? String) ?? ""
                apps.append(DockEntry(bundleID: nil, name: label))
            }
        }
        return apps
    }

    private static func entryFromPlist(_ entry: [String: Any]) -> DockEntry? {
        let tileData = entry["tile-data"] as? [String: Any]
        let label = tileData?["file-label"] as? String ?? ""
        let fileData = tileData?["file-data"] as? [String: Any]
        if let value = fileData?["_CFURLString"] as? String, let url = URL(string: value) {
            return DockEntry(bundleID: bundleIDForAppURL(url),
                              name: label.isEmpty ? url.deletingPathExtension().lastPathComponent : label)
        }
        return label.isEmpty ? nil : DockEntry(bundleID: nil, name: label)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func iconSlot(at point: NSPoint) -> IconSlot? {
        iconSlots.first { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
    }
}

/// Kept as a compatibility helper for the CLI diagnostics and future use.
enum NativeDockPreviewDetector {
    static func frame() -> CGRect? {
        WindowEnumerator.allWindows().first {
            ($0.ownerName.contains("Dock") || $0.ownerName.contains("程序坞")) &&
            $0.layer == 25 && $0.bounds.width >= 200 && $0.bounds.width <= 700 &&
            $0.bounds.height >= 100 && $0.bounds.height <= 800
        }?.bounds
    }
}
