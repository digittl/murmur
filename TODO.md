# TODO — Murmur v1.1.0: design polish + AI chat, then ship

Handover for another agent. **State:** branch `main`, **no PR** (this repo ships
directly on `main` + GitHub releases). **Nothing since v1.0.0 is committed — all
v1.1.0 work is uncommitted in the working tree only.** Last release/commit is
`v1.0.0` (`b53b126`). Remote is **already** `github.com/digittl/murmur` (only the
local folder is still named `batch-whisper`). Source **compiles clean**
(`swift build -c release --product Murmur` OK) and the bundle is freshly built;
the app is currently **running on the user's real iCloud library**.

Not prod-impacting (a local macOS app), but do a real end-to-end verify before
cutting a release — a lot changed.

## Goal & context — read first

Murmur is a native macOS **spoken-journal / diary** app (SwiftUI + WhisperKit
on-device transcription + a bundled **Ollama** LLM for AI titles/summaries; files
in iCloud Drive). This session added a large batch of design polish AND a new
**"Ask your journal" AI chat** feature on top of the earlier v1.1.0 work.

The user iterates rapidly on design by looking at the running app and screenshots.
**Verify visually after each change** (see "How to verify"). The user is holding
the v1.1.0 release until happy — **do not ship without an explicit "ship it".**

## Current state — what's running

Everything below is **code-complete and compiles**; most is visually verified.
The app was rebuilt via `zsh build.sh` and launched on the real library.

## Done this session (all uncommitted)

