import Foundation
import AVFoundation

/// Plays an entry's audio and publishes a live playhead so the transcript can
/// highlight and scrub. One player is shared across the app; loading a new entry
/// swaps the file. iOS-safe.
@MainActor
final class Player: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Points the player at a file without starting playback. No-op if already loaded.
    func load(_ url: URL) {
        if loadedURL == url {
            return
        }
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        loadedURL = url
    }

    func togglePlayPause() {
        guard let player else {
            return
        }
        if player.isPlaying {
            pause()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        currentTime = 0
        stopTicker()
    }

    /// Seeks to an absolute time (used when tapping a transcript timestamp).
    func seek(to time: Double) {
        guard let player else {
            return
        }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension Player: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
        }
    }
}
