import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// The main window. Left column: the month calendar and the import queue. Right
/// column: a navigation stack — the recordings list drilling into each entry's
/// detail (with a back button).
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var importer: Importer
    @EnvironmentObject private var ollama: OllamaService
    @EnvironmentObject private var updater: Updater

    @State private var visibleMonth = Date()
    @State private var filterDay: Date?
    @State private var path: [UUID] = []
    @State private var isTargetedForDrop = false

    // The day whose section is currently scrolled up under the top of the feed —
    // shown as a slim pinned bar. nil at the very top (the inline header is visible).
    @State private var stickyDay: Date?
    // Height of the selection/filter bar, so the pinned day bar can sit just below
    // it (rather than being hidden) when a selection or day filter is active.
    @State private var topInsetHeight: CGFloat = 0

    // Multi-select in the feed: hover reveals a checkbox; shift-click extends a
    // range; right-clicking a selected row acts on the whole selection.
    @State private var selection: Set<UUID> = []
    @State private var hoveredID: UUID?
    @State private var anchorID: UUID?
    @State private var pendingDelete: [UUID] = []
    @State private var showDeleteConfirm = false
    @State private var showChat = false

    // Ask-your-journal chat (history persists via ChatStore).
    @StateObject private var chatStore = ChatStore()
    @AppStorage("MurmurChatWidth") private var chatWidth: Double = 360
    @State private var dragStartWidth: Double?

    // In-app voice recording.
    @StateObject private var recorder = Recorder()

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView {
                leftColumn
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 430)
            } detail: {
                NavigationStack(path: $path) {
                    recordingsList
                        .navigationDestination(for: UUID.self) { id in
                            if let entry = library.entries.first(where: { $0.id == id }) {
                                EntryDetailView(entry: entry)
                            } else {
                                ContentUnavailableView("Entry not found", systemImage: "questionmark")
                            }
                        }
                }
            }
            .toolbar { toolbar }

            if showChat {
                chatResizeHandle
                ChatView(store: chatStore)
                    .frame(width: chatWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChat)
        .overlay(alignment: .top) {
            if updater.available != nil {
                updateBanner
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.available)
        .background(WindowTint(accent: settings.accent))
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargetedForDrop {
                dropHint
            }
        }
    }

    // A draggable seam between the detail pane and the chat drawer; drag left to
    // widen the chat, right to narrow it. The width is remembered across launches.
    private var chatResizeHandle: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = chatWidth }
                                let start = dragStartWidth ?? chatWidth
                                chatWidth = min(620, max(300, start - value.translation.width))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            )
    }

    // A slim banner offering the newer release. Sits over the top of the window;
    // "Update now" downloads and swaps the bundle, then relaunches.
    @ViewBuilder
    private var updateBanner: some View {
        if let release = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.white)
                Text(installingUpdate
                     ? "Updating to \(release.version)…"
                     : "Murmur \(release.version) is available.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if installingUpdate {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Button("Update now") {
                        Task { await updater.downloadAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(settings.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(settings.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var installingUpdate: Bool {
        updater.state == .downloading || updater.state == .installing
    }

    // MARK: - Left column (calendar + queue)

    private var leftColumn: some View {
        VStack(spacing: 0) {
            CalendarView(
                month: $visibleMonth,
                populatedDays: library.populatedDays,
                selectedDay: filterDay,
                onSelectDay: { day in
                    filterDay = (filterDay == day) ? nil : day
                }
            )
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(settings.accent.opacity(0.14))
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)

            QueueView(recorder: recorder, isTargetedForDrop: isTargetedForDrop)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowTint.solid(settings.accent).ignoresSafeArea())
    }

    // MARK: - Right column (recordings list)

    /// The entries currently on screen, in display order — respecting the day
    /// filter. Drives shift-range selection and Select all.
    private var visibleDays: [(day: Date, entries: [Entry])] {
        filterDay == nil
            ? library.days
            : library.days.filter { Calendar.current.isDate($0.day, inSameDayAs: filterDay!) }
    }

    private var visibleIDs: [UUID] { visibleDays.flatMap(\.entries).map(\.id) }

    private var recordingsList: some View {
        let days = visibleDays
        let ordered = visibleIDs   // display order, for shift-range

        return Group {
            if library.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.day) { group in
                            // The filter chip already names the day when filtering
                            // to one, so the per-day heading would be redundant.
                            if filterDay == nil {
                                dayHeader(group.day)
                            }
                            ForEach(group.entries) { entry in
                                entryRow(entry, ordered: ordered)
                                    .background(dayScanReporter(group.day))
                            }
                        }
                    }
                    .padding(.top, filterDay == nil ? 14 : 6)
                    .padding(.bottom, 24)
                    .padding(.leading, 12)
                }
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: Self.feedSpace)
                .onPreferenceChange(DayScanKey.self) { items in
                    // Current day = the day of the top-most row that's reached the bar
                    // band; nil at the very top, where the inline header shows instead.
                    // Tracking rows (always rendered near the top) rather than headers
                    // (recycled once scrolled far off) keeps the bar from dropping out
                    // mid-day.
                    let passed = items.filter { $0.minY <= 44 }
                    stickyDay = passed.max { $0.minY < $1.minY }?.day
                }
                // An overlay (not a safeAreaInset) so showing/hiding it never shifts
                // the content — which would feed back into the offsets and flicker.
                // Offset below the selection/filter bar (topInsetHeight) so it sits
                // beneath it rather than colliding, and still shows during selection.
                .overlay(alignment: .top) {
                    if filterDay == nil, let day = stickyDay {
                        stickyDayBar(day)
                            .padding(.top, topInsetHeight)
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !selection.isEmpty || filterDay != nil {
                VStack(spacing: 0) {
                    if !selection.isEmpty {
                        selectionBar
                    }
                    if let day = filterDay {
                        filterChip(day)
                    }
                }
                .background(.bar)   // opaque header layer so rows scroll cleanly under it
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.6)
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TopInsetHeightKey.self, value: geo.size.height)
                })
            }
        }
        .onPreferenceChange(TopInsetHeightKey.self) { topInsetHeight = $0 }
        .onExitCommand { selection.removeAll() }   // Esc clears the selection
        .confirmationDialog(
            pendingDelete.count > 1 ? "Delete \(pendingDelete.count) recordings?" : "Delete this recording?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This permanently removes the audio and transcript. This can't be undone.")
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: 8) {
            Circle().fill(settings.accent).frame(width: 6, height: 6)
            Text(Format.dayHeading(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.accent)
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
        .padding(.leading, 28)
    }

    static let feedSpace = "recordingsFeed"

    /// Reports an entry row's day and vertical position within the feed so
    /// `stickyDay` can track which day is at the top. Rows (unlike day headers)
    /// stay rendered near the top edge, so the current day never drops out mid-day.
    private func dayScanReporter(_ day: Date) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: DayScanKey.self,
                value: [DayScanItem(day: day, minY: geo.frame(in: .named(Self.feedSpace)).minY)]
            )
        }
    }

    /// The slim pinned bar showing the current day. Matches the inline day header
    /// but on an opaque bar so rows scroll cleanly beneath it.
    private func stickyDayBar(_ day: Date) -> some View {
        HStack(spacing: 8) {
            Circle().fill(settings.accent).frame(width: 6, height: 6)
            Text(Format.dayHeading(day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.accent)
            Spacer(minLength: 0)
        }
        // 40 = the LazyVStack's leading 12 + the inline day header's leading 28, so
        // the pinned dot/label line up horizontally with the inline day headings.
        .padding(.leading, 40)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func entryRow(_ entry: Entry, ordered: [UUID]) -> some View {
        let isSelected = selection.contains(entry.id)
        let showBox = hoveredID == entry.id || !selection.isEmpty
        return HStack(alignment: .top, spacing: 10) {
            Button {
                toggleSelection(entry.id, ordered: ordered)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? AnyShapeStyle(settings.accent) : AnyShapeStyle(.secondary.opacity(0.45)))
                    .frame(width: 20, height: 32)   // 32 == waveform badge height, so it tops out with the badge
                    .padding(.top, 6)               // match EntryRow's own vertical padding
                    .opacity(showBox ? 1 : 0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select recording")

            Button {
                path.append(entry.id)
            } label: {
                EntryRow(entry: entry)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.leading, 18)
        .padding(.trailing, 28)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? settings.accent.opacity(0.10) : Color.clear)
                .padding(.horizontal, 8)
        )
        .onHover { inside in
            if inside { hoveredID = entry.id }
            else if hoveredID == entry.id { hoveredID = nil }
        }
        .contextMenu { contextMenuItems(for: entry.id) }
    }

    // MARK: - Selection & bulk actions

    private func toggleSelection(_ id: UUID, ordered: [UUID]) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = anchorID,
           let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) {
            for i in stride(from: min(a, b), through: max(a, b), by: 1) {
                selection.insert(ordered[i])
            }
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
        }
    }

    /// The right-click menu for a row: acts on the whole selection if the row is
    /// part of it, otherwise on just that row.
    @ViewBuilder
    private func contextMenuItems(for id: UUID) -> some View {
        let targets = selection.contains(id) ? Array(selection) : [id]
        let n = targets.count
        Button {
            regenerate(ids: targets, title: true)
        } label: {
            Label(n > 1 ? "Regenerate \(n) titles" : "Regenerate title", systemImage: "textformat")
        }
        Button {
            regenerate(ids: targets, title: false)
        } label: {
            Label(n > 1 ? "Regenerate \(n) summaries" : "Regenerate summary", systemImage: "text.alignleft")
        }
        Divider()
        Button {
            reTranscribe(ids: targets)
        } label: {
            Label(n > 1 ? "Re-transcribe \(n) recordings" : "Re-transcribe", systemImage: "waveform.badge.magnifyingglass")
        }
        if !selection.isEmpty {
            Button { selection.removeAll() } label: { Label("Clear selection", systemImage: "xmark.circle") }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = targets
            showDeleteConfirm = true
        } label: {
            Label(n > 1 ? "Delete \(n) recordings" : "Delete recording", systemImage: "trash")
        }
    }

    private func regenerate(ids: [UUID], title: Bool) {
        for id in ids {
            guard let entry = library.entries.first(where: { $0.id == id }) else { continue }
            Task {
                var updated = entry
                if title {
                    if let value = await ollama.regenerateTitle(from: entry.prose, prompt: settings.effectiveTitlePrompt) {
                        updated.title = value
                    }
                } else {
                    if let value = await ollama.regenerateSummary(from: entry.prose, prompt: settings.effectiveSummaryPrompt) {
                        updated.summary = value
                    }
                }
                library.upsert(updated)
            }
        }
    }

    private func reTranscribe(ids: [UUID]) {
        for id in ids {
            if let entry = library.entries.first(where: { $0.id == id }) {
                importer.reTranscribe(entry)
            }
        }
    }

    private func confirmDelete() {
        for id in pendingDelete {
            if let entry = library.entries.first(where: { $0.id == id }) {
                library.delete(entry)
            }
        }
        selection.subtract(pendingDelete)
        pendingDelete = []
    }

    /// A subtle, dismissable pill shown at the top of the feed when the calendar
    /// is filtering to a single day. Tapping the ✕ clears the filter.
    /// A visible affordance to clear a multi-selection — the discoverable
    /// counterpart to Esc and the right-click "Clear selection" item.
    private var selectionBar: some View {
        let allSelected = !visibleIDs.isEmpty && selection.isSuperset(of: visibleIDs)
        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { selection.removeAll() }
            } label: {
                selectionPill {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                    Text("\(selection.count) selected")
                        .font(.subheadline.weight(.medium))
                    Text("·")
                        .foregroundStyle(settings.accent.opacity(0.5))
                    Text("Clear")
                        .font(.subheadline.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .help("Clear the selection")

            Button {
                withAnimation(.easeOut(duration: 0.15)) { selection.formUnion(visibleIDs) }
            } label: {
                selectionPill {
                    Image(systemName: "checklist.checked")
                        .font(.caption.weight(.semibold))
                    Text("Select all")
                        .font(.subheadline.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .disabled(allSelected)
            .opacity(allSelected ? 0.4 : 1)
            .help("Select every recording shown")

            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, filterDay == nil ? 10 : 6)
    }

    /// The shared accent capsule used by the selection-bar pills.
    private func selectionPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .foregroundStyle(settings.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(settings.accent.opacity(0.13))
                    .overlay(Capsule().strokeBorder(settings.accent.opacity(0.18)))
            )
    }

    private func filterChip(_ day: Date) -> some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                Text(Format.dayHeading(day))
                    .font(.subheadline.weight(.medium))
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filterDay = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(settings.accent.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Show all recordings")
            }
            .foregroundStyle(settings.accent)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(settings.accent.opacity(0.13))
                    .overlay(Capsule().strokeBorder(settings.accent.opacity(0.18)))
            )
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(settings.accent)
            Text("Your journal is empty")
                .font(.headline)
            Text("Drop a folder of voice recordings onto the queue,\nor use Import above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                chooseFolder()
            } label: {
                Label {
                    Text("Import…")
                } icon: {
                    Image(systemName: "square.and.arrow.down").offset(y: -1.5)
                }
            }
            .help("Import a folder of recordings (you can add more while a batch runs)")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")

            Button {
                showChat.toggle()
            } label: {
                Label("Ask your journal", systemImage: showChat ? "sparkles.rectangle.stack.fill" : "sparkles")
            }
            .help("Ask your journal — chat about your recordings")
        }
    }

    // MARK: - Import plumbing

    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose a folder of recordings (or the recordings themselves)."
        if panel.runModal() == .OK {
            importer.enqueue(urls: panel.urls)
        }
        #endif
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        #if os(macOS)
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                importer.enqueue(urls: urls)
            }
        }
        return true
        #else
        return false
        #endif
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(settings.accent, style: StrokeStyle(lineWidth: 3, dash: [10]))
            .background(settings.accent.opacity(0.06))
            .overlay {
                Label("Drop recordings to import", systemImage: "tray.and.arrow.down")
                    .font(.title2.weight(.medium))
            }
            .padding(24)
            .allowsHitTesting(false)
    }
}

