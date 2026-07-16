import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The reading/editing surface for one diary entry: editable title and summary,
/// a playback bar, and the transcript as timestamped, editable segments that
/// highlight and scrub in time with the audio. Edits autosave to the library.
struct EntryDetailView: View {
    let entry: Entry

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var summarizer: Summarizer

    @State private var draft: Entry
    @State private var saveTask: Task<Void, Never>?
    @State private var isRegenerating = false

    init(entry: Entry) {
        self.entry = entry
        _draft = State(initialValue: entry)
    }

    private var audioURL: URL { library.audioURL(for: draft) }
    private var isCurrentAudio: Bool { player.loadedURL == audioURL }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleField
                    metadataRow
                    summaryBlock
                    playbackBar
                    Divider()
                    transcript(scrollProxy: proxy)
                }
                .padding(28)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: player.currentTime) { _, _ in autoScroll() }
        .onAppear { player.load(audioURL) }
        .toolbar { detailToolbar }
    }

    // MARK: - Header

    private var titleField: some View {
        TextField("Title", text: $draft.title)
            .textFieldStyle(.plain)
            .font(.system(size: 30, weight: .bold))
            .onChange(of: draft.title) { _, _ in scheduleSave() }
    }

    private var metadataRow: some View {
        HStack(spacing: 14) {
            Label(draft.date.formatted(.dateTime.weekday().day().month().hour().minute()), systemImage: "calendar")
            Label(Format.clock(draft.duration), systemImage: "waveform")
            if let language = draft.language {
                Label(language.uppercased(), systemImage: "globe")
            }
            Label(draft.model, systemImage: "cpu")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    regenerate()
                } label: {
                    Label("Regenerate", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isRegenerating)
            }
            TextEditor(text: $draft.summary)
                .font(.body)
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                .onChange(of: draft.summary) { _, _ in scheduleSave() }
                .overlay(alignment: .center) {
                    if isRegenerating {
                        ProgressView().controlSize(.small)
                    }
                }
        }
    }

    // MARK: - Playback

    private var playbackBar: some View {
        HStack(spacing: 14) {
            Button {
                if !isCurrentAudio { player.load(audioURL) }
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying && isCurrentAudio ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
            }
            .buttonStyle(.plain)

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { isCurrentAudio ? player.currentTime : 0 },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                HStack {
                    Text(Format.clock(isCurrentAudio ? player.currentTime : 0))
                    Spacer()
                    Text(Format.clock(draft.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Transcript

    private func transcript(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if draft.transcriptEdited {
                    Text("· edited")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 4)

            ForEach($draft.segments) { $segment in
                SegmentRow(
                    segment: $segment,
                    isCurrent: isCurrentAudio && player.currentTime >= segment.start && player.currentTime < segment.end,
                    onSeek: {
                        if !isCurrentAudio { player.load(audioURL) }
                        player.seek(to: segment.start)
                        if !player.isPlaying { player.togglePlayPause() }
                    },
                    onEdit: {
                        draft.transcriptEdited = true
                        scheduleSave()
                    }
                )
                .id(segment.id)
            }
        }
    }

    private func autoScroll() {
        // Kept intentionally light — no forced scrolling to avoid fighting the user.
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                revealInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button(role: .destructive) {
                player.stop()
                library.delete(draft)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = draft
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            library.upsert(snapshot)
        }
    }

    private func regenerate() {
        isRegenerating = true
        Task {
            let caption = await summarizer.summarize(draft.plainText)
            draft.title = caption.title
            draft.summary = caption.summary
            draft.summaryEdited = false
            isRegenerating = false
            library.upsert(draft)
        }
    }

    private func revealInFinder() {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        #endif
    }
}

/// One transcript segment: a timestamp button that seeks, and inline-editable text.
private struct SegmentRow: View {
    @Binding var segment: Segment
    let isCurrent: Bool
    let onSeek: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onSeek) {
                Text(Format.clock(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .padding(.top, 3)

            TextField("", text: $segment.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .onChange(of: segment.text) { _, _ in onEdit() }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
        }
    }
}
