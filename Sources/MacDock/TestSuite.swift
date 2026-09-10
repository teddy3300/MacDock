import AppKit
import Foundation

/// Lightweight assertion-based self tests (XCTest unavailable with CLT only).
enum TestSuite {
    static func run() -> Int {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { print("PASS  \(name)") }
            else { print("FAIL  \(name)"); failures += 1 }
        }

        // DockItem codable round trip
        do {
            let item = DockItem.app(bundleID: "com.example.a", name: "A")
            let data = try! JSONEncoder().encode(item)
            let decoded = try! JSONDecoder().decode(DockItem.self, from: data)
            check(decoded == item, "DockItem codable round trip")
        }

        // DockItem containment
        do {
            let folder = DockItem.folder(name: "f", children: [
                .app(bundleID: "a", name: "A"),
                .app(bundleID: "b", name: "B"),
            ])
            check(folder.containedAppBundleIDs == ["a", "b"], "containedAppBundleIDs")
        }

        // DockState owner name candidates always include bundleID
        do {
            let state = DockState()
            state.refreshRunningApps()
            let names = state.ownerNameCandidates(bundleID: "com.apple.Notes")
            check(names.contains("com.apple.Notes"), "ownerNameCandidates includes bundleID")
        }

        // CGWindowList dictionaries bridge their geometry values as NSNumber
        // on some SDKs and as CGFloat on others. Verify both forms are parsed.
        do {
            let nsNumberBounds: [String: Any] = [
                "X": NSNumber(value: 12), "Y": NSNumber(value: 34),
                "Width": NSNumber(value: 640), "Height": NSNumber(value: 480)
            ]
            let cgFloatBounds: [String: Any] = [
                "X": CGFloat(12), "Y": CGFloat(34),
                "Width": CGFloat(640), "Height": CGFloat(480)
            ]
            let a = WindowEnumerator.bounds(from: nsNumberBounds)
            let b = WindowEnumerator.bounds(from: cgFloatBounds)
            check(a == CGRect(x: 12, y: 34, width: 640, height: 480), "window bounds NSNumber parsing")
            check(b == CGRect(x: 12, y: 34, width: 640, height: 480), "window bounds CGFloat parsing")
            check(WindowEnumerator.bounds(from: ["Width": 0, "Height": 10]) == nil,
                  "window bounds rejects empty dimensions")
        }

        // Native dock geometry sanity (this machine has a bottom dock)
        do {
            let geo = NativeDockGeometry.current()
            if let geo {
                let screen = NSScreen.main?.frame ?? .zero
                check(geo.dockBarRect.width > 0 && geo.dockBarRect.width <= screen.width, "geometry width sane")
                check(!geo.iconSlots.isEmpty, "geometry finds dock icons")
                check(geo.orientation == "bottom", "geometry bottom orientation")
                check(geo.iconSlots.allSatisfy { $0.rect.height > 0 }, "all slots have valid rects")
                let runningCount = geo.iconSlots.filter { $0.isRunning }.count
                print("INFO  geometry: \(geo.iconSlots.count) icons, \(runningCount) running")
            } else {
                print("INFO  geometry unavailable (dock not at bottom?)")
                check(true, "geometry optional")
            }
        }

        // Preview expansion rules.
        check(
            !PreviewController.shouldExpandSecondLayer(windowCount: 1, isAppFrontmost: true),
            "single frontmost app skips second preview"
        )
        check(
            PreviewController.shouldExpandSecondLayer(windowCount: 1, isAppFrontmost: false),
            "single background app expands second preview"
        )
        check(
            PreviewController.shouldExpandSecondLayer(windowCount: 2, isAppFrontmost: true),
            "multi-window app expands second preview"
        )
        check(
            PreviewController.shouldExpandSecondLayer(
                windowCount: 1,
                isAppFrontmost: true,
                isWindowOnScreen: false
            ),
            "minimized frontmost window expands second preview"
        )

        check(
            FullPreviewPanel.usesExpandedLayout(
                windowBounds: CGRect(x: 0, y: 0, width: 2500, height: 1350),
                screenSize: NSSize(width: 2560, height: 1440)
            ),
            "fullscreen landscape window uses expanded preview"
        )
        check(
            !FullPreviewPanel.usesExpandedLayout(
                windowBounds: CGRect(x: 0, y: 0, width: 620, height: 1320),
                screenSize: NSSize(width: 2560, height: 1440)
            ),
            "tall utility window keeps compact preview"
        )

