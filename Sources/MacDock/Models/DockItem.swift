import Foundation

enum DockKind: String, Codable, Equatable {
    case app
    case folder
}

/// One entry in the dock: either a single app or a folder of apps.
struct DockItem: Codable, Equatable {
    var kind: DockKind
    var bundleID: String?
    var name: String
    var children: [DockItem]

    init(kind: DockKind, bundleID: String? = nil, name: String, children: [DockItem] = []) {
        self.kind = kind
        self.bundleID = bundleID
        self.name = name
        self.children = children
    }

    static func app(bundleID: String, name: String) -> DockItem {
        DockItem(kind: .app, bundleID: bundleID, name: name)
    }

    static func folder(name: String, children: [DockItem]) -> DockItem {
        DockItem(kind: .folder, name: name, children: children)
    }

    var isFolder: Bool { kind == .folder }
    var appBundleID: String? { kind == .app ? bundleID : nil }

    /// All app bundle ids contained (self included if it is an app).
    var containedAppBundleIDs: [String] {
        if kind == .app, let b = bundleID { return [b] }
        return children.flatMap { $0.containedAppBundleIDs }
    }
}
