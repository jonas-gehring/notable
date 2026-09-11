import AppKit
import ApplicationServices
import os

/// Reads one app's call window through Accessibility and turns it into a
/// `ScreenObservation` (Spec 24 §4.3).
///
/// Adapters are written per app **after** the Stufe-0 measurement (§4.1) with
/// `ScreenProbe` — none is guessed. Call UIs change with every release, and an
/// adapter that reads the wrong tile as the speaker writes a confident wrong
/// name, which is the one outcome this whole spec exists to avoid.
protocol CallScreenAdapter: Sendable {
    var bundleIDPrefixes: [String] { get }
    func observe(_ application: AXUIElement) -> ScreenObservation?
}

enum CallScreenAdapters {
    /// Empty until the measurement says which app exposes what.
    static let all: [any CallScreenAdapter] = []

    static func adapter(for bundleID: String) -> (any CallScreenAdapter)? {
        all.first { $0.bundleIDPrefixes.contains { bundleID.hasPrefix($0) } }
    }
}

/// Samples the call window while a recording runs: on its own utility queue,
/// never in the capture path, once a second — three samples over the 50 ms
/// budget in a row halve the rate. What it sees goes to `screen.jsonl` in the
/// spool (names and times only), so crash recovery still has it.
final class CallScreenObserver: @unchecked Sendable {
    static let budget: TimeInterval = 0.05
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "screen")

    private let queue = DispatchQueue(label: "de.jonasgehring.notable.screen", qos: .utility)
    private let adapter: any CallScreenAdapter
    private let application: AXUIElement
    private let spool: SpoolStore.Session?
    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 1
    private var overBudget = 0
    private var observations: [ScreenObservation] = []

    private init(adapter: any CallScreenAdapter, application: AXUIElement, spool: SpoolStore.Session?) {
        self.adapter = adapter
        self.application = application
        self.spool = spool
    }

    /// `nil` when switched off, when Accessibility is missing, or when no
    /// adapter knows the app — then there is simply nothing to observe.
    @MainActor
    static func start(bundleIDs: [String], spool: SpoolStore.Session?) -> CallScreenObserver? {
        guard DefaultsKey.screenSpeakerRecognition.value(), AXIsProcessTrusted() else { return nil }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, ScreenProbe.belongs(bundle, to: bundleIDs) else { continue }
            guard let adapter = CallScreenAdapters.adapter(for: bundle) else {
                log.notice("Kein Bildschirm-Adapter für \(bundle, privacy: .public)")
                continue
            }
            let observer = CallScreenObserver(
                adapter: adapter, application: AXUIElementCreateApplication(app.processIdentifier), spool: spool
            )
            observer.queue.async { observer.schedule() }
            return observer
        }
        return nil
    }

    /// Stops sampling and hands back everything seen.
    func stop() -> [ScreenObservation] {
        queue.sync {
            timer?.cancel()
            timer = nil
            return observations
        }
    }

    private func schedule() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    private func sample() {
        let began = Date()
        let observation = adapter.observe(application)
        let took = Date().timeIntervalSince(began)
        if let observation {
            observations.append(observation)
            if let spool { SpoolStore.appendScreenObservation(observation, to: spool) }
        }
        overBudget = took > Self.budget ? overBudget + 1 : 0
        if overBudget >= 3, interval < 8 {
            overBudget = 0
            interval *= 2
            Self.log.notice("Bildschirm-Abfrage über Budget — nur noch alle \(self.interval, privacy: .public) s")
            schedule()
        }
    }
}

/// Stufe 0's measuring tool (§4.1): writes the call window's accessibility tree
/// as **text** — roles, titles, descriptions, values — to
/// `~/Library/Logs/Notable/screen-probe/`. No image. Run it during a real call
/// in Teams, Zoom and Meet; the files decide which adapter is possible at all.
@MainActor
enum ScreenProbe {
    enum ProbeError: LocalizedError {
        case accessibilityMissing
        case noCallApp

        var errorDescription: String? {
            switch self {
            case .accessibilityMissing: String(localized: "Bedienungshilfen sind für Notable nicht erlaubt.")
            case .noCallApp: String(localized: "Kein laufender Call erkannt.")
            }
        }
    }

    static let maxNodes = 8000
    static let maxDepth = 40

    /// A running app's bundle id against the call's process ids. Both ways
    /// round: a web call reports its helper (`com.google.Chrome.helper`), the
    /// app that owns the window is `com.google.Chrome`.
    nonisolated static func belongs(_ bundleID: String, to processIDs: [String]) -> Bool {
        processIDs.contains { bundleID.hasPrefix($0) || $0.hasPrefix(bundleID) }
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Notable/screen-probe", isDirectory: true)
    }

    static func dump(bundleIDs: [String], callName: String) throws -> URL {
        guard AXIsProcessTrusted() else { throw ProbeError.accessibilityMissing }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleIdentifier.map { belongs($0, to: bundleIDs) } ?? false
        }), let bundle = app.bundleIdentifier else { throw ProbeError.noCallApp }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var lines = ["# \(callName) — \(app.localizedName ?? bundle) (\(bundle)), \(Date().formatted(.iso8601))"]
        let (count, millis) = walkTimed(element, into: &lines)
        lines.insert("# \(count) Elemente in \(millis) ms (Budget je Abfrage: 50 ms)", at: 1)

        // Chromium and WebKit build the tree of the web content only when an
        // app asks for it. Asking is itself part of the measurement (§4.1).
        if count < 200 {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var retry: [String] = []
            let (again, againMillis) = walkTimed(element, into: &retry)
            lines.append("")
            lines.append("## Nach AXManualAccessibility = true: \(again) Elemente in \(againMillis) ms")
            lines += retry
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(stamp)-\(bundle).txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func walkTimed(_ element: AXUIElement, into lines: inout [String]) -> (Int, Int) {
        let began = Date()
        var count = 0
        walk(element, depth: 0, lines: &lines, count: &count)
        return (count, Int(Date().timeIntervalSince(began) * 1000))
    }

    private static func walk(_ element: AXUIElement, depth: Int, lines: inout [String], count: inout Int) {
        guard depth <= maxDepth, count < maxNodes else { return }
        count += 1
        var fields = [string(element, kAXRoleAttribute) ?? "?"]
        for (label, attribute) in [("sub", kAXSubroleAttribute), ("title", kAXTitleAttribute),
                                   ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute),
                                   ("id", kAXIdentifierAttribute), ("help", kAXHelpAttribute)] {
            if let value = string(element, attribute), !value.isEmpty {
                fields.append("\(label)=\"\(value.prefix(160))\"")
            }
        }
        lines.append(String(repeating: "  ", count: depth) + fields.joined(separator: " "))
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { walk(child, depth: depth + 1, lines: &lines, count: &count) }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
