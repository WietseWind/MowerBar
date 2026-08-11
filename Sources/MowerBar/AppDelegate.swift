import AppKit
import ServiceManagement

/// Carried on each action menu item so one selector can serve every command.
private final class ActionRequest: NSObject {
    let deviceId: String
    let action: MowerAction
    let taskName: String?

    init(deviceId: String, action: MowerAction, taskName: String? = nil) {
        self.deviceId = deviceId
        self.action = action
        self.taskName = taskName
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var monitor: FleetMonitor!
    private var settingsWindow: SettingsWindowController?
    private var appearanceObserver: NSKeyValueObservation?

    // Rebuilding the menu wholesale on every poll makes the panel flicker and
    // jump, and collapses any open submenu. Instead the structure is built once
    // per fleet change and then updated in place, guarded by these signatures.
    private var mowerItems: [String: NSMenuItem] = [:]
    private var titleSignatures: [String: String] = [:]
    private var submenuSignatures: [String: String] = [:]
    private var builtForIds: [String] = []
    private var builtWithNotificationsBlocked = false
    private var statusLineItem: NSMenuItem?
    private var trayImageKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Store.loadConfig()
        monitor = FleetMonitor(config: config)
        monitor.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.syncMenu()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = AppInfo.name
        menu.delegate = self
        // Enablement is decided per item from the mower's current status, not by AppKit.
        menu.autoenablesItems = false
        statusItem.menu = menu

        // A literal (badged) icon has to be re-tinted when the menu bar flips
        // between light and dark; a template icon is handled by AppKit.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateStatusItem() }
        }

