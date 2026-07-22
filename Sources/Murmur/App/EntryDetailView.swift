import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The reading surface for one diary entry. Title and summary are AI-generated
/// and read-only (change them via Regenerate); the transcript shows as flowing,
/// editable prose. Playback scrubs the recording. Edits autosave.
struct EntryDetailView: View {
    let entry: Entry

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ollama: OllamaService
    @EnvironmentObject private var importer: Importer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Entry
    @State private var saveTask: Task<Void, Never>?
    @State private var regenerating: Field?

    private enum Field { case title, summary }

    init(entry: Entry) {
        self.entry = entry
        _draft = State(initialValue: entry)
    }

    private var audioURL: URL { library.audioURL(for: draft) }
    private var isCurrentAudio: Bool { player.loadedURL == audioURL }

    /// The entry as it currently stands in the library. Diverges from `draft` only
    /// when something outside this view changes it — notably a re-transcribe, whose
    /// fresh transcript, title and summary we then pull into the draft.
    private var stored: Entry? { library.entries.first { $0.id == entry.id } }
    private var isReTranscribing: Bool { importer.isReTranscribing(entry.id) }

    private var proseBinding: Binding<String> {
        Binding(
            get: { draft.prose },
            set: {
                draft.text = $0
                draft.transcriptEdited = true
                scheduleSave()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryBlock
                playbackBar
                Divider()
                transcriptBlock
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(draft.title.isEmpty ? "Entry" : draft.title)
        .onAppear { player.load(audioURL) }
        .onChange(of: stored) { _, latest in
            // Our own edits round-trip draft → save → stored, so stored == draft
            // after they land; a mismatch means an external change (re-transcribe).
            if let latest, latest != draft {
                draft = latest
            }
        }
        .toolbar { detailToolbar }
    }

    // MARK: - Header (read-only title + metadata)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.title.isEmpty ? "Untitled" : draft.title)
                .font(.system(size: 30, weight: .bold))
                .textSelection(.enabled)
                .overlay(alignment: .trailing) {
                    if regenerating == .title { ProgressView().controlSize(.small) }
                }

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
    }

    // MARK: - Summary (read-only)

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(draft.summary.isEmpty ? "No summary." : draft.summary)
                .font(.body)
                .foregroundStyle(draft.summary.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .modifier(GlassCard(cornerRadius: 14))
                .overlay(alignment: .center) {
                    if regenerating == .summary { ProgressView().controlSize(.small) }
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
        .background(RoundedRectangle(cornerRadius: 12).fill(settings.accentWash))
    }

    // MARK: - Transcript (editable prose)

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if draft.transcriptEdited {
                    Text("· edited").font(.caption).foregroundStyle(.tertiary)
                }
                if isReTranscribing {
                    Text("· re-transcribing…").font(.caption).foregroundStyle(.tertiary)
                    ProgressView().controlSize(.small)
                }
            }

            TextField("Transcript", text: proseBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button { regenerate(.title) } label: { Label("Regenerate title", systemImage: "textformat") }
                Button { regenerate(.summary) } label: { Label("Regenerate summary", systemImage: "text.alignleft") }
                Divider()
                Button { importer.reTranscribe(draft) } label: { Label("Re-transcribe", systemImage: "waveform.badge.magnifyingglass") }
                    .disabled(isReTranscribing)
            } label: {
                Label("Regenerate", systemImage: "sparkles")
            }
            .disabled(regenerating != nil)

            Button {
                revealInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            ShareLink(item: audioURL) {
                Label("Share Audio", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                player.stop()
                library.delete(draft)
                dismiss()
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

    private func regenerate(_ field: Field) {
        regenerating = field
        Task {
            switch field {
            case .title:
                if let title = await ollama.regenerateTitle(from: draft.prose, prompt: settings.effectiveTitlePrompt, persona: settings.authorPersona) {
                    draft.title = title
                }
            case .summary:
                if let summary = await ollama.regenerateSummary(from: draft.prose, prompt: settings.effectiveSummaryPrompt, persona: settings.authorPersona) {
                    draft.summary = summary
                }
            }
            library.upsert(draft)
            regenerating = nil
        }
    }

    private func revealInFinder() {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        #endif
    }
}

/// Apple Liquid Glass on macOS 26; a clean translucent fallback below that.
struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                )
        }
    }
}
