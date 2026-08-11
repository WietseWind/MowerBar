import Foundation

/// Product identity in one place.
///
/// The app is deliberately **not** named after the mower manufacturer: the brand
/// and model names are trademarks, and naming a third-party tool after them
/// implies an endorsement that does not exist. The name below is descriptive,
/// and every user-visible string derives from it.
enum AppInfo {
    static let name = "MowerBar"
    static let bundleIdentifier = "net.ipublications.MowerBar"

    /// `mowerbar://` is the current scheme; `mammotion://` stays registered so
    /// links made before the rename keep working.
    static let urlSchemes = ["mowerbar", "mammotion"]

    static let supportDirectory = "MowerBar"
    /// Earlier support directories, migrated on first launch after a rename.
    static let legacySupportDirectories = ["MammotionMenu"]
}
