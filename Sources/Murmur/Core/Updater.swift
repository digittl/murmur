import Foundation
import AppKit

/// Checks GitHub Releases for a newer build and installs it in place. The app is
/// distributed as a zip on the digittl/murmur releases page (not the App Store),
/// so this is a lightweight self-updater: fetch the latest release, compare the
/// version, download the `.app.zip`, and swap the running bundle via a small
/// detached shell helper that waits for us to quit, replaces the app, and
/// relaunches it. Fully user-initiated for the actual install step.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var state: State = .idle

    private let repo = "digittl/murmur"
    private let autoCheckKey = "MurmurAutoUpdate"

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Silent check on launch (honours the auto-check preference).
    func checkOnLaunch() async {
        guard autoCheckEnabled else { return }
        await check()
    }

    /// Queries the latest release and sets `available` if it's newer than us.
    func check() async {
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            state = .failed("Bad update URL.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else {
            state = .failed("Couldn't reach the update server.")
            return
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = root["body"] as? String ?? ""
        let assets = root["assets"] as? [[String: Any]] ?? []
        let zip = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".zip") }

        if Self.isNewer(latest, than: currentVersion), let zip, let zipURL = URL(string: zip) {
            available = Release(version: latest, notes: notes, zipURL: zipURL)
            state = .idle
        } else {
            available = nil
            state = .upToDate
        }
    }

    /// Downloads the update, unpacks it, and swaps the running bundle, then quits
    /// so the helper can relaunch the new version.
    func downloadAndInstall() async {
        guard let release = available else { return }
        state = .downloading

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MurmurUpdate-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let zipDest = tmp.appendingPathComponent("Murmur.app.zip")
        do {
            let (localURL, _) = try await URLSession.shared.download(from: release.zipURL)
            try FileManager.default.moveItem(at: localURL, to: zipDest)
        } catch {
            state = .failed("Download failed: \(error.localizedDescription)")
            return
        }

        state = .installing
        let extractDir = tmp.appendingPathComponent("extracted", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipDest.path, extractDir.path]
        try? unzip.run()
        unzip.waitUntilExit()

        let newApp = extractDir.appendingPathComponent("Murmur.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            state = .failed("The update package was invalid.")
            return
        }

        // Hand off to a detached helper: wait for us to quit, replace the bundle,
        // clear quarantine, relaunch. Then terminate so it can do its work.
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(appPath)"
        /usr/bin/ditto "\(newApp.path)" "\(appPath)"
        /usr/bin/xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null
        /usr/bin/open "\(appPath)"
        """
        let scriptURL = tmp.appendingPathComponent("install.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            state = .failed("Couldn't stage the installer.")
            return
        }

        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/sh")
        installer.arguments = [scriptURL.path]
        do {
            try installer.run()
        } catch {
            state = .failed("Couldn't launch the installer.")
            return
        }
        NSApp.terminate(nil)
    }

    /// Compares dotted version strings numerically (1.10.0 > 1.9.0).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ string: String) -> [Int] {
            string.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let new = parts(candidate), old = parts(current)
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
