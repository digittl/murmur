import Foundation

/// Headless smoke test of the full pipeline (queue → dedupe → transcribe →
/// Ollama tidy-up → summarize → persist), run via `Murmur --selftest <folder>`. Uses the
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
            await library.load()
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

            let settings = AppSettings()
            // In MURMUR_SELFTEST_ROOT mode the library is reused, so only entries this
            // run imports can be held to the pipeline's assertions.
            let preexisting = Set(library.entries.map(\.id))
            let importer = Importer(library: library, transcriber: transcriber, ollama: ollama, settings: settings)
            print("enqueueing \(folder) with whisper=\(transcriber.selectedVariant)…")
            importer.enqueue(urls: [URL(fileURLWithPath: folder)])
            await waitForQueue(importer)

            print("\n-- entries (\(library.entries.count)) --")
            for entry in library.entries.sorted(by: { $0.date < $1.date }) {
                print("• [\(entry.date.formatted(date: .abbreviated, time: .shortened))] \"\(entry.title)\"")
                print("  summary: \(entry.summary)")
                print("  \(entry.segments.count) segments, \(String(format: "%.1fs", entry.duration))")
                print("  tidied: \(entry.hasTidy ? entry.prose : "— (raw)")")
            }

            // Tidy-up: with a caption model available every new entry should carry a
            // rewrite, and the raw words must still be intact behind it. Without
            // Ollama the tidy is skipped by design, so it can't be a failure.
            var tidyOK = true
            let imported = library.entries.filter { !preexisting.contains($0.id) }
            if ollama.serverState == .ready, ollama.isInstalled(ollama.activeTag), settings.tidyOnImport, !imported.isEmpty {
                let tidied = imported.filter(\.hasTidy).count
                let rawIntact = imported.allSatisfy { !$0.rawProse.isEmpty }
                tidyOK = tidied == imported.count && rawIntact
                print("\ntidy-up: \(tidied)/\(imported.count) rewritten, raw kept — \(tidyOK ? "PASS" : "FAIL")")
            }

            // Dedupe: clear finished, re-enqueue the same folder — all should skip
            // (and be pulled out of the queue, so count them via skippedCount).
            let before = library.entries.count
            importer.clearFinished()
            importer.enqueue(urls: [URL(fileURLWithPath: folder)])
            await waitForQueue(importer)
            let skipped = importer.skippedCount
            let after = library.entries.count
            print("\ndedupe: \(before) -> \(after) entries, \(skipped) skipped on re-import — \(before == after && skipped > 0 ? "PASS" : "FAIL")")

            // Persistence: a fresh Library reads the same entries back.
            let reopened = Library()
            await reopened.load()
            print("persistence: reloaded \(reopened.entries.count) — \(reopened.entries.count == after ? "PASS" : "FAIL")")

            // Soft delete: delete one entry, re-import the folder — it must not come
            // back, and a fresh Library must still remember the tombstone.
            var softDeleteOK = true
            if let victim = library.entries.first {
                let checksum = victim.checksum
                library.delete(victim)
                importer.clearFinished()
                importer.enqueue(urls: [URL(fileURLWithPath: folder)])
                await waitForQueue(importer)
                let resurrected = library.entries.contains { $0.checksum == checksum }

                let recheck = Library()
                await recheck.load()
                let remembered = recheck.wasDeleted(checksum)
                softDeleteOK = !resurrected && library.entries.count == after - 1 && remembered
                print("soft delete: re-import after delete — \(softDeleteOK ? "PASS" : "FAIL")")
            }

            ollama.stop()
            if !keep {
                try? FileManager.default.removeItem(at: temp)
            }
            print("\n== done ==")
            exit(before == after && skipped > 0 && reopened.entries.count == after && after > 0 && softDeleteOK && tidyOK ? 0 : 1)
        }

        RunLoop.main.run()
    }

    @MainActor
    private static func waitForQueue(_ importer: Importer) async {
        // enqueue() is async (it walks the tree off-main), so first wait for the run
        // to actually start…
        for _ in 0..<50 {
            if importer.runState != .idle || !importer.items.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // …then for it to drain. Skipped items are removed, so "done" is simply:
        // idle with nothing left unfinished (an empty queue counts as done).
        // Long enough to outlast the slowest single step — a tidy-up chunk can sit on
        // its 180s HTTP timeout — so a stall is reported as a stall, not as whatever
        // the later assertions happen to see mid-drain.
        for _ in 0..<6000 {   // up to ~600s
            if importer.runState == .idle, importer.items.allSatisfy({ $0.state.isFinished }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
