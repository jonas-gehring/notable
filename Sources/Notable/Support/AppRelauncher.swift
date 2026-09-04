import AppKit

/// Restarts Notable as a fresh process.
///
/// One place, because it is needed in three: after a language change, after a
/// permission grant that macOS caches per-process (input monitoring,
/// accessibility), and from the onboarding tour. The three copies were
/// identical, which is the usual prelude to two of them being right.
///
/// `createsNewApplicationInstance` is what makes it work at all: without it
/// `openApplication` on the bundle that is already running just activates the
/// current process, and the terminate that follows leaves nothing behind.
/// `LSMultipleInstancesProhibited` does not interfere — the old instance is
/// gone by the time the new one finishes launching.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