/// One entry row's day and vertical offset within the feed, collected across all
/// currently-rendered rows so the list can tell which day is at the top and pin it.
private struct DayScanItem: Equatable {
    let day: Date
    let minY: CGFloat
}

private struct DayScanKey: PreferenceKey {
    static let defaultValue: [DayScanItem] = []
    static func reduce(value: inout [DayScanItem], nextValue: () -> [DayScanItem]) {
        value.append(contentsOf: nextValue())
    }
}

/// The measured height of the selection/filter bar, so the pinned day bar can be
/// offset to sit directly beneath it.
private struct TopInsetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One card in the diary feed: an accent waveform badge, the title, a preview,
/// and a duration tag. Presentational only — selection and the right-click menu
/// are owned by the parent list (see `entryRow`).
private struct EntryRow: View {
    let entry: Entry
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(settings.accent.opacity(0.16))
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(settings.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title.isEmpty ? "Untitled" : entry.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Format.time(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(Format.clock(entry.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(settings.accent)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(settings.accent.opacity(0.12)))
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 6)
    }
}

#if os(macOS)
extension NSItemProvider {
    /// Async wrapper around `loadObject(ofClass: URL.self)` for drag-and-drop.
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = self.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

/// Paints the whole window — titlebar included — a single opaque tinted colour.
/// The sidebar is then given the *same* solid colour (see `leftColumn`) so no
/// translucent `NSVisualEffectView` is left showing: vibrancy is what macOS
/// dims/desaturates when the window loses focus, and its edge against the detail
/// pane was the "white vertical line" seam. A flat opaque fill can't seam or
/// change with focus, so the window looks identical active or inactive.
struct WindowTint: NSViewRepresentable {
    var accent: Color

