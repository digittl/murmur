// BatchWhisper — native macOS app.
//
// Feeds voice recordings into Whisper Transcription (MacWhisper) one at a time,
// in chronological order (by the YYYY-MM-DD-HH-MM-SS timestamp in each filename),
// waiting for each file's transcript to land in the export folder before sending
// the next — so MacWhisper only ever holds one job and the order can't scramble.

import Cocoa

let macWhisperBundleID = "com.goodsnooze.MacWhisper"
let audioExts: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "flac", "ogg"]

// MARK: - Drop target

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true; needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false; needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false; needsDisplay = true
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirty: NSRect) {
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let path = NSBezierPath(roundedRect: inset, xRadius: 14, yRadius: 14)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()

        let text = "Drop recordings or a folder here"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: attrs)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var dropView: DropView!
    private var pathField: NSTextField!
    private var startButton: NSButton!
    private var progress: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var logView: NSTextView!

    private var pendingURLs: [URL] = []
    private var running = false

    // MARK: UI

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BatchWhisper", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BatchWhisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "BatchWhisper"
        window.center()

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        dropView = DropView(frame: NSRect(x: 20, y: 250, width: 480, height: 150))
        dropView.autoresizingMask = [.width, .minYMargin]
        dropView.onDrop = { [weak self] urls in self?.receive(urls) }
        content.addSubview(dropView)

        let chooseButton = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded
        chooseButton.frame = NSRect(x: 20, y: 210, width: 140, height: 30)
        chooseButton.autoresizingMask = [.minYMargin]
        content.addSubview(chooseButton)

        let pathLabel = makeLabel("Export folder:", size: 11, color: .secondaryLabelColor)
        pathLabel.frame = NSRect(x: 175, y: 216, width: 90, height: 18)
        pathLabel.autoresizingMask = [.minYMargin]
        content.addSubview(pathLabel)

        pathField = NSTextField(frame: NSRect(x: 265, y: 212, width: 235, height: 24))
        pathField.stringValue = "~/.whisper-extracts"
        pathField.placeholderString = "~/.whisper-extracts"
        pathField.autoresizingMask = [.minYMargin, .width]
        content.addSubview(pathField)

        startButton = NSButton(title: "Start", target: self, action: #selector(start))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.frame = NSRect(x: 20, y: 170, width: 480, height: 32)
        startButton.autoresizingMask = [.width, .minYMargin]
        startButton.isEnabled = false
        content.addSubview(startButton)

        progress = NSProgressIndicator(frame: NSRect(x: 20, y: 145, width: 480, height: 16))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.autoresizingMask = [.width, .minYMargin]
        content.addSubview(progress)

        statusLabel = makeLabel("Drop a folder of recordings to begin.", size: 12, color: .labelColor)
        statusLabel.frame = NSRect(x: 20, y: 120, width: 480, height: 18)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(statusLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 480, height: 92))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        scroll.documentView = logView
        content.addSubview(scroll)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func makeLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size)
        l.textColor = color
        return l
    }

    // MARK: Actions

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Select"
        if panel.runModal() == .OK {
            receive(panel.urls)
        }
    }

    private func receive(_ urls: [URL]) {
        pendingURLs = urls
        let files = collectAudioFiles(urls)
        if files.isEmpty {
            setStatus("No audio files found in the selection.")
            startButton.isEnabled = false
            return
        }
        setStatus("\(files.count) recording\(files.count == 1 ? "" : "s") ready. Press Start.")
        startButton.isEnabled = !running
    }

    @objc private func start() {
        guard !running else { return }
        let files = collectAudioFiles(pendingURLs)
        guard !files.isEmpty else { return }

        let exportDir = (pathField.stringValue as NSString).expandingTildeInPath
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: macWhisperBundleID) else {
            setStatus("Whisper Transcription (MacWhisper) not found.")
            return
        }

        running = true
        startButton.isEnabled = false
        progress.maxValue = Double(files.count)
        progress.doubleValue = 0
        logView.string = ""
        appendLog("Export folder: \(exportDir)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.process(files: files, exportDir: exportDir, appURL: appURL)
        }
    }

    // MARK: Batch engine (background thread)

    private let maxWaitPerFile = 600.0
    private let pollInterval = 0.1
    private let stabilityGap = 0.15
    private let settle = 0.5

    private func process(files: [URL], exportDir: String, appURL: URL) {
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)

        var done = 0
        for (i, file) in files.enumerated() {
            setStatus("Transcribing \(i + 1)/\(files.count): \(file.lastPathComponent)")

            let before = listFiles(exportDir)
            openInMacWhisper(file, appURL: appURL)

            if let produced = waitForNewTranscript(in: exportDir, excluding: before) {
                done += 1
                appendLog("✓ \(file.lastPathComponent)  →  \(produced)")
                DispatchQueue.main.async { self.progress.doubleValue = Double(done) }
                Thread.sleep(forTimeInterval: settle)
            } else {
                appendLog("✗ timed out on \(file.lastPathComponent) — stopping to keep order")
                break
            }
        }

        let finished = done
        DispatchQueue.main.async {
            self.running = false
            self.startButton.isEnabled = true
            self.setStatus("Done — transcribed \(finished)/\(files.count) in order.")
            NSSound(named: "Glass")?.play()
        }
    }

    private func openInMacWhisper(_ file: URL, appURL: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: cfg) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
    }

    private func waitForNewTranscript(in dir: String, excluding before: Set<String>) -> String? {
        var waited = 0.0
        while waited < maxWaitPerFile {
            Thread.sleep(forTimeInterval: pollInterval)
            waited += pollInterval

            for name in listFiles(dir) where !before.contains(name) {
                let path = (dir as NSString).appendingPathComponent(name)
                let s1 = fileSize(path)
                Thread.sleep(forTimeInterval: stabilityGap)
                waited += stabilityGap
                let s2 = fileSize(path)
                if s1 > 0 && s1 == s2 {
                    return name
                }
            }
        }
        return nil
    }

    // MARK: Helpers

    private func collectAudioFiles(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let kids = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for k in kids where audioExts.contains(k.pathExtension.lowercased()) {
                    out.append(k)
                }
            } else if audioExts.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        // Ascending by filename (oldest first) — timestamped names sort chronologically.
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func listFiles(_ dir: String) -> Set<String> {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    private func fileSize(_ path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? 0
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.stringValue = text }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async {
            self.logView.string += line + "\n"
            self.logView.scrollToEndOfDocument(nil)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
