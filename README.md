# BatchWhisper

A tiny macOS app that imports voice recordings into **Whisper Transcription.app**
(MacWhisper) in **chronological order** — reliably, not by guessing at timing.

MacWhisper sorts its list by the order files were *added to it*, and it ingests
drops asynchronously, so dragging a batch in at once lands them jumbled.
BatchWhisper feeds them one at a time, oldest first, and **waits for each file's
transcript to actually appear before sending the next** — so MacWhisper only ever
holds one job and the order can't scramble.

## How it works

- Drag a **folder** of recordings (or the recordings themselves) onto the app icon.
  Or double-click it to pick a folder.
- It gathers every audio file and sorts them by the `YYYY-MM-DD-HH-MM-SS` timestamp
  in the filename.
- For each file: open it in MacWhisper → wait until its transcript lands in the
  export folder → send the next. When it finishes you get a notification with the count.

Supported extensions: `m4a mp3 wav aac caf aiff flac ogg` (case-insensitive).

## One-time MacWhisper setup

BatchWhisper detects "this file is done" by watching MacWhisper's auto-export folder,
so MacWhisper must be set to auto-export:

1. **Turn on auto-export** of transcripts and point it at `~/.whisper-extracts`
   (matching `exportSubpath` in [`src/main.applescript`](src/main.applescript)).
2. **Turn off any watched folders** — a watched folder auto-transcribes files in
   async order and double-processes them, defeating the point. Feed files through
   BatchWhisper instead.
3. Work from a **copy of the recordings** (e.g. copied off the USB) — not a folder
   MacWhisper is watching.

## Build it yourself

Needs nothing but macOS (`osacompile` ships with the OS):

```sh
zsh build.sh
```

The app appears at `dist/BatchWhisper.app`. Drag it to `/Applications`.

## Tuning

Two knobs at the top of [`src/main.applescript`](src/main.applescript):

- `maxWaitSeconds` — how long to wait for a single file's transcript before giving
  up and stopping (default 600s). If a file legitimately takes longer than this to
  transcribe, raise it.
- `exportSubpath` — the folder under your home directory that MacWhisper auto-exports
  into (default `.whisper-extracts`). Change it if you point MacWhisper elsewhere.

Rebuild with `zsh build.sh` after changing either.

## Layout

- [`src/main.applescript`](src/main.applescript) — the droplet: handles drops / the folder picker, calls the worker.
- [`src/import.sh`](src/import.sh) — expands folders, sorts chronologically, feeds each file and waits for its transcript.
- [`build.sh`](build.sh) — compiles `src/` into `dist/BatchWhisper.app` and applies the icon.
- [`assets/make-icon.py`](assets/make-icon.py) — regenerates `assets/AppIcon.icns` (run it if you tweak the icon).
