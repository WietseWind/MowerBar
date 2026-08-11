import Foundation
import UserNotifications

/// macOS notifications for mower state changes.
///
/// The menu bar badge only tells you *something* is wrong once you look at the
/// bar; a mow that stalls while you are in another app should reach you without
/// looking. Notifications fire on transitions only, never on the current state,
/// so a paused mower nags once rather than every poll.
@MainActor
final class Notifier {
    private var authorized = false
    /// Last known system authorization, so the menu can say "notifications are
    /// off" rather than just quietly never notifying.
    private(set) var isBlocked = false

    /// Fired when the system authorization actually flips, so the menu can
    /// redraw. `getNotificationSettings` answers asynchronously — without this
    /// the menu would keep showing a stale "notifications are off" row until
    /// something else happened to rebuild it.
    var onStatusChange: (() -> Void)?

    /// `UNUserNotificationCenter` traps when the process is not a real bundle,
    /// which is the case for `--status` runs from the command line.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func refreshStatus() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.apply(settings.authorizationStatus)
            }
        }
    }

    private func apply(_ status: UNAuthorizationStatus) {
        let wasBlocked = isBlocked
        authorized = status == .authorized || status == .provisional
        isBlocked = status == .denied
        if wasBlocked != isBlocked { onStatusChange?() }
    }

    /// Asks only when the user has not decided yet; on later launches this just
    /// reads back the existing grant instead of re-prompting.
    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self.apply(granted ? .authorized : .denied) }
                }
            default:
                Task { @MainActor in self.apply(settings.authorizationStatus) }
            }
        }
    }

    /// Fires a test notification and reports why if nothing shows up — the
    /// failure modes here (denied, not yet asked, unsigned bundle) are all
    /// silent otherwise.
    func postTest(_ report: @escaping (String) -> Void) {
        guard isAvailable else { return report("Not running from an app bundle, so notifications are unavailable.") }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.apply(settings.authorizationStatus)
                    self.post(title: AppInfo.name, body: "Notifications are working.", identifier: "test")
                    report("Test notification sent.")
                case .denied:
                    self.apply(.denied)
                    report("Notifications are turned off for \(AppInfo.name) in System Settings › Notifications.")
                case .notDetermined:
                    self.requestAuthorization()
                    report("Requested permission — approve it and try again.")
                @unknown default:
                    report("Notification permission is in an unknown state.")
                }
            }
        }
    }

    func post(title: String, body: String, identifier: String) {
        guard isAvailable, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// What a status change is worth telling the user about.
enum MowerEvent {
    case problem(String, String)
    case recovery(String, String)

    /// Decides whether a transition deserves a notification.
    ///
    /// Fires when a mower stops doing what it was doing — stuck mid-job,
    /// faulted, or dropped off the network — and again when it picks back up.
    /// Everything else stays quiet.
    ///
    /// The subtlety is `Paused`. The API reports it both for a mower stalled in
    /// the middle of the lawn and for one sitting on its dock charging. Only the
    /// first is worth waking someone for, which is why this compares snapshots
    /// carrying the dock state rather than bare statuses.
    static func between(_ before: MowerSnapshot, _ after: MowerSnapshot, mower: MowerState) -> MowerEvent? {
        guard before != after else { return nil }
        let name = mower.name

        func isTrouble(_ snapshot: MowerSnapshot) -> Bool {
            // On the dock, nothing is wrong — that is just charging.
            guard !snapshot.charging else { return false }
            return snapshot.status == .paused
                || snapshot.status == .abnormal
                || snapshot.status == .offline
        }

        if isTrouble(after) {
            let battery = mower.battery.map { " · \($0)% battery" } ?? ""
            switch after.status {
            case .paused:
                return .problem("\(name) is stuck",
                                "Paused mid-job, off the dock\(battery).")
            case .abnormal:
                return .problem("\(name) needs attention",
                                "Reported an abnormal condition\(battery).")
            case .offline:
                return .problem("\(name) went offline",
                                "No longer reachable. Last seen \(before.status.label.lowercased()).")
            default:
                return nil
            }
        }

        if isTrouble(before), !isTrouble(after) {
            return .recovery("\(name) is back", "Now \(mower.stateLabel.lowercased()).")
        }
        return nil
    }
}
