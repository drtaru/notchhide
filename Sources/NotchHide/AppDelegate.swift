import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var autoItem: NSMenuItem!
    private var statusLine: NSMenuItem!
    private var timer: Timer?
    private let queue = DispatchQueue(label: "notchhide.process", qos: .userInitiated)
    private let defaults = UserDefaults.standard
    private let originalsKey = "originals"   // [screenID: original wallpaper path]
    private let autoKey = "autoApply"
    private let allKey = "allDisplays"
    private var allItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "statusIcon")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchHide")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true   // adapts to light/dark menu bar
        statusItem.button?.image = icon

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Notch Now", action: #selector(applyNow), keyEquivalent: "").target = self
        autoItem = NSMenuItem(title: "Auto-apply on wallpaper change", action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        menu.addItem(autoItem)
        allItem = NSMenuItem(title: "Apply to all displays", action: #selector(toggleAll), keyEquivalent: "")
        allItem.target = self
        menu.addItem(allItem)
        loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Restore Original Wallpaper", action: #selector(restoreAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu

        defaults.register(defaults: [autoKey: true])
        autoItem.state = defaults.bool(forKey: autoKey) ? .on : .off
        allItem.state = defaults.bool(forKey: allKey) ? .on : .off
        refreshLoginState()
        updateWatching()

        // Menu click triggers a fresh pass only in auto mode; otherwise use Hide Notch Now.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { [weak self] _ in
            self?.refreshLoginState()
            guard let self, self.defaults.bool(forKey: self.autoKey) else { return }
            self.applyAll()
        }
    }

    // MARK: Watching

    private func updateWatching() {
        timer?.invalidate(); timer = nil
        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self)
        guard defaults.bool(forKey: autoKey) else { return }

        let trigger: (Notification) -> Void = { [weak self] _ in self?.applyAll() }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: trigger)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: trigger)
        // Wallpaper changes in System Settings post no public notification; poll cheaply.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.applyAll() }
        applyAll()
    }

    // MARK: Actions

    @objc private func applyNow() { applyAll() }

    @objc private func toggleAuto() {
        defaults.set(!defaults.bool(forKey: autoKey), forKey: autoKey)
        autoItem.state = defaults.bool(forKey: autoKey) ? .on : .off
        updateWatching()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            setStatus("Login item failed: \(error.localizedDescription)")
        }
        refreshLoginState()
    }

    /// SMAppService is the source of truth; the user can also change it in System Settings.
    private func refreshLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
    }

    @objc private func toggleAll() {
        let on = !defaults.bool(forKey: allKey)
        defaults.set(on, forKey: allKey)
        allItem.state = on ? .on : .off
        if on {
            applyAll()
        } else {
            // Internal-only: undo what we applied to external displays.
            restore(screens: NSScreen.screens.filter { !WallpaperProcessor.isBuiltIn($0) })
        }
    }

    @objc private func restoreAll() { restore(screens: NSScreen.screens) }

    private func restore(screens: [NSScreen]) {
        var originals = defaults.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        for screen in screens {
            let id = screenID(screen)
            guard let path = originals[id] else { continue }
            let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: opts)
            originals[id] = nil
        }
        defaults.set(originals, forKey: originalsKey)
        setStatus("Restored original")
    }

    // MARK: Core

    private func applyAll() {
        let ws = NSWorkspace.shared
        let all = defaults.bool(forKey: allKey)
        for screen in NSScreen.screens where all || WallpaperProcessor.isBuiltIn(screen) {
            guard let current = ws.desktopImageURL(for: screen) else { continue }
            if WallpaperProcessor.isProcessed(current) { continue }   // already ours
            let id = screenID(screen)
            queue.async { [weak self] in
                do {
                    let out = try WallpaperProcessor.process(source: current, for: screen)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Re-check: user may have changed wallpaper while rendering.
                        guard ws.desktopImageURL(for: screen) == current else { return }
                        var originals = self.defaults.dictionary(forKey: self.originalsKey) as? [String: String] ?? [:]
                        originals[id] = current.path
                        self.defaults.set(originals, forKey: self.originalsKey)
                        let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
                            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                            .allowClipping: true,
                        ]
                        do {
                            try ws.setDesktopImageURL(out, for: screen, options: opts)
                            self.setStatus("Applied: \(current.lastPathComponent)")
                        } catch {
                            self.setStatus("Set failed: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    DispatchQueue.main.async { self?.setStatus(error.localizedDescription) }
                }
            }
        }
    }

    private func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
    }
}
