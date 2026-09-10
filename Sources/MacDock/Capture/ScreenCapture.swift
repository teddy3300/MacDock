import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One-shot window/screen capture via ScreenCaptureKit.
enum ScreenCapture {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    private static var cachedShareableWindows: [CGWindowID: SCWindow] = [:]
    private static var shareableWindowsLoadedAt = Date.distantPast
    private static var loadingShareableWindows = false
    private static var shareableWindowWaiters: [(CGWindowID, (SCWindow?) -> Void)] = []

    static func requestAccess() {
        guard !isAuthorized else { return }
        CGRequestScreenCaptureAccess()
    }

    /// Capture `rect` (top-left screen points). When `excludeRects` is non-empty,
    /// those regions are copied over from `cleanBase` (a frame captured with our
    /// overlay hidden) so our own preview panels never appear in the result.
    static func capture(rect: CGRect, excludeRects: [CGRect] = [], cleanBase: CGImage? = nil,
                         completion: @escaping (CGImage?) -> Void) {
        guard isAuthorized else {
            Logger.log("capture skipped: screen recording NOT authorized")
            completion(nil)
            return
        }
        if #available(macOS 15.2, *) {
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error { Logger.log("capture error: \(error)") }
                guard let image else { completion(nil); return }
                finish(image, rect: rect, excludeRects: excludeRects, cleanBase: cleanBase, completion: completion)
            }
        } else {
            // SCScreenshotManager.captureImage(in:) is only available on
            // macOS 15.2+. Keep the app usable on the package's macOS 14
            // deployment target with the older CGWindow API.
            DispatchQueue.global(qos: .userInitiated).async {
                let image = CGWindowListCreateImage(rect, .optionOnScreenOnly,
                                                     kCGNullWindowID, [.bestResolution])
                if let image {
                    finish(image, rect: rect, excludeRects: excludeRects,
                           cleanBase: cleanBase, completion: completion)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private static func finish(_ image: CGImage, rect: CGRect, excludeRects: [CGRect],
                               cleanBase: CGImage?, completion: @escaping (CGImage?) -> Void) {
        if excludeRects.isEmpty {
            Logger.log("capture ok \(rect)")
            completion(image)
            return
        }
        Logger.log("capture ok(erased) \(rect)")
        guard let cleanBase else {
            completion(image)
            return
        }
        completion(eraseRegions(in: image, rect: rect, excludeRects: excludeRects, cleanBase: cleanBase) ?? image)
    }

    /// Overwrites `excludeRects` (top-left screen points) of `image` with the
    /// matching region from `cleanBase` (same capture rect, same pixel size).
    private static func eraseRegions(in image: CGImage, rect: CGRect, excludeRects: [CGRect], cleanBase: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scale = CGFloat(image.width) / rect.width
        for r in excludeRects where r.intersects(rect) {
            let px = CGRect(x: (r.minX - rect.minX) * scale,
                            y: (r.minY - rect.minY) * scale,
                            width: r.width * scale,
                            height: r.height * scale)
            ctx.saveGState()
            ctx.clip(to: px)
            ctx.draw(cleanBase, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Capture one window independently from the composited display. Asking
    /// ScreenCaptureKit for off-screen windows is important: minimized windows
    /// can still expose their last WindowServer frame even though they are not
    /// part of an on-screen-only list.
    static func captureWindow(_ window: WindowInfo, completion: @escaping (CGImage?) -> Void) {
        guard isAuthorized else {
            Logger.log("window capture skipped: screen recording NOT authorized")
            completion(nil)
            return
        }
        shareableWindow(for: window.id) { shareableWindow in
            guard let shareableWindow else {
                legacyCaptureWindow(window, completion: completion)
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
            let configuration = SCStreamConfiguration()
            let frame = shareableWindow.frame
            let nativeScale = NSScreen.main?.backingScaleFactor ?? 2
            let boundedScale = min(nativeScale, 2560 / max(max(frame.width, frame.height), 1))
            let scale = max(0.5, boundedScale)
            configuration.width = max(1, Int(frame.width * scale))
            configuration.height = max(1, Int(frame.height * scale))
            configuration.sourceRect = .zero
            configuration.scalesToFit = true
            configuration.showsCursor = false
            configuration.capturesAudio = false
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    Logger.log("ScreenCaptureKit window \(window.id) failed: \(error)")
                }
                guard let image else {
                    legacyCaptureWindow(window, completion: completion)
                    return
                }
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    static func shareableWindow(
        for id: CGWindowID,
        completion: @escaping (SCWindow?) -> Void
    ) {
        DispatchQueue.main.async {
            let cacheIsFresh = Date().timeIntervalSince(shareableWindowsLoadedAt) < 5
            if cacheIsFresh, let window = cachedShareableWindows[id] {
                completion(window)
                return
            }
            shareableWindowWaiters.append((id, completion))
            guard !loadingShareableWindows else { return }
            loadingShareableWindows = true
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ) { content, error in
                DispatchQueue.main.async {
                    if let error {
                        Logger.log("shareable window list failed: \(error)")
                    }
                    cachedShareableWindows = Dictionary(
                        uniqueKeysWithValues: (content?.windows ?? []).map { ($0.windowID, $0) }
                    )
                    shareableWindowsLoadedAt = Date()
                    loadingShareableWindows = false
                    let waiters = shareableWindowWaiters
                    shareableWindowWaiters.removeAll()
                    for (windowID, callback) in waiters {
                        callback(cachedShareableWindows[windowID])
                    }
                }
            }
        }
    }

    private static func legacyCaptureWindow(
        _ window: WindowInfo,
        completion: @escaping (CGImage?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = CGWindowListCreateImage(.null, .optionIncludingWindow, window.id,
                                              [.boundsIgnoreFraming])
            DispatchQueue.main.async {
                completion(img)
            }
        }
    }

    /// Synchronous whole-main-screen capture used by --capture-test.
    static func captureScreenForTest() -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: CGImage?
        capture(rect: screen.frame) { image in
            result = image
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }
}
