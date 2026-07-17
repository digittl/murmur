import Foundation
import AVFoundation

/// The import queue. Accepts new files at any time — even mid-run — and works
/// them one at a time (oldest filename first) so the diary fills chronologically
/// and the Whisper model is never asked to do two files at once. Each finished
/// entry appears in the library the moment it's transcribed. Supports pause /
/// resume and cancel (which aborts the in-flight file too). iOS-safe.
@MainActor
final class Importer: ObservableObject {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "flac", "ogg"]

    enum ItemState: Equatable {
        case pending, transcribing, summarizing, done, skipped, cancelled
        case failed(String)

        var isPending: Bool { self == .pending }
        var isActive: Bool { self == .transcribing || self == .summarizing }
        var isFinished: Bool {
            switch self {
            case .done, .skipped, .cancelled, .failed: return true
            default: return false
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        var state: ItemState = .pending
        var entryID: UUID?
    }

    enum RunState { case idle, running, paused }

    @Published private(set) var items: [Item] = []
    @Published private(set) var runState: RunState = .idle
    @Published private(set) var statusLine = ""

    private let library: Library
    private let transcriber: Transcriber
    private let ollama: OllamaService
    private let settings: AppSettings
    private var worker: Task<Void, Never>?
    private var cancelledIDs: Set<UUID> = []
    private var autoClearTask: Task<Void, Never>?

    init(library: Library, transcriber: Transcriber, ollama: OllamaService, settings: AppSettings) {
        self.library = library
        self.transcriber = transcriber
        self.ollama = ollama
        self.settings = settings
    }

    // MARK: - Progress (for the queue view)

    var total: Int { items.count }
    var finishedCount: Int { items.filter { $0.state.isFinished }.count }
    var pendingCount: Int { items.filter { $0.state.isPending }.count }
    var activeItem: Item? { items.first { $0.state.isActive } }
    var isBusy: Bool { runState == .running }

    // MARK: - Controls

    /// Adds files (folders walked recursively). Starts the worker if idle; if
    /// paused, the files simply wait until resumed.
    func enqueue(urls: [URL]) {
        let existing = Set(items.map(\.url))
        let files = collectAudioFiles(from: urls)
            .filter { !existing.contains($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            if items.isEmpty { statusLine = "No new audio files found." }
            return
        }
        autoClearTask?.cancel()   // new work arrived; don't clear out from under it
        items.append(contentsOf: files.map { Item(url: $0, name: $0.lastPathComponent) })

        if runState == .idle {
            startWorker()
        }
    }

    /// Halts after the current file finishes; pending items keep their place.
    func pause() {
        if runState == .running {
            runState = .paused
            statusLine = "Paused."
        }
    }

    func resume() {
        if runState == .paused {
            startWorker()
        }
    }

    /// Stops everything, aborting the in-flight file, and marks the rest cancelled.
    func cancelAll() {
        transcriber.cancelCurrent()
        worker?.cancel()
        worker = nil
        for i in items.indices where !items[i].state.isFinished {
            items[i].state = .cancelled
        }
        runState = .idle
        statusLine = "Cancelled."
    }

    func clearFinished() {
        let removed = Set(items.filter { $0.state.isFinished }.map(\.id))
        items.removeAll { $0.state.isFinished }
        cancelledIDs.subtract(removed)
        if items.isEmpty {
            statusLine = ""
        }
    }

    /// Cancels or removes a single queued file. Pending items are dropped; the
    /// in-flight file is aborted mid-transcription; finished items are ignored.
    func cancel(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), !items[idx].state.isFinished else {
            return
        }
        cancelledIDs.insert(id)
        if items[idx].state.isActive {
            transcriber.cancelCurrent()   // aborts WhisperKit mid-file if it's transcribing
        }
        items[idx].state = .cancelled
    }

    // MARK: - Worker

    private func startWorker() {
        guard worker == nil else {
            return
        }
        runState = .running
        worker = Task { await drain() }
    }

    private func drain() async {
        statusLine = "Preparing \(transcriber.selectedVariant) model…"
        await transcriber.prepare()
        if case .failed(let message) = transcriber.state {
            statusLine = "Model failed to load: \(message)"
            worker = nil
            runState = .idle
            return
        }

        while !Task.isCancelled, runState == .running,
              let idx = items.firstIndex(where: { $0.state.isPending }) {
            await process(index: idx)
        }

        worker = nil
        if runState == .running {
            runState = .idle
            let added = items.filter { $0.state == .done }.count
            let skipped = items.filter { $0.state == .skipped }.count
            statusLine = "Done — \(added) added\(skipped > 0 ? ", \(skipped) skipped" : "")."
        }
        scheduleAutoClearIfDone()
    }

    /// Once the queue is idle and every item has finished, clear it after a short
    /// grace period so the drop zone (and the record button's empty state) return
    /// instead of the finished list lingering forever.
    private func scheduleAutoClearIfDone() {
        autoClearTask?.cancel()
        guard runState == .idle, !items.isEmpty, items.allSatisfy({ $0.state.isFinished }) else {
            return
        }
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled,
                  self.runState == .idle, self.items.allSatisfy({ $0.state.isFinished }) else {
                return
            }
            self.clearFinished()
        }
    }

    private func process(index: Int) async {
        let item = items[index]
        var copiedAudio: URL?

        guard let checksum = Library.checksum(of: item.url) else {
            items[index].state = .failed("Couldn't read file")
            return
        }
        if library.hasChecksum(checksum) {
            items[index].state = .skipped
            statusLine = "Skipped duplicate: \(item.name)"
            return
        }

        do {
            let id = UUID()
            let ext = item.url.pathExtension.isEmpty ? "m4a" : item.url.pathExtension.lowercased()
            let storedName = "\(id.uuidString).\(ext)"
            let dest = Storage.audioDir.appendingPathComponent(storedName)
            try Storage.ensureDirectories()
            try FileManager.default.copyItem(at: item.url, to: dest)
            copiedAudio = dest

            items[index].state = .transcribing
            statusLine = "Transcribing \(item.name)…"
            let result = try await transcriber.transcribe(url: dest)

            if cancelledIDs.contains(item.id) {
                throw Transcriber.TranscriberError.cancelled
            }

            // Silence / non-speech: WhisperKit emits tokens like "[BLANK_AUDIO]"
            // rather than empty text. Don't invent a captioned entry for it.
            let text = Self.cleanTranscript(result.segments.map(\.text).joined())
            if text.isEmpty {
                items[index].state = .failed("No speech detected")
                if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
                statusLine = "No speech detected in \(item.name)."
                return
            }

            items[index].state = .summarizing
            statusLine = "Summarizing \(item.name)…"
            let caption = await ollama.summarize(
                text,
                titlePrompt: settings.effectiveTitlePrompt,
                summaryPrompt: settings.effectiveSummaryPrompt
            )

            if cancelledIDs.contains(item.id) {
                throw Transcriber.TranscriberError.cancelled
            }

            var duration = result.segments.last?.end ?? 0
            if duration == 0 {
                duration = await Self.probeDuration(dest)
            }

            let entry = Entry(
                id: id,
                audioFileName: storedName,
                originalName: item.name,
                checksum: checksum,
                date: Self.recordingDate(for: item.url),
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
            library.upsert(entry)
            items[index].entryID = entry.id
            items[index].state = .done
            statusLine = "Added: \(entry.title)"
        } catch is CancellationError {
            items[index].state = .cancelled
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
        } catch let error as Transcriber.TranscriberError where error == .cancelled {
            items[index].state = .cancelled
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
        } catch {
            items[index].state = .failed(error.localizedDescription)
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
        }
    }

    // MARK: - File helpers

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

    /// Strips WhisperKit's non-speech markers — "[BLANK_AUDIO]", "(silence)",
    /// "[MUSIC]" and the like — so a recording of pure silence reads as empty
    /// rather than a bracketed token that gets captioned into a phantom entry.
    static func cleanTranscript(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^\)]*\)"#] {
            if let re = try? NSRegularExpression(pattern: pattern) {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func probeDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            return 0
        }
        return CMTimeGetSeconds(duration)
    }
}
