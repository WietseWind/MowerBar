import AppKit

/// Credentials and polling, in a plain AppKit panel — the same values the
/// config file holds, for when editing JSON is not what you want.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let monitor: FleetMonitor

    private let clientIdField = NSTextField()
    private let clientSecretField = NSSecureTextField()
    private let pollField = NSTextField()
    private let rememberField = NSTextField()
    private let alertOnPausedBox = NSButton(checkboxWithTitle: "Badge the menu bar when a mower is paused", target: nil, action: nil)
    private let notifyBox = NSButton(checkboxWithTitle: "Notify when a mower pauses, faults or goes offline", target: nil, action: nil)
    private let notifyRecoveryBox = NSButton(checkboxWithTitle: "…and when it picks back up", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let signInButton = NSButton()

    private let knownStack = NSStackView()
    private let knownHeader = NSTextField(labelWithString: "Remembered mowers")

    init(monitor: FleetMonitor) {
        self.monitor = monitor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppInfo.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildLayout()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Settings promotes the app to `.regular` so it can actually take keyboard
    /// focus. Closing it goes straight back to menu-bar-only: no Dock tile, no
    /// menu bar.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let header = NSTextField(wrappingLabelWithString:
            "The Mammotion API authenticates with client credentials — there is no browser sign-in. "
            + "Create a credential on developer.mammotion.com and paste it here.")
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor

        clientIdField.placeholderString = "client_id"
        clientSecretField.placeholderString = "client_secret"
        // Credentials are long opaque strings; a monospaced face makes them
        // possible to eyeball, and both fields need to fit ~40 characters.
        let credentialFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        clientIdField.font = credentialFont
        clientSecretField.font = credentialFont
        pollField.placeholderString = "5"
        pollField.alignment = .right

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2

        signInButton.title = "Sign In"
        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.target = self
        signInButton.action = #selector(signIn)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded

        rememberField.placeholderString = "30"
        rememberField.alignment = .right

        let grid = NSGridView(views: [
            [label("Client ID"), clientIdField],
            [label("Client Secret"), clientSecretField],
            [label("Poll every"), row(pollField, NSTextField(labelWithString: "minutes"))],
            [label("Remember for"), row(rememberField, NSTextField(labelWithString: "days"))],
            [NSGridCell.emptyContentView, alertOnPausedBox],
            [NSGridCell.emptyContentView, notifyBox],
            [NSGridCell.emptyContentView, notifyRecoveryBox]
        ])
        grid.columnSpacing = 10
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 420

        let buttons = NSStackView(views: [NSView(), saveButton, signInButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        knownHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        knownHeader.textColor = .secondaryLabelColor
        knownStack.orientation = .vertical
        knownStack.alignment = .leading
        knownStack.spacing = 6

        let stack = NSStackView(views: [header, grid, statusLabel, buttons, knownHeader, knownStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        views.first?.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return stack
    }

    // MARK: - Values

    private func load() {
        let config = monitor.config
        clientIdField.stringValue = config.clientId
        clientSecretField.stringValue = config.clientSecret
        pollField.stringValue = String(format: "%g", config.pollMinutes)
        rememberField.stringValue = String(format: "%g", config.rememberDays)
        alertOnPausedBox.state = config.alertOnPaused ? .on : .off
        notifyBox.state = config.notifyOnChange ? .on : .off
        notifyRecoveryBox.state = config.notifyOnRecovery ? .on : .off
        describeToken()
        reloadKnownMowers()
    }

    /// Every mower the app has seen, with a way to drop one it should stop
    /// showing. A forgotten mower that is still reachable simply comes back on
    /// the next sync.
    private func reloadKnownMowers() {
        knownStack.arrangedSubviews.forEach {
            knownStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let known = monitor.knownMowers.sorted { $0.displayName < $1.displayName }
        guard !known.isEmpty else {
            knownStack.addArrangedSubview(NSTextField(labelWithString: "None yet."))
            return
        }

        let liveIds = Set(monitor.mowers.filter { !$0.isRemembered }.map(\.id))
        for mower in known {
            let seen = liveIds.contains(mower.id)
                ? "in sync now"
                : "last seen \(AppDelegate.relative(mower.lastSeen))"
            let title = NSTextField(labelWithString: "\(mower.displayName) — \(seen)")
            title.font = .systemFont(ofSize: 11)
            title.textColor = seen == "in sync now" ? .labelColor : .secondaryLabelColor

            let forget = NSButton(title: "Forget", target: self, action: #selector(forget(_:)))
            forget.bezelStyle = .rounded
            forget.controlSize = .small
            forget.identifier = NSUserInterfaceItemIdentifier(mower.id)

            let row = NSStackView(views: [title, forget])
            row.orientation = .horizontal
            row.spacing = 8
            knownStack.addArrangedSubview(row)
        }
    }

    @objc private func forget(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        monitor.forget(id)
        reloadKnownMowers()
    }

    private func currentConfig() -> AppConfig {
        var config = monitor.config
        config.clientId = clientIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.clientSecret = clientSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.pollMinutes = max(1, Double(pollField.stringValue) ?? config.pollMinutes)
        config.rememberDays = max(0, Double(rememberField.stringValue) ?? config.rememberDays)
        config.alertOnPaused = alertOnPausedBox.state == .on
        config.notifyOnChange = notifyBox.state == .on
        config.notifyOnRecovery = notifyRecoveryBox.state == .on
        return config
    }

    private func describeToken() {
        Task {
            guard let expiry = await monitor.api.tokenExpiry else {
                statusLabel.stringValue = "Not signed in yet."
                return
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            statusLabel.stringValue = expiry > Date()
                ? "Signed in. Token valid until \(formatter.string(from: expiry))."
                : "Token expired — sign in again."
        }
    }

    // MARK: - Actions

    @objc private func save() {
        monitor.apply(config: currentConfig())
        monitor.refresh()
        reloadKnownMowers()
        statusLabel.stringValue = "Saved to \(Store.configURL.path)"
    }

    @objc private func signIn() {
        let config = currentConfig()
        monitor.apply(config: config)
        signInButton.isEnabled = false
        statusLabel.stringValue = "Signing in…"

        Task {
            defer { signInButton.isEnabled = true }
            do {
                try await monitor.api.signIn()
                monitor.refresh()
                describeToken()
            } catch {
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }
}
