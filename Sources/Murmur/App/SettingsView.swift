import SwiftUI

/// The Preferences window (⌘,): accent theme and the local caption models.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            PromptSettings()
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

/// Software update controls: current version, auto-check toggle, manual check.
private struct UpdateSettings: View {
    @EnvironmentObject private var updater: Updater
    @State private var autoCheck = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Version")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(updater.currentVersion)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $autoCheck) {
                Text("Automatically check for updates on launch")
                    .font(.subheadline)
            }
            .onChange(of: autoCheck) { updater.autoCheckEnabled = autoCheck }

            HStack(spacing: 10) {
                Button("Check Now") {
                    Task { await updater.check() }
                }
                .disabled(updater.state == .checking)
                statusView
            }

            if let release = updater.available {
                Divider()
                Text("Murmur \(release.version) is available.")
                    .font(.subheadline.weight(.medium))
                Button("Download & Install") {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(updater.state == .downloading || updater.state == .installing)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { autoCheck = updater.autoCheckEnabled }
    }

    @ViewBuilder
    private var statusView: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                .font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…") }
                .font(.caption).foregroundStyle(.secondary)
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…") }
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }
}

/// Custom captioning prompts — override how titles and summaries are written.
private struct PromptSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Custom prompts")
                .font(.headline)
            Text("By default Murmur writes a short evocative title and a one–two sentence summary. Turn these on to steer the wording yourself. Applies to new imports and to Regenerate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            promptBlock(
                title: "Title prompt",
                isOn: $settings.customTitleEnabled,
                text: $settings.customTitlePrompt,
                placeholder: "e.g. A playful 2–4 word title in lowercase."
            )

            promptBlock(
                title: "Summary prompt",
                isOn: $settings.customSummaryEnabled,
                text: $settings.customSummaryPrompt,
                placeholder: "e.g. One factual sentence, no adjectives."
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promptBlock(title: String, isOn: Binding<Bool>, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                Text(title).font(.subheadline.weight(.medium))
            }
            if isOn.wrappedValue {
                TextEditor(text: text)
                    .font(.callout)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                    .overlay(alignment: .topLeading) {
                        if text.wrappedValue.isEmpty {
                            Text(placeholder)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }
}

/// Accent theme picker — blue, pink, or teal.
private struct AppearanceSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Accent")
                .font(.headline)

            HStack(spacing: 18) {
                ForEach(AppSettings.themes) { theme in
                    swatch(theme)
                }
            }

            Text("Sets the app-wide tint. Blue is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(_ theme: AppSettings.Theme) -> some View {
        let selected = settings.themeID == theme.id
        return Button {
            settings.themeID = theme.id
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(theme.color)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(selected ? 0.55 : 0.12), lineWidth: selected ? 2.5 : 1)
                    }
                Text(theme.name)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Local caption models: pick fast vs best, and download them in-app.
private struct ModelSettings: View {
    @EnvironmentObject private var ollama: OllamaService
    @EnvironmentObject private var transcriber: Transcriber

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // 1. Speech-to-text.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription")
                        .font(.headline)
                    Text("Turns your recordings into text, on-device with Whisper. Bigger models are more accurate but slower to run and download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Transcriber.models) { model in
                        WhisperRow(model: model)
                    }
                }

                Divider()

                // 2. Title + summary.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Captions")
                            .font(.headline)
                        Spacer()
                        serverBadge
                    }
                    Text("Writes each entry's title and summary from the transcript — a local LLM run by Ollama, fully on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(OllamaService.catalog) { model in
                        ModelRow(model: model)
                    }
                }

                Divider()

                // 3. The "Ask your journal" chat assistant.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Assistant")
                        .font(.headline)
                    Text("Powers “Ask your journal”, which searches your transcripts to answer questions. Standard is shared with Best captions; download Deep for the most accurate answers on a large journal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(OllamaService.assistantCatalog) { model in
                        ModelRow(model: model, isAssistant: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .frame(height: 460)
    }

    @ViewBuilder
    private var serverBadge: some View {
        switch ollama.serverState {
        case .ready:
            Label("Ollama ready", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .starting:
            Label("Starting…", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .stopped:
            Label("Stopped", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

/// One selectable model with a download button + progress. Controls either the
/// caption model (`activeTag`) or the chat assistant model (`assistantTag`).
private struct ModelRow: View {
    let model: OllamaService.LLMModel
    var isAssistant: Bool = false
    @EnvironmentObject private var ollama: OllamaService

    private var installed: Bool { ollama.isInstalled(model.tag) }
    private var pull: OllamaService.PullState? { ollama.pulls[model.tag] }
    private var isActive: Bool { (isAssistant ? ollama.assistantTag : ollama.activeTag) == model.tag }
    private var pulling: Bool { pull != nil && !(pull?.done ?? false) && pull?.error == nil }

    private func select() {
        if isAssistant { ollama.assistantTag = model.tag } else { ollama.activeTag = model.tag }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .onTapGesture {
                    if installed { select() }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).font(.body.weight(.medium))
                    Text(model.role)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.tint.opacity(0.18)))
                }
                Text(model.note).font(.caption).foregroundStyle(.secondary)
                if pulling, let pull {
                    ProgressView(value: pull.fraction) {
                        Text(pull.status).font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let error = pull?.error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }

            Spacer()

            trailing
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    @ViewBuilder
    private var trailing: some View {
        if installed {
            if isActive {
                Text("Active").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Use") { select() }
                    .buttonStyle(.bordered)
                Button(role: .destructive) {
                    Task { await ollama.delete(model.tag) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this model")
            }
        } else if pulling {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task { await ollama.pull(model.tag) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(ollama.serverState != .ready)
        }
    }
}

/// One selectable Whisper transcription model with download + progress.
private struct WhisperRow: View {
    let model: Transcriber.Model
    @EnvironmentObject private var transcriber: Transcriber

    private var installed: Bool { transcriber.isInstalled(model.variant) }
    private var isActive: Bool { transcriber.selectedVariant == model.variant }
    private var progress: Double? { transcriber.downloads[model.variant] }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .onTapGesture { transcriber.selectedVariant = model.variant }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.label).font(.body.weight(.medium))
                Text(model.note).font(.caption).foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress) {
                        Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if progress != nil {
                ProgressView().controlSize(.small)
            } else if installed {
                if isActive {
                    Text("Active").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Use") { transcriber.selectedVariant = model.variant }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        Task { await transcriber.delete(model.variant) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this model")
                }
            } else {
                Button {
                    Task { await transcriber.download(model.variant) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }
}
