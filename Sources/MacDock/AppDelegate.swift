import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayController?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = OverlayController()
        controller.show()
        overlayController = controller
        observeWorkspace()
        // First-launch permission prompts
        ScreenCapture.requestAccess()
        WindowActions.requestAccess()
        controller.refreshPermissionBanner()
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            BackgroundThumbnailRecorder.shared.captureVisibleWindows(of: frontmost, after: 0.8)
        }
        Logger.log("launch")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        overlayController?.state.refreshRunningApps()
        overlayController?.refreshGeometry()
        overlayController?.refreshPermissionBanner()
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.overlayController?.state.refreshRunningApps()
            self?.overlayController?.refreshGeometry()
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.overlayController?.state.refreshRunningApps()
            self?.overlayController?.refreshGeometry()
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            BackgroundThumbnailRecorder.shared.captureVisibleWindows(of: app, after: 0.6)
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            BackgroundThumbnailRecorder.shared.captureVisibleWindows(of: app)
        })
    }
}
