import Foundation
import CryptoKit

/// The diary's data store. Owns the in-memory list of entries and reads/writes
/// them as one JSON file each under the storage root. Dedupe keys off the audio
/// checksum so re-importing the same folder never doubles anything up.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var entries: [Entry] = []

    private var checksums: Set<String> = []
    // Checksums of deleted recordings, persisted so a re-import can't resurrect
    // something the user deliberately removed (see `wasDeleted`).
    private var deletedChecksums: Set<String> = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Loads every entry JSON from disk, newest first. The reads run off the main
    /// actor: on an iCloud-Drive library, `Data(contentsOf:)` can block while iCloud
    /// materialises an evicted file, and doing that on the main thread beachballs the
    /// whole app on launch. Only the final assignment hops back to the main actor.
    func load() async {
        do {
            try Storage.ensureDirectories()
        } catch {
            return
        }

        let entriesDir = Storage.entriesDir
        let deletedFile = Storage.deletedFile

        let result = await Task.detached(priority: .userInitiated) { () -> (entries: [Entry], deleted: [String]) in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let files = (try? FileManager.default.contentsOfDirectory(
                at: entriesDir,
                includingPropertiesForKeys: nil
            )) ?? []

            var loaded: [Entry] = []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? decoder.decode(Entry.self, from: data) else {
                    continue
                }
                loaded.append(entry)
            }
            loaded.sort { $0.date > $1.date }

            var deleted: [String] = []
            if let data = try? Data(contentsOf: deletedFile),
               let list = try? decoder.decode([String].self, from: data) {
                deleted = list
            }
            return (loaded, deleted)
        }.value

        entries = result.entries
        checksums = Set(result.entries.map(\.checksum))
        deletedChecksums = Set(result.deleted)
    }

    func hasChecksum(_ checksum: String) -> Bool {
        checksums.contains(checksum)
    }

    /// True if this audio was previously deleted — reimporting it should skip.
    func wasDeleted(_ checksum: String) -> Bool {
        deletedChecksums.contains(checksum)
    }

    /// Inserts or updates an entry both in memory and on disk.
    func upsert(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.date > $1.date }
        }
        checksums.insert(entry.checksum)
        persist(entry)
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        checksums.remove(entry.checksum)

        // Tombstone the checksum so a later re-import doesn't bring it back.
        deletedChecksums.insert(entry.checksum)
        persistDeleted()

        try? FileManager.default.removeItem(at: jsonURL(for: entry))
        try? FileManager.default.removeItem(at: Storage.audioDir.appendingPathComponent(entry.audioFileName))
    }

    private func persistDeleted() {
        guard let data = try? encoder.encode(Array(deletedChecksums)) else {
            return
        }
        try? data.write(to: Storage.deletedFile, options: .atomic)
    }

    func audioURL(for entry: Entry) -> URL {
        Storage.audioDir.appendingPathComponent(entry.audioFileName)
    }

    /// Entries grouped by calendar day, each day's entries in chronological order,
    /// days themselves newest first — the diary's natural reverse-chronological feed.
    var days: [(day: Date, entries: [Entry])] {
        let grouped = Dictionary(grouping: entries, by: \.day)
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.date > $1.date })   // newest first within the day
        }
    }

    /// The set of calendar days that hold at least one entry — drives the calendar dots.
    var populatedDays: Set<Date> {
        Set(entries.map(\.day))
    }

    // MARK: - Disk

    private func jsonURL(for entry: Entry) -> URL {
        Storage.entriesDir.appendingPathComponent("\(entry.id.uuidString).json")
    }

    private func persist(_ entry: Entry) {
        guard let data = try? encoder.encode(entry) else {
            return
        }
        try? data.write(to: jsonURL(for: entry), options: .atomic)
    }

    /// SHA-256 of a file's bytes, the identity used for dedupe. `nonisolated` so the
    /// hash (which reads the whole file) can run off the main actor — hashing a large
    /// audio file on the main thread beach-balls the UI on import.
    nonisolated static func checksum(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
