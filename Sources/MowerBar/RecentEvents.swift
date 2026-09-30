import Foundation

/// The fault-history endpoint also includes routine events, such as charging
/// and scheduled rest. These records must not drive live health or alerts.
struct MowerHistoryEvent: Decodable, Equatable, Sendable {
    let code: Int?
    let implication: String?
    let solution: String?
    let gmtCreate: Double?
    let createTime: Double?

    var date: Date? {
        // Prefer when the event occurred over when the cloud stored it.
        guard let milliseconds = [gmtCreate, createTime].compactMap({ $0 })
            .first(where: { $0.isFinite && $0 > 0 }) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    var explanation: String {
        let text = implication?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? code.map { "Mower event \($0)" } ?? "Mower event" : text
    }

    var advice: String? {
        let text = solution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var timestamp: String {
        date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
            ?? "Time unavailable"
    }

    var menuTitle: String {
        let shortDate = date.map {
            DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
        } ?? "Time unavailable"
        let summary = explanation.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shortSummary = summary.count > 56 ? String(summary.prefix(55)) + "…" : summary
        return "\(shortDate) · \(shortSummary)"
    }

    var details: String {
        var parts = [timestamp]
        if let code { parts.append("Event code: \(code)") }
        if let advice { parts.append("Mammotion’s suggested action:\n\(advice)") }
        return parts.joined(separator: "\n\n")
    }
}

struct MowerHistoryPage: Decodable, Sendable {
    let records: [MowerHistoryEvent]
}

struct RecentEventsQuery: Encodable {
    static let limit = 10
    let deviceId: String
    let pageSize = Self.limit
    let pageNumber = 1
    let startDate: String
    let endDate: String

    init(deviceId: String, now: Date = Date(), timeZone: TimeZone = .current) {
        self.deviceId = deviceId
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        // Both bounds are inclusive: today plus the previous 29 calendar days.
        startDate = formatter.string(from: calendar.date(byAdding: .day, value: -29, to: now) ?? now)
        endDate = formatter.string(from: now)
    }
}

/// Per-mower, in-memory history cache. Fetching history is independent of fleet
/// polling, so an unavailable history endpoint cannot hide a live status.
@MainActor
final class RecentEventsHistory {
    private(set) var events: [MowerHistoryEvent] = []
    private(set) var lastUpdate: Date?
    private(set) var error: String?
    private(set) var isLoading = false
    var onChange: (() -> Void)?

    private var lastAttempt: Date?
    private let load: () async throws -> [MowerHistoryEvent]

    init(load: @escaping () async throws -> [MowerHistoryEvent]) {
        self.load = load
    }

    func refresh(force: Bool = false, now: Date = Date()) async {
        guard !isLoading else { return }
        // Failed requests are throttled too; the user can explicitly retry.
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < 300 { return }
        lastAttempt = now
        isLoading = true
        onChange?()
        do {
            let records = try await load()
            events = Array(records.sorted {
                ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }.prefix(RecentEventsQuery.limit))
            lastUpdate = now
            error = nil
        } catch {
            // Keep previously fetched records visible, but mark them as stale.
            self.error = error.localizedDescription
        }
        isLoading = false
        onChange?()
    }
}
