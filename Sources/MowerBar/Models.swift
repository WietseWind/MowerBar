import Foundation

// MARK: - Envelope

/// Every Mammotion endpoint wraps its payload as `{ code, msg, data }`.
/// `code == 0` means success; anything else carries a human message in `msg`.
struct APIResponse<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: T?
}

// MARK: - Devices

struct DeviceInfo: Decodable, Sendable {
    let id: String
    let name: String?
    let nickname: String?
    let model: String?
    let online: Int?

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let name, !name.isEmpty { return name }
        return id
    }

    /// The account also returns RTK reference stations from `/v1/mowers`.
    /// They carry no status, battery or work plan, so they never reach the menu.
    var looksLikeMower: Bool {
        guard let model = model?.lowercased() else { return true }
        return !model.contains("rtk") && !model.contains("refstation")
    }
}

struct DeviceNetwork: Decodable, Sendable {
    /// Which radio the mower is currently on: "1" Wi-Fi, "2" cellular.
    let usedNetwork: String?
    let wifiAvailable: Bool?
    let wifiRssi: Int?
    let cellularAvailable: Bool?
    let cellularRssi: Int?

    /// Signal is reported for *both* radios regardless of which one is carrying
    /// traffic, which is worth showing: a mower about to walk out of Wi-Fi range
    /// is a different prospect depending on whether it has cellular to fall back on.
    var lines: [String] {
        [
            line("Wi‑Fi", rssi: wifiRssi, available: wifiAvailable, usedCode: "1",
                 floor: -90, ceiling: -50),
            line("Cellular", rssi: cellularRssi, available: cellularAvailable, usedCode: "2",
                 floor: -105, ceiling: -65)
        ].compactMap { $0 }
    }

    private func line(_ label: String, rssi: Int?, available: Bool?, usedCode: String,
                      floor: Int, ceiling: Int) -> String? {
        // Nothing to say about a radio the mower does not have.
        guard available == true || rssi != nil else { return nil }

        var text = label
        if let rssi {
            text += " \(rssi) dBm · \(Self.strength(rssi, floor: floor, ceiling: ceiling))%"
        }
        if usedNetwork == usedCode { text += "  (in use)" }
        return text
    }

    /// dBm means nothing to most people, so pair it with a percentage.
    ///
    /// Linear across a 40 dB span, with the endpoints set where each radio stops
    /// being useful — around −50/−90 for Wi-Fi and −65/−105 for cellular. This is
    /// a rule of thumb, not a measurement, which is exactly why the dBm figure
    /// stays on screen next to it.
    private static func strength(_ dBm: Int, floor: Int, ceiling: Int) -> Int {
        let clamped = min(max(dBm, floor), ceiling)
        return Int((Double(clamped - floor) / Double(ceiling - floor) * 100).rounded())
    }
}

struct DeviceDetail: Decodable, Sendable {
    let id: String
    let model: String?
    let version: String?
    let online: Int?
    let status: String?
    let batteryLevel: Int?
    let chargeStatus: Int?
    let network: DeviceNetwork?
}

struct WorkTask: Decodable, Sendable {
    let taskId: String?
    let taskName: String?
}

// MARK: - Status

enum MowerStatus: String, Sendable {
    case standby, working, paused, mapping, updating, offline, returning, abnormal
    case unknown

    /// The API documents `Standby` but has been observed emitting `StandBy`,
    /// so match case-insensitively.
    init(_ raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = MowerStatus(rawValue: value) ?? .unknown
    }

    var label: String {
        switch self {
        case .standby: return "Standby"
        case .working: return "Working"
        case .paused: return "Paused"
        case .mapping: return "Mapping"
        case .updating: return "Updating"
        case .offline: return "Offline"
        case .returning: return "Returning"
        case .abnormal: return "Abnormal"
        case .unknown: return "Unknown"
        }
    }
}

/// How a mower's state should read in the menu bar.
enum MowerHealth: Sendable {
    case active     // green — doing what it should
    case charging   // blue — on the dock, topping up, nothing to do
    case idle       // neutral — parked and fine
    case alert      // red — offline, faulted, or stalled mid-job
}

/// Status plus whether it is on the dock — the pair needed to tell a mower
/// stalled on the lawn from one sitting on its charger.
struct MowerSnapshot: Equatable, Sendable {
    let status: MowerStatus
    let charging: Bool
}

// MARK: - Actions

enum MowerAction: String, Sendable {
    case cmdStart = "CMD_START"
    case start = "START"
    case pause = "PAUSE"
    case resume = "RESUME"
    case stop = "STOP"
    case returnToDock = "RETURN"
    case cancelReturn = "CANCEL_RETURN"

    var title: String {
        switch self {
        case .cmdStart: return "Start Mowing"
        case .start: return "Start Task"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Stop"
        case .returnToDock: return "Return to Dock"
        case .cancelReturn: return "Cancel Return"
        }
    }

