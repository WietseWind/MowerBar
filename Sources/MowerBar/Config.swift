import Foundation

/// Everything tunable lives in one JSON file so it can be edited without a rebuild:
/// `~/Library/Application Support/MowerBar/config.json`
struct AppConfig: Codable, Equatable, Sendable {
    var clientId: String
    var clientSecret: String
    var authBaseURL: String
    var apiBaseURL: String
    var acceptLanguage: String
    /// How often the fleet is polled, in minutes.
    var pollMinutes: Double
    /// Treat a paused mower as a tray alert (it is stalled mid-job).
    var alertOnPaused: Bool
    /// Height of the menu bar icon in points; width follows the artwork's aspect.
    var trayIconHeight: Double
    /// How long a mower that has stopped appearing in the device list keeps its
    /// place in the menu, shown as offline. Zero disables the memory entirely.
    var rememberDays: Double
    /// How recent a remembered status has to be to still be shown as
    /// "last known" rather than simply unreachable.
    var lastKnownMinutes: Double
    /// Notify when a mower pauses, faults or drops offline.
    var notifyOnChange: Bool
    /// Also notify when it picks back up.
    var notifyOnRecovery: Bool

    /// Deliberately empty. Credentials are per-account and are the account
    /// identity — baking any in would ship whoever built the app's fleet to
    /// everyone who runs it. A fresh install starts unconfigured and asks.
    static let fallback = AppConfig(
        clientId: "",
        clientSecret: "",
        authBaseURL: "https://id.mammotion.com",
        apiBaseURL: "https://api-open.mammotion.com",
        acceptLanguage: "en-US",
        pollMinutes: 5,
        alertOnPaused: true,
        trayIconHeight: 15,
        rememberDays: 30,
        lastKnownMinutes: 10,
        notifyOnChange: true,
        notifyOnRecovery: true
    )

    var isConfigured: Bool { !clientId.isEmpty && !clientSecret.isEmpty }

    var pollInterval: TimeInterval { max(30, pollMinutes * 60) }

    /// Decode leniently so a hand-edited file with missing keys still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.fallback
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? d.clientId
        clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? d.clientSecret
        authBaseURL = try c.decodeIfPresent(String.self, forKey: .authBaseURL) ?? d.authBaseURL
        apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? d.apiBaseURL
        acceptLanguage = try c.decodeIfPresent(String.self, forKey: .acceptLanguage) ?? d.acceptLanguage
        pollMinutes = try c.decodeIfPresent(Double.self, forKey: .pollMinutes) ?? d.pollMinutes
        alertOnPaused = try c.decodeIfPresent(Bool.self, forKey: .alertOnPaused) ?? d.alertOnPaused
        trayIconHeight = try c.decodeIfPresent(Double.self, forKey: .trayIconHeight) ?? d.trayIconHeight
        rememberDays = try c.decodeIfPresent(Double.self, forKey: .rememberDays) ?? d.rememberDays
        lastKnownMinutes = try c.decodeIfPresent(Double.self, forKey: .lastKnownMinutes) ?? d.lastKnownMinutes
        notifyOnChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnChange) ?? d.notifyOnChange
        notifyOnRecovery = try c.decodeIfPresent(Bool.self, forKey: .notifyOnRecovery) ?? d.notifyOnRecovery
    }

    init(clientId: String, clientSecret: String, authBaseURL: String, apiBaseURL: String,
         acceptLanguage: String, pollMinutes: Double, alertOnPaused: Bool, trayIconHeight: Double,
         rememberDays: Double, lastKnownMinutes: Double,
         notifyOnChange: Bool, notifyOnRecovery: Bool) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.authBaseURL = authBaseURL
        self.apiBaseURL = apiBaseURL
        self.acceptLanguage = acceptLanguage
        self.pollMinutes = pollMinutes
        self.alertOnPaused = alertOnPaused
        self.trayIconHeight = trayIconHeight
        self.rememberDays = rememberDays
        self.lastKnownMinutes = lastKnownMinutes
        self.notifyOnChange = notifyOnChange
        self.notifyOnRecovery = notifyOnRecovery
    }
}

/// Cached OAuth2 token. Written next to the config with `0600` permissions.
struct StoredToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 120 }
}

/// A mower the app has seen before. Kept so a machine that drops off the
/// account's device list stays visible as offline instead of silently
/// vanishing from the menu.
struct RememberedMower: Codable, Sendable {
    var id: String
    var name: String?
    var nickname: String?
    var model: String?
    /// Last time the mower appeared in the account's device list.
    var lastSeen: Date
    /// Last status actually read back from the device, and when. Shown as
    /// "last known" while it is recent enough to still mean something.
    var lastStatus: String?
    var lastBattery: Int?
    var lastStateAt: Date?

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let name, !name.isEmpty { return name }
        return id
    }
}

enum Store {
    static let directory: URL = {
        // Application Support resolves through getpwuid, not $HOME, so an env
        // override is the only way to point a test run at a throwaway directory.
        if let override = ProcessInfo.processInfo.environment["MOWERBAR_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent(AppInfo.supportDirectory, isDirectory: true)

        // Carry state across a rename rather than stranding the user's config
        // and token in a directory nothing reads any more.
        let manager = FileManager.default
        if !manager.fileExists(atPath: current.path) {
            for legacy in AppInfo.legacySupportDirectories {
                let old = base.appendingPathComponent(legacy, isDirectory: true)
                if manager.fileExists(atPath: old.path) {
                    try? manager.moveItem(at: old, to: current)
                    break
                }
            }
        }
        return current
    }()

    static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var tokenURL: URL { directory.appendingPathComponent("token.json") }
    static var knownMowersURL: URL { directory.appendingPathComponent("mowers.json") }

    // MARK: Config

    /// Loads the config, seeding the file on first run so there is something to edit.
    static func loadConfig() -> AppConfig {
        ensureDirectory()
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        let seeded = AppConfig.fallback
        saveConfig(seeded)
        return seeded
    }

    static func saveConfig(_ config: AppConfig) {
        ensureDirectory()
        write(config, to: configURL)
    }

    // MARK: Token

    static func loadToken() -> StoredToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? JSONDecoder.store.decode(StoredToken.self, from: data)
    }

    static func saveToken(_ token: StoredToken?) {
        ensureDirectory()
        guard let token else {
            try? FileManager.default.removeItem(at: tokenURL)
            return
        }
        write(token, to: tokenURL)
    }

    // MARK: Known mowers

    static func loadKnownMowers() -> [RememberedMower] {
        guard let data = try? Data(contentsOf: knownMowersURL) else { return [] }
        return (try? JSONDecoder.store.decode([RememberedMower].self, from: data)) ?? []
    }

    static func saveKnownMowers(_ mowers: [RememberedMower]) {
        ensureDirectory()
        write(mowers, to: knownMowersURL)
    }

    // MARK: Plumbing

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        // Credentials and tokens live here in the clear — keep them owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONDecoder {
    static let store: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
