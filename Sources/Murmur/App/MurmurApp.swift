import SwiftUI

/// Process entry point. Diverts to a headless self-test when launched with
/// `--selftest <folder>` (used for CI/dev verification), else runs the app.
@main
enum Main {
    static func main() {
        if let idx = CommandLine.arguments.firstIndex(of: "--selftest") {
            let folder = CommandLine.arguments[safe: idx + 1] ?? ""
            SelfTest.run(folder: folder)
            return
        }
        MurmurApp.main()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Murmur — a spoken journal. Import a folder of voice notes; each is transcribed
/// on-device with Whisper, captioned by Apple's on-device model, and laid out as
/// a dated diary you can play back and edit. Everything lives in iCloud Drive.
struct MurmurApp: App {
    @StateObject private var library: Library
    @StateObject private var transcriber: Transcriber
    @StateObject private var summarizer: Summarizer
    @StateObject private var player: Player
    @StateObject private var importer: Importer

    init() {
        let library = Library()
        let transcriber = Transcriber()
        let summarizer = Summarizer()
        _library = StateObject(wrappedValue: library)
        _transcriber = StateObject(wrappedValue: transcriber)
        _summarizer = StateObject(wrappedValue: summarizer)
        _player = StateObject(wrappedValue: Player())
        _importer = StateObject(wrappedValue: Importer(library: library, transcriber: transcriber, summarizer: summarizer))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(transcriber)
                .environmentObject(summarizer)
                .environmentObject(player)
                .environmentObject(importer)
                .task { library.load() }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Formatting shared across the diary views.
enum Format {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
