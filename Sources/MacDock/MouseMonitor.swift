import AppKit

/// Polls the global mouse position and reports which native Dock icon is hovered.
final class MouseMonitor {
    weak var controller: OverlayController?
    private var timer: Timer?
    private var globalLeftMouseMonitor: Any?
    private var localLeftMouseMonitor: Any?
    private var globalMiddleMouseMonitor: Any?
    private var localMiddleMouseMonitor: Any?
    private var lastKey: String?
    private var overDock = false
    private var rightButtonDown = false
    private var rightClickSuppressedKey: String?
    private var hoverTimer: Timer?
    private var pendingSlot: NativeDockGeometry.IconSlot?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 1.0 / 60.0
        globalLeftMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.handleLeftMouseDown(at: NSEvent.mouseLocation)
        }
        localLeftMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleLeftMouseDown(at: NSEvent.mouseLocation)
            return event
        }
        globalMiddleMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard event.buttonNumber == 2 else { return }
            self?.handleMiddleMouseDown(at: NSEvent.mouseLocation)
        }
        localMiddleMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard event.buttonNumber == 2 else { return event }
            self?.handleMiddleMouseDown(at: NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        cancelHoverTimer()
        timer?.invalidate()
        timer = nil
        if let globalLeftMouseMonitor {
            NSEvent.removeMonitor(globalLeftMouseMonitor)
            self.globalLeftMouseMonitor = nil
        }
        if let localLeftMouseMonitor {
            NSEvent.removeMonitor(localLeftMouseMonitor)
            self.localLeftMouseMonitor = nil
        }
        if let globalMiddleMouseMonitor {
            NSEvent.removeMonitor(globalMiddleMouseMonitor)
            self.globalMiddleMouseMonitor = nil
        }
        if let localMiddleMouseMonitor {
            NSEvent.removeMonitor(localMiddleMouseMonitor)
            self.localMiddleMouseMonitor = nil
        }
        rightButtonDown = false
        rightClickSuppressedKey = nil
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingSlot = nil
    }

    private func tick() {
        guard let controller else { return }
        let mouse = NSEvent.mouseLocation  // bottom-left origin, AppKit space

        if AppSettings.shared.isPaused {
            cancelHoverTimer()
            if overDock || lastKey != nil {
                overDock = false
                lastKey = nil
                controller.previewController.closeAll()
            }
            return
        }

        // A right-click belongs to the Dock's context-menu interaction. Do
        // not let our hover feature compete with it: close any open preview,
        // suppress expansion while the button is held, and keep the current
        // icon suppressed until the pointer leaves it.
        let hoveredKey = controller.currentGeometry?.iconSlot(at: mouse)?.key
        let isRightButtonDown = (NSEvent.pressedMouseButtons & (1 << 1)) != 0
        if isRightButtonDown {
            if !rightButtonDown {
                rightButtonDown = true
                rightClickSuppressedKey = hoveredKey
                cancelHoverTimer()
                lastKey = nil
                overDock = false
                controller.previewController.closeAll()
            }
            return
        }
        rightButtonDown = false
        if let suppressedKey = rightClickSuppressedKey {
            if hoveredKey == suppressedKey { return }
            rightClickSuppressedKey = nil
        }

        // Over our own floating UI -> keep current preview open
        if controller.isOverOurPanels(at: mouse) { return }

        guard let geo = controller.currentGeometry else {
            if overDock || lastKey != nil || pendingSlot != nil {
                cancelHoverTimer()
                overDock = false
                lastKey = nil
                controller.previewController.itemExited()
            }
            return
        }

        // Preserve the current app while the pointer travels diagonally from
        // its Dock icon towards any card in the first-layer preview. At Dock
        // height the corridor stays narrow, so deliberate horizontal movement
        // still switches to a neighboring app immediately.
        if hoveredKey != lastKey,
           lastKey != nil,
           let panel = controller.previewController.smallPanelFrame,
           Self.isInPreviewApproachCorridor(
               mouse,
               source: controller.previewController.anchorRect,
               target: panel
           ) {
            return
        }

        if let slot = geo.iconSlot(at: mouse) {
            if lastKey != slot.key {
                lastKey = slot.key
                cancelHoverTimer()
                let isExcluded = slot.bundleID.map { AppSettings.shared.isExcluded(bundleID: $0) } ?? false
                if slot.isRunning && !isExcluded {
                    let isAlreadyShowing = controller.previewController.isShowing
                    let delay = isAlreadyShowing ? 0.04 : AppSettings.shared.hoverDelay
                    if delay <= 0.02 {
                        overDock = true
                        controller.previewNativeIcon(slot)
                    } else {
                        pendingSlot = slot
                        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                            guard let self, let pending = self.pendingSlot, self.lastKey == pending.key else { return }
                            self.overDock = true
                            self.controller?.previewNativeIcon(pending)
                            self.cancelHoverTimer()
                        }
                    }
                } else {
                    overDock = false
                    controller.previewController.closeAll()
                }
            } else if overDock {
                // Returning from the enlarged preview to the same Dock icon
                // should collapse only the second layer and keep the small
                // preview available above the icon.
                controller.previewController.returnedToDockIcon()
            }
        } else {
            if overDock || lastKey != nil || pendingSlot != nil {
                cancelHoverTimer()
                overDock = false
                lastKey = nil
                controller.previewController.itemExited()
            }
        }
    }

    private func handleLeftMouseDown(at point: NSPoint) {
        let perform = { [weak self] in
            guard let controller = self?.controller else { return }
            let handled = controller.previewController.performFirstLayerAction(at: point)
            if handled { Logger.log("first-layer mouse handled at \(point)") }
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }

    private func handleMiddleMouseDown(at point: NSPoint) {
        let perform = { [weak self] in
            guard let controller = self?.controller else { return }
            switch AppSettings.shared.middleClickAction {
            case .closeWindow:
                let handled = controller.previewController.performFirstLayerMiddleClick(at: point)
                if handled { Logger.log("first-layer middle click handled (close) at \(point)") }
            case .activateWindow:
                let handled = controller.previewController.performFirstLayerAction(at: point)
                if handled { Logger.log("first-layer middle click handled (activate) at \(point)") }
            case .none:
                break
            }
        }
        if Thread.isMainThread {
            perform()
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }

    static func isInPreviewApproachCorridor(
        _ point: NSPoint,
        source: NSRect,
        target: NSRect
    ) -> Bool {
        guard !source.isEmpty, !target.isEmpty else { return false }
        let startY = source.midY
        let endY = target.minY
        guard endY > startY,
              point.y >= startY - 4,
              point.y <= endY + 8 else { return false }

        let progress = min(max((point.y - startY) / (endY - startY), 0), 1)
        let sourceLeft = source.minX - 12
        let sourceRight = source.maxX + 12
        let targetLeft = target.minX - 10
        let targetRight = target.maxX + 10
        let left = sourceLeft + (targetLeft - sourceLeft) * progress
        let right = sourceRight + (targetRight - sourceRight) * progress
        return point.x >= left && point.x <= right
    }
}
