import Foundation

/// Owns the polling loop and the last-known snapshot of the fleet.
/// Everything here runs on the main actor so the menu can read it directly.
@MainActor
final class FleetMonitor {
    private(set) var mowers: [MowerState] = []
    private(set) var knownMowers: [RememberedMower] = []
    private(set) var lastUpdate: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    var onChange: (() -> Void)?

    let api: MammotionAPI
    private(set) var config: AppConfig
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    private let notifier = Notifier()
    /// Baseline for change detection. Absent means "no baseline yet", which is
    /// why the first sync after launch never notifies.
    private var previousStatus: [String: MowerSnapshot] = [:]
    /// Commands the user just issued. The resulting status change is expected,
    /// so it should not come back as a notification.
    private var commandedAt: [String: Date] = [:]

    init(config: AppConfig) {
        self.config = config
        self.api = MammotionAPI(config: config)
        notifier.onStatusChange = { [weak self] in self?.onChange?() }
    }

    func start() {
        seedFromMemory()
        onChange?()
        scheduleTimer()
        refresh()
    }

    /// Show the remembered fleet straight away rather than an empty menu while
    /// the first request is in flight.
    private func seedFromMemory() {
        knownMowers = Store.loadKnownMowers()
        mowers = merge(live: [])
    }

    /// One seed-and-sync pass, awaited. Used by `--status`.
    func syncOnce() async {
        seedFromMemory()
        await reload()
    }

    func apply(config newValue: AppConfig) {
        let intervalChanged = newValue.pollMinutes != config.pollMinutes
        config = newValue
        Store.saveConfig(newValue)
        Task { await api.update(config: newValue) }
        if intervalChanged { scheduleTimer() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The exact minute does not matter; let the system batch the wakeups.
        timer.tolerance = config.pollInterval * 0.2
        self.timer = timer
    }

    // MARK: - Refresh

    /// Kicks off a refresh unless one is already in flight.
    func refresh() {
        guard refreshTask == nil else { return }
        // Deliberately no onChange() here: announcing "refreshing" only to
        // announce "done" a second later makes the menu redraw twice per poll.
        isRefreshing = true

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.reload()
            self.refreshTask = nil
            self.isRefreshing = false
            self.onChange?()
        }
    }

    /// Refreshes only if the snapshot is older than `staleAfter`. Used when the
    /// menu opens so clicking the icon feels live without hammering the API.
    func refreshIfStale(_ staleAfter: TimeInterval = 45) {
        guard let lastUpdate else { return refresh() }
        if Date().timeIntervalSince(lastUpdate) > staleAfter { refresh() }
    }

