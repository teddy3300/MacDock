import AppKit
import Foundation

/// Coordinates the small -> full preview flow for hovered dock apps.
/// Captures each app window individually (CGWindowListCreateImage) so previews
/// show the real window content and never include our own panels.
final class PreviewController {
    weak var dockController: OverlayController?

    private var smallPanel: SmallPreviewPanel?
    private var fullPanel: FullPreviewPanel?
    private var refreshTimer: Timer?
    private var closeTimer: Timer?
    private var liveStreamDebounceTimer: Timer?
    private var currentBundleID: String?
    private var currentPID: pid_t?
    private var currentAppName = ""
    private var currentAppIcon: NSImage?
    private var currentOwnerNames: [String] = []
    private var chromeProfileNames: [CGWindowID: String] = [:]
    var anchorRect: NSRect = .zero
    private var windows: [WindowInfo] = []
    private var selectedWindowID: CGWindowID?
    private var images: [CGWindowID: CGImage] = [:]
    private var imageCache: [CGWindowID: CGImage] = [:]
    private var refreshingWindowIDs: Set<CGWindowID> = []
    private var closingWindowIDs: Set<CGWindowID> = []
    private let maxCachedImages = 24
    private var isAppRunning = false
    private var sessionReady = false
    private var capturing = false
    private var lastLiveCaptureAt = Date.distantPast
    /// Invalidates callbacks from a previous hover session. Window captures
    /// finish asynchronously, so a fast move from app A to app B must not let
    /// A's images reopen or overwrite B's panel.
    private var sessionGeneration: UInt64 = 0

    private var overItem = false
    private var overSmall = false
    private var overFull = false

    var smallPanelFrame: NSRect? {
        guard smallPanel?.isVisible == true else { return nil }
        return smallPanel?.frame
    }

    var isShowing: Bool {
        smallPanel?.isVisible == true
    }

    var fullPanelFrame: NSRect? {
        guard fullPanel?.isVisible == true else { return nil }
        return fullPanel?.frame
    }

    // MARK: - Entry points

