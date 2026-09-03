import AppKit
import Foundation

/// Downloads a GitHub release `.zip`, unpacks it, and hands off to a detached
/// shell script that waits for this process to quit, swaps the running bundle in
/// place, and relaunches. One-click auto-update for a personal, self-signed tool:
/// there is no Gatekeeper prompt (the download is signed with the same stable
/// identity as the running app), so no user interaction is needed after the click.
///
/// Split so the risky part — the swap script — is a **pure** static function
/// (`swapScript`) that is unit-tested without touching the network or the disk.
@MainActor
final class UpdateInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case unpacking
        case installing
        case failed(String)

        /// True while an install is in flight (the UI disables re-entry).
        var isBusy: Bool {
            switch self {
            case .downloading, .unpacking, .installing: true
            case .idle, .failed: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// 0…1 while downloading, `nil` when the server sends no `Content-Length`.
    /// A ten-megabyte download on a slow line is long enough that "Wird geladen…"
    /// alone is indistinguishable from a hang.
    @Published private(set) var downloadProgress: Double?

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Downloads and installs `info`, then quits so the swap script can replace the
    /// bundle and relaunch. Returns only on failure (success ends in `NSApp.terminate`).
    ///
    /// - Parameter bundlePath: the running bundle to replace; defaults to
    ///   `Bundle.main.bundlePath` (wherever Notable is actually installed).
    func installAndRelaunch(_ info: UpdateInfo, bundlePath: String = Bundle.main.bundlePath) async {
        // Only a direct `.zip` asset can be auto-installed. If the update points at
        // the release *page* (no zip attached), fall back to opening the browser.
        guard info.downloadURL.pathExtension.lowercased() == "zip" else {
            NSWorkspace.shared.open(info.releaseURL)
            return
        }
        guard !phase.isBusy else { return }

        do {
            phase = .downloading
            downloadProgress = nil
            let zip = try await download(info.downloadURL)
            defer { try? FileManager.default.removeItem(at: zip) }

            downloadProgress = nil
            phase = .unpacking
            let newApp = try unpack(zip, expectedName: (bundlePath as NSString).lastPathComponent)

            phase = .installing
            try launchSwap(newApp: newApp, dest: bundlePath)

            // The script is now waiting on our PID. Quit so it can replace us.
            NSApp.terminate(nil)
        } catch {
            downloadProgress = nil
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    private func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("Notable-UpdateInstaller", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        // The async `download(for:delegate:)` takes a *per-task* delegate, which is
        // the only way to see byte counts without giving up async/await or building
        // a second URLSession just for this.
        let progress = DownloadProgressDelegate { [weak self] fraction in
            Task { @MainActor in self?.downloadProgress = fraction }
        }
        let (tempFile, response) = try await session.download(for: request, delegate: progress)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw InstallError.download("Download fehlgeschlagen (HTTP \(code)).")
        }
        // The URLSession temp file is deleted when this call returns — move it now.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notable-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tempFile, to: dest)
        return dest
    }

    /// Extracts the zip with `ditto` (which, unlike `unzip`, faithfully preserves the
    /// app bundle's code signature and extended attributes) and returns the `.app`.
    private func unpack(_ zip: URL, expectedName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notable-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let status = try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard status == 0 else { throw InstallError.unpack("Entpacken fehlgeschlagen (ditto \(status)).") }

        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        // Prefer an exact name match; otherwise take the single app in the archive.
        guard let app = apps.first(where: { $0.lastPathComponent == expectedName }) ?? apps.first else {
            throw InstallError.unpack("Keine .app im Archiv gefunden.")
        }
        return app
    }

    /// Writes the swap script and launches it detached. It receives the pid, the
    /// staged app, and the destination as positional arguments (never interpolated
    /// into the script body) so paths with spaces are safe.
    private func launchSwap(newApp: URL, dest: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-update-\(UUID().uuidString).sh")
        try Self.swapScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(pid), newApp.path, dest]
        try process.run() // detached — do NOT waitUntilExit; we are about to quit
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Reports `totalBytesWritten / totalBytesExpectedToWrite` for one download.
    /// `didFinishDownloadingTo` is required by the protocol but never used here —
    /// the async API takes the file itself.
    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        private let onProgress: @Sendable (Double?) -> Void

        init(onProgress: @escaping @Sendable (Double?) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite totalBytesExpectedToWrite: Int64) {
            // -1 means the server did not say how big it is; a made-up bar would be
            // worse than none, so pass nil and let the UI fall back to plain text.
            guard totalBytesExpectedToWrite > 0 else { return onProgress(nil) }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    enum InstallError: LocalizedError {
        case download(String)
        case unpack(String)

        var errorDescription: String? {
            switch self {
            case let .download(msg), let .unpack(msg): msg
            }
        }
    }

    // MARK: - Pure swap script (unit-tested)

    /// Positional args: `$1` = pid to wait on, `$2` = staged new app, `$3` = the
    /// bundle to replace. Waits up to ~20 s for the app to quit, moves the old
    /// bundle aside, copies the new one in (rolling back on failure), then relaunches.
    nonisolated static let swapScript = """
    #!/bin/sh
    pid="$1"
    newapp="$2"
    dest="$3"

    # Wait for the running app to quit (max ~20s), so we don't replace a live bundle.
    i=0
    while [ "$i" -lt 100 ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
      i=$((i + 1))
    done

    rm -rf "$dest.old"
    mv "$dest" "$dest.old" 2>/dev/null
    if /usr/bin/ditto "$newapp" "$dest"; then
      rm -rf "$dest.old" "$newapp"
    else
      # Roll back to the previous bundle on any copy failure.
      rm -rf "$dest"
      mv "$dest.old" "$dest"
    fi
    open "$dest"
    """
}
