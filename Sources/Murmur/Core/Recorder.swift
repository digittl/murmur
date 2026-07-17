import Foundation
import AVFoundation

/// Captures a voice note from the microphone straight into the app, so entries
/// can be created without importing a file. Writes a timestamped `.m4a` to a temp
/// folder (the filename encodes the date so the importer dates the entry
/// correctly), then hands the URL to the import queue. Fully local.
@MainActor
final class Recorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, recording
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// A 0…1 loudness value for the live meter, smoothed for a calm animation.
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var ticker: Timer?

    var isRecording: Bool { state == .recording }

    /// Requests mic access (once), starts recording. Sets `.denied`/`.failed` on error.
    func start() async {
        guard state != .recording else { return }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            state = .denied
            return
        }

        let name = Self.timestampName()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Murmur-recordings", isDirectory: true)
            .appendingPathComponent("\(name).m4a")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record() else {
                state = .failed("Couldn't start recording.")
                return
            }
            self.recorder = recorder
            self.currentURL = url
            elapsed = 0
            level = 0
            state = .recording
            startTicker()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops recording and returns the finished file's URL (nil if nothing usable).
    func stop() -> URL? {
        guard state == .recording, let recorder else {
            return nil
        }
        stopTicker()
        recorder.stop()
        let url = currentURL
        self.recorder = nil
        self.currentURL = nil
        state = .idle
        level = 0
        // Discard clips too short to be a real entry.
        if elapsed < 0.6 {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }

    /// Stops and discards the in-progress recording without producing a file.
    func cancel() {
        guard state == .recording else { return }
        stopTicker()
        recorder?.stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        currentURL = nil
        state = .idle
        elapsed = 0
        level = 0
    }

    // MARK: - Metering

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                recorder.updateMeters()
                // Map dBFS (-60…0) to 0…1, then ease toward it so the bar glides.
                let db = Double(recorder.averagePower(forChannel: 0))
                let target = max(0, min(1, (db + 60) / 60))
                self.level += (target - self.level) * 0.35
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: .now)
    }
}

extension Recorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.state = .failed(error?.localizedDescription ?? "Recording error.")
            self.stopTicker()
        }
    }
}
