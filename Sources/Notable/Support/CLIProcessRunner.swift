import Darwin
import Foundation

/// Runs a headless AI CLI and returns its stdout.
///
/// Extracted from `ClaudeCodeCLIProvider` unchanged when a second and third CLI
/// arrived: the hard part here is not the invocation, it is the shutdown, and
/// duplicating that per tool would mean duplicating every lesson in it — the
/// grandchild processes that inherit the pipe, the CLI that ignores SIGTERM, the
/// continuation that must resume exactly once. `tool` only names the culprit in
/// error messages.
enum CLIProcessRunner {
/// Geteilter Zustand eines CLI-Laufs. readability-/terminationHandler und
/// Watchdog laufen auf beliebigen GCD-Queues — alles Veränderliche liegt
/// hinter dem Lock. `claimResume` garantiert genau ein Resume: doppelt
/// wäre ein Crash, keins ein ewiger Hänger.
private final class CLIRunState: @unchecked Sendable {
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle

    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var resumed = false
    private var timedOut = false
    private var exited = false

    init(stdout: FileHandle, stderr: FileHandle) {
        stdoutHandle = stdout
        stderrHandle = stderr
    }

    func appendStdout(_ data: Data) { lock.withLock { stdoutData.append(data) } }
    func appendStderr(_ data: Data) { lock.withLock { stderrData.append(data) } }
    var stdout: Data { lock.withLock { stdoutData } }
    var stderr: Data { lock.withLock { stderrData } }

    func markTimedOut() { lock.withLock { timedOut = true } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    func markExited() { lock.withLock { exited = true } }
    var hasExited: Bool { lock.withLock { exited } }

    func claimResume() -> Bool {
        lock.withLock {
            if resumed { return false }
            resumed = true
            return true
        }
    }
}

/// The PATH a child CLI is started with.
///
/// An app launched from Finder or as a login item inherits launchd's
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — nothing else. `claude` happens to be
/// a native Mach-O and survives that, but an npm-installed CLI is a
/// `#!/usr/bin/env node` script: `CLIToolLocator` finds the script, the shebang
/// then fails to find `node`, and the whole thing surfaces as
/// "Exit-Code 127: env: node: No such file". The directories the locator
/// searches are exactly the ones such a CLI's runtime lives in.
private static func childEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let inherited = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
    var seen = Set<String>()
    let merged = (CLIToolLocator.searchPaths + inherited + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        .filter { seen.insert($0).inserted }
    environment["PATH"] = merged.joined(separator: ":")
    return environment
}

/// Runs a headless CLI and returns its stdout.
///
/// Cancelling the calling task terminates the process. Without that, a
/// `withDeadline` that gave up after 15 s left `claude -p` running for the full
/// 300 s timeout with a dangling continuation, and a retry started a second one
/// next to it.
static func run(
    tool: String,
    executable: String,
    arguments: [String],
    stdin input: String,
    timeout: TimeInterval = 300
) async throws -> String {
    // Handed to the cancellation handler, which runs outside the continuation
    // body and on an arbitrary thread — hence the lock inside.
    let handle = RunHandle()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
        // Cancelled before the process even started: do not launch one.
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = childEnvironment()
        // Scratch cwd: the transcript is untrusted input — do not
        // hand the CLI a real project directory as working context.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        process.currentDirectoryURL = scratch

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = CLIRunState(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        let watchdogs = WatchdogBox()
        let finish: @Sendable (Result<String, Error>) -> Void = { result in
            guard state.claimResume() else { return }
            state.stdoutHandle.readabilityHandler = nil
            state.stderrHandle.readabilityHandler = nil
            try? state.stdoutHandle.close()
            try? state.stderrHandle.close()
            // The three watchdog stages are scheduled up to timeout + 6 s out
            // and captured `process`; without this they keep it (and the run
            // state) alive for the full timeout after a successful run.
            watchdogs.cancelAll()
            handle.clear()
            continuation.resume(with: result)
        }

        // Kein readDataToEndOfFile: EOF kommt erst, wenn *alle* Schreiber
        // weg sind — die node-Enkelprozesse der CLI erben den fd, und ein
        // SIGTERM-resistenter Enkel hielte den Leser (und damit die
        // Continuation) für immer fest. Stattdessen häppchenweise sammeln;
        // das Fertig-Signal ist die Termination, nicht der Pipe-EOF.
        state.stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } // EOF
            else { state.appendStdout(data) }
        }
        state.stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { state.appendStderr(data) }
        }