    private func reload() async {
        guard config.isConfigured else {
            lastError = APIError.notConfigured.localizedDescription
            mowers = []
            return
        }

        do {
            let devices = try await api.listDevices().filter(\.looksLikeMower)
            let states = await withTaskGroup(of: (Int, MowerState).self) { group in
                for (index, device) in devices.enumerated() {
                    group.addTask { [api] in
                        var state = MowerState(info: device)
                        do {
                            let detail = try await api.detail(device.id)
                            state.detail = detail
                            // Plans are only actionable from Standby, so only pay for them there.
                            if MowerStatus(detail.status) == .standby, detail.online == 1 {
                                state.tasks = (try? await api.tasks(device.id)) ?? []
                            }
                        } catch {
                            state.error = error.localizedDescription
                        }
                        return (index, state)
                    }
                }
                var collected: [(Int, MowerState)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            // A device whose detail carries no status is not a mower (RTK base
            // stations answer /v1/mowers too). Keep failures so they stay visible.
            let live = states.filter { $0.detail == nil || $0.detail?.status != nil }
            mowers = merge(live: live)
            notifier.refreshStatus()
            announceChanges()
            lastUpdate = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Notifications

    func requestNotificationAuthorization() {
        notifier.requestAuthorization()
    }

    func testNotification(_ report: @escaping (String) -> Void) {
        notifier.postTest(report)
    }

    /// True when macOS is refusing notifications for this app, so the menu can
    /// offer a way to fix it instead of silently never notifying.
    var notificationsBlocked: Bool { config.notifyOnChange && notifier.isBlocked }

    func refreshNotificationStatus() {
        notifier.refreshStatus()
    }

    /// Compares this sync against the last one and notifies on the transitions
    /// worth interrupting for.
    private func announceChanges() {
        defer {
            previousStatus = Dictionary(uniqueKeysWithValues: mowers.map { ($0.id, $0.snapshot) })
        }
        guard config.notifyOnChange else { return }

        for mower in mowers {
            // No baseline (first sync, or a newly appeared mower) means nothing
            // has "changed" yet — announcing here would fire a burst at launch.
            guard let before = previousStatus[mower.id] else { continue }
            if let issued = commandedAt[mower.id], Date().timeIntervalSince(issued) < 45 { continue }

            switch MowerEvent.between(before, mower.snapshot, mower: mower) {
            case .problem(let title, let body):
                notifier.post(title: title, body: body, identifier: "\(mower.id)-\(mower.status.rawValue)")
            case .recovery(let title, let body):
                guard config.notifyOnRecovery else { continue }
                notifier.post(title: title, body: body, identifier: "\(mower.id)-\(mower.status.rawValue)")
            case nil:
                continue
            }
        }
    }

    // MARK: - Remembering mowers

    /// A mower that drops out of `/v1/mowers` — off-grid, powered down, or the
    /// account momentarily not listing it — should not silently disappear from
    /// the menu. Every sighting is recorded, and anything seen within
    /// `rememberDays` is shown as offline until it comes back or is forgotten.
    private func merge(live: [MowerState]) -> [MowerState] {
        let now = Date()
        var known = Store.loadKnownMowers()

        for mower in live {
            var record = known.first { $0.id == mower.id }
                ?? RememberedMower(id: mower.id, lastSeen: now)
            record.name = mower.info.name
            record.nickname = mower.info.nickname
            record.model = mower.model
            record.lastSeen = now
            // Only overwrite the remembered status when we actually read one —
            // a failed detail call should not erase what we last knew.
            if let status = mower.detail?.status, !status.isEmpty {
                record.lastStatus = status
                record.lastBattery = mower.detail?.batteryLevel
                record.lastStateAt = now
            }
            if let index = known.firstIndex(where: { $0.id == mower.id }) {
                known[index] = record
            } else {
                known.append(record)
            }
        }

        let horizon = max(0, config.rememberDays) * 86_400
        if horizon > 0 {
            known.removeAll { now.timeIntervalSince($0.lastSeen) > horizon }
        } else {
            known.removeAll { mower in !live.contains { $0.id == mower.id } }
        }
        Store.saveKnownMowers(known)
        knownMowers = known

        let liveIds = Set(live.map(\.id))
        let window = max(0, config.lastKnownMinutes) * 60
        let missing = known
            .filter { !liveIds.contains($0.id) }
            .map { record in
                MowerState(
                    info: DeviceInfo(id: record.id, name: record.name, nickname: record.nickname,
                                     model: record.model, online: 0),
                    remembered: record,
                    lastKnownWindow: window
                )
            }

        // Live mowers first, then the ones we are only remembering.
        return live + missing.sorted { ($0.name) < ($1.name) }
    }

    /// Drops a mower from the memory. If it is still reachable it simply
    /// reappears on the next sync — this only clears the remembered entry.
    func forget(_ deviceId: String) {
        var known = Store.loadKnownMowers()
        known.removeAll { $0.id == deviceId }
        Store.saveKnownMowers(known)
        knownMowers = known
        mowers.removeAll { $0.id == deviceId && $0.isRemembered }
        onChange?()
    }

    // MARK: - Commands

    /// Sends a command, then re-polls twice because the mower's reported status
    /// trails the command by a few seconds.
    func send(_ action: MowerAction, to deviceId: String, taskName: String? = nil,
              onFailure: @escaping (String) -> Void) {
        // A status change the user just asked for is not news.
        commandedAt[deviceId] = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.send(action, to: deviceId, taskName: taskName)
                self.refresh()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self.refresh()
            } catch {
                onFailure(error.localizedDescription)
                self.refresh()
            }
        }
    }

    // MARK: - Derived state

    /// Red when a mower needs a human: offline, faulted, or stalled mid-job.
    /// A mower charging on its dock is not one of those.
    var alertLevel: MowerHealth? {
        // Remembered mowers are seeded as offline before the first sync lands;
        // don't flash the badge red for them until we have actually checked.
        guard lastUpdate != nil else { return nil }
        if lastError != nil { return .alert }

        let raising = mowers.filter { $0.health == .alert }
        if raising.contains(where: { !$0.isStalled }) { return .alert }
        // A stall is always an alert in the menu; this setting only decides
        // whether it also takes over the menu bar icon.
        if config.alertOnPaused, raising.contains(where: \.isStalled) { return .alert }
        return nil
    }

    var statusLine: String {
        if isRefreshing && lastUpdate == nil { return "Loading…" }
        if let lastError { return lastError }
        guard let lastUpdate else { return "Not updated yet" }
        let seconds = Int(Date().timeIntervalSince(lastUpdate))
        switch seconds {
        case ..<10: return "Updated just now"
        case ..<60: return "Updated \(seconds)s ago"
        case ..<3600: return "Updated \(seconds / 60) min ago"
        default: return "Updated \(seconds / 3600) h ago"
        }
    }
}
