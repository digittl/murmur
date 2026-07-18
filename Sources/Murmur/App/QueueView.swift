import SwiftUI

/// The import queue — fills the left column under the calendar. Shows a drop
/// zone when empty, otherwise a roomy scrollable list of files with per-item
/// cancel and overall controls. Files can be dropped onto the whole window at
/// any time (handled in ContentView); this view is the visual home for that.
struct QueueView: View {
    @ObservedObject var recorder: Recorder
    var isTargetedForDrop: Bool = false

    @EnvironmentObject private var importer: Importer
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            recordBar
            Group {
                if importer.items.isEmpty {
                    dropZone
                } else {
                    queue
                }
            }
        }
    }

    // MARK: - Record a note (in-app capture)

    @ViewBuilder
    private var recordBar: some View {
        if recorder.isRecording {
            recordingActive
        } else {
            VStack(spacing: 6) {
                Button {
                    Task { await recorder.start() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                        Text("Record a note").fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(settings.accent)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(settings.accent.opacity(0.14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(settings.accent.opacity(0.22))
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Record a voice note with your microphone")

                if case .denied = recorder.state {
                    Text("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if case .failed(let why) = recorder.state {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var recordingActive: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(0.45 + recorder.level * 0.55)
            Text(Format.clock(recorder.elapsed))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()

            GeometryReader { geo in
                Capsule()
                    .fill(settings.accent.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(settings.accent)
                            .frame(width: max(2, geo.size.width * recorder.level))
                    }
            }
            .frame(height: 5)

            Button { stopRecording() } label: {
                Image(systemName: "stop.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.accent)
            .help("Stop and add to the queue")

            Button { recorder.cancel() } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Discard this recording")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(settings.accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(settings.accent.opacity(0.2))
                )
        )
    }

    private func stopRecording() {
        if let url = recorder.stop() {
            importer.enqueue(urls: [url])
        }
    }

    // MARK: - Empty state: drop zone

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(settings.accent)
            Text("Drop recordings here")
                .font(.callout.weight(.medium))
            Text("Drag a folder or audio files\nonto the queue to import them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(settings.accent.opacity(isTargetedForDrop ? 0.12 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(settings.accent.opacity(0.35),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                )
        )
    }

    // MARK: - Active queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(importer.items) { item in
                        QueueRow(item: item)
                    }
                }
            }
            if !importer.statusLine.isEmpty {
                Text(importer.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if importer.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text("Queue").font(.headline)
                Text("\(importer.finishedCount)/\(importer.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                controls
                    .buttonStyle(.borderless)
                    .imageScale(.large)
            }
            ProgressView(value: Double(importer.finishedCount), total: Double(max(importer.total, 1)))
                .tint(settings.accent)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch importer.runState {
        case .running:
            Button { importer.pause() } label: { Image(systemName: "pause.fill") }
                .help("Pause after the current file")
        case .paused:
            Button { importer.resume() } label: { Image(systemName: "play.fill") }
                .help("Resume")
        case .idle:
            EmptyView()
        }

        if importer.runState != .idle {
            Button(role: .destructive) { importer.cancelAll() } label: { Image(systemName: "stop.fill") }
                .help("Cancel the whole queue")
        }
        if importer.finishedCount > 0 {
            Button { importer.clearFinished() } label: { Image(systemName: "xmark.circle") }
                .help("Clear finished items")
        }
    }
}

/// One roomy row in the queue: status glyph, filename, and a per-item cancel.
private struct QueueRow: View {
    let item: Importer.Item
    @EnvironmentObject private var importer: Importer

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(item.state.isFinished && item.state != .done ? .secondary : .primary)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !item.state.isFinished {
                Button { importer.cancel(id: item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from queue")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
    }

    private var statusText: String {
        let redo = item.reTranscribeEntryID != nil
        switch item.state {
        case .pending: return "Waiting…"
        case .transcribing: return redo ? "Re-transcribing…" : "Transcribing…"
        case .summarizing: return "Summarizing…"
        case .done: return redo ? "Re-transcribed" : "Added"
        case .skipped: return "Duplicate — skipped"
        case .cancelled: return "Cancelled"
        case .failed(let why): return why
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .transcribing:
            Image(systemName: "waveform").foregroundStyle(.tint).symbolEffect(.variableColor.iterative, isActive: true)
        case .summarizing:
            Image(systemName: "sparkles").foregroundStyle(.tint)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "arrow.uturn.forward").foregroundStyle(.secondary)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
