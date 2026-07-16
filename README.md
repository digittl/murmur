# Murmur

**A spoken journal, transcribed on-device.**

Murmur turns a folder of voice recordings into a diary. Point it at your
recordings and it transcribes each one locally with Whisper, gives it an AI
title and summary using Apple's on-device model, and lays the whole thing out as
a calendar of days you can browse, play back, and edit — every word aligned to
the audio. Nothing leaves your Mac; everything syncs through iCloud Drive.

## What it does

- **Import a folder** of recordings (or drag them onto the window). Files are
  processed oldest-first so the diary fills in chronological order.
- **Local transcription** with [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Core ML). Defaults to **large-v3** for best accuracy; switch models (distil,
  small, base, tiny) from the toolbar. Models download once and stay cached.
- **AI title + summary** for every entry via Apple's on-device Foundation Models
  (Apple Intelligence) — fully local, no key, no network. Falls back to a
  heuristic caption when Apple Intelligence is off.
- **Diary layout**: a month calendar (days with entries are dotted), a
  reverse-chronological feed grouped by day with Today / Yesterday headings, and
  a reading pane per entry.
- **Playback + timestamps**: play the recording, scrub, and tap any line's
  timestamp to jump there. The current line highlights as it plays.
- **Editable**: fix the title, rewrite the summary (or regenerate it), and
  correct any word inline — edits autosave.
- **Skips duplicates**: dedupe is by audio checksum, so re-importing the same
  folder never doubles anything up.

## Where your files live

Murmur stores everything under your **iCloud Drive** so it syncs across your
Macs automatically — no paid developer profile or entitlement required:

```
~/Library/Mobile Documents/com~apple~CloudDocs/Murmur/
  audio/     copied recordings
  entries/   one JSON per entry (transcript, title, summary, timings)
```

If iCloud Drive isn't present it falls back to `~/Documents/Murmur/`. One entry
per file means iCloud never has to merge a shared index.

## Requirements

- **macOS 26** (Tahoe) or later — for the Foundation Models framework.
- **Apple Silicon** recommended (Whisper runs on the Neural Engine / GPU).
- **Apple Intelligence** turned on (System Settings ▸ Apple Intelligence & Siri)
  for AI titles and summaries. Without it, Murmur still transcribes and captions
  using a built-in fallback.

## Build

Needs Xcode 26 (Swift 6.2, macOS 26 SDK):

```sh
zsh build.sh
```

The app appears at `dist/Murmur.app`. Drag it to `/Applications`. First launch
downloads the chosen Whisper model.

## An iPhone version?

The whole core — model, storage, transcription (WhisperKit), and summarization
(Foundation Models) — is UI-free Swift that also compiles for **iOS 26**, and the
SwiftUI views are largely shared. The only real blocker is distribution: iOS apps
can't be sideloaded, so an iPhone build needs the Apple Developer Program for
TestFlight / the App Store, plus a proper iCloud-container entitlement (the
generic iCloud-Drive-folder trick the Mac app uses is macOS-only). That's a
follow-up target, not a rewrite.

## Layout

- [`Sources/Murmur/Model/`](Sources/Murmur/Model/) — `Entry`, `Storage` (iCloud
  path resolution), `Library` (load/save/dedupe). Platform-agnostic.
- [`Sources/Murmur/Core/`](Sources/Murmur/Core/) — `Transcriber` (WhisperKit),
  `Summarizer` (Foundation Models), `Importer` (the pipeline), `Player`.
- [`Sources/Murmur/App/`](Sources/Murmur/App/) — the SwiftUI app: calendar,
  diary feed, and the entry detail/editor.
- [`assets/make-icon.py`](assets/make-icon.py) — regenerates `AppIcon.icns`.
- [`build.sh`](build.sh) — compiles via SwiftPM and assembles `dist/Murmur.app`.

## Verifying

A headless smoke test exercises the whole pipeline (dedupe → transcribe →
summarize → persist) with the fast `tiny` model against a throwaway library:

```sh
swift build -c release --product Murmur
"$(swift build -c release --product Murmur --show-bin-path)/Murmur" --selftest /path/to/recordings
```
