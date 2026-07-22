# Planned changes

Captured from a design pass — not yet implemented. Nothing here is live in the
built app yet.

> **Layout direction (ties #1 and #3 together):** the recordings list moves to
> the **right** pane (#3). That frees the **entire left column** to be: the
> **calendar pinned at the top**, and the **queue filling everything below it**.
> The calendar stays on the left (this answers the #3 open question). Because the
> queue now owns the whole left area, it no longer needs to be crammed into a
> small box — see #1.

## 1. Roomier full-height queue on the left (was: expandable popup)

**Now:** the import queue renders inline in the sidebar
([`QueueView.swift`](../Sources/Murmur/App/QueueView.swift)) with a fixed
`maxHeight: 150` scroll area — long queues are cramped.

**Want:** with the recordings list gone from the left (#3), the queue **takes up
the whole left column under the calendar**. Drop the 150pt cap and let it fill
the available height, with **bigger font size and more generous spacing per
item** so each queued file is easy to read and act on.

- Remove `maxHeight: 150`; the queue scroll area expands to fill the column.
- Larger per-row type and padding (rows currently use `.caption`; bump to
  `.body`/`.callout` with more vertical padding and clearer status glyphs).
- Keep the header (progress `finished/total` + pause / resume / cancel-all /
  clear-finished).
- The expandable-popup idea is **no longer needed** now that the queue has room —
  but keep it in mind as a fallback if the left column ever gets tight again.
- Per-file cancel (#2) lives on each of these roomier rows.

**Always droppable + empty drop zone.** The whole queue area is **always** a
drag-and-drop target — drop recordings onto it any time to enqueue them, whether
the queue is empty or already running. When the queue is **empty**, that area
shows a friendly dashed **drop zone** ("Drop recordings to import"); once items
are queued the live list shows, and dropping more onto it keeps adding. Reuse the
existing `importer.enqueue` + drop handling. This is the primary import entry
point alongside the toolbar Import button.

## 2. Per-file cancel in the queue

**Now:** only whole-queue controls exist — `pause()`, `resume()`, `cancelAll()`
in [`Importer.swift`](../Sources/Murmur/Core/Importer.swift). You can't drop a
single file.

**Want:** each queue row (in both the inline view and the expanded popup) gets a
**cancel/remove button** for that individual item.

Implementation notes:
- Add `func cancel(id: Item.ID)` to `Importer`:
  - **Pending item:** just mark it `.cancelled` (or remove it) so the worker
    skips it. No transcription started, so nothing to abort.
  - **The in-flight item** (`.transcribing` / `.summarizing`): call
    `transcriber.cancelCurrent()` (the existing `CancelToken` path already aborts
    WhisperKit mid-file), mark it `.cancelled`, and let the worker move on to the
    next pending item. Note the current cancel token is per-transcriber, not
    per-item — cancelling the active item and cancelling-all share the same
    mechanism; that's fine since only one item is ever in-flight.
  - Clean up any partial audio copy (mirror the `copiedAudio` removal already in
    `process(index:)`).
- Row UI: a small `xmark` button per `QueueRow`, hidden once the item is finished.

## 3. Recordings list moves to the right; detail replaces it with a back button

**Now:** `ContentView` is a two-column `NavigationSplitView` — calendar + queue +
**recordings list on the LEFT sidebar**, entry detail on the right. The user
finds the left-hand list placement bad.

**Want:** a **single main pane on the right** that has two states:

1. **List state (default):** the recordings listed on the right-hand side
   (grouped by day, as now).
2. **Detail state:** clicking a recording **replaces the right pane** with that
   recording's details (the current `EntryDetailView`), with a **Back button**
   to return to the list.

So the interaction becomes list → drill-in → back, instead of
persistent-master + detail.

**Left column stays** = calendar pinned at top + queue filling the rest (#1).

Implementation notes:
- Keep the two-column shell, but the **right column** becomes a
  `NavigationStack`: root = the day-grouped recordings list; tapping an entry
  pushes `EntryDetailView` with a system back button.
- The **left column** keeps the calendar (top) and the roomy full-height queue
  (below). Selecting a day still filters the right-hand list.
- Preserve current behaviours: live-updating list as entries import, day
  headings (Today / Yesterday / date), accent theming, and the entry
  detail's editing/playback.

### Open question for #3
- On import while viewing a detail, do we stay on the detail or pop back to the
  list? (Probably stay put; the list updates underneath.)

## 4. Right-click to regenerate title / summary per recording

**Now:** regeneration only exists inside `EntryDetailView` via the "Regenerate"
button, and it rewrites **both** title and summary together
(`ollama.summarize(...)` → sets `title` + `summary`).

**Want:** a **context menu (right-click)** on every recording — in the list rows
(and it can stay in the detail view too) — with **separate** actions:

- **Regenerate title**
- **Regenerate summary**

So each can be redone independently without touching the other.

Implementation notes:
- Add `.contextMenu { … }` to the recording row (`EntryRow`) and/or a menu button
  in `EntryDetailView`.
- Split captioning in [`OllamaService.swift`](../Sources/Murmur/Core/OllamaService.swift):
  - `func regenerateTitle(from transcript:) async -> String`
  - `func regenerateSummary(from transcript:) async -> String`
  - Each prompts the model for just that field (or reuse the combined
    `summarize` and pick one field — but targeted prompts give better results and
    respect the custom prompts in #5).
- The action loads the entry, regenerates the one field, and `library.upsert`s it
  so the change persists + the UI updates live. Mirror the existing
  `regenerate()` flow (progress state, fallback when the model isn't ready).
- Works whether or not the entry is currently open in the detail pane.

## 5. Custom title / summary prompts in Settings (toggleable)

**Now:** the captioning prompt is hard-coded in `OllamaService.system` (the
instruction that asks for `{title, summary}`), with no user control.

**Want:** in **Settings**, add controls to **override the title prompt and the
summary prompt independently**:

- A **toggle** for a custom **title** prompt. When **on**, reveal a **text
  field** to enter the prompt. When off, use the built-in default.
- A **toggle** for a custom **summary** prompt. Same pattern.

When a custom prompt is on, it's used everywhere that field is generated — the
import pipeline **and** the right-click regenerate actions from #4.

Implementation notes:
- Store in [`AppSettings.swift`](../Sources/Murmur/Model/AppSettings.swift)
  (UserDefaults-backed):
  - `customTitleEnabled: Bool`, `customTitlePrompt: String`
  - `customSummaryEnabled: Bool`, `customSummaryPrompt: String`
- `OllamaService` needs access to these when building prompts. Either pass the
  effective prompts into `summarize`/`regenerateTitle`/`regenerateSummary`, or
  give `OllamaService` a reference to `AppSettings`. Prefer passing them in so the
  service stays free of UI/settings coupling.
- Settings UI: a new section (Appearance tab, or a dedicated "Captions" area of
  the Models tab, or its own tab). Each row: `Toggle` + a `TextEditor`/`TextField`
  that's enabled/visible only when the toggle is on. Include a hint about what the
  transcript context will be.
- Guard against empty custom prompts (fall back to default if the field is blank
  while the toggle is on).
- Since title/summary can now be generated separately (#4) and with separate
  prompts, the combined-JSON `summarize` may split into two calls, or stay
  combined for the import path and add single-field calls for regenerate. Decide
  during implementation (combined is one model call = faster on import).
