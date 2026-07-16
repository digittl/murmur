import Foundation

/// One transcribed segment of audio with its timestamps, the unit the player
/// syncs to and the unit the user edits. Times are seconds from the start.
struct Segment: Codable, Identifiable, Hashable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
}

/// A single diary entry: one imported recording plus everything Murmur derived
/// from it. Persisted as one JSON file per entry so iCloud never has to merge a
/// shared index. This type is UI-free and safe to compile on iOS.
struct Entry: Codable, Identifiable, Hashable {
    var id: UUID
    var audioFileName: String   // basename inside the audio/ dir
    var originalName: String    // the file's name as imported, for display
    var checksum: String        // sha256 of the audio bytes — the dedupe key
    var date: Date              // when the recording was made (parsed or file date)
    var duration: Double
    var title: String
    var summary: String
    var segments: [Segment]
    var transcriptEdited: Bool
    var summaryEdited: Bool
    var createdAt: Date
    var model: String
    var language: String?

    var plainText: String {
        segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The calendar day this entry belongs to, used to group the diary.
    var day: Date {
        Calendar.current.startOfDay(for: date)
    }
}
