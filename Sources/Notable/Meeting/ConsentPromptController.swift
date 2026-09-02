import AppKit
import SwiftUI

/// Non-activating detection prompt: "Meeting erkannt" with Aufnehmen / Später and
/// a "Für diese App merken" toggle. It announces an auto-detected call and starts
/// recording only on an explicit "Aufnehmen" tap — never a silent auto-record.
///
/// Modelled on `DictationOverlayController` — the app is `LSUIElement` and this
/// surface **must never become key or main**, or the dictation paste-into-focused-
/// field mechanic breaks. It uses the same recipe as the dictation overlay
/// (`.nonactivatingPanel`, `.statusBar` level, `orderFrontRegardless()`, never
/// `makeKey`/`NSApp.activate`) with one deliberate difference: it accepts mouse
/// events (`ignoresMouseEvents = false`), because a `.nonactivatingPanel` delivers
/// clicks to its SwiftUI buttons **without** becoming key, so the buttons work while
/// keyboard focus stays in the user's call app. The backing panel additionally
/// forces `canBecomeKey`/`canBecomeMain` to `false` as belt-and-suspenders.
///
/// Since Notification Center carries the prompt (Spec 09), this panel
/// is the **fallback** for when notifications are not authorized — an
/// `LSUIElement` whose notifications are denied would otherwise never ask at all.
@MainActor
final class ConsentPromptController: ConsentPresenting {
    fileprivate final class Model: ObservableObject {
        @Published var sourceName = ""
        @Published var remember = false
        /// False for sources too coarse to remember (unidentified browser call).
        @Published var canRemember = true
    }

    private let model = Model()
    private var panel: NSPanel?
    private var onChoice: ((ConsentChoice) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    /// Presents the panel. `onChoice` is invoked **exactly once**: on a button tap,
    /// or after `timeout` seconds with no interaction (implicit Nein, `remember` off).
    /// If the call ends first, call `dismiss()` and `onChoice` is *not* invoked.
    func present(sourceName: String,
                 identityKey: String,
                 timeout: TimeInterval?,
                 onChoice: @escaping (ConsentChoice) -> Void) {
        // A newer prompt supersedes any pending one without resolving the old.
        // (The coordinator is single-flight per call, so this only guards races.)
        dismiss()

        model.sourceName = sourceName
        model.canRemember = MeetingIdentity.isRememberable(identityKey)
        model.remember = false
        self.onChoice = onChoice

        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless() // never makeKey / NSApp.activate

        guard let timeout else { return } // nil = wait for an answer or the call's end
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            // Timeout = implicit Nein; never remember an implicit decline.
            self?.resolve(ConsentChoice(kind: .no, remember: false))
        }
    }

    /// Tears the panel down without invoking `onChoice` — used when the call ended
    /// before the user chose (the coordinator handles stopping the recording).
    func dismiss() {
        timeoutTask?.cancel()
        timeoutTask = nil
        onChoice = nil
        panel?.orderOut(nil)
    }

    // MARK: - Button routing

    private func userTapped(_ kind: ConsentChoice.Kind) {
        resolve(ConsentChoice(kind: kind, remember: model.canRemember && model.remember))
    }

    private func resolve(_ choice: ConsentChoice) {
        guard let callback = onChoice else { return } // already resolved
        onChoice = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        panel?.orderOut(nil)
        callback(choice)
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true // reads as a card
        panel.ignoresMouseEvents = false // buttons must receive clicks
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: ConsentPromptView(
                model: model,
                onYes: { [weak self] in self?.userTapped(.yes) },
                onNo: { [weak self] in self?.userTapped(.no) }
            )
        )
        self.panel = panel
        return panel
    }

    /// Top-right under the menu bar, so it reads as coming from the menu-bar app.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.maxX - size.width - 16
        let y = visible.maxY - size.height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A panel that can never become key or main — the hard guarantee the dictation
/// paste mechanic depends on.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ConsentPromptView: View {
    @ObservedObject var model: ConsentPromptController.Model
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.title3)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting erkannt")
                        .font(.headline)
                    Text(model.sourceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if model.canRemember {
                Toggle("Für diese App merken", isOn: $model.remember)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Button("Später", action: onNo)
                Spacer()
                Button("Aufnehmen", action: onYes)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
