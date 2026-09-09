import AppKit
import Foundation

final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let icon = AppCatalog.icon(bundleID: bundleID) else { return nil }
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}
