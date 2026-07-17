import SwiftUI

/// First-run (and whenever-a-model-is-missing) setup: pick a transcription model
/// and a caption model, download them, and enter the app. Dismisses itself once
/// both are ready.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var ollama: OllamaService

    @State private var busy = false

    private var transcriptionReady: Bool { transcriber.isInstalled(transcriber.selectedVariant) }
    private var captionReady: Bool { ollama.serverState == .ready && ollama.isInstalled(ollama.activeTag) }
    private var assistantReady: Bool { ollama.serverState == .ready && ollama.isInstalled(ollama.assistantTag) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            section(
                number: "1",
                title: "Transcription",
                subtitle: "Turns your recordings into text, on-device with Whisper."
            ) {
                ForEach(Transcriber.models) { model in
                    ChoiceRow(
                        title: model.label,
                        note: model.note,
                        selected: transcriber.selectedVariant == model.variant,
                        installed: transcriber.isInstalled(model.variant),
                        progress: transcriber.downloads[model.variant]
                    ) { transcriber.selectedVariant = model.variant }
                }
            }

            section(
                number: "2",
                title: "Captions",
                subtitle: "Writes each entry's title and summary — a local model run by Ollama."
            ) {
                ForEach(OllamaService.catalog) { model in
                    ChoiceRow(
                        title: "\(model.name)  ·  \(model.role)",
                        note: model.note,
                        selected: ollama.activeTag == model.tag,
                        installed: ollama.isInstalled(model.tag),
                        progress: pullFraction(model.tag)
                    ) { ollama.activeTag = model.tag }
                }
            }

            section(
                number: "3",
                title: "Ask your journal",
                subtitle: "Answers questions about your entries. Standard is shared with the Best caption model."
            ) {
                ForEach(OllamaService.assistantCatalog) { model in
                    ChoiceRow(
                        title: "\(model.name)  ·  \(model.role)",
                        note: model.note,
                        selected: ollama.assistantTag == model.tag,
                        installed: ollama.isInstalled(model.tag),
                        progress: pullFraction(model.tag)
                    ) { ollama.assistantTag = model.tag }
                }
            }

            footer
        }
        .padding(26)
        .frame(width: 560)
        .task { await ollama.start() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(settings.accent.opacity(0.18)).frame(width: 52, height: 52)
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(settings.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Murmur")
                    .font(.title2.bold())
                Text("A spoken journal, transcribed on your Mac. Choose your models to get started — both run locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(
        number: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(number)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(settings.accent))
                Text(title).font(.headline)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            if busy {
                ProgressView().controlSize(.small)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }

            Button {
                downloadAndContinue()
            } label: {
                Text(busy ? "Downloading…" : "Download & Continue")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
    }

    private var statusLine: String {
        if ollama.serverState != .ready { return "Starting Ollama…" }
        if !transcriptionReady { return "Getting \(transcriber.selectedVariant)…" }
        if !captionReady { return "Getting \(ollama.activeModel.name)…" }
        if !assistantReady { return "Getting the assistant model…" }
        return "Ready"
    }

    private func pullFraction(_ tag: String) -> Double? {
        guard let pull = ollama.pulls[tag], !pull.done, pull.error == nil else { return nil }
        return pull.fraction
    }

    // MARK: - Action

    private func downloadAndContinue() {
        busy = true
        Task {
            await ollama.start()
            async let whisper: Void = ensureTranscription()
            async let caption: Void = ensureCaption()
            _ = await (whisper, caption)
            // The assistant model may be the same tag as the caption model, so
            // fetch it after captions to avoid pulling the same weights twice.
            await ensureAssistant()
            busy = false
            // RootView's gate dismisses this sheet automatically once all are ready.
        }
    }

    private func ensureTranscription() async {
        if !transcriber.isInstalled(transcriber.selectedVariant) {
            await transcriber.download(transcriber.selectedVariant)
        }
    }

    private func ensureCaption() async {
        if !ollama.isInstalled(ollama.activeTag) {
            await ollama.pull(ollama.activeTag)
        }
    }

    private func ensureAssistant() async {
        if !ollama.isInstalled(ollama.assistantTag) {
            await ollama.pull(ollama.assistantTag)
        }
    }
}

/// A selectable model row for onboarding: radio, name, note, and install state.
private struct ChoiceRow: View {
    let title: String
    let note: String
    let selected: Bool
    let installed: Bool
    let progress: Double?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    if let progress {
                        ProgressView(value: progress).controlSize(.small)
                    }
                }

                Spacer()

                if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Downloaded")
                }
            }
            .contentShape(Rectangle())
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.35)))
            )
        }
        .buttonStyle(.plain)
    }
}