        let landscapeWin = WindowInfo(id: 1, ownerName: "Chrome", ownerPID: 100, title: "Web",
                                      bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), layer: 0, isOnScreen: true)
        let landscapeFit = WindowCardView.adaptiveFullPreviewSize(for: landscapeWin, screenSize: NSSize(width: 2560, height: 1440))
        check(landscapeFit.card.width == 960 && landscapeFit.card.height == 540, "landscape window scales comfortably preserving aspect")

        let tallWin = WindowInfo(id: 2, ownerName: "WeChat", ownerPID: 101, title: "Chat",
                                 bounds: CGRect(x: 0, y: 0, width: 600, height: 1200), layer: 0, isOnScreen: true)
        let tallFit = WindowCardView.adaptiveFullPreviewSize(for: tallWin, screenSize: NSSize(width: 2560, height: 1440))
        check(abs(tallFit.card.width / tallFit.card.height - 0.5) < 0.02, "tall window strictly maintains aspect ratio")

        let smallWin = WindowInfo(id: 3, ownerName: "Finder", ownerPID: 102, title: "Dialog",
                                  bounds: CGRect(x: 0, y: 0, width: 480, height: 320), layer: 0, isOnScreen: true)
        let smallFit = WindowCardView.adaptiveFullPreviewSize(for: smallWin, screenSize: NSSize(width: 2560, height: 1440))
        check(smallFit.card.width == 480 && smallFit.card.height == 320, "small window displays at 1:1 scale")

        check(SmallPreviewPanel.maxCards == 20, "small preview supports 20 windows")
        check(
            SmallPreviewPanel.layoutWidth(windowCount: 1, screenWidth: 2560) == 300,
            "single window keeps standard card width with padding"
        )
        check(
            SmallPreviewPanel.layoutWidth(windowCount: 5, screenWidth: 2560) == 1460,
            "five windows layout width is 1460"
        )
        check(
            SmallPreviewPanel.layoutWidth(windowCount: 20, screenWidth: 2560) > 1460,
            "twenty windows expand the preview row"
        )
        check(
            SmallPreviewPanel.layoutWidth(windowCount: 20, screenWidth: 1440) <= 1424,
            "twenty-window preview stays inside the screen"
        )

        // WindowCardView 4-button header action tests
        do {
            let win = WindowInfo(id: 100, ownerName: "TestApp", ownerPID: 1, title: "Test Window", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0, isOnScreen: true)
            let card = WindowCardView(window: win, cardSize: NSSize(width: 280, height: 200), thumbHeight: 160, closeSize: 16, footerHeight: 34, titleFontSize: 11, titleInHeader: true, displayTitle: "Test Window", showsCloseButton: true, showsTitle: true, allowsRefresh: false, fallbackImage: nil)
            card.frame = NSRect(x: 0, y: 0, width: 280, height: 200)

            // Hit test quit button
            if case .quit(let qid) = card.action(atWindowPoint: NSPoint(x: 14, y: 171)) {
                check(qid == 100, "card header quit button returns .quit action")
            } else {
                check(false, "card header quit button returns .quit action")
            }

            // Hit test close button
            if case .close(let cid) = card.action(atWindowPoint: NSPoint(x: 36, y: 171)) {
                check(cid == 100, "card header close button returns .close action")
            } else {
                check(false, "card header close button returns .close action")
            }

            // Hit test minimize button
            if case .minimize(let mid) = card.action(atWindowPoint: NSPoint(x: 58, y: 171)) {
                check(mid == 100, "card header minimize button returns .minimize action")
            } else {
                check(false, "card header minimize button returns .minimize action")
            }

            // Hit test fullscreen button
            if case .fullscreen(let fid, _) = card.action(atWindowPoint: NSPoint(x: 80, y: 171)) {
                check(fid == 100, "card header fullscreen button returns .fullscreen action")
            } else {
                check(false, "card header fullscreen button returns .fullscreen action")
            }

            // Hit test thumbnail body -> activate
            if case .activate(let aid) = card.action(atWindowPoint: NSPoint(x: 140, y: 80)) {
                check(aid == 100, "card body returns .activate action")
            } else {
                check(false, "card body returns .activate action")
            }

            check(card.displayLayerForLiveStream() != nil, "card provides AVSampleBufferDisplayLayer for live streaming")
        }

        check(
            PreviewController.shouldUseSeamlessSwitch(
                panelVisible: true,
                currentBundleID: "app.left",
                nextBundleID: "app.right"
            ),
            "visible preview switches directly between running apps"
        )
        check(
            !PreviewController.shouldUseSeamlessSwitch(
                panelVisible: false,
                currentBundleID: "app.left",
                nextBundleID: "app.right"
            ),
            "hidden preview keeps normal first appearance"
        )
        check(
            !PreviewController.shouldUseSeamlessSwitch(
                panelVisible: true,
                currentBundleID: "app.left",
                nextBundleID: "app.left"
            ),
            "same app does not restart its preview session"
        )

        check(
            WindowActions.chromeProfileName(fromAXTitle: "API 密钥 - lave - Google Chrome - 好") == "好",
            "Chrome profile is parsed from accessible window title"
        )
        check(
            WindowActions.chromeProfileName(fromAXTitle: "新标签页 - Google Chrome") == nil,
            "Chrome title without profile falls back safely"
        )

        // Diagonal movement from a Dock icon to a wide preview should be
        // protected without blocking deliberate horizontal app switching.
        let source = NSRect(x: 100, y: 10, width: 48, height: 60)
        let target = NSRect(x: 40, y: 84, width: 360, height: 120)
        check(
            MouseMonitor.isInPreviewApproachCorridor(
                NSPoint(x: 250, y: 68), source: source, target: target
            ),
            "diagonal preview approach stays on current app"
        )
        check(
            !MouseMonitor.isInPreviewApproachCorridor(
                NSPoint(x: 190, y: 40), source: source, target: target
            ),
            "horizontal Dock movement can switch apps"
        )
        check(
            !MouseMonitor.isInPreviewApproachCorridor(
                NSPoint(x: 430, y: 90), source: source, target: target
            ),
            "movement outside preview corridor is released"
        )

        // AppSettings tests
        do {
            let suiteName = "com.local.macdock.test.\(UUID().uuidString)"
            let testDefaults = UserDefaults(suiteName: suiteName)!
            let settings = AppSettings(userDefaults: testDefaults)
            check(!settings.closeLastWindowQuitsApp, "default closeLastWindowQuitsApp is false")
            check(settings.showMenuBarIcon, "default showMenuBarIcon is true")
            check(settings.enableFullPreview, "default enableFullPreview is true")
            check(settings.enableLiveStreamPreview, "default enableLiveStreamPreview is true")
            check(settings.liveStreamFPS == 30, "default liveStreamFPS is 30")
            check(settings.hoverDelay > 0.05, "default hoverDelay is positive")
            check(settings.middleClickAction == .closeWindow, "default middleClickAction is close")

            // Exclusion test
            check(!settings.isExcluded(bundleID: "com.test.app"), "app not excluded initially")
            settings.exclude(bundleID: "com.test.app")
            check(settings.isExcluded(bundleID: "com.test.app"), "app excluded after call")
            settings.unexclude(bundleID: "com.test.app")
            check(!settings.isExcluded(bundleID: "com.test.app"), "app unexcluded after call")

            // Reset test
            settings.hoverDelay = 0.75
            settings.showWindowTitle = false
            settings.enableLiveStreamPreview = false
            settings.liveStreamFPS = 60
            settings.resetToDefaults()
            check(settings.hoverDelay == 0.20, "reset restores hoverDelay")
            check(settings.showWindowTitle == true, "reset restores showWindowTitle")
            check(settings.enableLiveStreamPreview == true, "reset restores enableLiveStreamPreview")
            check(settings.liveStreamFPS == 30, "reset restores liveStreamFPS")

            testDefaults.removePersistentDomain(forName: suiteName)
        }

        // LiveStreamManager test
        do {
            check(LiveStreamManager.shared.currentWindowID == nil, "initial LiveStreamManager has no active stream")
            LiveStreamManager.shared.stopCurrentStream()
            check(LiveStreamManager.shared.currentWindowID == nil, "stopCurrentStream is safe when idle")
        }

        // Screen recording permission state (informational)
        print("INFO  screenRecording=\(ScreenCapture.isAuthorized) accessibility=\(WindowActions.isTrusted)")

        print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
        return failures == 0 ? 0 : 1
    }
}
