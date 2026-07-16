import Foundation

/// Resolves where Murmur keeps its files. Prefers the user's iCloud Drive so
/// recordings and transcripts sync across devices with no entitlement or paid
/// developer profile required; falls back to ~/Documents when iCloud Drive
/// isn't present. The chosen root can be overridden and is remembered.
enum Storage {
    private static let overrideKey = "MurmurStorageRoot"

    /// The generic iCloud Drive documents folder, if the user has iCloud Drive on.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isUsingICloud: Bool {
        root.path.contains("Mobile Documents")
    }

    /// The Murmur library root — an override if set, else iCloud Drive, else ~/Documents.
    static var root: URL {
        if let override = UserDefaults.standard.string(forKey: overrideKey) {
            return URL(fileURLWithPath: override)
        }
        let base = iCloudDrive
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return base.appendingPathComponent("Murmur", isDirectory: true)
    }

    static func setRoot(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: overrideKey)
    }

    static var audioDir: URL { root.appendingPathComponent("audio", isDirectory: true) }
    static var entriesDir: URL { root.appendingPathComponent("entries", isDirectory: true) }

    /// Creates the library folders if they don't exist yet.
    static func ensureDirectories() throws {
        for dir in [root, audioDir, entriesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
