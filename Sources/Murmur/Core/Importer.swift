import Foundation
import AVFoundation

/// Drives a folder (or a set of files) through the whole pipeline: dedupe →
/// copy audio into the library → transcribe → summarize → save an entry. Runs
/// oldest-first so the diary fills in chronological order, and publishes
/// progress for the UI. iOS-safe (no AppKit).
@MainActor
final class Importer: ObservableObject {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "flac", "ogg"]

    @Published private(set) var isRunning = false
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var skipped = 0
    @Published private(set) var currentName = ""
    @Published private(set) var statusLine = ""

    private let library: Library
    private let transcriber: Transcriber
    private let summarizer: Summarizer

    init(library: Library, transcriber: Transcriber, summarizer: Summarizer) {
        self.library = library
        self.transcriber = transcriber
        self.summarizer = summarizer
    }

    /// Imports every audio file found under the given URLs (folders are walked
    /// recursively). Safe to hand a mix of folders and loose files.
    func `import`(urls: [URL]) async {
        guard !isRunning else {
            return
        }

        let files = collectAudioFiles(from: urls).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            statusLine = "No audio files found."
            return
        }

        isRunning = true
        total = files.count
        done = 0
        skipped = 0
        defer {
            isRunning = false
            currentName = ""
        }

        statusLine = "Preparing \(transcriber.selectedVariant) model…"
        await transcriber.prepare()
        if case .failed(let message) = transcriber.state {
            statusLine = "Model failed to load: \(message)"
            return
        }

        for file in files {
            currentName = file.lastPathComponent

            guard let checksum = Library.checksum(of: file) else {
                done += 1
                continue
            }
            if library.hasChecksum(checksum) {
                skipped += 1
                done += 1
                statusLine = "Skipped duplicate: \(file.lastPathComponent)"
                continue
            }

            do {
                let entry = try await makeEntry(from: file, checksum: checksum)
                library.upsert(entry)
                statusLine = "Added: \(entry.title)"
            } catch {
                statusLine = "Failed: \(file.lastPathComponent) — \(error.localizedDescription)"
            }

            done += 1
        }

        statusLine = "Done — \(done - skipped) added, \(skipped) skipped."
    }

    // MARK: - One file

    private func makeEntry(from source: URL, checksum: String) async throws -> Entry {
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let storedName = "\(id.uuidString).\(ext)"
        let dest = Storage.audioDir.appendingPathComponent(storedName)

        try Storage.ensureDirectories()
        try FileManager.default.copyItem(at: source, to: dest)

        statusLine = "Transcribing \(source.lastPathComponent)…"
        let result = try await transcriber.transcribe(url: dest)

        var duration = result.segments.last?.end ?? 0
        if duration == 0 {
            duration = await Self.probeDuration(dest)
        }
        let text = result.segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        statusLine = "Summarizing \(source.lastPathComponent)…"
        let caption = await summarizer.summarize(text)

        return Entry(
            id: id,
            audioFileName: storedName,
            originalName: source.lastPathComponent,
            checksum: checksum,
            date: Self.recordingDate(for: source),
            duration: duration,
            title: caption.title,
            summary: caption.summary,
            segments: result.segments,
            transcriptEdited: false,
            summaryEdited: false,
            createdAt: .now,
            model: transcriber.selectedVariant,
            language: result.language
        )
    }

    // MARK: - Helpers

    private func collectAudioFiles(from urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }

            if isDir.boolValue {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let child = enumerator?.nextObject() as? URL {
                    if Self.audioExtensions.contains(child.pathExtension.lowercased()) {
                        out.append(child)
                    }
                }
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }

        return out
    }

    /// The recording's timestamp. Filenames like `2026-07-17-09-30-00` are the
    /// truth (they survive copying off a USB); otherwise fall back to file dates.
    static func recordingDate(for url: URL) -> Date {
        let name = url.deletingPathExtension().lastPathComponent
        if let parsed = parseTimestamp(from: name) {
            return parsed
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
            ?? .now
    }

    private static func parseTimestamp(from name: String) -> Date? {
        // Match 6 numeric groups anywhere: YYYY MM DD HH MM SS with any separators.
        let pattern = #"(\d{4})\D(\d{2})\D(\d{2})\D(\d{2})\D(\d{2})\D(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else {
            return nil
        }

        func group(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: name) else { return 0 }
            return Int(name[r]) ?? 0
        }

        var comps = DateComponents()
        comps.year = group(1); comps.month = group(2); comps.day = group(3)
        comps.hour = group(4); comps.minute = group(5); comps.second = group(6)
        return Calendar.current.date(from: comps)
    }

    static func probeDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            return 0
        }
        return CMTimeGetSeconds(duration)
    }
}
