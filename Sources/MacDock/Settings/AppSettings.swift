import AppKit
import Combine
import Foundation
import ServiceManagement

enum MiddleClickAction: String, CaseIterable, Identifiable, Codable {
    case closeWindow = "close"
    case activateWindow = "activate"
    case none = "none"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closeWindow: return "关闭窗口"
        case .activateWindow: return "激活窗口"
        case .none: return "无操作"
        }
    }
}

/// Central user settings store backed by UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    // MARK: - Keys
    private enum Keys {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let closeLastWindowQuitsApp = "closeLastWindowQuitsApp"
        static let isPaused = "isPaused"
        static let hoverDelay = "hoverDelay"
        static let dismissDelay = "dismissDelay"
        static let enableFullPreview = "enableFullPreview"
        static let requireOptionForFullPreview = "requireOptionForFullPreview"
        static let middleClickAction = "middleClickAction"
        static let cardHeight = "cardHeight"
        static let showWindowTitle = "showWindowTitle"
        static let showCloseButton = "showCloseButton"
        static let showChromeProfile = "showChromeProfile"
        static let includeMinimizedWindows = "includeMinimizedWindows"
        static let enableLiveStreamPreview = "enableLiveStreamPreview"
        static let liveStreamFPS = "liveStreamFPS"
    }

    // MARK: - Published Properties

    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }

    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }

    @Published var closeLastWindowQuitsApp: Bool {
        didSet { defaults.set(closeLastWindowQuitsApp, forKey: Keys.closeLastWindowQuitsApp) }
    }

    @Published var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.isPaused) }
    }

    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) }
    }

    @Published var dismissDelay: Double {
        didSet { defaults.set(dismissDelay, forKey: Keys.dismissDelay) }
    }

    @Published var enableFullPreview: Bool {
        didSet { defaults.set(enableFullPreview, forKey: Keys.enableFullPreview) }
    }

    @Published var requireOptionForFullPreview: Bool {
        didSet { defaults.set(requireOptionForFullPreview, forKey: Keys.requireOptionForFullPreview) }
    }

    @Published var middleClickAction: MiddleClickAction {
        didSet { defaults.set(middleClickAction.rawValue, forKey: Keys.middleClickAction) }
    }

    @Published var cardHeight: CGFloat {
        didSet { defaults.set(Double(cardHeight), forKey: Keys.cardHeight) }
    }

    @Published var showWindowTitle: Bool {
        didSet { defaults.set(showWindowTitle, forKey: Keys.showWindowTitle) }
    }

    @Published var showCloseButton: Bool {
        didSet { defaults.set(showCloseButton, forKey: Keys.showCloseButton) }
    }

    @Published var showChromeProfile: Bool {
        didSet { defaults.set(showChromeProfile, forKey: Keys.showChromeProfile) }
    }

    @Published var includeMinimizedWindows: Bool {
        didSet { defaults.set(includeMinimizedWindows, forKey: Keys.includeMinimizedWindows) }
    }

    @Published var enableLiveStreamPreview: Bool {
        didSet { defaults.set(enableLiveStreamPreview, forKey: Keys.enableLiveStreamPreview) }
    }

    @Published var liveStreamFPS: Int {
        didSet { defaults.set(liveStreamFPS, forKey: Keys.liveStreamFPS) }
    }

    // MARK: - Launch at Login (SMAppService)

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                        }
                    } else {
                        if SMAppService.mainApp.status == .enabled {
                            try SMAppService.mainApp.unregister()
                        }
                    }
                } catch {
                    Logger.log("launch at login toggle failed: \(error)")
                }
                objectWillChange.send()
            }
        }
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults

        // Register default values
        userDefaults.register(defaults: [
            Keys.showMenuBarIcon: true,
            Keys.excludedBundleIDs: [String](),
            Keys.closeLastWindowQuitsApp: false,
            Keys.isPaused: false,
            Keys.hoverDelay: 0.20,
            Keys.dismissDelay: 0.40,
            Keys.enableFullPreview: true,
            Keys.requireOptionForFullPreview: false,
            Keys.middleClickAction: MiddleClickAction.closeWindow.rawValue,
            Keys.cardHeight: 110.0,
            Keys.showWindowTitle: true,
            Keys.showCloseButton: true,
            Keys.showChromeProfile: true,
            Keys.includeMinimizedWindows: true,
            Keys.enableLiveStreamPreview: true,
            Keys.liveStreamFPS: 30,
        ])

        self.showMenuBarIcon = userDefaults.bool(forKey: Keys.showMenuBarIcon)
        self.excludedBundleIDs = userDefaults.stringArray(forKey: Keys.excludedBundleIDs) ?? []
        self.closeLastWindowQuitsApp = userDefaults.bool(forKey: Keys.closeLastWindowQuitsApp)
        self.isPaused = userDefaults.bool(forKey: Keys.isPaused)
        self.hoverDelay = userDefaults.double(forKey: Keys.hoverDelay)
        self.dismissDelay = userDefaults.double(forKey: Keys.dismissDelay)
        self.enableFullPreview = userDefaults.bool(forKey: Keys.enableFullPreview)
        self.requireOptionForFullPreview = userDefaults.bool(forKey: Keys.requireOptionForFullPreview)
        let actionRaw = userDefaults.string(forKey: Keys.middleClickAction) ?? MiddleClickAction.closeWindow.rawValue
        self.middleClickAction = MiddleClickAction(rawValue: actionRaw) ?? .closeWindow
        self.cardHeight = CGFloat(userDefaults.double(forKey: Keys.cardHeight))
        self.showWindowTitle = userDefaults.bool(forKey: Keys.showWindowTitle)
        self.showCloseButton = userDefaults.bool(forKey: Keys.showCloseButton)
        self.showChromeProfile = userDefaults.bool(forKey: Keys.showChromeProfile)
        self.includeMinimizedWindows = userDefaults.bool(forKey: Keys.includeMinimizedWindows)
        self.enableLiveStreamPreview = userDefaults.bool(forKey: Keys.enableLiveStreamPreview)
        let fps = userDefaults.integer(forKey: Keys.liveStreamFPS)
        self.liveStreamFPS = (fps > 0) ? fps : 30
    }

    // MARK: - Exclusion Helpers

    func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    func exclude(bundleID: String) {
        guard !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
    }

    func unexclude(bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
    }

    // MARK: - Reset

    func resetToDefaults() {
        showMenuBarIcon = true
        excludedBundleIDs = []
        closeLastWindowQuitsApp = false
        isPaused = false
        hoverDelay = 0.20
        dismissDelay = 0.40
        enableFullPreview = true
        requireOptionForFullPreview = false
        middleClickAction = .closeWindow
        cardHeight = 110.0
        showWindowTitle = true
        showCloseButton = true
        showChromeProfile = true
        includeMinimizedWindows = true
        enableLiveStreamPreview = true
        liveStreamFPS = 30
    }
}