        process.terminationHandler = { process in
            state.markExited()
            let status = process.terminationStatus
            let signalled = process.terminationReason == .uncaughtSignal
            // Nachfrist: gepufferter Output trudelt nach der Termination
            // noch über die readabilityHandler ein.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if state.didTimeOut {
                    finish(.failure(SummarizationError.requestFailed(
                        String(localized: "\(tool) antwortete nicht innerhalb von \(Int(timeout)) s und wurde beendet.")
                    )))
                } else if status != 0 {
                    let stderr = String(data: state.stderr, encoding: .utf8) ?? ""
                    let hint = signalled ? String(localized: " (durch Signal beendet)") : ""
                    finish(.failure(SummarizationError.requestFailed(
                        "\(tool) Exit-Code \(status)\(hint): \(String(stderr.prefix(300)))"
                    )))
                } else {
                    finish(.success(String(data: state.stdout, encoding: .utf8) ?? ""))
                }
            }
        }

        do {
            try process.run()
        } catch {
            finish(.failure(SummarizationError.requestFailed(
                String(localized: "\(tool) ließ sich nicht starten: \(error.localizedDescription)")
            )))
            return
        }

        // Throwing write: an early-exiting CLI (broken pipe) must not
        // raise an uncatchable NSException. Auf eigener Queue — bei
        // Transkripten > Pipe-Puffer blockiert write, bis die CLI liest.
        let stdinWriter = DispatchWorkItem {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: stdinWriter)

        // Watchdog in drei Stufen: SIGTERM (höflich), 3 s später SIGKILL
        // (die CLI darf SIGTERM ignorieren), weitere 3 s später notfalls
        // selbst resumen — der Aufrufer darf unter keinen Umständen hängen.
        // hasExited-Guards statt cancel(): kein Signal an eine ggf.
        // wiederverwendete PID. Nach Resume sind alle Stufen No-ops.
        let sigterm = DispatchWorkItem {
            guard !state.hasExited else { return }
            state.markTimedOut()
            process.terminate()
        }
        let sigkill = DispatchWorkItem {
            guard !state.hasExited else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        let lastResort = DispatchWorkItem {
            finish(.failure(SummarizationError.requestFailed(
                String(localized: "\(tool) antwortete nicht innerhalb von \(Int(timeout)) s und wurde beendet.")
            )))
        }
        let queue = DispatchQueue.global()
        watchdogs.store([sigterm, sigkill, lastResort])
        queue.asyncAfter(deadline: .now() + timeout, execute: sigterm)
        queue.asyncAfter(deadline: .now() + timeout + 3, execute: sigkill)
        queue.asyncAfter(deadline: .now() + timeout + 6, execute: lastResort)

        // Same shutdown sequence the watchdog uses, reachable from cancellation:
        // SIGTERM, then SIGKILL for a CLI that ignores it. `finish` resumes
        // exactly once, so an arriving termination handler is a no-op.
        handle.arm {
            guard !state.hasExited else { return }
            process.terminate()
            queue.asyncAfter(deadline: .now() + 3) {
                guard !state.hasExited else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            finish(.failure(CancellationError()))
        }
        // Cancellation that landed between the guard above and `arm`.
        if Task.isCancelled { handle.cancel() }
        }
    } onCancel: {
        handle.cancel()
    }
}

/// Holds the terminate closure for the cancellation handler, which runs on an
/// arbitrary thread and may fire before the process exists or after it is gone.
private final class RunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var terminate: (() -> Void)?
    private var cancelled = false

    func arm(_ action: @escaping () -> Void) {
        let fireNow: Bool = lock.withLock {
            if cancelled { return true }
            terminate = action
            return false
        }
        if fireNow { action() }
    }

    func cancel() {
        let action: (() -> Void)? = lock.withLock {
            cancelled = true
            defer { terminate = nil }
            return terminate
        }
        action?()
    }

    func clear() { lock.withLock { terminate = nil } }
}

/// The scheduled watchdog work items, so a finished run can cancel them.
private final class WatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DispatchWorkItem] = []

    func store(_ new: [DispatchWorkItem]) { lock.withLock { items = new } }
    func cancelAll() {
        let pending: [DispatchWorkItem] = lock.withLock { defer { items = [] }; return items }
        pending.forEach { $0.cancel() }
    }
}
}
