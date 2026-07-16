# BatchWhisper

A small native macOS app that imports voice recordings into **Whisper
Transcription.app** (MacWhisper) in **chronological order** — reliably, not by
guessing at timing.

MacWhisper sorts its list by the order files were *added to it*, and it ingests
drops asynchronously, so dragging a batch in at once lands them jumbled.
BatchWhisper feeds them one at a time, oldest first, and **waits for each file's
transcript to actually appear before sending the next** — so MacWhisper only ever
holds one job and the order can't scramble.

## Using it

- Drop a **folder** of recordings (or the recordings themselves) onto the window —
  or click **Choose Folder…**. You can also drag them onto the app/Dock icon.
- Confirm the **export folder** matches MacWhisper's auto-export folder
  (default `~/.whisper-extracts`).
- Press **Start**. The progress bar and log track each file as its transcript lands.

Files are sorted **ascending by filename** (`YYYY-MM-DD-HH-MM-SS`), which is
chronological and immune to created-date being reset when copying off a USB.
Supported: `m4a mp3 wav aac caf aiff flac ogg`.

## One-time MacWhisper setup

BatchWhisper detects "this file is done" by watching MacWhisper's auto-export folder:

1. **Turn on auto-export** of transcripts, pointed at `~/.whisper-extracts`
   (or set a different folder in the app's Export folder field).
2. **Turn off any watched folders** — a watched folder auto-transcribes files in
   async order and double-processes them. Feed files through BatchWhisper instead.
3. Work from a **copy of the recordings** — not a folder MacWhisper is watching.

## Build

Needs the Xcode command line tools (`swiftc`):

```sh
zsh build.sh
```

The app appears at `dist/BatchWhisper.app`. Drag it to `/Applications`.

## Tuning

Timing constants live at the top of the batch engine in
[`src/main.swift`](src/main.swift): `maxWaitPerFile` (per-file timeout, default
600s), `pollInterval` (0.1s), `stabilityGap`, and `settle`.

## Layout

- [`src/main.swift`](src/main.swift) — the whole app: UI, drop handling, and the feed-and-wait engine.
- [`src/Info.plist`](src/Info.plist) — bundle metadata, icon, and accepted document types.
- [`assets/make-icon.py`](assets/make-icon.py) — regenerates `assets/AppIcon.icns`.
- [`build.sh`](build.sh) — compiles `src/main.swift` and assembles `dist/BatchWhisper.app`.
