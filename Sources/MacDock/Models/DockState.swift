import AppKit
import Foundation

/// Lightweight runtime app snapshot used for preview targeting.
final class DockState {
    private(set) var runningApps: [RunningApp] = []

    struct RunningApp: Equatable {
        let bundleID: String
        let name: String
        let pid: pid_t
    }

    func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
        runningApps = apps.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return RunningApp(bundleID: id, name: app.localizedName ?? id, pid: app.processIdentifier)
        }
    }

    func isRunning(bundleID: String) -> Bool {
        runningApps.contains { $0.bundleID == bundleID }
    }

    /// Candidate owner names (CGWindowList kCGWindowOwnerName) for an app.
    func ownerNameCandidates(bundleID: String) -> [String] {
        var names: [String] = []
        if let ra = runningApps.first(where: { $0.bundleID == bundleID }) { names.append(ra.name) }
        if let url = AppCatalog.url(bundleID: bundleID) {
            names.append(url.deletingPathExtension().lastPathComponent)
        }
        names.append(bundleID)
        return names
    }
}
