import AppKit

/// Owns a stable submenu, so a completed history request never rebuilds or
/// collapses its parent mower menu.
@MainActor
final class RecentEventsMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Recent Events")
    var mowerName: String
    private let history: RecentEventsHistory

    init(mowerName: String, history: RecentEventsHistory) {
        self.mowerName = mowerName
        self.history = history
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        history.onChange = { [weak self] in self?.render() }
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        render()
        Task { await history.refresh() }
    }

    private func render() {
        menu.removeAllItems()
        menu.addItem(disabled("Last 30 days · up to 10 latest events"))
        menu.addItem(disabled("Includes routine charging and rest stops"))
        menu.addItem(.separator())

        if let error = history.error {
            menu.addItem(disabled("Could not refresh events"))
            let message = disabled(String(error.prefix(90)))
            message.toolTip = error
            menu.addItem(message)
        }

        if history.events.isEmpty {
            if history.isLoading || (history.lastUpdate == nil && history.error == nil) {
                menu.addItem(disabled("Loading recent events…"))
            } else if history.error == nil {
                menu.addItem(disabled("No events in the last 30 days"))
            }
        } else {
            for event in history.events {
                let item = NSMenuItem(title: event.menuTitle, action: #selector(showEvent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = event
                item.toolTip = event.explanation
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if let updated = history.lastUpdate {
            let prefix = history.error == nil ? "Updated" : "Showing saved results from"
            menu.addItem(disabled("\(prefix) \(AppDelegate.relative(updated))"))
        }
        let refresh = NSMenuItem(title: history.isLoading ? "Refreshing…" : "Refresh Events",
                                 action: #selector(refreshEvents), keyEquivalent: "")
        refresh.target = self
        refresh.isEnabled = !history.isLoading
        menu.addItem(refresh)
    }

    @objc private func refreshEvents() {
        Task { await history.refresh(force: true) }
    }

    @objc private func showEvent(_ sender: NSMenuItem) {
        guard let event = sender.representedObject as? MowerHistoryEvent else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = event.explanation
        alert.informativeText = "\(mowerName)\n\n\(event.details)"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