    /// Used by the `mammotion://mower/<id>/<verb>` URL scheme.
    static func fromURLVerb(_ verb: String) -> MowerAction? {
        switch verb.lowercased() {
        case "start", "cmd_start": return .cmdStart
        case "pause": return .pause
        case "resume": return .resume
        case "stop": return .stop
        case "return": return .returnToDock
        case "cancel_return", "cancelreturn": return .cancelReturn
        default: return nil
        }
    }
}

// MARK: - Combined state

struct MowerState: Sendable {
    let info: DeviceInfo
    var detail: DeviceDetail?
    var tasks: [WorkTask] = []
    var error: String?
    /// Set when this row was reconstructed from memory rather than from the
    /// current device listing — the mower is out of reach, not gone.
    var remembered: RememberedMower?
    /// How long a remembered status still says something useful.
    var lastKnownWindow: TimeInterval = 600

    var isRemembered: Bool { remembered != nil }
    var lastSeen: Date? { remembered?.lastSeen }

    /// What the mower was last observed doing, but only while that reading is
    /// recent. Older than the window and we admit we simply do not know.
    var lastKnown: (status: MowerStatus, battery: Int?)? {
        guard let remembered,
              let raw = remembered.lastStatus,
              let at = remembered.lastStateAt,
              Date().timeIntervalSince(at) <= lastKnownWindow
        else { return nil }
        return (MowerStatus(raw), remembered.lastBattery)
    }

    var id: String { info.id }
    var name: String { info.displayName }
    var model: String? { detail?.model ?? info.model }

    var isOnline: Bool {
        (detail?.online ?? info.online ?? 0) == 1 && status != .offline
    }

    var status: MowerStatus {
        guard isReachable else { return .offline }
        return MowerStatus(detail?.status)
    }

    private var isReachable: Bool { (detail?.online ?? info.online ?? 0) == 1 }

    var battery: Int? { detail?.batteryLevel }

    /// `chargeStatus` is `0` off the dock and non-zero on it. Both `1` and `2`
    /// have been observed on-dock (at 17% and at 100%), so only zero/non-zero
    /// is treated as meaningful.
    var isDocked: Bool { (detail?.chargeStatus ?? 0) != 0 }

    /// The API reports `Paused` for a mower sitting on its dock, which is a
    /// completely different situation from one stopped mid-lawn. `chargeStatus`
    /// is the only thing that separates them.
    var isCharging: Bool {
        guard isOnline, isDocked else { return false }
        switch status {
        case .paused, .standby: return true
        default: return false
        }
    }

    /// Paused, not on the dock: stopped in the middle of a job and going
    /// nowhere until someone does something. The case this app exists for.
    var isStalled: Bool { isOnline && status == .paused && !isDocked }

    /// What the row should actually say, which is not always what the API said.
    var stateLabel: String {
        guard isCharging else { return status.label }
        return (battery ?? 0) >= 100 ? "Docked" : "Charging"
    }

    var snapshot: MowerSnapshot { MowerSnapshot(status: status, charging: isCharging) }

    var health: MowerHealth {
        if !isOnline { return .alert }
        // Checked before .paused: on the dock, paused means charging.
        if isCharging { return .charging }
        switch status {
        case .offline, .abnormal: return .alert
        // Stopped mid-job, off the dock — the worst of the recoverable states.
        case .paused: return .alert
        case .working, .returning: return .active
        default: return .idle
        }
    }

    /// One line of status for the menu: "Paused · 91%".
    ///
    /// An out-of-reach mower keeps showing what it was last seen doing, tagged
    /// as stale, so a mow that dropped off mid-job is not reduced to "Offline".
    var summary: String {
        if isRemembered {
            guard let lastKnown else { return "Not reachable" }
            var parts = [lastKnown.status.label]
            if let battery = lastKnown.battery { parts.append("\(battery)%") }
            return parts.joined(separator: " · ") + " · last known"
        }
        var parts = [stateLabel]
        if let battery { parts.append("\(battery)%") }
        return parts.joined(separator: " · ")
    }

    /// Only offer commands the mower can actually accept right now.
    var availableActions: [MowerAction] {
        guard isOnline else { return [] }
        switch status {
        case .standby:
            // A task-less start is the only start that works when no plan exists.
            return isDocked ? [.cmdStart] : [.cmdStart, .returnToDock]
        case .working:
            return [.pause, .stop, .returnToDock]
        case .paused:
            return isDocked ? [.resume, .stop] : [.resume, .stop, .returnToDock]
        case .returning:
            return [.cancelReturn, .stop]
        case .mapping, .updating, .abnormal, .offline, .unknown:
            return []
        }
    }

    /// Saved plans are only startable from Standby, and only by name.
    var startableTasks: [WorkTask] {
        guard isOnline, status == .standby else { return [] }
        return tasks.filter { ($0.taskName?.isEmpty == false) }
    }
}
