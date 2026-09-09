import AppKit

/// Coordinates the native-Dock overlay: hover previews + permission banner.
final class OverlayController: NSObject {
    let state = DockState()
    let previewController = PreviewController()
    private(set) var currentGeometry: NativeDockGeometry?
    private var mouseMonitor: MouseMonitor?
    private var permissionBanner: NSPanel?
    private var geometryTimer: Timer?
    private var lastGeometrySignature: String?
    private var lastPermissionSignature: String?
    private var lastGeometryRefreshAt = Date.distantPast

    override init() {
        super.init()
        previewController.dockController = self
    }

    func show() {
        state.refreshRunningApps()
        refreshGeometry()

        let monitor = MouseMonitor()
        monitor.controller = self
        mouseMonitor = monitor
        monitor.start()

        // The Dock moves icon frames continuously while magnifying and when
        // apps/stacks are inserted. Refresh the live AX geometry frequently
        // enough to follow those transitions without tying it to mouse speed.
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshGeometry()
            self?.refreshPermissionBanner()
        }
        refreshPermissionBanner()
        Logger.log("overlay shown")
    }

    func refreshGeometry() {
        let now = Date()
        if let currentGeometry,
           !currentGeometry.dockBarRect.insetBy(dx: -120, dy: -120).contains(NSEvent.mouseLocation),
           now.timeIntervalSince(lastGeometryRefreshAt) < 1.0 {
            return
        }
        lastGeometryRefreshAt = now
        currentGeometry = NativeDockGeometry.current()
        if let geo = currentGeometry {
            let signature = geo.iconSlots.map { "\($0.key):\($0.rect)" }.joined(separator: ";")
            if signature != lastGeometrySignature {
                lastGeometrySignature = signature
                Logger.log("geometry bar=\(geo.dockBarRect) icons=\(geo.iconSlots.count) tile=\(geo.tileSize) mag=\(geo.magnificationEnabled)")
            }
        } else {
            if lastGeometrySignature != "unavailable" {
                lastGeometrySignature = "unavailable"
                Logger.log("geometry unavailable (dock not at bottom?)")
            }
        }
    }

    func previewNativeIcon(_ slot: NativeDockGeometry.IconSlot) {
        guard !AppSettings.shared.isPaused else { return }
        guard slot.isRunning, let bid = slot.bundleID else { return }
        guard !AppSettings.shared.isExcluded(bundleID: bid) else {
            previewController.closeAll()
            return
        }
        let item = DockItem.app(bundleID: bid, name: slot.name)
        let names = state.ownerNameCandidates(bundleID: bid)
        previewController.itemEntered(item: item, ownerNames: names, anchorScreenRect: slot.rect)
        Logger.log("preview hover \(slot.name)")
    }

    /// Bottom-left anchor for the preview. Kept stable (the dock icon rect).

    /// True when the point is over one of our floating preview panels.
    func isOverOurPanels(at point: NSPoint) -> Bool {
        if let sp = previewController.smallPanelFrame, sp.contains(point) { return true }
        if let fp = previewController.fullPanelFrame, fp.contains(point) { return true }
        return false
    }

    // MARK: - Permission banner

    func refreshPermissionBanner() {
        var missing: [(label: String, pane: String)] = []
        if !ScreenCapture.isAuthorized {
            missing.append(("屏幕录制", "com.apple.preference.security?Privacy_ScreenCapture"))
        }
        if !WindowActions.isTrusted {
            missing.append(("辅助功能", "com.apple.preference.security?Privacy_Accessibility"))
        }
        let signature = missing.map(\.label).joined(separator: "|")
        guard signature != lastPermissionSignature else { return }
        lastPermissionSignature = signature
        if missing.isEmpty {
            permissionBanner?.orderOut(nil)
            permissionBanner = nil
            return
        }
        showPermissionBanner(missing: missing)
    }

    private func showPermissionBanner(missing: [(label: String, pane: String)]) {
        let panel = permissionBanner ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                                backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        permissionBanner = panel

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        root.addSubview(effect)

        let title = NSTextField(labelWithString: "MacDock 需要以下权限")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 16, y: 88, width: 388, height: 20)
        root.addSubview(title)

        var y: CGFloat = 64
        for item in missing {
            let label = NSTextField(labelWithString: "· \(item.label)：用于窗口预览")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .white.withAlphaComponent(0.85)
            label.frame = NSRect(x: 16, y: y, width: 320, height: 18)
            root.addSubview(label)

            let button = NSButton(title: "去设置", target: self, action: #selector(openSettings(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            button.layer?.cornerRadius = 6
            button.contentTintColor = .white
            button.tag = missing.firstIndex(where: { $0.label == item.label }) ?? 0
            button.frame = NSRect(x: 350, y: y - 2, width: 56, height: 22)
            root.addSubview(button)
            settingsPanes[button.tag] = item.pane
            y -= 28
        }

        let dismiss = NSButton(title: "知道了", target: self, action: #selector(dismissBanner))
        dismiss.isBordered = false
        dismiss.contentTintColor = .white.withAlphaComponent(0.8)
        dismiss.frame = NSRect(x: 380, y: 8, width: 32, height: 18)
        root.addSubview(dismiss)

        panel.contentView = root
        let screen = NSScreen.main?.frame ?? .zero
        let x = screen.maxX - 440
        let bannerY = screen.maxY - 130
        panel.setFrame(NSRect(x: x, y: bannerY, width: 420, height: 120), display: true)
        panel.orderFrontRegardless()
    }

    private var settingsPanes: [Int: String] = [:]

    @objc private func openSettings(_ sender: NSButton) {
        guard let pane = settingsPanes[sender.tag] else { return }
        let url = URL(string: "x-apple.systempreferences:\(pane)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func dismissBanner() {
        permissionBanner?.orderOut(nil)
        permissionBanner = nil
    }
}