    func itemEntered(item: DockItem, ownerNames: [String], anchorScreenRect: NSRect) {
        cancelClose()
        let nextBundleID = item.appBundleID
        let seamlessSwitch = Self.shouldUseSeamlessSwitch(
            panelVisible: smallPanel?.isVisible == true,
            currentBundleID: currentBundleID,
            nextBundleID: nextBundleID
        )

        // Dock magnification can slightly change the detected icon slot while
        // the pointer is still on the same app. Re-anchor the existing panel
        // without restarting capture or briefly hiding it.
        if smallPanel?.isVisible == true,
           let nextBundleID,
           nextBundleID == currentBundleID {
            overItem = true
            anchorRect = anchorScreenRect
            positionSmallPanel(animated: true)
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        overItem = true
        currentBundleID = nextBundleID
        currentAppName = item.name
        currentOwnerNames = ownerNames
        anchorRect = anchorScreenRect
        let runningApp = item.appBundleID.flatMap { AppCatalog.runningApp(bundleID: $0) }
        currentPID = runningApp?.processIdentifier
        currentAppIcon = runningApp?.icon
        isAppRunning = runningApp != nil
        sessionReady = false
        windows = []
        selectedWindowID = nil
        images = [:]
        chromeProfileNames.removeAll()
        capturing = false
        lastLiveCaptureAt = .distantPast
        if !seamlessSwitch {
            smallPanel?.orderOut(nil)
        }
        fullPanel?.orderOut(nil)

        // Only running apps get previews
        guard isAppRunning else {
            closeAll()
            return
        }

        if smallPanel == nil {
            let panel = SmallPreviewPanel(onEntered: { [weak self] in self?.smallEntered() },
                                          onExited: { [weak self] in self?.smallExited() })
            panel.onCardEntered = { [weak self] id in self?.smallCardEntered(id) }
            panel.onCardHeaderEntered = { [weak self] id in self?.smallCardHeaderEntered(id) }
            panel.onCardClick = { [weak self] id in self?.activateWindow(id) }
            panel.onCardClose = { [weak self] id in self?.closeWindow(id) }
            panel.onCardQuit = { [weak self] _ in self?.quitApplication() }
            panel.onCardMinimize = { [weak self] id in self?.minimizeWindow(id) }
            panel.onCardFullscreen = { [weak self] id, zoom in self?.fullscreenWindow(id, zoomOnly: zoom) }
            panel.onCardRefresh = { [weak self] id in self?.refreshWindowPreview(id) }
            smallPanel = panel
        }
        if fullPanel == nil {
            let panel = FullPreviewPanel(onEntered: nil, onExited: nil)
            fullPanel = panel
        }

        windows = previewWindows()
        images = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            guard let image = imageCache[window.id] else { return nil }
            return (window.id, image)
        })
        if seamlessSwitch {
            presentSmallPanelImmediately(animated: true)
        }
        loadPersistentImages(generation: generation)
        scheduleInitialCapture(generation: generation, deferred: seamlessSwitch)
        Logger.log(
            "preview enter \(currentAppName) windows=\(windows.count) "
                + "seamless=\(seamlessSwitch)"
        )
    }

    static func shouldUseSeamlessSwitch(
        panelVisible: Bool,
        currentBundleID: String?,
        nextBundleID: String?
    ) -> Bool {
        panelVisible
            && currentBundleID != nil
            && nextBundleID != nil
            && currentBundleID != nextBundleID
    }

    func itemExited() {
        overItem = false
        armClose()
    }

    /// The pointer has returned to the Dock icon after visiting a preview.
    /// Keep the first-layer panel anchored to the icon, but collapse the
    /// selected second-layer window instead of leaving it behind.
    func returnedToDockIcon() {
        guard selectedWindowID != nil else { return }
        overItem = true
        overSmall = false
        overFull = false
        cancelClose()
        liveStreamDebounceTimer?.invalidate()
        liveStreamDebounceTimer = nil
        selectedWindowID = nil
        fullPanel?.orderOut(nil)
    }

    func smallEntered() {
        overSmall = true
        cancelClose()
    }

    /// The second layer is tied to the card under the pointer, rather than
    /// rendering every window again. This keeps multi-window apps readable
    /// and prevents a single-window app from looking like a split preview.
    private func smallCardEntered(_ id: CGWindowID) {
        guard sessionReady,
              let selectedWindow = windows.first(where: { $0.id == id }) else { return }
        overSmall = true
        cancelClose()

        guard AppSettings.shared.enableFullPreview else {
            selectedWindowID = nil
            fullPanel?.orderOut(nil)
            return
        }
        if AppSettings.shared.requireOptionForFullPreview {
            guard NSEvent.modifierFlags.contains(.option) else {
                selectedWindowID = nil
                fullPanel?.orderOut(nil)
                return
            }
        }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let isCurrentAppFrontmost = frontmostApplication?.bundleIdentifier == currentBundleID
            || frontmostApplication?.processIdentifier == currentPID
        guard Self.shouldExpandSecondLayer(
            windowCount: windows.count,
            isAppFrontmost: isCurrentAppFrontmost,
            isWindowOnScreen: selectedWindow.isOnScreen
        ) else {
            selectedWindowID = nil
            fullPanel?.orderOut(nil)
            return
        }

        if selectedWindowID == id, fullPanel?.isVisible == true {
            return
        }

        selectedWindowID = id
        showFullPanel(for: id)
    }

    private func smallCardHeaderEntered(_ id: CGWindowID) {
        overSmall = true
        cancelClose()
        liveStreamDebounceTimer?.invalidate()
        liveStreamDebounceTimer = nil
        selectedWindowID = nil
        fullPanel?.orderOut(nil)
    }

    static func shouldExpandSecondLayer(
        windowCount: Int,
        isAppFrontmost: Bool,
        isWindowOnScreen: Bool = true
    ) -> Bool {
        windowCount > 1 || !isAppFrontmost || !isWindowOnScreen
    }

    func smallExited() {
        overSmall = false
        liveStreamDebounceTimer?.invalidate()
        liveStreamDebounceTimer = nil
        selectedWindowID = nil
        fullPanel?.orderOut(nil)
        armClose()
    }

    // MARK: - Capture

    private func scheduleInitialCapture(generation: UInt64, deferred: Bool) {
        let delay = deferred ? 0.06 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            self.captureAllWindows(generation: generation)
        }
    }

    private func isCapturable(_ window: WindowInfo) -> Bool {
        window.bounds.width > 2 && window.bounds.height > 2
    }

    private func isLiveCapturable(_ window: WindowInfo) -> Bool {
        window.isOnScreen && isCapturable(window)
    }

    private func recordImage(_ image: CGImage, for window: WindowInfo, persist: Bool = true) {
        images[window.id] = image
        imageCache[window.id] = image
        pruneImageCache()
        if persist, let bundleID = currentBundleID {
            ThumbnailStore.shared.store(image, bundleID: bundleID, window: window)
        }
    }

    private func loadPersistentImages(generation: UInt64) {
        guard let bundleID = currentBundleID else { return }
        let titleCounts = Dictionary(grouping: windows) {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.mapValues(\.count)
        let singleWindow = windows.count == 1
        for window in windows where images[window.id] == nil {
            let normalizedTitle = window.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let allowTitleFallback = !normalizedTitle.isEmpty && titleCounts[normalizedTitle] == 1
            ThumbnailStore.shared.load(
                bundleID: bundleID,
                window: window,
                allowTitleFallback: allowTitleFallback,
                allowAppFallback: singleWindow
            ) { [weak self] result in
                guard let self,
                      self.sessionGeneration == generation,
                      self.images[window.id] == nil,
                      let result else { return }
                self.recordImage(result.image, for: window, persist: false)
                self.smallPanel?.updateImage(result.image, for: window.id)
                self.fullPanel?.updateImage(result.image, for: window.id)
            }
        }
    }

    private func captureAllWindows(generation: UInt64) {
        guard !windows.isEmpty else {
            guard generation == sessionGeneration else { return }
            capturing = false
            sessionReady = true
            updatePanelsAndShow()
            lastLiveCaptureAt = Date()
            startRefreshTimer()
            return
        }
        let capturable = windows.filter(isCapturable)
        guard !capturable.isEmpty else {
            guard generation == sessionGeneration else { return }
            capturing = false
            sessionReady = true
            updatePanelsAndShow()
            lastLiveCaptureAt = Date()
            startRefreshTimer()
            return
        }
        capturing = true
        let group = DispatchGroup()
        for w in capturable {
            group.enter()
            ScreenCapture.captureWindow(w) { [weak self] img in
                guard let self else { group.leave(); return }
                if self.sessionGeneration == generation, let img {
                    self.recordImage(img, for: w)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            self.capturing = false
            self.sessionReady = true
            self.updatePanelsAndShow()
            self.lastLiveCaptureAt = Date()
            self.startRefreshTimer()
        }
    }

    private func captureLive() {
        guard !capturing, !windows.isEmpty,
              Date().timeIntervalSince(lastLiveCaptureAt) >= 1.0 else { return }
        let capturable = windows.filter(isLiveCapturable)
        guard !capturable.isEmpty else { return }
        lastLiveCaptureAt = Date()
        let generation = sessionGeneration
        capturing = true
        var pending = capturable.count
        for w in capturable {
            ScreenCapture.captureWindow(w) { [weak self] img in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.sessionGeneration == generation else { return }
                    if let img {
                        self.recordImage(img, for: w)
                    }
                    self.smallPanel?.updateImage(img, for: w.id)
                    self.fullPanel?.updateImage(img, for: w.id)
                    pending -= 1
                    if pending <= 0 { self.capturing = false }
                }
            }
        }
    }

    // MARK: - Panels

    private func presentSmallPanelImmediately(animated: Bool) {
        updateSmallPanelContent()
        positionSmallPanel(animated: animated)
        smallPanel?.orderFrontRegardless()
    }

    private func updateSmallPanelContent() {
        smallPanel?.setWindows(
            windows,
            images: images,
            appName: currentAppName,
            appIcon: currentAppIcon,
            titleForWindow: { [weak self] window in self?.displayTitle(for: window) ?? window.title }
        )
    }

    private func updatePanelsAndShow() {
        guard sessionReady else { return }
        updateSmallPanelContent()
        updateFullPanelSelection()
        positionSmallPanel()
        smallPanel?.orderFrontRegardless()
    }

    /// Stable anchor: fixed above the dock icon. No jumping based on the
    /// native Dock preview (that caused the up/down flashing).
    private func positionSmallPanel(animated: Bool = false) {
        guard let panel = smallPanel else { return }
        let size = panel.desiredSize()
        let screen = NSScreen.main?.frame ?? .zero
        let anchor = anchorRect
        let y = anchor.maxY + 6
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animated)
        Logger.log("small panel frame=\(frame) anchor=\(anchor)")
    }

    private func showFullPanel(for id: CGWindowID) {
        guard let panel = fullPanel, sessionReady,
              let window = windows.first(where: { $0.id == id }) else { return }
        panel.setWindows([window], images: images, appName: currentAppName, appIcon: currentAppIcon)
        let size = panel.desiredSize()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? screen?.frame ?? .zero
        let w = size.width
        let h = size.height
        let x = visibleFrame.midX - w / 2
        let y = visibleFrame.midY - h / 2
        let targetFrame = NSRect(x: x, y: y, width: w, height: h)

        if panel.isVisible && panel.frame != targetFrame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
        panel.orderFrontRegardless()
        smallPanel?.orderFrontRegardless()

        liveStreamDebounceTimer?.invalidate()
        if AppSettings.shared.enableLiveStreamPreview, window.isOnScreen {
            // Debounce stream start by 60ms so fast mouse skimming displays instant snapshots
            // without choking ScreenCaptureKit with rapid start/stop cycles.
            liveStreamDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
                guard let self, self.selectedWindowID == id else { return }
                self.fullPanel?.startLiveStream(for: window, frameRate: AppSettings.shared.liveStreamFPS)
            }
        }
    }

    private func updateFullPanelSelection() {
        guard let selectedWindowID,
              let selected = windows.first(where: { $0.id == selectedWindowID }) else {
            selectedWindowID = nil
            fullPanel?.orderOut(nil)
            return
        }
        fullPanel?.setWindows([selected], images: images, appName: currentAppName, appIcon: currentAppIcon)
        if let panel = fullPanel, panel.isVisible {
            let size = panel.desiredSize()
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? screen?.frame ?? .zero
            let targetFrame = NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            if panel.frame != targetFrame {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(targetFrame, display: true)
                }
            }
        }
        liveStreamDebounceTimer?.invalidate()
        if AppSettings.shared.enableLiveStreamPreview, selected.isOnScreen {
            liveStreamDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
                guard let self, self.selectedWindowID == selected.id else { return }
                self.fullPanel?.startLiveStream(for: selected, frameRate: AppSettings.shared.liveStreamFPS)
            }
        }
    }

    // MARK: - Refresh loop

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        guard (overItem || overSmall || overFull), sessionReady,
              refreshingWindowIDs.isEmpty else { return }

        // Re-enumerate (windows may open/close); capture any new windows
        let newWindows = previewWindows()
        var capturedNewWindow = false
        if newWindows.map(\.id) != windows.map(\.id) {
            let oldIDs = Set(windows.map(\.id))
            windows = newWindows
            for id in windows.map(\.id) where !oldIDs.contains(id) {
                if let w = windows.first(where: { $0.id == id }) {
                    guard isCapturable(w) else { continue }
                    capturedNewWindow = true
                    let generation = sessionGeneration
                    ScreenCapture.captureWindow(w) { [weak self] img in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard self.sessionGeneration == generation else { return }
                            if let img {
                                self.recordImage(img, for: w)
                            }
                            self.smallPanel?.updateImage(img, for: id)
                            self.fullPanel?.updateImage(img, for: id)
                        }
                    }
                }
            }
            updateSmallPanelContent()
            if let selectedWindowID {
                if windows.contains(where: { $0.id == selectedWindowID }) {
                    showFullPanel(for: selectedWindowID)
                } else {
                    self.selectedWindowID = nil
                    fullPanel?.orderOut(nil)
                }
            }
            positionSmallPanel()
        }

        // The new-window path already captured the additions above. Avoid a
        // second full capture pass in the same refresh tick.
        if capturedNewWindow {
            lastLiveCaptureAt = Date()
        } else {
            captureLive()
        }
    }

    private func pruneImageCache() {
        guard imageCache.count > maxCachedImages else { return }
        let activeIDs = Set(windows.map(\.id))
        for id in imageCache.keys where imageCache.count > maxCachedImages && !activeIDs.contains(id) {
            imageCache.removeValue(forKey: id)
        }
        while imageCache.count > maxCachedImages, let id = imageCache.keys.first {
            imageCache.removeValue(forKey: id)
        }
    }

    private func previewWindows() -> [WindowInfo] {
        var candidates: [WindowInfo]
        if let pid = currentPID {
            candidates = WindowEnumerator.previewWindows(forOwnerPID: pid, ownerName: currentAppName)
        } else {
            candidates = WindowEnumerator.normalWindows(forOwnerNames: currentOwnerNames)
                .filter { !$0.title.lowercased().contains("translate") }
        }
        if !AppSettings.shared.includeMinimizedWindows {
            candidates = candidates.filter { $0.isOnScreen }
        }
        return Array(candidates.prefix(SmallPreviewPanel.maxCards))
    }

    private func displayTitle(for window: WindowInfo) -> String {
        let fallback = window.title.isEmpty ? currentAppName : window.title
        guard AppSettings.shared.showChromeProfile else { return fallback }
        guard currentAppName == "Google Chrome" else { return fallback }
        if let cached = chromeProfileNames[window.id] { return cached }
        guard let profile = WindowActions.chromeProfileName(for: window) else { return fallback }
        chromeProfileNames[window.id] = profile
        return profile
    }

    // MARK: - Actions

    @discardableResult
    func performFirstLayerAction(at screenPoint: NSPoint) -> Bool {
        guard let action = smallPanel?.action(atScreenPoint: screenPoint) else { return false }
        switch action {
        case let .activate(id): activateWindow(id)
        case let .close(id): closeWindow(id)
        case .quit: quitApplication()
        case let .minimize(id): minimizeWindow(id)
        case let .fullscreen(id, zoomOnly): fullscreenWindow(id, zoomOnly: zoomOnly)
        case let .refresh(id): refreshWindowPreview(id)
        }
        return true
    }

    @discardableResult
    func performFirstLayerMiddleClick(at screenPoint: NSPoint) -> Bool {
        guard let action = smallPanel?.action(atScreenPoint: screenPoint) else { return false }
        let id: CGWindowID
        switch action {
        case let .activate(windowID), let .close(windowID), let .quit(windowID),
             let .minimize(windowID), let .fullscreen(windowID, _), let .refresh(windowID):
            id = windowID
        }
        closeWindow(id)
        return true
    }

    func quitApplication() {
        guard let bid = currentBundleID else { return }
        Logger.log("first-layer quit app bundleID=\(bid)")
        WindowActions.quitApplication(bundleID: bid)
        closeAll()
    }

    func minimizeWindow(_ id: CGWindowID) {
        guard let bid = currentBundleID,
              let win = windows.first(where: { $0.id == id }) else { return }
        Logger.log("first-layer minimize id=\(id) title=\(win.title)")
        WindowActions.minimizeWindow(bundleID: bid, window: win)
        let generation = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            self.refreshNow()
        }
    }

    func fullscreenWindow(_ id: CGWindowID, zoomOnly: Bool) {
        guard let bid = currentBundleID,
              let win = windows.first(where: { $0.id == id }) else { return }
        Logger.log("first-layer fullscreen id=\(id) zoomOnly=\(zoomOnly) title=\(win.title)")
        WindowActions.fullscreenWindow(bundleID: bid, window: win, zoomOnly: zoomOnly)
        closeAll()
    }

    private func refreshWindowPreview(_ id: CGWindowID) {
        guard let bundleID = currentBundleID,
              let window = windows.first(where: { $0.id == id }),
              refreshingWindowIDs.insert(id).inserted else { return }
        let generation = sessionGeneration
        smallPanel?.setRefreshing(true, for: id)
        Logger.log("refresh minimized preview id=\(id) title=\(window.title)")
        WindowActions.refreshMinimizedSnapshot(bundleID: bundleID, window: window) { [weak self] image in
            guard let self else { return }
            self.refreshingWindowIDs.remove(id)
            guard self.sessionGeneration == generation else {
                if let image {
                    ThumbnailStore.shared.store(image, bundleID: bundleID, window: window)
                }
                return
            }
            self.smallPanel?.setRefreshing(false, for: id)
            if let image {
                self.recordImage(image, for: window)
                self.smallPanel?.updateImage(image, for: id)
                self.fullPanel?.updateImage(image, for: id)
            }
        }
    }

    func activateWindow(_ id: CGWindowID) {
        guard let bid = currentBundleID, let win = windows.first(where: { $0.id == id }) else { return }
        Logger.log("first-layer click id=\(id) title=\(win.title)")
        WindowActions.raiseWindow(bundleID: bid, window: win)
        closeAll()
    }

    func closeWindow(_ id: CGWindowID) {
        guard let bid = currentBundleID,
              let win = windows.first(where: { $0.id == id }),
              closingWindowIDs.insert(id).inserted else { return }
        let quitsApplication = AppSettings.shared.closeLastWindowQuitsApp && (windows.count == 1)
        let closed = quitsApplication
            ? WindowActions.quitApplication(bundleID: bid)
            : WindowActions.closeWindow(bundleID: bid, window: win)
        Logger.log(
            "first-layer close id=\(id) title=\(win.title) "
                + "action=\(quitsApplication ? "quit" : "window") success=\(closed)"
        )
        if closed && quitsApplication {
            closeAll()
            return
        }
        let generation = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.closingWindowIDs.remove(id)
            guard self.sessionGeneration == generation else { return }
            self.refreshNow()
        }
    }

    // MARK: - Close / arm

    func closeAll() {
        cancelClose()
        liveStreamDebounceTimer?.invalidate()
        liveStreamDebounceTimer = nil
        sessionGeneration &+= 1
        capturing = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        smallPanel?.orderOut(nil)
        fullPanel?.orderOut(nil)
        windows = []
        images = [:]
        lastLiveCaptureAt = .distantPast
        currentBundleID = nil
        currentPID = nil
        currentOwnerNames = []
        selectedWindowID = nil
        refreshingWindowIDs.removeAll()
        closingWindowIDs.removeAll()
        sessionReady = false
        overItem = false
        overSmall = false
        overFull = false
    }

    private func armClose() {
        closeTimer?.invalidate()
        let delay = AppSettings.shared.dismissDelay
        closeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.overItem && !self.overSmall && !self.overFull {
                self.closeAll()
            }
        }
    }

    private func cancelClose() {
        closeTimer?.invalidate()
        closeTimer = nil
    }
}
