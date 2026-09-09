import AppKit
import Foundation

// CLI self-test modes (run the bare binary directly, not the .app)
let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--hover-test"), args.count >= idx + 4,
   let hx = Double(args[idx + 1]), let hy = Double(args[idx + 2]), let hold = Double(args[idx + 3]) {
    if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                       mouseCursorPosition: CGPoint(x: hx, y: hy), mouseButton: .left) {
        e.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: hold)
    if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                       mouseCursorPosition: CGPoint(x: 1280, y: 700), mouseButton: .left) {
        e.post(tap: .cghidEventTap)
    }
    exit(0)
}
if let idx = args.firstIndex(of: "--click-test"), args.count >= idx + 3,
   let x = Double(args[idx + 1]), let y = Double(args[idx + 2]) {
    let point = CGPoint(x: x, y: y)
    if let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left) {
        moved.post(tap: .cghidEventTap)
    }
    usleep(100_000)
    if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                          mouseCursorPosition: point, mouseButton: .left) {
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                        mouseCursorPosition: point, mouseButton: .left) {
        up.post(tap: .cghidEventTap)
    }
    exit(0)
}
if args.contains("--cgwindow-test") {
    let info = WindowEnumerator.allWindows()
    var report = "no chrome window"
    if let chrome = info.first(where: { $0.ownerName == "Google Chrome" && $0.layer == 0 }) {
        let img = CGWindowListCreateImage(.null, .optionIncludingWindow, chrome.id, [.boundsIgnoreFraming])
        report = "window=\(chrome.id) bounds=\(chrome.bounds) image=\(img == nil ? "nil" : "\(img!.width)x\(img!.height)")"
        if let img {
            let rep = NSBitmapImageRep(cgImage: img)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/cgwindow_test.png"))
            }
        }
    }
    try? report.write(toFile: "/tmp/cgwindow_test.txt", atomically: true, encoding: .utf8)
    exit(0)
}
if args.contains("--verify-align") {
    var report: [String] = []
    func move(_ p: CGPoint) {
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
            e.post(tap: .cghidEventTap)
        }
        usleep(150_000)
    }
    if let geo = NativeDockGeometry.current() {
        report.append("bar=\(geo.dockBarRect) cell=\(geo.cellWidth)")
        let screen = NSScreen.main?.frame ?? .zero
        for slot in geo.iconSlots where slot.isRunning {
            // CGEvent mouse coordinates use a top-left origin while the
            // geometry model uses AppKit's bottom-left origin.
            move(CGPoint(x: slot.rect.midX, y: screen.maxY - slot.rect.midY))
            Thread.sleep(forTimeInterval: 3.0)
            var nativeCenter: CGFloat? = nil
            if let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                for w in raw {
                    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
                    if owner.contains("Dock") || owner.contains("程序坞") {
                    if let b = WindowEnumerator.bounds(from: w[kCGWindowBounds as String]),
                       b.width >= 200, b.width <= 700 {
                        nativeCenter = b.midX
                        break
                    }
                    }
                }
            }
            if let nc = nativeCenter {
                report.append("\(slot.name): est=\(Int(slot.rect.midX)) native=\(Int(nc)) diff=\(Int(nc - slot.rect.midX))")
            } else {
                report.append("\(slot.name): est=\(Int(slot.rect.midX)) native=none")
            }
        }
        move(CGPoint(x: screen.midX, y: screen.midY))
    }
    try? report.joined(separator: "\n").write(toFile: "/tmp/align_report.txt", atomically: true, encoding: .utf8)
    exit(0)
}
if args.contains("--run-tests") {
    exit(Int32(TestSuite.run()))
}
if args.contains("--dump-dock-geometry") {
    if let geo = NativeDockGeometry.current() {
        print("dockAccessibilityFrames=\(DockAccessibility.itemFrames().count)")
        print("dockBarRect=\(geo.dockBarRect) tile=\(geo.tileSize) cell=\(geo.cellWidth) mag=\(geo.magnificationEnabled)")
        for slot in geo.iconSlots {
            print("  [\(slot.index)] \(slot.name) \(slot.bundleID ?? "?") rect=\(slot.rect)")
        }
    } else {
        print("geometry unavailable (dock not at bottom?)")
    }
    exit(0)
}
if args.contains("--dump-windows") {
    for w in WindowEnumerator.allWindows() {
        print("\(w.ownerName) | pid=\(w.ownerPID ?? 0) | \(w.title) | layer=\(w.layer) | onscreen=\(w.isOnScreen) | \(w.bounds)")
    }
    exit(0)
}
if args.contains("--capture-test") {
    var reportLines: [String] = []
    reportLines.append("screenRecording=\(ScreenCapture.isAuthorized)")
    reportLines.append("accessibility=\(WindowActions.isTrusted)")
    if let img = ScreenCapture.captureScreenForTest() {
        reportLines.append("captured \(img.width)x\(img.height)")
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/macdock_capture_test.png"))
        }
    } else {
        reportLines.append("capture returned nil")
    }
    try? reportLines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/macdock_capture_test.txt"), atomically: true, encoding: .utf8)
    exit(0)
}
if args.contains("--selftest") {
    print("screenRecordingAuthorized=\(ScreenCapture.isAuthorized)")
    print("accessibilityTrusted=\(WindowActions.isTrusted)")
    if let img = ScreenCapture.captureScreenForTest() {
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/macdock_selftest.png"))
            print("captured \(img.width)x\(img.height) -> /tmp/macdock_selftest.png")
        }
    } else {
        print("capture failed (no permission?)")
    }
    exit(0)
}

if args.contains("--version") || args.contains("-v") {
    print("MacDock 1.0.0")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if args.contains("--settings") || args.contains("-p") {
    DispatchQueue.main.async {
        SettingsWindowController.shared.show()
    }
}
app.run()
