import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// The main window: a calendar + diary feed on the left, the selected entry on
/// the right. Handles importing (button + drag-and-drop) and the model picker.
struct ContentView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @EnvironmentObject private var importer: Importer

    @State private var selectedEntryID: UUID?
    @State private var visibleMonth = Date()
    @State private var filterDay: Date?
    @State private var isTargetedForDrop = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargetedForDrop {
                dropHint
            }
        }
    }

    // MARK: - Sidebar (calendar + diary feed)

    private var sidebar: some View {
        VStack(spacing: 0) {
            CalendarView(
                month: $visibleMonth,
                populatedDays: library.populatedDays,
                selectedDay: filterDay,
                onSelectDay: { day in
                    filterDay = (filterDay == day) ? nil : day
                }
            )
            .padding(12)

            Divider()

            if importer.isRunning {
                ImportProgressBar()
                    .padding(12)
                Divider()
            }

            diaryFeed
        }
    }

    private var diaryFeed: some View {
        let days = filterDay == nil
            ? library.days
            : library.days.filter { Calendar.current.isDate($0.day, inSameDayAs: filterDay!) }

        return Group {
            if library.entries.isEmpty {
                emptyState
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(days, id: \.day) { group in
                        Section(Format.dayHeading(group.day)) {
                            ForEach(group.entries) { entry in
                                EntryRow(entry: entry).tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Your journal is empty")
                .font(.headline)
            Text("Drop a folder of voice recordings here,\nor use Import above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let id = selectedEntryID, let entry = library.entries.first(where: { $0.id == id }) {
                EntryDetailView(entry: entry)
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    "No entry selected",
                    systemImage: "text.quote",
                    description: Text("Pick a day on the calendar or an entry from the list.")
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                chooseFolder()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .disabled(importer.isRunning)
        }

        ToolbarItem(placement: .automatic) {
            Picker("Model", selection: $transcriber.selectedVariant) {
                ForEach(Transcriber.models) { model in
                    Text(model.label).tag(model.variant)
                }
            }
            .disabled(importer.isRunning)
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
            let urls = panel.urls
            Task { await importer.import(urls: urls) }
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
                await importer.import(urls: urls)
            }
        }
        return true
        #else
        return false
        #endif
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10]))
            .background(.tint.opacity(0.06))
            .overlay {
                Label("Drop recordings to import", systemImage: "tray.and.arrow.down")
                    .font(.title2.weight(.medium))
            }
            .padding(24)
            .allowsHitTesting(false)
    }
}

/// One line in the diary feed: time, title, and a short preview.
private struct EntryRow: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
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
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(Format.clock(entry.duration))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
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
#endif

/// Live import status shown above the feed while a batch runs.
private struct ImportProgressBar: View {
    @EnvironmentObject private var importer: Importer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text(importer.currentName.isEmpty ? "Working…" : importer.currentName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(importer.done)/\(importer.total)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(importer.done), total: Double(max(importer.total, 1)))
            Text(importer.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
