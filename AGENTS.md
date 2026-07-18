# Murmur — agent guide

Native macOS (SwiftUI/AppKit) spoken-journal app. Voice notes are transcribed on-device with WhisperKit, captioned by a bundled local Ollama model, and laid out as an editable, playable diary. Everything is local; the library syncs via iCloud Drive. Apache-2.0, shipped as an unsigned `.app` from GitHub Releases.

## Commands

```sh
# Build the runnable bundle (SwiftPM compile → bundle the Ollama binary → ad-hoc
# sign). Output: dist/Murmur.app. Needs Xcode 16+ / Swift 6.2, macOS 14+.
zsh build.sh

# Compile-only check while iterating:
swift build -c release --product Murmur

# Headless end-to-end test — the ONLY automated test. Runs the whole pipeline
# (queue → dedupe → transcribe → caption → persist) on a throwaway library with the
# `tiny` model. Needs a folder of audio and (ideally) Ollama running. Exits non-zero
# on failure. MURMUR_SELFTEST_ROOT=<dir> keeps the seeded library instead of a temp.
BIN="$(swift build -c release --product Murmur --show-bin-path)/Murmur"
"$BIN" --selftest /path/to/recordings
```

No unit-test target and no linter — the self-test is the regression gate. Generate test input with `say -o file.aiff "..."`; include a duplicate file to exercise dedupe.

## Release / ship

No CI. A release is built locally and its zip attached to a GitHub Release; the in-app `Updater` polls `digittl/murmur` releases, compares `CFBundleShortVersionString`, and installs the newest `.app.zip` asset. There is no `CHANGELOG.md` — release notes live only on the GitHub release.

1. Bump both `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`.
2. `zsh build.sh`
3. `ditto -c -k --keepParent dist/Murmur.app Murmur.app.zip`
4. Commit source (not the zip — it's untracked), push to `main`.
5. `gh release create vX.Y.Z --target main --title "Murmur X.Y.Z" --notes "..." Murmur.app.zip`

Feature → minor bump, fixes → patch. The release must carry the `Murmur.app.zip` asset or auto-update breaks.

## Layout

Three layers under `Sources/Murmur/`:

- **`Model/`** — platform-agnostic (compiles on iOS): `Entry`, `Library` (list + disk I/O + dedupe), `Storage` (library-root resolution), `AppSettings`.
- **`Core/`** — engines: `Transcriber`, `OllamaService`, `Importer`, `Recorder`, `Player`, `Updater`.
- **`App/`** — SwiftUI: `ContentView` (calendar + diary feed + detail nav + chat drawer), `EntryDetailView`, `OnboardingView`, `SettingsView`, `QueueView`, `ChatView`/`ChatStore`, `SelfTest`. `MurmurApp.swift` wires the DI graph and owns `RootView`.

`Main.main()` in `MurmurApp.swift` is the entry point; it diverts to `SelfTest` on `--selftest`, else runs the app.

## Architecture

### Storage — one JSON per entry

The library lives under iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/Murmur/`, falling back to `~/Documents/Murmur/`) as one JSON file per entry in `entries/`, with copied audio in `audio/`. There is deliberately no shared index file, so iCloud never merges concurrent edits. Dedupe is by SHA-256 of the audio bytes (`Entry.checksum`). `Entry.text` (a user edit) overrides `segments` for display via `Entry.prose`.

### Concurrency — read before touching `Importer`

Every service (`Importer`, `Transcriber`, `OllamaService`, `Library`) is a `@MainActor` `ObservableObject`. Parallelism comes from off-actor async work (`WhisperEngine.run` is `nonisolated`); the main actor stays responsive between `await`s. `Importer` runs the import queue on a worker pool with load-bearing invariants — break one and you get a WhisperKit data-race crash or item corruption:

- **One engine per worker.** WhisperKit can't transcribe two files on one loaded model. `Transcriber` holds `workerCount` (2) `WhisperEngine`s; `prepare()` loads the model into each. This multiplies model RAM — a deliberate speed/RAM trade.
- **Single-drain invariant.** Only one `worker` (drain) `Task` is ever alive. Clear `worker` only inside `drain()`'s `defer` (after its worker loops exit); `ensureRunning()` starts a drain only when `worker == nil`; `cancelAll()` must not null `worker`. This stops a re-import from spawning a second drain that shares the engines.
- **Mutate items by id, never by index across an `await`.** `items` is mutated by `clearFinished()`/appends at any time — use `update(id) { … }`; workers capture an immutable `Item` snapshot after claiming.
- **Claim synchronously.** A worker finds the first `.pending` item and marks it `.transcribing` with no `await` between, so two workers can't grab the same item.
- **Per-item cancellation.** Each in-flight item gets a fresh single-use `CancelToken` in `tokens`. `inFlightChecksums` reserves a checksum synchronously so parallel workers dedupe identical files within one batch.

`reTranscribe(_:)` re-runs an existing entry through the same queue (an `Item` with `reTranscribeEntryID` set), updating it in place and re-deriving title/summary.

### Ollama integration

`OllamaService` attaches to a running Ollama or launches the bundled binary, and never kills a server it didn't spawn. It does captions (`summarize`) and the "Ask your journal" chat — a tool loop: `chatStep(...)` returns the model's turn plus any `toolCalls`; the caller runs the tools (search/read transcripts) and loops until there are none, streaming content live. The installed model-tag set is cached to `UserDefaults` (`MurmurInstalledLLMs`) so onboarding distinguishes a fresh machine from a slow server probe.

### Onboarding gate

`RootView` shows `OnboardingView` based on whether the selected transcription/caption/assistant models are downloaded — not on live Ollama server readiness. A slow or failed probe must not resurrect the welcome screen on a set-up machine; captioning/chat paths guard on live `serverState` separately.

## Conventions

- Keep service logic in methods on the service; push heavy work off the main actor rather than blocking it.
- When extending the import pipeline, preserve the concurrency invariants above and re-run `--selftest` with a duplicate file to confirm dedupe and parallel processing still hold.
