import Foundation

/// Headless smoke test of the full pipeline (queue → dedupe → transcribe →
/// Ollama summarize → persist), run via `Murmur --selftest <folder>`. Uses the
/// fast `tiny` Whisper model and a throwaway storage root so it never touches the
/// real iCloud library. Not part of the shipping UI; kept for dev/CI verification.
enum SelfTest {
    static func run(folder: String) {
        // Dev override: MURMUR_SELFTEST_ROOT seeds a real library and keeps it.
        let env = ProcessInfo.processInfo.environment
        let keep = env["MURMUR_SELFTEST_ROOT"] != nil
        let temp = env["MURMUR_SELFTEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("murmur-selftest-\(UUID().uuidString)")
        UserDefaults.standard.set(temp.path, forKey: "MurmurStorageRoot")
        UserDefaults.standard.set("tiny", forKey: "MurmurModel")

        Task { @MainActor in
            print("== Murmur self-test ==")
            print("storage root: \(Storage.root.path)")

            let library = Library()
            library.load()
            let transcriber = Transcriber()
            let ollama = OllamaService()

            await ollama.start()
            switch ollama.serverState {
            case .ready:
                print("Ollama: ready — installed: \(ollama.installed.sorted().joined(separator: ", "))")
            case .failed(let why):
                print("Ollama: unavailable — \(why) (using fallback captions)")
            default:
                print("Ollama: \(ollama.serverState)")
            }
            print("active model: \(ollama.activeTag) (installed: \(ollama.isInstalled(ollama.activeTag)))")

            let importer = Importer(library: library, transcriber: transcriber, ollama: ollama, settings: AppSettings())
            print("enqueueing \(folder) with whisper=\(transcriber.selectedVariant)…")
            importer.enqueue(urls: [URL(fileURLWithPath: folder)])
            await waitForQueue(importer)

            print("\n-- entries (\(library.entries.count)) --")
            for entry in library.entries.sorted(by: { $0.date < $1.date }) {
                print("• [\(entry.date.formatted(date: .abbreviated, time: .shortened))] \"\(entry.title)\"")
                print("  summary: \(entry.summary)")
                print("  \(entry.segments.count) segments, \(String(format: "%.1fs", entry.duration))")
            }

            // Dedupe: clear finished, re-enqueue the same folder — all should skip.
            let before = library.entries.count
            importer.clearFinished()
            importer.enqueue(urls: [URL(fileURLWithPath: folder)])
            await waitForQueue(importer)
            let skipped = importer.items.filter { $0.state == .skipped }.count
            let after = library.entries.count
            print("\ndedupe: \(before) -> \(after) entries, \(skipped) skipped on re-import — \(before == after && skipped > 0 ? "PASS" : "FAIL")")

            // Persistence: a fresh Library reads the same entries back.
            let reopened = Library()
            reopened.load()
            print("persistence: reloaded \(reopened.entries.count) — \(reopened.entries.count == after ? "PASS" : "FAIL")")

            ollama.stop()
            if !keep {
                try? FileManager.default.removeItem(at: temp)
            }
            print("\n== done ==")
            exit(before == after && skipped > 0 && reopened.entries.count == after && after > 0 ? 0 : 1)
        }

        RunLoop.main.run()
    }

    @MainActor
    private static func waitForQueue(_ importer: Importer) async {
        for _ in 0..<1200 {   // up to ~120s
            if importer.runState == .idle, importer.finishedCount == importer.total, importer.total > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
