import AppKit
import Combine

/// Manages the macOS menu bar status item and its drop-down menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var statusTitleItem: NSMenuItem?
    private var pauseToggleItem: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        buildMenu()
        updateStatusItemVisibility()
        observeSettings()
    }

    private func observeSettings() {
        AppSettings.shared.$showMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemVisibility()
            }
            .store(in: &cancellables)

        AppSettings.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuState()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemVisibility() {
        if AppSettings.shared.showMenuBarIcon {
            if statusItem == nil {
                setupStatusItem()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "menubar.dock.rectangle",
                accessibilityDescription: "MacDock"
            ) ?? NSImage(
                systemSymbolName: "macwindow.on.rectangle",
                accessibilityDescription: "MacDock"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MacDock 原生程序坞增强"
        }
        item.menu = menu
        statusItem = item
        updateMenuState()
    }

    private func buildMenu() {
        menu.delegate = self

        // 1. App Title & Version
        let titleItem = NSMenuItem(title: "MacDock (v1.0.0)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        statusTitleItem = titleItem

        // 2. Pause / Resume Toggle
        let pauseItem = NSMenuItem(title: "暂停预览", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        pauseToggleItem = pauseItem

        menu.addItem(NSMenuItem.separator())

        // 3. Preferences...
        let prefsItem = NSMenuItem(title: "偏好设置...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // 4. Permission Status
        let permItem = NSMenuItem(title: "系统权限状态", action: nil, keyEquivalent: "")
        let permSubmenu = NSMenu()
        permItem.submenu = permSubmenu
        menu.addItem(permItem)
        permissionMenuItem = permItem

        menu.addItem(NSMenuItem.separator())

        // 5. Quit
        let quitItem = NSMenuItem(title: "退出 MacDock", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
        refreshPermissionSubmenu()
    }

    private func updateMenuState() {
        let isPaused = AppSettings.shared.isPaused
        pauseToggleItem?.title = isPaused ? "恢复预览" : "暂停预览"
        statusTitleItem?.title = isPaused ? "MacDock (已暂停)" : "MacDock (运行中)"
        if let button = statusItem?.button {
            button.appearsDisabled = isPaused
        }
    }

    private func refreshPermissionSubmenu() {
        guard let submenu = permissionMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let screenOk = ScreenCapture.isAuthorized
        let axOk = WindowActions.isTrusted

        let screenItem = NSMenuItem(
            title: "屏幕录制: \(screenOk ? "已授权 ✓" : "未授权 ✕")",
            action: screenOk ? nil : #selector(openScreenCapturePref),
            keyEquivalent: ""
        )
        screenItem.target = self
        screenItem.isEnabled = !screenOk
        submenu.addItem(screenItem)

        let axItem = NSMenuItem(
            title: "辅助功能: \(axOk ? "已授权 ✓" : "未授权 ✕")",
            action: axOk ? nil : #selector(openAccessibilityPref),
            keyEquivalent: ""
        )
        axItem.target = self
        axItem.isEnabled = !axOk
        submenu.addItem(axItem)

        if !screenOk || !axOk {
            submenu.addItem(NSMenuItem.separator())
            let guideItem = NSMenuItem(title: "点击未授权项跳转至系统设置", action: nil, keyEquivalent: "")
            guideItem.isEnabled = false
            submenu.addItem(guideItem)
        }
    }

    @objc private func togglePause() {
        AppSettings.shared.isPaused.toggle()
        updateMenuState()
    }

    @objc private func openPreferences() {
        SettingsWindowController.shared.show()
    }

    @objc private func openScreenCapturePref() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibilityPref() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
