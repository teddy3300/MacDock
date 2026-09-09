import CoreGraphics
import Foundation
import AppKit
import ApplicationServices

struct WindowInfo: Equatable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t?
    let title: String
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool
}

enum WindowEnumerator {
    private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        return nil
    }

    /// Core Graphics returns window dictionaries backed by NSNumber values.
    /// Do not rely on a direct `[String: CGFloat]` cast: it varies by SDK and
    /// can silently make every window look like it has a null-sized bounds.
    static func bounds(from value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = number(dict["X"]),
              let y = number(dict["Y"]),
              let width = number(dict["Width"]),
              let height = number(dict["Height"]),
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func parseWindow(_ dict: [String: Any]) -> WindowInfo? {
        guard let id = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              id != 0 else { return nil }
        let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
        let ownerPID = (dict[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.intValue) }
        let title = dict[kCGWindowName as String] as? String ?? ""
        let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let onScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
        guard let bounds = bounds(from: dict[kCGWindowBounds as String]) else { return nil }
        return WindowInfo(id: id, ownerName: owner, ownerPID: ownerPID, title: title,
                          bounds: bounds, layer: layer, isOnScreen: onScreen)
    }

    static func allWindows() -> [WindowInfo] {
        // optionAll is required here: minimized application windows are not
        // marked on-screen, but they still have a valid WindowServer record.
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap(parseWindow)
    }

    private static func normalWindows(ownerPID: pid_t? = nil, ownerNames: Set<String>? = nil) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            // Filter inexpensive metadata before constructing WindowInfo for
            // every other application window on the system.
            guard ((dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0 else { return nil }
            if let ownerPID {
                guard (dict[kCGWindowOwnerPID as String] as? NSNumber).map({ pid_t($0.intValue) }) == ownerPID else { return nil }
            }
            if let ownerNames {
                guard let owner = dict[kCGWindowOwnerName as String] as? String,
                      ownerNames.contains(owner) else { return nil }
            }
            guard let window = parseWindow(dict), window.bounds.width > 60, window.bounds.height > 40 else { return nil }
            return window
        }
    }

    /// Normal windows owned by any of the given owner names, frontmost first.
    /// Off-screen entries are retained so minimized windows still appear.
    static func normalWindows(forOwnerNames names: [String]) -> [WindowInfo] {
        normalWindows(ownerNames: Set(names))
    }

    static func frontmostWindow(forOwnerNames names: [String]) -> WindowInfo? {
        normalWindows(forOwnerNames: names).first
    }

    static func normalWindows(forOwnerPID pid: pid_t) -> [WindowInfo] {
        normalWindows(ownerPID: pid)
    }

    /// Returns all user-facing windows for an app. CGWindowList is ordered
    /// front-to-back, which gives a stable order while still showing every
    /// document window (including minimized ones).
    static func previewWindows(forOwnerPID pid: pid_t, ownerName: String) -> [WindowInfo] {
        let candidates = normalWindows(forOwnerPID: pid).filter { !isKnownTransientWindow($0) }

        // CGWindowList also exposes menu bars, service surfaces and duplicate
        // backing layers. Prefer on-screen windows when there is at least one;
        // when an app is minimized, keep only titled records (or the single
        // largest untitled record) so a one-window app does not become two or
        // five blank cards.
        var result: [WindowInfo]
        let onScreen = candidates.filter(\.isOnScreen)
        if !onScreen.isEmpty {
            // Keep every on-screen record: two real Chrome windows can have
            // the same size and even the same tab title, so geometry/title
            // deduplication would incorrectly merge them.
            result = onScreen
            if ownerName == "Google Chrome" {
                // Chrome can keep a legitimate second window on another
                // Space/off-screen. Its titled records are real browser
                // windows, unlike the untitled tab bars and popovers filtered
                // above.
                result += candidates.filter {
                    !$0.isOnScreen && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
        } else {
            let titled = candidates.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            result = titled.isEmpty
                ? Array(candidates.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }.prefix(1))
                : titled
            if ownerName == "微信" || ownerName == "WeChat" {
                result = Array(result.sorted {
                    $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height
                }.prefix(1))
            }
        }

        guard AXIsProcessTrusted(), result.isEmpty else { return result }

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return result }

        let existingTitles = Set(result.map { $0.title }.filter { !$0.isEmpty })
        let tinyCGWindows = allWindows().filter {
            $0.ownerPID == pid && $0.layer == 0 && $0.bounds.width <= 2 && $0.bounds.height <= 2
        }
        var tinyIndex = 0
        for axWindow in axWindows {
            guard axBoolAttribute(axWindow, kAXMinimizedAttribute as CFString) == true,
                  let title = axStringAttribute(axWindow, kAXTitleAttribute as CFString),
                  !title.isEmpty, !existingTitles.contains(title) else { continue }

            let id: CGWindowID
            if tinyIndex < tinyCGWindows.count {
                id = tinyCGWindows[tinyIndex].id
                tinyIndex += 1
            } else {
                // Some apps do not publish a WindowServer record while
                // minimized. Keep a stable synthetic id for the title card;
                // activation/close still use the AX title/geometry fallback.
                id = CGWindowID(abs(title.hashValue) | 1)
            }
            result.append(WindowInfo(id: id, ownerName: ownerName, ownerPID: pid,
                                     title: title, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                     layer: 0, isOnScreen: false))
        }
        return result
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func axBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func isKnownTransientWindow(_ window: WindowInfo) -> Bool {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let translationTerms = ["google translate", "translate this page", "翻译", "翻譯"]
        if translationTerms.contains(where: { title.contains($0) }) { return true }

        // Chrome translation/tool popovers are usually untitled and tiny. Do
        // not reject every small Chrome window: a legitimate second browser
        // window must remain visible in the preview.
        if window.ownerName == "Google Chrome" && title.isEmpty &&
           (window.bounds.width < 600 || window.bounds.height < 400) {
            return true
        }
        return false
    }
}
