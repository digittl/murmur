import Foundation
import AVFoundation

/// The import queue. Accepts new files at any time — even mid-run — and works
/// them one at a time (oldest filename first) so the diary fills chronologically
/// and the Whisper model is never asked to do two files at once. Each finished
/// entry appears in the library the moment it's transcribed. Supports pause /
/// resume and cancel (which aborts the in-flight file too). iOS-safe.
@MainActor
final class Importer: ObservableObject {
    nonisolated static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "flac", "ogg"]

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
        // When set, this item re-transcribes an existing entry's stored audio in
        // place rather than importing a new file (see `reprocess`).
        var reTranscribeEntryID: UUID?
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
    private var workerTasks: [Task<Void, Never>] = []
    private var cancelledIDs: Set<UUID> = []
    private var autoClearTask: Task<Void, Never>?
    // One cancel token per in-flight item, so a single file can be aborted (and
    // the whole queue cancelled) across the parallel workers.
    private var tokens: [UUID: CancelToken] = [:]
    // Checksums claimed by an in-flight import. With parallel workers, two copies
    // of the same audio can clear the library dedupe before either is saved; this
    // reserves the checksum synchronously so the second copy still skips.
    private var inFlightChecksums: Set<String> = []
    // Duplicates/deleted files skipped this batch. They're pulled from the queue on
    // sight, so this preserves the count for the "Done" summary. Reset on clear.
    private(set) var skippedCount = 0

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
        Task { await ingest(urls: urls) }
    }

    /// Walks the dropped tree off the main actor — a big folder can hang the UI for
    /// a beat otherwise (the "beach ball" on a first drag) — then appends the new
    /// files back on the main actor.
    private func ingest(urls: [URL]) async {
        let collected = await Task.detached(priority: .userInitiated) {
            Self.collectAudioFiles(from: urls)
        }.value
        // Snapshot the existing URLs AFTER the walk (and with no `await` before the
        // append below) so two overlapping drops can't both clear a stale snapshot
        // and queue the same file twice.
        let existing = Set(items.map(\.url))
        let files = collected
            .filter { !existing.contains($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            if items.isEmpty { statusLine = "No new audio files found." }
            return
        }
        autoClearTask?.cancel()   // new work arrived; don't clear out from under it
        items.append(contentsOf: files.map { Item(url: $0, name: $0.lastPathComponent) })

        ensureRunning()
    }

    /// Re-runs transcription (and re-captioning) on an entry that's already in the
    /// library, using its stored audio and the currently selected model. Routed
    /// through the same queue as imports so WhisperKit is never asked to do two
    /// files at once, and so progress shows in the queue view. Updates the entry
    /// in place; a fresh transcript means a fresh title and summary too.
    func reTranscribe(_ entry: Entry) {
        guard !isReTranscribing(entry.id) else {
            return
        }
        autoClearTask?.cancel()
        let label = entry.title.isEmpty ? entry.originalName : entry.title
        items.append(Item(url: library.audioURL(for: entry), name: label, reTranscribeEntryID: entry.id))

        ensureRunning()
    }

    /// True while a re-transcribe of this entry is queued or running.
    func isReTranscribing(_ entryID: UUID) -> Bool {
        items.contains { $0.reTranscribeEntryID == entryID && !$0.state.isFinished }
    }

    /// Halts after the current file finishes; pending items keep their place.
    func pause() {
        if runState == .running {
            runState = .paused
            statusLine = "Paused."
        }
    }

    func resume() {
        guard runState == .paused else {
            return
        }
        runState = .idle   // ensureRunning starts a fresh drain (now, or when the old one finishes)
        ensureRunning()
    }

    /// Stops everything, aborting every in-flight file, and marks the rest cancelled.
    /// `worker` is deliberately left set — the running drain clears it in its `defer`
    /// once its workers have fully exited, which is what guarantees a re-import can't
    /// start a second drain that shares the same WhisperKit engines.
    func cancelAll() {
        for token in tokens.values {
            token.cancel()
        }
        for task in workerTasks {
            task.cancel()
        }
        worker?.cancel()
        for i in items.indices where !items[i].state.isFinished {
            items[i].state = .cancelled
        }
        runState = .idle
        skippedCount = 0
        statusLine = "Cancelled."
    }

    func clearFinished() {
        let removed = Set(items.filter { $0.state.isFinished }.map(\.id))
        items.removeAll { $0.state.isFinished }
        cancelledIDs.subtract(removed)
        if items.isEmpty {
            statusLine = ""
            skippedCount = 0
        }
    }

    /// Cancels or removes a single queued file. Pending items are dropped; the
    /// in-flight file is aborted mid-transcription; finished items are ignored.
    func cancel(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), !items[idx].state.isFinished else {
            return
        }
        cancelledIDs.insert(id)
        tokens[id]?.cancel()   // aborts this file's WhisperKit run mid-transcription
        items[idx].state = .cancelled
    }

    // MARK: - Worker

    /// Starts the drain if one isn't already running, there's pending work, and
    /// we're not paused. The single-drain invariant (only ever one live `worker`)
    /// is what keeps two drains from sharing the WhisperKit engines.
    private func ensureRunning() {
        guard worker == nil, runState != .paused,
              items.contains(where: { $0.state.isPending }) else {
            return
        }
        runState = .running
        worker = Task { await drain() }
    }

    /// Mutates the item with this id, if it still exists. Workers key off ids, not
    /// array indices, so a `clearFinished()` (or any removal) that shifts the array
    /// mid-flight can't make a worker write to the wrong slot or trap out of bounds.
    private func update(_ id: UUID, _ mutate: (inout Item) -> Void) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            mutate(&items[idx])
        }
    }

    private func drain() async {
        // The drain owns `worker`'s lifetime: only it clears the handle, and only
        // once its workers have fully exited — then it re-arms for anything that
        // was enqueued while it was finishing. This is the single-drain guarantee.
        // Re-arm is suppressed only on a model-load failure, where the pending items
        // would otherwise spin us straight back into the same failing prepare().
        var rearm = true
        defer {
            worker = nil
            scheduleAutoClearIfDone()
            if rearm {
                ensureRunning()
            }
        }

        statusLine = "Preparing \(transcriber.selectedVariant) model…"
        await transcriber.prepare()
        if case .failed(let message) = transcriber.state {
            statusLine = "Model failed to load: \(message)"
            runState = .idle
            rearm = false
            return
        }
        // Cancelled or paused while the model was loading — don't spawn workers.
        guard !Task.isCancelled, runState == .running else {
            return
        }

        // Fan out one loop per worker. Each pulls the next pending file, transcribes
        // it on its own engine, then captions it — so two files transcribe at once
        // and one can be captioning (Ollama) while the other still transcribes. The
        // loops share the main actor and interleave at each `await`, while the heavy
        // WhisperKit work runs off-actor on distinct engines — real parallelism.
        let workers = (0..<transcriber.workerCount).map { w in
            Task { @MainActor in await self.runWorker(w) }
        }
        workerTasks = workers
        for task in workers {
            await task.value
        }
        workerTasks = []

        if runState == .running {
            runState = .idle
            let done = items.filter { $0.state == .done }
            let added = done.filter { $0.reTranscribeEntryID == nil }.count
            let redone = done.count - added
            let skipped = skippedCount

            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if redone > 0 { parts.append("\(redone) re-transcribed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            statusLine = parts.isEmpty ? "Done." : "Done — " + parts.joined(separator: ", ") + "."
        }
    }

    /// One worker's loop: claim the next pending file and process it, until none
    /// remain. Claiming is a synchronous find-and-mark (no `await` between the two)
    /// so the two workers running on the main actor can never grab the same file.
    private func runWorker(_ worker: Int) async {
        while !Task.isCancelled, runState == .running {
            guard let idx = items.firstIndex(where: { $0.state.isPending }) else {
                return
            }
            items[idx].state = .transcribing   // claim before any suspension point
            let item = items[idx]              // immutable snapshot; state is mutated by id from here
            await process(item, worker: worker)
        }
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

    private func process(_ item: Item, worker: Int) async {
        let token = CancelToken()
        tokens[item.id] = token
        defer { tokens[item.id] = nil }

        if let entryID = item.reTranscribeEntryID {
            await reprocess(item, entryID: entryID, worker: worker, token: token)
            return
        }

        var copiedAudio: URL?

        guard let checksum = Library.checksum(of: item.url) else {
            update(item.id) { $0.state = .failed("Couldn't read file") }
            return
        }
        if library.hasChecksum(checksum) || library.wasDeleted(checksum) || inFlightChecksums.contains(checksum) {
            // Duplicate or previously-deleted: pull it straight out of the queue.
            skippedCount += 1
            items.removeAll { $0.id == item.id }
            statusLine = library.wasDeleted(checksum) ? "Skipped deleted: \(item.name)" : "Skipped duplicate: \(item.name)"
            return
        }
        inFlightChecksums.insert(checksum)   // reserve synchronously; the other worker will now skip a dup
        defer { inFlightChecksums.remove(checksum) }

        do {
            let id = UUID()
            let ext = item.url.pathExtension.isEmpty ? "m4a" : item.url.pathExtension.lowercased()
            let storedName = "\(id.uuidString).\(ext)"
            let dest = Storage.audioDir.appendingPathComponent(storedName)
            try Storage.ensureDirectories()
            try FileManager.default.copyItem(at: item.url, to: dest)
            copiedAudio = dest

            update(item.id) { $0.state = .transcribing }
            statusLine = "Transcribing \(item.name)…"
            let result = try await transcriber.transcribe(url: dest, worker: worker, cancel: token)

            if cancelledIDs.contains(item.id) {
                throw Transcriber.TranscriberError.cancelled
            }

            // Silence / non-speech: WhisperKit emits tokens like "[BLANK_AUDIO]"
            // rather than empty text. Don't invent a captioned entry for it.
            let text = Self.cleanTranscript(result.segments.map(\.text).joined())
            if text.isEmpty {
                update(item.id) { $0.state = .failed("No speech detected") }
                if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
                statusLine = "No speech detected in \(item.name)."
                return
            }

            update(item.id) { $0.state = .summarizing }
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
            update(item.id) { $0.entryID = entry.id; $0.state = .done }
            statusLine = "Added: \(entry.title)"
        } catch is CancellationError {
            update(item.id) { $0.state = .cancelled }
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
        } catch let error as Transcriber.TranscriberError where error == .cancelled {
            update(item.id) { $0.state = .cancelled }
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
        } catch {
            update(item.id) { $0.state = .failed(error.localizedDescription) }
            if let copiedAudio { try? FileManager.default.removeItem(at: copiedAudio) }
        }
    }

    /// Re-transcribes an existing entry's stored audio and updates it in place.
    /// Mirrors `process`'s transcribe → summarize steps, but keeps the entry's
    /// identity (id, audio file, checksum, date) and overwrites only the derived
    /// fields — segments, language, model, duration, title, summary — dropping any
    /// manual transcript edit since the words come out fresh.
    private func reprocess(_ item: Item, entryID: UUID, worker: Int, token: CancelToken) async {
        let name = item.name

        guard var entry = library.entries.first(where: { $0.id == entryID }) else {
            update(item.id) { $0.state = .failed("Entry no longer exists") }
            return
        }
        let audio = library.audioURL(for: entry)
        guard FileManager.default.fileExists(atPath: audio.path) else {
            update(item.id) { $0.state = .failed("Audio file is missing") }
            return
        }

        do {
            update(item.id) { $0.state = .transcribing }
            statusLine = "Re-transcribing \(name)…"
            let result = try await transcriber.transcribe(url: audio, worker: worker, cancel: token)

            if cancelledIDs.contains(item.id) {
                throw Transcriber.TranscriberError.cancelled
            }

            let text = Self.cleanTranscript(result.segments.map(\.text).joined())
            if text.isEmpty {
                update(item.id) { $0.state = .failed("No speech detected") }
                statusLine = "No speech detected in \(name)."
                return
            }

            update(item.id) { $0.state = .summarizing }
            statusLine = "Summarizing \(name)…"
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
                duration = await Self.probeDuration(audio)
            }

            entry.segments = result.segments
            entry.language = result.language
            entry.model = transcriber.selectedVariant
            entry.duration = duration
            entry.text = nil                  // the fresh transcript supersedes any manual edit
            entry.transcriptEdited = false
            entry.title = caption.title
            entry.summary = caption.summary
            entry.summaryEdited = false
            library.upsert(entry)

            update(item.id) { $0.entryID = entry.id; $0.state = .done }
            statusLine = "Re-transcribed: \(entry.title)"
        } catch is CancellationError {
            update(item.id) { $0.state = .cancelled }
        } catch let error as Transcriber.TranscriberError where error == .cancelled {
            update(item.id) { $0.state = .cancelled }
        } catch {
            update(item.id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: - File helpers

    nonisolated private static func collectAudioFiles(from urls: [URL]) -> [URL] {
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
