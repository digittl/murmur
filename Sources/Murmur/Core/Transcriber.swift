import Foundation
import WhisperKit

/// A thread-safe cancel flag shared into WhisperKit's transcription callback so a
/// long file can be aborted mid-way (e.g. when the user cancels the queue).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
}

/// Holds the WhisperKit instance in a non-isolated context so its non-Sendable
/// async methods can be called without crossing an actor boundary. Access is
/// serialized by the importer (one recording at a time), which is why the
/// `@unchecked Sendable` is sound.
private final class WhisperEngine: @unchecked Sendable {
    private var kit: WhisperKit?
    private var loadedVariant: String?
    private var loadedFolder: String?

    func isReady(for variant: String) -> Bool {
        kit != nil && loadedVariant == variant
    }

    /// Downloads a model into the local cache without loading it; returns the
    /// on-disk folder (used for the explicit "Download" button in Settings).
    func prefetch(variant: String, onProgress: @Sendable @escaping (Double) -> Void) async throws -> String {
        let folder = try await WhisperKit.download(variant: variant) { progress in
            onProgress(progress.fractionCompleted)
        }
        return folder.path
    }

    /// Loads the model, downloading it first if needed; returns its on-disk folder.
    func load(variant: String, onProgress: @Sendable @escaping (Double) -> Void) async throws -> String {
        if isReady(for: variant), let loadedFolder {
            return loadedFolder
        }
        let folder = try await WhisperKit.download(variant: variant) { progress in
            onProgress(progress.fractionCompleted)
        }
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
        loadedVariant = variant
        loadedFolder = folder.path
        return folder.path
    }

    /// Drops the loaded model if it matches (so a deleted model isn't kept warm).
    func unloadIfLoaded(_ variant: String) {
        if loadedVariant == variant {
            kit = nil
            loadedVariant = nil
            loadedFolder = nil
        }
    }

    func run(path: String, cancel: CancelToken) async throws -> (segments: [Segment], language: String?) {
        guard let kit else {
            throw Transcriber.TranscriberError.notReady
        }
        let options = DecodingOptions(skipSpecialTokens: true, withoutTimestamps: false)
        // Returning false from the callback stops WhisperKit early — mid-file cancel.
        let results = try await kit.transcribe(audioPath: path, decodeOptions: options) { _ in
            cancel.isCancelled ? false : nil
        }
        if cancel.isCancelled {
            throw Transcriber.TranscriberError.cancelled
        }
        let raw = results.flatMap(\.segments)

        var segments: [Segment] = []
        for (index, s) in raw.enumerated() {
            // Strip any residual Whisper special tokens like <|startoftranscript|> or <|0.00|>.
            let cleaned = s.text
                .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else {
                continue
            }
            segments.append(Segment(id: index, start: Double(s.start), end: Double(s.end), text: " " + cleaned))
        }
        return (segments, results.first?.language)
    }
}

/// On-device speech-to-text via WhisperKit (Core ML). Downloads the chosen model
/// once, keeps it warm, and turns an audio file into timestamped segments. This
/// is the main-actor UI shell around `WhisperEngine`; it only publishes state.
@MainActor
final class Transcriber: ObservableObject {
    /// A Whisper model the user can pick. `variant` is the substring WhisperKit
    /// matches against the model repo.
    struct Model: Identifiable, Hashable {
        let variant: String
        let label: String
        let note: String
        let folder: String   // on-disk folder name in the WhisperKit cache
        var id: String { variant }
    }

    static let models: [Model] = [
        Model(variant: "large-v3", label: "Large v3", note: "Best accuracy · ~1.5 GB", folder: "openai_whisper-large-v3"),
        Model(variant: "distil-large-v3", label: "Distil Large v3", note: "Near-best · much faster · ~600 MB", folder: "distil-whisper_distil-large-v3"),
        Model(variant: "small", label: "Small", note: "Fast · good enough · ~480 MB", folder: "openai_whisper-small"),
        Model(variant: "base", label: "Base", note: "Very fast · rough · ~150 MB", folder: "openai_whisper-base"),
        Model(variant: "tiny", label: "Tiny", note: "Fastest · lowest accuracy · ~75 MB", folder: "openai_whisper-tiny"),
    ]

    /// The WhisperKit model cache — `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.
    static var modelsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")
    }

    static func folderURL(for variant: String) -> URL? {
        guard let model = models.first(where: { $0.variant == variant }) else { return nil }
        return modelsRoot.appending(path: model.folder)
    }

    static let defaultVariant = "large-v3"

    enum State: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var selectedVariant: String = UserDefaults.standard.string(forKey: "MurmurModel") ?? Transcriber.defaultVariant
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloads: [String: Double] = [:]   // variant -> fraction while downloading

    private let engine = WhisperEngine()
    private let cancelToken = CancelToken()

    init() {
        refreshInstalled()
    }

    func isInstalled(_ variant: String) -> Bool { installed.contains(variant) }
    func isDownloading(_ variant: String) -> Bool { downloads[variant] != nil }

    /// Truth comes from disk: a model is installed iff its cache folder exists.
    func refreshInstalled() {
        var found: Set<String> = []
        for model in Self.models {
            let url = Self.modelsRoot.appending(path: model.folder)
            if FileManager.default.fileExists(atPath: url.path) {
                found.insert(model.variant)
            }
        }
        installed = found
    }

    /// Aborts the file currently being transcribed, if any.
    func cancelCurrent() {
        cancelToken.cancel()
    }

    /// Explicitly downloads a model (the Settings "Download" button).
    func download(_ variant: String) async {
        guard downloads[variant] == nil else { return }
        downloads[variant] = 0
        do {
            _ = try await engine.prefetch(variant: variant) { fraction in
                Task { @MainActor in self.downloads[variant] = fraction }
            }
        } catch {
            // Leave uninstalled; the row shows the Download button again.
        }
        downloads[variant] = nil
        refreshInstalled()
    }

    /// Deletes a downloaded model's files. Refuses to delete the active model.
    func delete(_ variant: String) async {
        guard variant != selectedVariant, let url = Self.folderURL(for: variant) else { return }
        engine.unloadIfLoaded(variant)
        try? FileManager.default.removeItem(at: url)
        refreshInstalled()
    }

    /// Ensures the selected model is downloaded and loaded. Cheap to call repeatedly.
    func prepare() async {
        UserDefaults.standard.set(selectedVariant, forKey: "MurmurModel")
        let variant = selectedVariant

        do {
            state = .downloading(0)
            _ = try await engine.load(variant: variant) { fraction in
                Task { @MainActor in self.state = .downloading(fraction) }
            }
            refreshInstalled()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    struct Result {
        var segments: [Segment]
        var language: String?
    }

    /// Transcribes one audio file into ordered segments. Assumes `prepare()` succeeded.
    func transcribe(url: URL) async throws -> Result {
        cancelToken.reset()
        let (segments, language) = try await engine.run(path: url.path, cancel: cancelToken)
        return Result(segments: segments, language: language)
    }

    enum TranscriberError: LocalizedError {
        case notReady
        case cancelled
        var errorDescription: String? {
            switch self {
            case .notReady: return "The transcription model isn't loaded yet."
            case .cancelled: return "Transcription cancelled."
            }
        }
    }
}
