import Foundation
import FoundationModels

/// The shape we ask the on-device model to fill for each entry: a short diary
/// title and a one-or-two-sentence gist. Guided generation guarantees we get
/// both fields back rather than parsing free text.
@Generable
struct DiarySummary {
    @Guide(description: "A short, evocative diary-entry title of 3 to 7 words. No surrounding quotes, no trailing punctuation.")
    var title: String

    @Guide(description: "A one or two sentence summary of what the recording is about, in plain past tense, as a diary caption.")
    var summary: String
}

/// Wraps Apple's on-device Foundation Model to caption a transcript. Fully local,
/// no key, no network. Degrades gracefully to a heuristic title when Apple
/// Intelligence isn't available so the app still works on every machine. iOS-safe.
@MainActor
final class Summarizer: ObservableObject {
    enum Availability {
        case available
        case unavailable(String)
    }

    var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings for AI titles.")
        case .unavailable(.modelNotReady):
            return .unavailable("The on-device model is still downloading.")
        @unknown default:
            return .unavailable("On-device summaries are unavailable.")
        }
    }

    private static let instructions = """
        You caption entries in a personal spoken journal. Given a raw voice-note \
        transcript, produce a concise title and a short summary. Write as if \
        labelling a diary entry — warm, specific, never generic. Do not invent \
        facts that aren't in the transcript.
        """

    /// Produces a title + summary for a transcript, or a heuristic fallback when
    /// the on-device model can't run. Never throws — captioning must not block import.
    func summarize(_ transcript: String) async -> DiarySummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DiarySummary(title: "Untitled", summary: "")
        }

        if case .available = availability {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Caption this voice-journal transcript:\n\n\(clip(trimmed))"
            if let result = try? await session.respond(to: prompt, generating: DiarySummary.self) {
                return result.content
            }
        }

        return Self.fallback(for: trimmed)
    }

    /// Foundation Models has a bounded context; a long ramble only needs its gist.
    private func clip(_ text: String) -> String {
        let limit = 6000
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// A serviceable title/summary without any model: first words as a title,
    /// first sentence as a summary.
    static func fallback(for text: String) -> DiarySummary {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        let title = words.isEmpty ? "Untitled" : words.prefix(1).uppercased() + words.dropFirst()

        let sentence = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        let summary = String(sentence.prefix(160)).trimmingCharacters(in: .whitespaces)

        return DiarySummary(title: title, summary: summary)
    }
}
