import AppKit
import Foundation

/// Resolve app metadata (URL, name, icon, launch) from a bundle identifier.
enum AppCatalog {
    static func url(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(bundleID: String) -> String {
        if let url = url(bundleID: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    static func icon(bundleID: String) -> NSImage? {
        if let url = url(bundleID: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    static func launch(bundleID: String) {
        guard let url = url(bundleID: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func activate(bundleID: String) {
        if let app = runningApp(bundleID: bundleID) {
            app.activate(options: [.activateAllWindows])
        } else {
            launch(bundleID: bundleID)
        }
    }

    static func quit(bundleID: String) {
        if let app = runningApp(bundleID: bundleID) { app.terminate() }
    }
}
