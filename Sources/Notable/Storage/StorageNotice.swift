import Foundation

/// The one line in the menu that says how much disk Notable is using — and
/// only once that has become a real number.
///
/// Seven weeks of use, 3,9 GB of meeting audio, and not a word anywhere. The
/// retention sweep exists and stays off by default, for good reason; what was
/// missing is the moment at which anyone would think to switch it on. This is
/// that moment, and nothing more: it opens the page where the decision is made,
/// it does not make the decision.
///
/// **Above a threshold, not always.** A permanent "2,1 GB" in the menu is
/// noise; a line that appears at five gigabytes is an answer to a question you
/// would otherwise never ask. The threshold is a constant in the code —
/// "ab wann darfst du mir sagen, dass du 5 GB belegst" is exactly the kind of
/// setting nobody wants to be asked about.
///
/// Push, not pull, for the same reason as ``UsageSummary``: a `.menu`-style
/// `MenuBarExtra` is built from `NSMenuItem`s and has no usable `onAppear`.
/// Refreshed at launch and after a meeting has been archived — the only two
/// moments at which this number moves by anything worth mentioning.
@MainActor
final class StorageNotice: ObservableObject {
    /// e.g. `Notable belegt 5,3 GB`, or `nil` below the threshold.
    @Published private(set) var line: String?

    func refreshSoon() {
        Task { await refresh() }
    }

    func refresh() async {
        let engine = ASREngineID.current
        update(with: await Task.detached {
            StorageFootprint.measure(modelEntries: ModelInventory.current(engine: engine))
        }.value)
    }

    /// For callers that have just measured anyway — the storage pane walks the
    /// same four directories every time it is opened or something is deleted,
    /// and walking them twice to answer the same question would be silly.
    func update(with footprint: StorageFootprint) {
        guard footprint.deservesMention else {
            line = nil
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: footprint.total, countStyle: .file)
        line = String(localized: "Notable belegt \(size) — aufräumen…")
    }
}
