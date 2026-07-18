import SwiftUI
import AppKit

/// Process entry point. Diverts to a headless self-test when launched with
/// `--selftest <folder>` (used for dev verification), else runs the app.
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

/// Runs cleanup (terminate the bundled Ollama, cancel the queue) when the app
/// quits, so a mid-file quit leaves nothing orphaned.
@MainActor
private final class QuitHandler {
    static let shared = QuitHandler()
    var onQuit: @MainActor () -> Void = {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { QuitHandler.shared.onQuit() }
    }
}

/// Murmur — a spoken journal. Import a folder of voice notes; each is transcribed
/// on-device with Whisper, captioned by a local Ollama model, and laid out as a
/// dated diary you can play back and edit. Everything lives in iCloud Drive.
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var library: Library
    @StateObject private var transcriber: Transcriber
    @StateObject private var ollama: OllamaService
    @StateObject private var player: Player
    @StateObject private var importer: Importer
    @StateObject private var updater = Updater()

    init() {
        let settings = AppSettings()
        let library = Library()
        let transcriber = Transcriber()
        let ollama = OllamaService()
        let importer = Importer(library: library, transcriber: transcriber, ollama: ollama, settings: settings)

        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: library)
        _transcriber = StateObject(wrappedValue: transcriber)
        _ollama = StateObject(wrappedValue: ollama)
        _player = StateObject(wrappedValue: Player())
        _importer = StateObject(wrappedValue: importer)

        QuitHandler.shared.onQuit = {
            importer.cancelAll()
            ollama.stop()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(transcriber)
                .environmentObject(ollama)
                .environmentObject(player)
                .environmentObject(importer)
                .environmentObject(updater)
                .tint(settings.accent)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check() }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(ollama)
                .environmentObject(transcriber)
                .environmentObject(updater)
                .tint(settings.accent)
        }
    }
}

/// Hosts the main window and gates it behind onboarding until the profile (name +
/// gender) and the transcription/caption/assistant models are all set up.
/// Onboarding re-appears any time one of those becomes unavailable (fresh machine,
/// model removed, profile cleared).
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var ollama: OllamaService
    @EnvironmentObject private var updater: Updater

    @State private var startupChecked = false
    @State private var showOnboarding = false

    // Onboarding is about whether the profile and models are *set up*, not whether
    // the Ollama server happens to be answering this instant — a slow or failed
    // probe must not resurrect the welcome screen for a set-up machine. The
    // captioning/chat code paths guard on live server state separately.
    private var transcriptionReady: Bool {
        transcriber.isInstalled(transcriber.selectedVariant)
    }
    private var captionReady: Bool {
        ollama.isInstalled(ollama.activeTag)
    }
    private var assistantReady: Bool {
        ollama.isInstalled(ollama.assistantTag)
    }
    private var needsOnboarding: Bool {
        !settings.profileComplete || !transcriptionReady || !captionReady || !assistantReady
    }

    var body: some View {
        ContentView()
            .task {
                await library.load()
                await ollama.start()
                startupChecked = true   // only judge readiness once Ollama has answered
                showOnboarding = needsOnboarding
                await updater.checkOnLaunch()
            }
            // Re-appear if something needed later goes missing (a model deleted, the
            // profile cleared). Dismissal is explicit — the sheet closes only when
            // OnboardingView calls back, never reactively as the name is typed.
            .onChange(of: needsOnboarding) { _, needs in
                if startupChecked && needs {
                    showOnboarding = true
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(onComplete: { showOnboarding = false })
                    .interactiveDismissDisabled()
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