    /// The exact opaque colour the window (and sidebar) are painted, so SwiftUI
    /// and AppKit sides match to the pixel. Dynamic, so it tracks light/dark.
    static func solid(_ accent: Color) -> Color {
        Color(nsColor: fill(for: accent))
    }

    private static func fill(for accent: Color) -> NSColor {
        let base = NSColor.windowBackgroundColor
        return base.blended(withFraction: 0.08, of: NSColor(accent)) ?? base
    }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let accent = self.accent
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
            window.backgroundColor = Self.fill(for: accent)
            Self.installWordmark(in: window, accent: accent)
        }
    }

    private static let wordmarkID = NSUserInterfaceItemIdentifier("MurmurWordmark")

    /// Puts the app wordmark in the titlebar as a leading accessory — i.e. right
    /// after the window's traffic-light controls, vertically centred in the bar.
    private static func installWordmark(in window: NSWindow, accent: Color) {
        let host = NSHostingController(rootView: Wordmark(accent: accent))
        host.view.frame.size = host.view.fittingSize

        if let existing = window.titlebarAccessoryViewControllers.first(where: { $0.identifier == wordmarkID }) {
            existing.view = host.view
            return
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = wordmarkID
        accessory.layoutAttribute = .leading
        accessory.view = host.view
        window.addTitlebarAccessoryViewController(accessory)
    }

    private struct Wordmark: View {
        var accent: Color
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                Text("Murmur")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(accent)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 3)   // headroom so the nudge can't clip top or bottom
            .offset(y: -1)           // sit level with the traffic lights
        }
    }
}
#endif
