import AppKit
import ApplicationServices
import Darwin

/// Activate, raise or close windows of another app (Accessibility APIs).
enum WindowActions {
    private typealias AXWindowIDFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let axWindowIDFunction: AXWindowIDFunction? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "_AXUIElementGetWindow"
        ) else { return nil }
        return unsafeBitCast(symbol, to: AXWindowIDFunction.self)
    }()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        guard !isTrusted else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private static func titlesMatch(_ cgTitle: String, _ axTitle: String) -> Bool {
        let cg = cgTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ax = axTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cg.isEmpty, !ax.isEmpty else { return cg.isEmpty && ax.isEmpty }
        if cg == ax || cg.hasPrefix(ax) || ax.hasPrefix(cg) { return true }
        if let ellipsis = cg.firstIndex(of: "…") {
            let prefix = String(cg[..<ellipsis]).trimmingCharacters(in: .whitespacesAndNewlines)
            return !prefix.isEmpty && ax.hasPrefix(prefix)
        }
        return false
    }

    static func activate(bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateAllWindows])
        } else {
            AppCatalog.launch(bundleID: bundleID)
        }
    }

    /// Quit a single-window app instead of merely hiding its last window.
    /// This is a normal termination request, so apps can still show save or
    /// confirmation dialogs; it never force-quits the process.
    @discardableResult
    static func quitApplication(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else { return false }
        if app.terminate() { return true }

        // A small number of menu-bar/background apps decline the workspace
        // request but still support their standard Quit command.
        app.activate(options: [])
        sendKey(virtualKey: 12, flags: .maskCommand) // Q
        return true
    }

    /// Find the AX window of an app matching a CGWindow (by title, then geometry).
    private static func axWindow(app: NSRunningApplication, window: WindowInfo) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let list = windowsRef as? [AXUIElement] else { return nil }

        // Window titles, positions and sizes are not unique: Chrome commonly
        // has several maximized "new tab" windows. Resolve the WindowServer ID
        // directly when the system symbol is available, then retain the public
        // title/geometry matching below as a compatibility fallback.
        if let exact = list.first(where: { windowID(for: $0) == window.id }) {
            return exact
        }

        var titleMatches: [AXUIElement] = []
        var geometryMatches: [AXUIElement] = []
        var compatibleGeometryMatches: [AXUIElement] = []
        for axWin in list {
            var axTitle = ""
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success {
                axTitle = titleRef as? String ?? ""
            }
            if !window.title.isEmpty {
                if titlesMatch(window.title, axTitle) {
                    titleMatches.append(axWin)
                }
            }
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let pos = posRef, let size = sizeRef {
                var point = CGPoint.zero
                var cgSize = CGSize.zero
                guard CFGetTypeID(pos) == AXValueGetTypeID(),
                      CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                let posValue = unsafeBitCast(pos, to: AXValue.self)
                let sizeValue = unsafeBitCast(size, to: AXValue.self)
                if AXValueGetValue(posValue, .cgPoint, &point),
                   AXValueGetValue(sizeValue, .cgSize, &cgSize) {
                    // AX and WindowServer positions both use global top-left
                    // coordinates. Their frames can differ slightly around
                    // title bars, so keep a small vertical tolerance.
                    if abs(point.y - window.bounds.minY) < 50 && abs(point.x - window.bounds.minX) < 6 &&
                       abs(cgSize.width - window.bounds.width) < 6 && abs(cgSize.height - window.bounds.height) < 8 {
                        geometryMatches.append(axWin)
                        if window.title.isEmpty || titlesMatch(window.title, axTitle) {
                            compatibleGeometryMatches.append(axWin)
                        }
                    }
                }
            }
        }
        if compatibleGeometryMatches.count == 1 { return compatibleGeometryMatches[0] }
        if geometryMatches.count == 1 { return geometryMatches[0] }
        if geometryMatches.count > 1 {
            // Chrome can expose two windows with identical bounds and tab
            // titles. Preserve the CGWindowList front-to-back order to choose
            // the matching AX element instead of always raising AX's first
            // (currently frontmost) window.
            let matchingCG = WindowEnumerator.normalWindows(forOwnerPID: app.processIdentifier).filter {
                abs($0.bounds.minX - window.bounds.minX) < 6 &&
                abs($0.bounds.minY - window.bounds.minY) < 50 &&
                abs($0.bounds.width - window.bounds.width) < 6 &&
                abs($0.bounds.height - window.bounds.height) < 6 &&
                (window.title.isEmpty || $0.title == window.title)
            }
            let pool = compatibleGeometryMatches.isEmpty ? geometryMatches : compatibleGeometryMatches
            if let rank = matchingCG.firstIndex(where: { $0.id == window.id }) {
                return pool[min(rank, pool.count - 1)]
            }
            return pool[0]
        }
        // Titles are not unique in many document-based apps, so only use a
        // title match when it is unambiguous after trying geometry.
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    private static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let axWindowIDFunction else { return nil }
        var id: CGWindowID = 0
        guard axWindowIDFunction(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Chrome appends the active user profile to an accessible window title,
    /// for example: "订单 - Google Chrome - 湘阴mt054711p". This is more
    /// reliable than guessing from the page title, especially when several
    /// profiles have identical tabs.
    static func chromeProfileName(for window: WindowInfo) -> String? {
        guard window.ownerName == "Google Chrome",
              isTrusted,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.processIdentifier == window.ownerPID
                      || $0.bundleIdentifier == "com.google.Chrome"
              }),
              let axWin = axWindow(app: app, window: window) else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return chromeProfileName(fromAXTitle: title)
    }

    static func chromeProfileName(fromAXTitle title: String) -> String? {
        let marker = " - Google Chrome - "
        guard let range = title.range(of: marker, options: .backwards) else { return nil }
        let profile = title[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? nil : profile
    }

    /// Raise (bring to front) a specific window.
    static func raiseWindow(bundleID: String, window: WindowInfo) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }
        guard isTrusted else {
            app.activate(options: [])
            return
        }
        guard let axWin = axWindow(app: app, window: window) else {
            // Identification failed, so do not pretend a different document
            // was selected. Activating the app is the only safe fallback.
            app.activate(options: [])
            return
        }
        // Activate the process only after the target has been identified so a
        // failed match cannot silently choose Chrome's current front window.
        _ = AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        app.activate(options: [])
        // Raise and mark the exact AX window as main/focused. This avoids a
        // second app activation pass, which can otherwise restore Chrome's
        // previously frontmost window.
        _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Close a specific window via its AX close button.
    @discardableResult
    static func closeWindow(bundleID: String, window: WindowInfo) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        // Cmd+W is intentionally not used as a fallback here: if AX cannot
        // identify this exact window it would close whichever window happens
        // to be frontmost, which is worse than reporting failure.
        guard isTrusted, let axWin = axWindow(app: app, window: window) else { return false }
        var closeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
           let closeRef,
           CFGetTypeID(closeRef) == AXUIElementGetTypeID() {
            let button = unsafeBitCast(closeRef, to: AXUIElement.self)
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                return true
            }
        }

        // Some apps expose a window but no usable AX close button. Because the
        // exact AX window has already been resolved, focusing it before Cmd+W
        // closes the requested card rather than whichever window was foremost.
        _ = AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        app.activate(options: [])
        _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        sendKey(virtualKey: 13, flags: .maskCommand)
        return true
    }

    /// Minimize or restore a specific window via AX.
    @discardableResult
    static func minimizeWindow(bundleID: String, window: WindowInfo) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        guard isTrusted, let axWin = axWindow(app: app, window: window) else { return false }

        var minimizedRef: CFTypeRef?
        let isMin = AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimizedRef) == .success && (minimizedRef as? Bool == true)

        let target = isMin ? kCFBooleanFalse : kCFBooleanTrue
        let err = AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, target!)
        if err == .success { return true }

        var minBtnRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, "AXMinimizeButton" as CFString, &minBtnRef) == .success,
           let minBtnRef, CFGetTypeID(minBtnRef) == AXUIElementGetTypeID() {
            let button = unsafeBitCast(minBtnRef, to: AXUIElement.self)
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
        return false
    }

    /// Fullscreen or Zoom (maximize) a specific window via AX.
    @discardableResult
    static func fullscreenWindow(bundleID: String, window: WindowInfo, zoomOnly: Bool = false) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        guard isTrusted, let axWin = axWindow(app: app, window: window) else { return false }

        _ = AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        app.activate(options: [])
        _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)

        if zoomOnly {
            var zoomBtnRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, "AXZoomButton" as CFString, &zoomBtnRef) == .success,
               let zoomBtnRef, CFGetTypeID(zoomBtnRef) == AXUIElementGetTypeID() {
                let button = unsafeBitCast(zoomBtnRef, to: AXUIElement.self)
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        } else {
            var fsBtnRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, "AXFullScreenButton" as CFString, &fsBtnRef) == .success,
               let fsBtnRef, CFGetTypeID(fsBtnRef) == AXUIElementGetTypeID() {
                let button = unsafeBitCast(fsBtnRef, to: AXUIElement.self)
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }

            var fsRef: CFTypeRef?
            let isFS = AXUIElementCopyAttributeValue(axWin, "AXFullScreen" as CFString, &fsRef) == .success && (fsRef as? Bool == true)
            let target = isFS ? kCFBooleanFalse : kCFBooleanTrue
            return AXUIElementSetAttributeValue(axWin, "AXFullScreen" as CFString, target!) == .success
        }
        return false
    }

    /// User-requested fallback for a window that has no capturable backing
    /// frame. The window is restored without activating the app, captured,
    /// and returned to its previous minimized state.
    static func refreshMinimizedSnapshot(
        bundleID: String,
        window: WindowInfo,
        completion: @escaping (CGImage?) -> Void
    ) {
        guard isTrusted,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == bundleID
              }),
              let axWin = axWindow(app: app, window: window) else {
            completion(nil)
            return
        }

        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        var minimizedRef: CFTypeRef?
        let wasMinimized = AXUIElementCopyAttributeValue(
            axWin,
            kAXMinimizedAttribute as CFString,
            &minimizedRef
        ) == .success && (minimizedRef as? Bool == true)

        if wasMinimized {
            let error = AXUIElementSetAttributeValue(
                axWin,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            guard error == .success else {
                completion(nil)
                return
            }
        }

        func finish(_ image: CGImage?) {
            if wasMinimized {
                _ = AXUIElementSetAttributeValue(
                    axWin,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            if let previousFrontmost,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != previousFrontmost.processIdentifier {
                previousFrontmost.activate(options: [])
            }
            completion(image)
        }

        func locateAndCapture(attempt: Int) {
            let currentID = windowID(for: axWin)
            let candidates = WindowEnumerator.normalWindows(forOwnerPID: app.processIdentifier)
            let resolved = currentID.flatMap { id in candidates.first { $0.id == id } }
                ?? candidates.first { candidate in
                    titlesMatch(window.title, candidate.title) &&
                    candidate.bounds.width > 2 && candidate.bounds.height > 2
                }
            guard let resolved else {
                if attempt < 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        locateAndCapture(attempt: attempt + 1)
                    }
                } else {
                    finish(nil)
                }
                return
            }
            ScreenCapture.captureWindow(resolved) { image in finish(image) }
        }

        // Let the deminiaturize animation publish a real WindowServer surface.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasMinimized ? 0.28 : 0)) {
            locateAndCapture(attempt: 0)
        }
    }

    /// Raise the frontmost window of an app via AX.
    static func raiseFrontWindow(bundleID: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement], let first = list.first else { return }
        AXUIElementPerformAction(first, kAXRaiseAction as CFString)
    }

    /// Close the frontmost window of an app. Returns false when it cannot be done.
    @discardableResult
    static func closeFrontWindow(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        // 1) AX close button
        if isTrusted {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
               let list = windows as? [AXUIElement], let first = list.first {
                var closeButton: CFTypeRef?
                if AXUIElementCopyAttributeValue(first, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
                   let closeButton,
                   CFGetTypeID(closeButton) == AXUIElementGetTypeID() {
                    let button = unsafeBitCast(closeButton, to: AXUIElement.self)
                    if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
        }
        // 2) fallback: activate + Cmd+W
        app.activate(options: [])
        sendKey(virtualKey: 13, flags: .maskCommand) // W
        return true
    }

    private static func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
