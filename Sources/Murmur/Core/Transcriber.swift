import Foundation
import WhisperKit

/// Holds the WhisperKit instance in a non-isolated context so its non-Sendable
/// async methods can be called without crossing an actor boundary. Access is
/// serialized by the importer (one recording at a time), which is why the
/// `@unchecked Sendable` is sound.
private final class WhisperEngine: @unchecked Sendable {
    private var kit: WhisperKit?
    private var loadedVariant: String?

    func isReady(for variant: String) -> Bool {
        kit != nil && loadedVariant == variant
    }

    func load(variant: String, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        if isReady(for: variant) {
            return
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
    }

    func run(path: String) async throws -> (segments: [Segment], language: String?) {
        guard let kit else {
            throw Transcriber.TranscriberError.notReady
        }
        let options = DecodingOptions(skipSpecialTokens: true, withoutTimestamps: false)
        let results = try await kit.transcribe(audioPath: path, decodeOptions: options)
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
        var id: String { variant }
    }

    static let models: [Model] = [
        Model(variant: "large-v3", label: "Large v3", note: "Best accuracy · ~1.5 GB"),
        Model(variant: "distil-large-v3", label: "Distil Large v3", note: "Near-best, much faster"),
        Model(variant: "small", label: "Small", note: "Fast · good enough"),
        Model(variant: "base", label: "Base", note: "Very fast · rough"),
        Model(variant: "tiny", label: "Tiny", note: "Fastest · lowest accuracy"),
    ]

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

    private let engine = WhisperEngine()

    /// Ensures the selected model is downloaded and loaded. Cheap to call repeatedly.
    func prepare() async {
        UserDefaults.standard.set(selectedVariant, forKey: "MurmurModel")
        let variant = selectedVariant

        do {
            state = .downloading(0)
            try await engine.load(variant: variant) { fraction in
                Task { @MainActor in self.state = .downloading(fraction) }
            }
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
        let (segments, language) = try await engine.run(path: url.path)
        return Result(segments: segments, language: language)
    }

    enum TranscriberError: LocalizedError {
        case notReady
        var errorDescription: String? { "The transcription model isn't loaded yet." }
    }
}
