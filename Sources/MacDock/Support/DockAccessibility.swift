import AppKit
import ApplicationServices

/// Reads the Dock's live item frames through Accessibility. Unlike a
/// preference-file estimate, this follows magnification, inserted apps and
/// the right-side stacks while the Dock is animating.
enum DockAccessibility {
    struct ItemFrame {
        let title: String
        let rect: CGRect
    }

    static func itemFrames() -> [ItemFrame] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }

        let appElement = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [ItemFrame] = []
        // Dock items live under AXList directly; Dock does not expose them as
        // normal AX windows on recent macOS versions.
        walk(appElement, depth: 0, result: &result)
        return result.sorted { $0.rect.minX < $1.rect.minX }
    }

    private static func walk(_ element: AXUIElement, depth: Int, result: inout [ItemFrame]) {
        guard depth < 10 else { return }

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        let isDockItem = role == "AXDockItem" || subrole.contains("DockItem")
        if isDockItem, let rect = frameAttribute(element) {
            result.append(ItemFrame(title: stringAttribute(element, kAXTitleAttribute as CFString) ?? "",
                                    rect: rect))
            return
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, result: &result)
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func frameAttribute(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        let position = unsafeBitCast(positionRef, to: AXValue.self)
        let size = unsafeBitCast(sizeRef, to: AXValue.self)
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &cgSize),
              cgSize.width > 0, cgSize.height > 0 else { return nil }
        // AX positions are reported from the top-left of the display, while
        // NSEvent.mouseLocation and NSWindow frames use bottom-left.
        let topLeftFrame = CGRect(origin: point, size: cgSize)
        let screenMaxY = NSScreen.main?.frame.maxY ?? 0
        return CGRect(x: topLeftFrame.minX,
                      y: screenMaxY - topLeftFrame.maxY,
                      width: topLeftFrame.width,
                      height: topLeftFrame.height)
    }
}
