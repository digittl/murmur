import Foundation

/// Headless smoke test of the full pipeline (dedupe → transcribe → summarize →
/// persist), run via `Murmur --selftest <folder>`. Uses the fast `tiny` model and
/// a throwaway storage root so it never touches the real iCloud library. Not part
/// of the shipping UI; kept for dev/CI verification.
enum SelfTest {
    static func run(folder: String) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-selftest-\(UUID().uuidString)")
        UserDefaults.standard.set(temp.path, forKey: "MurmurStorageRoot")
        UserDefaults.standard.set("tiny", forKey: "MurmurModel")

        Task { @MainActor in
            print("== Murmur self-test ==")
            print("storage root: \(Storage.root.path)")

            let library = Library()
            library.load()
            let transcriber = Transcriber()
            let summarizer = Summarizer()

            switch summarizer.availability {
            case .available: print("Foundation Models: AVAILABLE (on-device summaries)")
            case .unavailable(let why): print("Foundation Models: unavailable — \(why) (using fallback captions)")
            }

            let importer = Importer(library: library, transcriber: transcriber, summarizer: summarizer)
            print("importing \(folder) with model=\(transcriber.selectedVariant)…")
            await importer.import(urls: [URL(fileURLWithPath: folder)])

            print("\n-- entries (\(library.entries.count)) --")
            for entry in library.entries.sorted(by: { $0.date < $1.date }) {
                print("• [\(entry.date.formatted(date: .abbreviated, time: .shortened))] \"\(entry.title)\"")
                print("  summary: \(entry.summary)")
                print("  \(entry.segments.count) segments, \(String(format: "%.1fs", entry.duration)), text: \(entry.plainText.prefix(90))…")
            }

            // Dedupe check: re-importing the same folder must add nothing.
            let before = library.entries.count
            await importer.import(urls: [URL(fileURLWithPath: folder)])
            let after = library.entries.count
            print("\ndedupe: \(before) -> \(after) after re-import (skipped \(importer.skipped)) — \(before == after ? "PASS" : "FAIL")")

            // Persistence check: a fresh Library reads the same entries back from disk.
            let reopened = Library()
            reopened.load()
            print("persistence: reloaded \(reopened.entries.count) entries from disk — \(reopened.entries.count == after ? "PASS" : "FAIL")")

            try? FileManager.default.removeItem(at: temp)
            print("\n== done ==")
            exit(before == after && reopened.entries.count == after && after > 0 ? 0 : 1)
        }

        RunLoop.main.run()
    }
}