        updateStatusItem()
        buildMenu()
        monitor.requestNotificationAuthorization()
        monitor.start()
    }

    // MARK: - Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        // One red dot for anything that needs looking at — offline, faulted, or
        // stalled mid-job. The per-mower dots inside the menu keep the finer
        // distinction between "broken" and "paused".
        let badge: NSColor? = monitor.alertLevel == nil ? nil : .systemRed

        let height = CGFloat(monitor.config.trayIconHeight)
        let tint = resolvedTint(for: button)
        // Reassigning an identical image still forces a redraw, which reads as a
        // blink in the menu bar on every poll. Only touch it when it changes.
        let key = "\(height)|\(badge == nil ? "plain" : "alert")|\(tint.hexKey)"
        if key != trayImageKey {
            trayImageKey = key
            button.image = MowerIcon.trayImage(height: height, tint: tint, badge: badge)
            button.imagePosition = .imageOnly
        }

        let attention = monitor.mowers.filter { $0.health == .alert }
        button.toolTip = attention.isEmpty
            ? "\(AppInfo.name) — \(monitor.mowers.count) mower\(monitor.mowers.count == 1 ? "" : "s")"
            : "\(AppInfo.name) — " + attention.map { "\($0.name): \($0.isStalled ? "stuck" : $0.stateLabel)" }
                .joined(separator: ", ")
    }

    /// `labelColor` is appearance-dependent, so resolve it against the menu bar's
    /// own appearance before baking it into a non-template image.
    private func resolvedTint(for button: NSStatusBarButton) -> NSColor {
        var color = NSColor.labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    /// Cached so an unchanged row is handed the very same image object.
    private var dotCache: [String: NSImage] = [:]

    private func dot(for health: MowerHealth) -> NSImage {
        let key = String(describing: health)
        if let cached = dotCache[key] { return cached }
        let color: NSColor
        switch health {
        case .active: color = .systemGreen
        case .charging: color = .systemBlue
        case .idle: color = .tertiaryLabelColor
        case .alert: color = .systemRed
        }
        let image = MowerIcon.dot(color)
        dotCache[key] = image
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        syncMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        monitor.refreshIfStale()
        monitor.refreshNotificationStatus()
    }

    /// Cheap path: touch only what actually changed. Falls back to a full
    /// rebuild when the set of mowers itself changes.
    private func syncMenu() {
        let ids = monitor.mowers.map(\.id)
        guard ids == builtForIds,
              monitor.notificationsBlocked == builtWithNotificationsBlocked,
              !ids.isEmpty
        else { return buildMenu() }

        for mower in monitor.mowers {
            guard let item = mowerItems[mower.id] else { return buildMenu() }
            update(item, for: mower)
        }
        statusLineItem?.title = monitor.statusLine
    }

    private func update(_ item: NSMenuItem, for mower: MowerState) {
        let title = "\(mower.name) — \(mower.summary)"
        let titleSignature = "\(title)|\(mower.health)"
        if titleSignatures[mower.id] != titleSignature {
            titleSignatures[mower.id] = titleSignature
            item.title = title
            item.image = dot(for: mower.health)
        }

        // Only rebuild a submenu when its contents would differ — otherwise an
        // open submenu would collapse under the user's cursor every poll.
        let signature = submenuSignature(for: mower)
        if submenuSignatures[mower.id] != signature {
            submenuSignatures[mower.id] = signature
            if let submenu = item.submenu { populate(submenu, for: mower) }
        }
    }

    private func submenuSignature(for mower: MowerState) -> String {
        var parts: [String] = []
        parts.append(mower.availableActions.map(\.rawValue).joined(separator: ","))
        parts.append(mower.startableTasks.compactMap(\.taskName).joined(separator: ","))
        parts.append(mower.status.label)
        parts.append(mower.error ?? "")
        parts.append(mower.model ?? "")
        parts.append(mower.detail?.version ?? "")
        parts.append(mower.detail?.network?.summary ?? "")
        parts.append(mower.isDocked ? "docked" : "off")
        parts.append(mower.isCharging ? "charging" : "notcharging")
        parts.append(mower.isOnline ? "online" : "offline")
        if let lastSeen = mower.lastSeen {
            parts.append("seen:" + Self.relative(lastSeen))
        } else {
            parts.append("live")
        }
        return parts.joined(separator: "|")
    }

    private func buildMenu() {
        menu.removeAllItems()
        mowerItems.removeAll()
        titleSignatures.removeAll()
        submenuSignatures.removeAll()
        builtForIds = monitor.mowers.map(\.id)
        builtWithNotificationsBlocked = monitor.notificationsBlocked

        if !monitor.config.isConfigured {
            menu.addItem(disabled("No credentials configured"))
        } else if monitor.mowers.isEmpty {
            menu.addItem(disabled(monitor.lastUpdate == nil ? "Loading…" : "No mowers found"))
        }

        for mower in monitor.mowers {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            item.submenu = submenu
            menu.addItem(item)
            mowerItems[mower.id] = item
            update(item, for: mower)
        }

        menu.addItem(.separator())
        let status = disabled(monitor.statusLine)
        statusLineItem = status
        menu.addItem(status)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        if monitor.notificationsBlocked {
            let fix = NSMenuItem(title: "Notifications are off — Turn On…",
                                 action: #selector(openNotificationSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let openConfig = NSMenuItem(title: "Reveal Config File", action: #selector(revealConfig), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func populate(_ submenu: NSMenu, for mower: MowerState) {
        submenu.removeAllItems()
        let actions = mower.availableActions

        for action in actions {
            let entry = NSMenuItem(title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = ActionRequest(deviceId: mower.id, action: action)
            submenu.addItem(entry)
        }

        // Saved plans start by name; only offered when the mower is idle and has some.
        let tasks = mower.startableTasks
        if !tasks.isEmpty {
            let parent = NSMenuItem(title: "Start Task", action: nil, keyEquivalent: "")
            let taskMenu = NSMenu()
            taskMenu.autoenablesItems = false
            for task in tasks {
                guard let name = task.taskName else { continue }
                let entry = NSMenuItem(title: name, action: #selector(performAction(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = ActionRequest(deviceId: mower.id, action: .start, taskName: name)
                taskMenu.addItem(entry)
            }
            parent.submenu = taskMenu
            submenu.addItem(parent)
        }

        if actions.isEmpty && tasks.isEmpty {
            submenu.addItem(disabled(mower.isOnline ? "No actions while \(mower.status.label.lowercased())"
                                                    : "Out of reach"))
        }

        submenu.addItem(.separator())
        if let error = mower.error {
            submenu.addItem(disabled(error))
        }
        if let lastSeen = mower.lastSeen {
            submenu.addItem(disabled("Last seen \(Self.relative(lastSeen))"))
        }
        if let model = mower.model {
            let version = mower.detail?.version ?? ""
            submenu.addItem(disabled(version.isEmpty ? model : "\(model) · v\(version)"))
        }
        if let network = mower.detail?.network?.summary {
            submenu.addItem(disabled(network))
        }
        submenu.addItem(disabled(mower.isDocked ? "On dock" : "Off dock"))

        let copy = NSMenuItem(title: "Copy Device ID", action: #selector(copyDeviceId(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = mower.id as NSString
        submenu.addItem(copy)

        if mower.isRemembered {
            let forget = NSMenuItem(title: "Forget This Mower", action: #selector(forgetMower(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = mower.id as NSString
            submenu.addItem(forget)
        }
    }

    /// "3 min ago" / "2 days ago", for last-seen timestamps.
    static func relative(_ date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default:
            let days = seconds / 86_400
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Commands

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ActionRequest else { return }
        monitor.send(request.action, to: request.deviceId, taskName: request.taskName) { [weak self] message in
            self?.presentError("Command failed", message)
        }
    }

    @objc private func refreshNow() {
        monitor.refresh()
    }

    @objc private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func forgetMower(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSString else { return }
        monitor.forget(id as String)
    }

    @objc private func copyDeviceId(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id as String, forType: .string)
    }

    @objc private func revealConfig() {
        Store.saveConfig(monitor.config)
        NSWorkspace.shared.activateFileViewerSelecting([Store.configURL])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentError("Could not change the login item", error.localizedDescription)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(monitor: monitor)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
    }

    private func presentError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - URL scheme

    /// Handles every scheme in `AppInfo.urlSchemes`:
    /// `mowerbar://refresh`, `mowerbar://settings`, `mowerbar://test-notification`
    /// and `mowerbar://mower/<deviceId>/<start|pause|resume|stop|return|cancel_return>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where AppInfo.urlSchemes.contains(url.scheme?.lowercased() ?? "") {
            let parts = ([url.host] + url.pathComponents.filter { $0 != "/" }).compactMap { $0 }
            switch parts.first?.lowercased() {
            case "refresh":
                monitor.refresh()
            case "settings", "signin":
                openSettings()
            case "test-notification":
                monitor.testNotification { [weak self] message in
                    self?.presentError("\(AppInfo.name) notifications", message)
                }
            case "mower":
                guard parts.count >= 3, let action = MowerAction.fromURLVerb(parts[2]) else { continue }
                monitor.send(action, to: parts[1]) { [weak self] message in
                    self?.presentError("Command failed", message)
                }
            default:
                continue
            }
        }
    }
}

private extension NSColor {
    /// Stable identity for the resolved menu bar tint, used to decide whether
    /// the status item image needs redrawing at all.
    var hexKey: String {
        guard let c = usingColorSpace(.sRGB) else { return description }
        return String(format: "%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