### Design polish (all verified in the running app)
- **Titlebar wordmark**: "Murmur" (waveform + rounded-bold text, accent-tinted)
  sits in the titlebar as a **leading accessory**, right of the traffic lights,
  nudged `-1px`. Implemented in `ContentView.swift` `WindowTint.installWordmark`
  via `NSTitlebarAccessoryViewController(layoutAttribute: .leading)` +
  `NSHostingController(rootView: Wordmark)`. (Earlier attempts — centered in
  content, and `.toolbar` `.navigation` placement — were WRONG; the accessory is
  the correct approach. Don't revert.)
- **Flat opaque sidebar** (kills the focus seam / "white vertical line"): the
  sidebar is painted the SAME solid colour as the window via
  `WindowTint.solid(accent)` on `leftColumn`, so there's no translucent
  `NSVisualEffectView` to dim/seam when the window loses focus. `WindowTint` sets
  `window.isOpaque=true` + `backgroundColor`. The old "force all effect views
  active" recursion was removed — flat fill is the fix. Focused/de-focused now
  look identical (only traffic-light dots + toolbar text dim, which macOS always
  does and can't be overridden).
- **Feed = `ScrollView` + `LazyVStack`** (was `List`). Switched specifically so
  the right-click menu uses SwiftUI `.contextMenu` **without** the List-row
  accent highlight ring (the user's macOS accent is **Pink**, `AppleAccentColor=6`,
  which was bleeding into the ring). Day headers, insets, selection highlight all
  reproduced manually. `recordingsList` + `entryRow` + `dayHeader` in `ContentView`.
- **Multi-select**: hover reveals a **square, top-aligned** checkbox in the left
  negative space (`entryRow`); click toggles, **shift-click extends a range**
  (`toggleSelection` over the flat `ordered` id list), selected rows get a subtle
  accent highlight, **Esc clears**. Right-click → `.contextMenu` with bulk
  **Regenerate N titles / Regenerate N summaries / Clear selection / Delete N
  recordings** (`contextMenuItems`), Delete behind a `.confirmationDialog`
  (`pendingDelete`/`showDeleteConfirm`/`confirmDelete`). Left-click row body still
  navigates (`path.append`). All verified with real CGEvent clicks.
- **Filter chip**: selecting a calendar day shows a dismissable pill on the right
  pane (`filterChip`); filtered view is a flat list (no redundant day header).
- **Day separations / top padding**: more negative space (header `.padding(.top,22)
  .bottom,16`, `.contentMargins(.top,14)`).
- **New app icon**: blue squircle + centered symmetric **voice waveform** (reads
  as speech, replaced old signal-bars). Generator: `assets/mkicon.py` (PIL, no
  numpy); master `assets/AppIcon-master.png`; `assets/AppIcon.icns` +
  `AppIcon.iconset` regenerated; old `assets/make-icon.py` removed. `build.sh`
  copies `assets/AppIcon.icns`.
- **Pronoun-free captions**: `OllamaService.defaultSummaryGuidance` /
  `defaultTitleGuidance` now forbid personal pronouns ("Reflected on…" not
  "He reflected…"). Verified.

### AI chat — "Ask your journal" (NEW, the current focus)
- **Toolbar button** (sparkles, top-right, `ContentView.toolbar`) toggles a
  **right-side chat panel** — a manual `HStack` column (`ChatView().frame(width:360)`
  with a trailing transition), NOT `.inspector` (inspector fought placement + added
  its own toggle — abandoned, don't reintroduce). State: `showChat`.
- **`ChatView.swift`** (new): message bubbles, empty-state with example prompts,
  thinking indicator, clear button, composer. Runs an **agentic tool loop** (up to
  8 rounds) — the model is NOT given the whole journal (won't scale); it calls
  **tools** to search/look up, and answers grounded in results.
- **Tools** (defined in `ChatView.tools`, executed in `runTool`): `search_journal`
  (returns ALL matches + a count, full transcripts, default limit 25),
  `entries_on_date`, `entries_in_range`, `recent_entries`. All query `library`.
- **`OllamaService.chatStep(messages:tools:)`** (new): one tool-aware round-trip to
  `/api/chat`, temp 0.2, decodes `message.tool_calls` into `ToolCall`, returns
  `ChatStep{content,toolCalls,rawMessage}`. Uses the **assistant** model.
- **Dedicated assistant model** (separate from caption model): `OllamaService`
  `assistantTag` (persisted `MurmurAssistantLLM`, default `qwen2.5:7b-instruct`)
  + `assistantCatalog` = Standard (7B, shared w/ Best caption) + **Deep
  (`qwen2.5:14b-instruct`, ~9 GB specialist)**. Settings ▸ Models ▸ **Assistant**
  section (`SettingsView` `ModelRow(isAssistant:true)`) downloads/selects it.
  `ChatView.ready` checks `assistantTag`.
- **Accuracy hardening** (system prompt in `ChatView.systemPrompt()`): must use
  tools, over-fetch, try synonyms (diazepam/Valium), **enumerate each mention with
  dates and sum actual quantities before totalling**, never guess.

## OPEN PROBLEM — chat still not good enough (do this next)

The user's live test: "how many valium did i take this week" → the bot gives a
wishy-washy answer, **asks permission to search further** ("Would you like me to
check previous days?"), and on "yes please" **repeats the same answer/question
over and over** (see the user's screenshots — 3 near-identical replies).

Two behaviours to kill: **(1) hedging / asking permission to search** instead of
just searching exhaustively in one turn, and **(2) repeating prior answers.**

**The user explicitly asked to model this on nuntiare's "Clod" chatbot.** Study
it and port the relevant patterns:
- Code: `~/Projects/nuntiare/src/agents/Clod.js` (2435 lines) — agentic loop with
  a per-turn iteration cap, a **retrieval pre-pass** (semantic search feeding
  results into the system prompt BEFORE the model's first call — see the
  `RETRIEVAL_PREPASS`/`toolSelection` area near the top), progressive tool
  disclosure, two-phase voicing, and **anti-repeat guards**.
- Web UI: `~/Projects/nuntiare/app/components/clod/` (`useClodChat.js`,
  `ChatBubble.jsx`, `WorkingPhrase.jsx`, `SuggestionPills.jsx`).
- **Skill: `clod-agent-tune`** — invoke it; it documents Clod's triage, two-phase
  voicing, judges, leak guards, and specifically **"Clod repeats himself"** fixes
  and which file owns which behaviour.

Concrete fixes to try for Murmur (adapt Clod's approach):
1. **Retrieval pre-pass**: before the first model call, run `search_journal` on
   the user's question (and obvious synonyms) and inject the results into the
   system prompt, so the model starts with evidence instead of asking to look.
2. **Prompt**: forbid asking the user for permission to search ("Never ask whether
   to search — just search. Give a single, complete, decisive answer."). Forbid
   restating a previous answer.
3. **Streaming** would also help perceived quality (Clod streams); Murmur's
   `chatStep` is non-streaming (`stream:false`). Optional.
4. Consider defaulting the assistant to **Deep (14B)** for reliability, or nudging
   the user to download it — 7B hedges/repeats more.

## Left to do — exact next steps

0. **Multi-select needs a discoverable "deselect all"** (user-reported): today the
   only ways to clear the selection are the **Esc** key and the right-click
   **"Clear selection"** item — there's no visible affordance. Add one, e.g. a
   small "N selected · Clear" bar/pill at the top of the feed (or in the toolbar)
   when `!selection.isEmpty`, tapping it clears `selection`. Lives in
   `ContentView` (`selection` state; feed is `recordingsList`).
1. **Fix the chat** per "OPEN PROBLEM" above (Clod patterns + retrieval pre-pass).
   Rebuild + verify with a counting question (seed a few clips mentioning a term,
   see "How to verify").
2. **Repo rename + free/open distribution "like Headlamp"** (user request): remote
   is already `digittl/murmur`. Headlamp = Apache-2.0, freely downloadable GitHub
   releases (+ Homebrew cask). Add a `LICENSE` (Apache-2.0 or MIT — confirm which),
   a proper README, and ship the `.app` as a downloadable zip on the release.
   Optional: a Homebrew cask / a landing page. The local folder is still
   `batch-whisper` — the user may want it renamed too (cosmetic).
3. **Update `README.md`** — still describes the old Foundation-Models / old-layout
   version. Rewrite: Ollama captions + two models, the new **Assistant model + Ask
   your journal chat**, queue controls, new layout, onboarding, custom prompts,
   multi-select, min macOS 14.
4. **Ship v1.1.0 on explicit go-ahead only.** Commit the batch to `main` (remove
   `TODO.md` from the commit), push, then
   `gh release create v1.1.0 --target main --title "Murmur 1.1.0"
   dist/Murmur.app.zip --notes "…"` (zip via
   `ditto -c -k --keepParent dist/Murmur.app dist/Murmur.app.zip`). Reply with the
   release URL + `https://github.com/digittl/murmur/actions`.

## Key files & paths

- `Sources/Murmur/App/ContentView.swift` — main window; `HStack{ NavigationSplitView … ; if showChat { ChatView } }`; `leftColumn` (calendar+queue, flat bg), `recordingsList`/`entryRow`/`dayHeader`/`entryLink`, `filterChip`, multi-select state + `toggleSelection`/`contextMenuItems`/`regenerate(ids:)`/`confirmDelete`, `toolbar` (Import/Settings/Ask), `WindowTint` (+ `Wordmark`, `installWordmark`).
- `Sources/Murmur/App/ChatView.swift` — the AI chat: agentic loop (`send`), `systemPrompt`, `tools`, `runTool`, `searchJournal`/`entriesOnDate`/`entriesInRange`/`recentEntries`, `ChatMessage`.
- `Sources/Murmur/Core/OllamaService.swift` — `chatStep` (tool round-trip), `ToolCall`/`ChatStep`, `assistantTag`/`assistantCatalog`, caption `summarize`/`regenerate*`, default guidance (pronoun-free).
- `Sources/Murmur/App/SettingsView.swift` — Appearance / Models (Transcription + Captions + **Assistant**) / Prompts. `ModelRow(isAssistant:)`.
- `assets/mkicon.py` — icon generator; `assets/AppIcon.icns` — bundled icon.
- `build.sh` — SwiftPM build + `.app` assembly + ollama bundling + ad-hoc sign.

## Gotchas & dead ends

- **`.inspector` for the chat panel = dead end** (auto-toggle + placement fights).
  Manual `HStack` right column is what works.
- **`.toolbar` `.navigation` placement for the wordmark = wrong spot** (lands at
  the sidebar/detail boundary). Titlebar **leading accessory** is correct.
- **List → LazyVStack was deliberate** to drop the pink context-menu ring; don't
  revert to `List`. The pink ring is the user's **system** accent (Pink), not
  ours — unfixable per-app for that highlight; avoided by not using List rows.
- **Overlay `NSView` right-click hitTest trick = dead end** (SwiftUI event routing
  didn't deliver the menu). SwiftUI `.contextMenu` on LazyVStack rows is what works.
- Chat uses `assistantTag`, captions use `activeTag` — keep them separate.
- Ollama tool-calling needs a tool-capable model; qwen2.5 (7B/14B) works. The
  `llama3.2:3b` Fast model was deleted earlier in testing (re-downloadable).
- Swift 6: `OllamaService` is `@MainActor`; the chat loop runs on MainActor so
  `[String:Any]` message dicts don't cross actors (fine). `RowContextMenu`
  Coordinator (now removed) was `@MainActor`.

## How to verify / ship

- Build: `zsh build.sh` → `dist/Murmur.app`. Launch: `open dist/Murmur.app`.
- **Screenshot recipe** (used all session): hide other apps
  `osascript -e 'tell application "System Events" to set visible of (every process whose visible is true and background only is false and name is not "Murmur") to false'`;
  `osascript -e 'tell application "Murmur" to activate'`; get bounds
  `osascript -e 'tell application "System Events" to tell process "Murmur" to get {position, size} of window 1'`;
  `screencapture -x -R"x,y,w,h" /path.png` and Read it. **Real** left/right clicks
  (System Events synthetic clicks miss small SwiftUI targets): post CGEvents via
  Python `ctypes` on `ApplicationServices` — mouse move (type 5), left down/up
  (1/2), right down/up (3/4 button 1); `CGEventSetFlags(e, 0x20000)` for shift.
  AXPress a control: `tell process "Murmur" to click (button N of toolbar 1 of window 1)`.
- **Screenshots must NOT show the user's real diary** (personal medical content).
  Seed a THROWAWAY library: `defaults write co.digittl.murmur MurmurStorageRoot
  "$SCRATCH/seed"; defaults write co.digittl.murmur MurmurLLM "qwen2.5:7b-instruct";
  MURMUR_SELFTEST_ROOT="$SCRATCH/seed" "dist/Murmur.app/Contents/MacOS/Murmur"
  --selftest <folder-of-YYYY-MM-DD-HH-MM-SS.aiff-clips>` then launch.
  **ALWAYS `defaults delete co.digittl.murmur MurmurStorageRoot` and `MurmurLLM`
  and relaunch on the real library when done** — leaving the override set makes the
  user's real entries look "gone" (this happened; the files were safe, just wrong
  root). Make clips with `say -o <date>.aiff "text"`. A big seed lives at
  `$SCRATCH/bigseed` (14 entries across ~6 days) — regenerate if gone.
  (`$SCRATCH` = the session scratchpad dir.)
- Headless pipeline test: `"$(swift build -c release --product Murmur --show-bin-path)/Murmur" --selftest <folder>` → expect dedupe/persistence PASS.
- **Ship** (only on go-ahead): see step 4 above. Remove `TODO.md` from the commit.

## Open questions / blockers

- **Release blocked on the user's explicit "ship it".** They're still refining.
- **License choice** for the Headlamp-style free distribution — Apache-2.0 vs MIT?
  Confirm with the user (Headlamp itself is Apache-2.0).
- Whether to make **Deep (14B)** the default assistant model (better accuracy) vs
  keep Standard (7B, no extra download) as default and let the user opt into Deep.
