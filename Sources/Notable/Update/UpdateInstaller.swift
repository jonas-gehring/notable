import AppKit
import Foundation

/// Downloads a GitHub release `.zip`, unpacks it, verifies its signature, and
/// hands off to a detached shell script that waits for this process to quit,
/// swaps the running bundle in place, and relaunches.
///
/// **The signature check is the whole trust story.** A `URLSession` download
/// carries no quarantine flag, so Gatekeeper never looks at the staged bundle;
/// without `verifySignature` anyone who could attach a zip to the release —
/// a compromised GitHub account, or just a wrongly named asset — got code
/// execution with this app's TCC grants (microphone, accessibility, calendar,
/// system audio). The header used to *assert* the download was signed with the
/// same identity; now it is checked, and a mismatch aborts the install.
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
    /// Whether a meeting is currently being captured. Injected so the installer
    /// keeps no reference to the meeting controller (and so tests can say no).
    private let isRecording: @MainActor () -> Bool

    init(session: URLSession = .shared, isRecording: @escaping @MainActor () -> Bool = { false }) {
        self.session = session
        self.isRecording = isRecording
    }

    // MARK: - Unattended install

    /// Whether a found update installs itself. Default **on**.
    ///
    /// Notable is a menu-bar app for one person: an update that waits for
    /// someone to open a settings pane and click a button is an update that does
    /// not happen. The swap takes about a second and the app comes back with its
    /// menu-bar item where it was, so the honest default is "just do it" — with
    /// the switch here for whoever disagrees, and the guards below so it never
    /// happens *while* something is going on.
    static let automaticInstallKey = "updateAutomaticInstall"

    static func automaticInstallEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticInstallKey) as? Bool ?? true
    }

    /// Why an unattended install did not happen. Purely for the log — none of
    /// these is worth interrupting anyone over.
    enum SkipReason: String {
        case switchedOff
        case busy
        case recording
        case windowOpen
        case noZip
    }

    /// Installs `info` without asking, but only when nothing would be lost by
    /// quitting right now.
    ///
    /// The three guards are the whole design. A capture in flight is obvious. An
    /// open Notable window is less so and matters just as much: settings being
    /// edited, a note being read, live notes being typed — a relaunch closes all
    /// of them, and "the app restarted while I was writing" is exactly the
    /// experience an automatic update must never produce. Everything else — the
    /// signature check, the swap script, the guarded rollback — is the same path
    /// the manual button takes.
    @discardableResult
    func installUnattended(
        _ info: UpdateInfo,
        defaults: UserDefaults = .standard,
        bundlePath: String = Bundle.main.bundlePath
    ) async -> SkipReason? {
        guard Self.automaticInstallEnabled(defaults) else { return .switchedOff }
        guard !phase.isBusy else { return .busy }
        guard !isRecording() else { return .recording }
        guard info.downloadURL.pathExtension.lowercased() == "zip" else { return .noZip }
        // `NSApp.windows` includes panels the user never sees (the dictation
        // overlay, the status item's own window), so only visible, titled
        // windows count as "the user is in the middle of something".
        let visible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        guard !visible else { return .windowOpen }

        await installAndRelaunch(info, bundlePath: bundlePath)
        return nil
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
        // Quitting mid-meeting kills the capture and leaves the spool to
        // recovery. An update is never urgent enough for that.
        guard !isRecording() else {
            phase = .failed(String(localized: "Update während einer Aufnahme nicht möglich — Meeting zuerst beenden."))
            return
        }

        do {
            phase = .downloading
            downloadProgress = nil
            let zip = try await download(info.downloadURL)
            defer { try? FileManager.default.removeItem(at: zip) }

            downloadProgress = nil
            phase = .unpacking
            let newApp = try unpack(zip, expectedName: (bundlePath as NSString).lastPathComponent)

            try Self.verifySignature(staged: newApp.path, matching: bundlePath)

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
            throw InstallError.download(String(localized: "Download fehlgeschlagen (HTTP \(code))."))
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
        guard status == 0 else { throw InstallError.unpack(String(localized: "Entpacken fehlgeschlagen (ditto \(status)).")) }

        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        // Prefer an exact name match; otherwise take the single app in the archive.
        guard let app = apps.first(where: { $0.lastPathComponent == expectedName }) ?? apps.first else {
            throw InstallError.unpack(String(localized: "Keine .app im Archiv gefunden."))
        }
        return app
    }

    // MARK: - Signature verification

    /// Refuses to install anything that is not signed by the same team as the
    /// bundle it would replace.
    ///
    /// Two questions, both of which have to be answered before the swap script
    /// exists: is the staged bundle intact and validly signed at all
    /// (`codesign --verify`), and is it *us* (same `TeamIdentifier`). A bundle
    /// with no team identifier — ad-hoc signed, or unsigned — never passes:
    /// "cannot tell" has to mean "do not install", or the check is decoration.
    nonisolated static func verifySignature(staged: String, matching destination: String) throws {
        let verify = Self.capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged])
        guard verify.status == 0 else {
            throw InstallError.signature(String(
                localized: "Signatur des Downloads ist ungültig — Update abgebrochen."
            ) + " (codesign \(verify.status))")
        }
        guard let downloaded = teamIdentifier(ofBundleAt: staged) else {
            throw InstallError.signature(String(
                localized: "Download trägt keine Team-ID — Update abgebrochen."
            ))
        }
        guard let installed = teamIdentifier(ofBundleAt: destination) else {
            throw InstallError.signature(String(
                localized: "Installierte App trägt keine Team-ID — Update abgebrochen."
            ))
        }
        guard downloaded == installed else {
            throw InstallError.signature(String(
                localized: "Download stammt von einem anderen Entwickler — Update abgebrochen."
            ) + " (\(downloaded) ≠ \(installed))")
        }
    }

    /// `codesign -dv` writes its fields to **stderr**, one `Key=Value` per line.
    nonisolated static func teamIdentifier(ofBundleAt path: String) -> String? {
        let result = capture("/usr/bin/codesign", ["-dv", "--verbose=4", path])
        guard result.status == 0 else { return nil }
        return parseTeamIdentifier(result.output)
    }

    /// Pure, so the parsing is testable without a signed bundle on disk.
    /// `not set` is what an ad-hoc signature reports — that is an absent team,
    /// not a team named "not set".
    nonisolated static func parseTeamIdentifier(_ codesignOutput: String) -> String? {
        for line in codesignOutput.split(separator: "\n") {
            guard let value = line.split(separator: "=", maxSplits: 1).last,
                  line.hasPrefix("TeamIdentifier=") else { continue }
            let team = value.trimmingCharacters(in: .whitespaces)
            return team.isEmpty || team == "not set" ? nil : team
        }
        return nil
    }

    /// Runs a tool and returns its exit status plus stdout **and** stderr —
    /// `codesign` reports on both depending on the flag.
    nonisolated private static func capture(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
        case signature(String)

        var errorDescription: String? {
            switch self {
            case let .download(msg), let .unpack(msg), let .signature(msg): msg
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

    # Still alive after the wait? Then the loop *timed out* rather than seeing
    # the app quit, and swapping now would gut a running bundle. Do nothing —
    # the user still has a working app and can retry the update.
    if kill -0 "$pid" 2>/dev/null; then
      rm -f "$0"
      exit 1
    fi

    rm -rf "$dest.old"
    # `|| exit 1`, not `2>/dev/null`: a failed move used to be swallowed, and
    # ditto then *merged* the new bundle into the old one — mixed files, invalid
    # signature, no way back.
    mv "$dest" "$dest.old" || { rm -f "$0"; exit 1; }
    if /usr/bin/ditto "$newapp" "$dest"; then
      rm -rf "$dest.old" "$newapp"
    else
      # Roll back to the previous bundle on any copy failure — but only if there
      # is one. Unconditional `rm -rf "$dest"` deleted the app outright whenever
      # `$dest.old` had never been created.
      if [ -d "$dest.old" ]; then
        rm -rf "$dest"
        mv "$dest.old" "$dest"
      fi
    fi
    open "$dest"
    rm -f "$0"
    """
}
