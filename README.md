# Whisper Chrono Import

A tiny macOS app that imports voice recordings into **Whisper Transcription.app** in
**chronological order**.

Whisper Transcription sorts its list by the order files were *added to it*, not by any
date on the file — so dragging a whole batch in at once lands them jumbled. This app
feeds them in one at a time, oldest first, so the list comes out in order.

## How it works

- Drag a **folder** of recordings (or the recordings themselves) onto the app icon.
  Or double-click it to pick a folder.
- It gathers every audio file, sorts them by the `YYYY-MM-DD-HH-MM-SS` timestamp in the
  filename, then opens each into Whisper Transcription with a short gap between them.
- When it finishes you get a notification with the count.

Supported extensions: `m4a mp3 wav aac caf aiff flac ogg` (case-insensitive).

> Sorting is by the timestamp **in the filename** — recordings must be named like
> `2026-07-16-22-08-10.m4a`. Files without a recognisable timestamp still import, they
> just sort by name.

## Build it yourself

Needs nothing but macOS (`osacompile` ships with the OS):

```sh
zsh build.sh
```

The app appears at `dist/Whisper Chrono Import.app`. Drag it to `/Applications`.

## Tuning

If the list still comes out jumbled, Whisper was ingesting faster than it registered
order — increase the gap. Edit `gapSeconds` at the top of [`src/main.applescript`](src/main.applescript)
(seconds between files) and rebuild.

## Layout

- [`src/main.applescript`](src/main.applescript) — the droplet: handles drops / the folder picker, calls the worker.
- [`src/import.sh`](src/import.sh) — expands folders, sorts chronologically, opens each file.
- [`build.sh`](build.sh) — compiles `src/` into `dist/Whisper Chrono Import.app`.
