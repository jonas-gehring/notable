import AppKit
import SwiftUI

/// Reduce Motion for the HUD, read live and in exactly one place.
///
/// A closure, and `nonisolated(unsafe)`, for one reason: a test cannot toggle a
/// system setting, and "with Reduce Motion nothing animates" is a rule worth a
/// test rather than a screenshot (Spec 37 §3.1). It is written only from a
/// test and read only on the main actor.
///
/// Live, not a `static let`: that was the Spec 30 bug — the value was taken at
/// launch, so changing the setting did nothing until a restart.
enum HUDMotion {
    /// Set only by tests; `nil` means "ask the system".
    nonisolated(unsafe) static var override: Bool?

    static var isReduced: Bool {
        override ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Transient dictation HUD: a borderless, non-activating panel near the
/// bottom of the screen. It must never steal focus — becoming key would
/// break the paste-into-focused-field mechanic.
@MainActor
final class DictationOverlayController {
    enum OverlayState {
        case recording
        case transcribing
        /// The deliberate LLM round-trip after a dictation started with the
        /// second hotkey. Seconds, not milliseconds — so it says so.
        case enhancing
        /// The on-device text stage (Spec 32). Says nothing about leaving the
        /// device, because nothing does.
        case formatting
        /// A spoken command running on the selection (Spec 32 Stufe 2).
        case commanding
        case loadingModel
        /// What arrived (Spec 37 §3.2). Shown **after** the paste and after the
        /// save: the word count is a display, never a step in the dictation.
        /// A milestone replaces the number and stands a little longer.
        case done(words: Int, milestone: String?)
        case error(String)
        /// Something worth saying that is not a failure — the model swap, for
        /// instance. Same transient behaviour, different icon, because dressing
        /// good news as a warning trains people to ignore warnings.
        case notice(String)
    }

    final class Model: ObservableObject {
        @Published var state: OverlayState = .recording
        @Published var level: Float = 0
        @Published var partial = ""
        @Published var locked = false
        /// True while a stand-in model is producing the text. Said out loud:
        /// Tiny is markedly weaker, and unmarked output would read as Notable's
        /// normal quality.
        @Published var provisional = false
        /// The notch's rectangle in the panel's own coordinates, so the view can
        /// leave it empty. `nil` on every screen without one.
        @Published var notchCutout: CGRect?
        /// False when the Esc tap could not be created (Accessibility missing).
        /// The hint is then not shown at all — an exit that does nothing is
        /// worse than no exit hint.
        @Published var escapeAvailable = true
        /// Where the capsule sits inside the transparent panel. Centred at the
        /// bottom; trailing at the right edge, so a state that needs more words
        /// grows the capsule inwards instead of pulling it off the edge (Spec 28).
        @Published var alignment: Alignment = .center
        /// The second line of a failure: what to do (Spec 30 §3.6).
        @Published var hint: String?
        /// Bumped every time the capsule comes back from nothing, so the view
        /// can grow it out of the middle. A *state* change inside a visible
        /// capsule must not re-grow it — that would be a switch again, not an
        /// object (Spec 37 §3.2).
        @Published var appearance = 0
        /// True while an abort is leaving: the capsule shrinks to the height of
        /// the line instead of fading, which is the only way the HUD can say
        /// afterwards that the words are gone rather than in the field.
        @Published var departing = false
        /// Where the capsule sits in the panel (top-left origin), for the mouse
        /// tracking that lets only the capsule take a click (Spec 30 §3.9). Not
        /// published: it changes with every layout, and nothing draws it.
        var capsuleFrame: CGRect = .zero
        /// The cancel action; without one there is no button.
        var cancel: (() -> Void)?
    }

    private let model = Model()
    /// Readable inside the module for one reason: `DictationOverlayTests` asserts
    /// that this panel can never become key. That invariant is what makes the
    /// paste-into-the-focused-field mechanic work at all, and it is exactly the
    /// kind of rule a future refactor breaks silently — so it is worth a test
    /// even at the price of a non-private property.
    private(set) var panel: NSPanel?
    private var flashHideTask: Task<Void, Never>?
    private var delayedShowTask: Task<Void, Never>?
    /// Bumped by every `show` and `hide`, so a fade-out or a delayed state that
    /// is overtaken by something newer does nothing when it lands.
    private var visibilityGeneration = 0
    /// Watches the pointer while a cancellable state is up — see `trackMouse`.
    private var mouseTracker: Timer?

    /// What the capsule's "×" does (Spec 30 §3.9).
    var onCancel: (() -> Void)? {
        get { model.cancel }
        set { model.cancel = newValue }
    }

    private static var reduceMotion: Bool { HUDMotion.isReduced }
    /// The style the current panel was built for. A change swaps the hosted view,
    /// so switching the setting takes effect on the next dictation without a
    /// restart.
    private var builtStyle: OverlayStyle?

    /// Builds the panel and its hosting view without showing anything.
    ///
    /// Called once at launch (Spec 29): the first `show` used to construct the
    /// `NSPanel` and the SwiftUI hierarchy on the key-down path of the very first
    /// dictation, right where the microphone is being opened.
    func prepare() {
        _ = ensurePanel(style: OverlayStyle.current)
    }

    func show(_ state: OverlayState) {
        flashHideTask?.cancel()
        delayedShowTask?.cancel()
        visibilityGeneration += 1
        model.state = state
        switch state {
        case .recording:
            model.partial = ""
            model.hint = nil
        case .error, .notice:
            // The hint was set by the caller just before.
            model.level = 0
            model.locked = false
        default:
            model.level = 0
            model.locked = false
            model.hint = nil
        }
        let style = OverlayStyle.current
        // "Aus" is a deliberate option: whoever wants only the sound cue gets it.
        // An error still shows — swallowing a failure silently is not a display
        // preference.
        guard style != .off || isError(state) else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel(style: style)
        position(panel, style: style)
        let alreadyShown = panel.isVisible && panel.alphaValue > 0.99
        model.departing = false
        if !alreadyShown { model.appearance &+= 1 }
        panel.orderFrontRegardless() // never makeKey
        updateMouseTracking(style: style, state: state)
        // Appears like an object, not like a switch (Spec 30 §3.2). A state
        // change inside a visible panel does not fade again.
        guard !alreadyShown, !Self.reduceMotion else {
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.appearSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// The success moment (Spec 37 §3.2).
    ///
    /// Called after `Paster.insert` **and** after the save — the 700 ms are
    /// display time, not waiting time, and nothing in the dictation path waits
    /// for them. With the HUD set to "Aus" this shows nothing, like every other
    /// non-failure state.
    func flashDone(_ moment: DictationPipeline.SuccessMoment) {
        show(.done(words: moment.words, milestone: moment.milestone))
        let seconds = moment.milestone == nil ? Theme.Motion.doneSeconds : Theme.Motion.milestoneSeconds
        flashHideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    /// For states that are usually over before they are worth seeing
    /// (Spec 30 §3.3). A 119 ms transcription used to flash a spinner for a
    /// frame or two; now the waveform simply goes. Anything shown or hidden in
    /// the meantime wins.
    func showAfterDelay(_ state: OverlayState, delay: Duration = .milliseconds(300)) {
        delayedShowTask?.cancel()
        let generation = visibilityGeneration
        delayedShowTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.visibilityGeneration == generation else { return }
            self.show(state)
        }
    }

    // MARK: - Clicks (Spec 30 §3.9)

    /// The panel ignores the mouse — a 380 × 68 window of mostly nothing must
    /// never swallow a click meant for the app below. Only while the pointer is
    /// over the capsule, and only in a state that can be cancelled, does it take
    /// clicks, so the "×" works. Taking a click does not make it key: a
    /// borderless non-activating panel cannot become key, and
    /// `DictationOverlayTests` keeps checking exactly that.
    private func updateMouseTracking(style: OverlayStyle, state: OverlayState) {
        stopMouseTracking()
        guard style != .notch, state.isCancellable, model.cancel != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTracker = timer
    }

    private func trackMouse() {
        guard let panel, panel.isVisible else { return }
        let capsule = model.capsuleFrame
        let onScreen = CGRect(
            x: panel.frame.minX + capsule.minX,
            y: panel.frame.maxY - capsule.maxY,
            width: capsule.width,
            height: capsule.height
        )
        let over = capsule.width > 0 && onScreen.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == over {
            panel.ignoresMouseEvents = !over
        }
    }

    private func stopMouseTracking() {
        mouseTracker?.invalidate()
        mouseTracker = nil
        panel?.ignoresMouseEvents = true
    }

    /// "Aus" still shows failures and the model-swap notice — those are not a
    /// display preference.
    private func isError(_ state: OverlayState) -> Bool {
        switch state {
        case .error, .notice: true
        default: false
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    /// Live text while incremental decoding runs during recording.
    func updatePartial(_ text: String) {
        model.partial = text
    }

    /// Hands-free lock engaged (tap instead of hold).
    func updateLocked(_ locked: Bool) {
        model.locked = locked
    }

    func setProvisional(_ provisional: Bool) {
        model.provisional = provisional
    }

    /// Whether Esc actually reaches this recording — see `escapeAvailable`.
    func setEscapeAvailable(_ available: Bool) {
        model.escapeAvailable = available
    }

    /// Like `flashError`, for something that is not an error.
    func flashNotice(_ message: String, hint: String? = nil) {
        model.hint = hint
        show(.notice(message))
        flashHideTask = Task {
            try? await Task.sleep(for: .seconds(hint == nil ? 4 : 6))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    /// How the capsule leaves (Spec 37 §3.2).
    ///
    /// An abort has to look different from a success, because by the time the
    /// HUD is gone the difference — text in the field or no text at all — is
    /// no longer visible anywhere else.
    enum Departure {
        case fade
        case shrink
    }

    func hide(_ departure: Departure = .fade) {
        delayedShowTask?.cancel()
        visibilityGeneration += 1
        model.level = 0
        model.partial = ""
        model.locked = false
        stopMouseTracking()
        guard let panel, panel.isVisible else { return }
        guard !Self.reduceMotion else {
            model.departing = false
            panel.orderOut(nil)
            return
        }
        model.departing = departure == .shrink
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.disappearSeconds
            panel.animator().alphaValue = 0
        }
        // Ordered out after the fade, unless something was shown meanwhile.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Theme.Motion.disappearSeconds * 1000) + 10))
            guard let self, self.visibilityGeneration == generation else { return }
            self.panel?.orderOut(nil)
            self.model.departing = false
        }
    }

    /// Shows an error briefly, then hides — unless something newer was
    /// shown in the meantime (show() cancels the pending hide).
    func flashError(_ message: String, hint: String? = nil) {
        model.hint = hint
        show(.error(message))
        flashHideTask = Task {
            try? await Task.sleep(for: .seconds(hint == nil ? 4 : 6))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func ensurePanel(style: OverlayStyle) -> NSPanel {
        if let panel, builtStyle == style { return panel }
        if let panel {
            // Same panel, different view: everything below (non-activating,
            // ignores the mouse, never key) has to stay exactly as it is.
            panel.contentView = OverlayHostingView(rootView: content(for: style))
            builtStyle = style
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = OverlayHostingView(rootView: content(for: style))
        self.panel = panel
        builtStyle = style
        return panel
    }

    @ViewBuilder
    private func content(for style: OverlayStyle) -> some View {
        if style == .notch {
            NotchOverlayView(model: model)
        } else {
            DictationOverlayView(model: model)
        }
    }

    private func position(_ panel: NSPanel, style: OverlayStyle) {
        guard let screen = currentScreen() else { return }
        let measured = NotchGeometry.Screen(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea
        )
        // The notch layout spans the whole strip; the panel itself stays one
        // window and the view keeps the middle free.
        let size = style == .notch && measured.hasNotch
            ? CGSize(width: measured.frame.width, height: max(panel.frame.height, measured.safeAreaTop))
            : panel.frame.size

        switch NotchGeometry.placement(for: measured, size: size, style: style) {
        case .aroundNotch(let left, let right):
            let frame = left.union(right)
            panel.setFrame(frame, display: false)
            model.notchCutout = CGRect(
                x: left.maxX - frame.minX, y: 0,
                width: right.minX - left.maxX, height: frame.height
            )
        case .pillUnderMenuBar(let frame), .bottomCenter(let frame):
            model.notchCutout = nil
            model.alignment = .center
            panel.setFrame(CGRect(origin: frame.origin, size: panel.frame.size), display: false)
        case .rightEdge(let frame):
            model.notchCutout = nil
            model.alignment = .trailing
            panel.setFrame(CGRect(origin: frame.origin, size: panel.frame.size), display: false)
        }
    }

    /// The screen under the **pointer**, not `NSScreen.main`.
    ///
    /// `NSScreen.main` is the screen holding the key window — and this panel is
    /// never key while the field being dictated into belongs to another app
    /// entirely. The pointer is the better guess at where the user is looking,
    /// and this fixes the bottom overlay on a second display too.
    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

/// The bottom HUD: a small dark capsule that says what is happening with as
/// little furniture as possible.
///
/// **While recording it shows only the waveform.** The panel stays 380 × 68, but
/// the pill inside hugs its content and floats centred in it — a small object in
/// a large transparent window is what keeps it from reading as a banner. Every
/// other state has something to say and says it in words, because a waveform
/// cannot express "failed" or "the model is still loading".
private struct DictationOverlayView: View {
    @ObservedObject var model: DictationOverlayController.Model

    var body: some View {
        pill
            .padding(.trailing, model.alignment == .trailing ? NotchGeometry.rightEdgePadding : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
            .coordinateSpace(name: Self.space)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
    }

    private static let space = "overlay"

    /// Grown out of the middle. Starts true, because the first `appearance`
    /// bump arrives before this view is ever on screen.
    @State private var grown = true
    /// The slow 1,0 ↔ 1,02 of a hands-free recording listening to silence.
    @State private var breathing = false

    private var reduceMotion: Bool { HUDMotion.isReduced }

    private var pill: some View {
        HStack(spacing: 9) {
            if model.state.isCancellable, let cancel = model.cancel {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Abbrechen")
                .accessibilityLabel("Abbrechen")
            }
            content
            if model.provisional {
                Text("vorläufig")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .foregroundStyle(.primary)
        .background {
            // One material for every style (Spec 30 §3.1). The fixed black
            // capsule was a second identity next to the notch strip, and the
            // only surface in the app that ignored light and dark.
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.30), radius: 10, y: 3)
        // The level, made *visible* rather than merely drawn (Spec 37 §3.2):
        // the waveform says what was heard, this says how loudly. Capped at
        // 0,25 — a HUD that glows brightly is a HUD nobody wants twice.
        .shadow(color: Theme.accent.opacity(glow), radius: 14)
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(Self.space))
                Color.clear
                    .onAppear { model.capsuleFrame = frame }
                    .onChange(of: frame) { _, new in model.capsuleFrame = new }
            }
        }
        .scaleEffect(x: scale.width, y: scale.height, anchor: .center)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: model.locked)
        .animation(reduceMotion ? nil : Theme.Motion.disappear, value: model.departing)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: model.state.kindID)
        .onChange(of: model.appearance) { _, _ in grow() }
        .onChange(of: breathes) { _, on in breathe(on) }
    }

    /// One scale for three things that never happen at once: growing in,
    /// breathing, and shrinking away on an abort.
    private var scale: CGSize {
        if model.departing { return CGSize(width: 1, height: 0.2) }
        let value: CGFloat = grown ? (breathing ? 1.02 : 1) : 0.8
        return CGSize(width: value, height: value)
    }

    /// 0 → 0,25, following the same gain curve as the waveform so the two say
    /// the same thing about the same sound.
    private var glow: Double {
        guard case .recording = model.state, !reduceMotion else { return 0 }
        return min(1, pow(Double(max(0, model.level)) * 8, 0.7)) * 0.25
    }

    /// Only a *fixed* recording in silence breathes — a held key needs no sign
    /// of life, the hand on it is one.
    private var breathes: Bool {
        guard case .recording = model.state else { return false }
        return model.locked && model.level < 0.02
    }

    private func grow() {
        guard !reduceMotion else {
            grown = true
            return
        }
        grown = false
        withAnimation(Theme.Motion.state) { grown = true }
    }

    private func breathe(_ on: Bool) {
        guard on, !reduceMotion else {
            withAnimation(nil) { breathing = false }
            return
        }
        withAnimation(Theme.Motion.breathe) { breathing = true }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording:
            WaveformView(level: model.level)
            // The waveform carries the state; text only appears when it adds
            // something the waveform cannot. Holding the key needs no exit hint —
            // letting go *is* the exit. Hands-free does: nothing is being held,
            // so the way out has to be written down.
            if !model.partial.isEmpty {
                Text(String(model.partial.suffix(48)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if model.locked {
                Text(model.escapeAvailable ? "Taste beendet · Esc verwirft" : "Taste beendet")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .transcribing:
            // The waveform fell to a line on release and pulses while the words
            // are being made. The spinner is gone: a second, rounder thing
            // spinning next to a waveform was two objects for one wait.
            waitingLine()
            Text("Transkribiere…").font(.callout.weight(.medium))
        case .enhancing:
            // Orange, because this is the one state in which the text is not on
            // this Mac any more. The colour says it before the sentence does.
            waitingLine(tint: .orange)
            Image(systemName: "wand.and.stars").foregroundStyle(.orange)
            // Names the fact, not the vendor: which provider gets the text is a
            // setting, and a wrong vendor name here would be worse than none.
            Text("Verbessere… (Text verlässt das Gerät)").font(.callout.weight(.medium))
        case .loadingModel:
            // Not a pulsing line: a download is a wait with a cause, and the
            // cause is worth its own icon.
            Image(systemName: "arrow.down.circle.fill")
            Text("Modell lädt — Diktat folgt…").font(.callout.weight(.medium))
        case .formatting:
            waitingLine()
            Image(systemName: "text.badge.checkmark")
            Text("Formatiere…").font(.callout.weight(.medium))
        case .commanding:
            waitingLine()
            Image(systemName: "wand.and.rays")
            Text("Führe Befehl aus…").font(.callout.weight(.medium))
        case .done(let words, let milestone):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .symbolEffect(.bounce, options: .nonRepeating, value: model.appearance)
            if let milestone {
                Text(milestone).font(.callout.weight(.medium)).lineLimit(1)
            } else {
                Text("\(UsageMetrics.integer(words)) Wörter")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            messageStack(message)
        case .notice(let message):
            Image(systemName: "checkmark.circle.fill")
            messageStack(message)
        }
    }

    /// The fallen waveform: eighteen capsules at their floor height, pulsing
    /// for as long as something is still running.
    private func waitingLine(tint: Color = .primary) -> some View {
        WaveformView(level: 0, tint: tint, flat: true, pulsing: true)
    }

    /// What happened, and — when there is something to do — what to do.
    private func messageStack(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(message).font(.callout.weight(.medium)).lineLimit(2)
            if let hint = model.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var accessibilityText: String {
        switch model.state {
        case .recording: model.locked ? String(localized: "Aufnahme fixiert") : String(localized: "Aufnahme läuft")
        case .transcribing: String(localized: "Transkribiere")
        case .enhancing: String(localized: "Verbessere")
        case .formatting: String(localized: "Formatiere")
        case .commanding: String(localized: "Führe Befehl aus")
        case .loadingModel: String(localized: "Modell lädt")
        case .done(let words, let milestone):
            milestone ?? String(localized: "\(UsageMetrics.integer(words)) Wörter eingefügt")
        case .error(let message), .notice(let message):
            [message, model.hint].compactMap { $0 }.joined(separator: " ")
        }
    }
}

/// A scrolling waveform: the last `barCount` level samples, newest on the right,
/// each drawn as a capsule growing symmetrically from the centre line.
///
/// It replaced a five-bar meter that filled left to right. That was a *staircase*
/// and read as a volume gauge — the same picture a stereo shows. What dictation
/// wants is the shape of the speech itself, and a bar chart only gets there by
/// keeping history and moving: the bars say "it heard that word", not merely
/// "something is loud".
struct WaveformView: View {
    let level: Float
    var barCount = 18
    var maxHeight: CGFloat = 18
    var tint: Color = .primary
    /// Collapsed to a line (Spec 37 §3.2). The eighteen capsules fall to their
    /// floor height in one movement when the key is released, instead of the
    /// waveform being swapped for a spinner.
    var flat = false
    /// The line breathes while the words are still being made — the same
    /// signal as the spinner it replaced, in the shape that was already there.
    var pulsing = false

    @State private var history: [CGFloat] = []
    @State private var pulse = false

    private var reduceMotion: Bool { HUDMotion.isReduced }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< barCount, id: \.self) { index in
                let value = flat ? 0 : (index < history.count ? history[index] : 0)
                Capsule()
                    .fill(tint.opacity(0.30 + 0.70 * value))
                    .frame(width: 2.5, height: max(2.5, value * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .opacity(pulse ? 0.45 : 1)
        .animation(reduceMotion ? nil : Theme.Motion.level, value: history)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: flat)
        .onAppear {
            if history.isEmpty { history = Array(repeating: 0, count: barCount) }
            startPulse(pulsing)
        }
        .onChange(of: level) { _, new in push(new) }
        .onChange(of: pulsing) { _, on in startPulse(on) }
        .accessibilityHidden(true)
    }

    private func startPulse(_ on: Bool) {
        guard on, !reduceMotion else {
            withAnimation(nil) { pulse = false }
            return
        }
        withAnimation(Theme.Motion.breathe) { pulse = true }
    }

    private func push(_ raw: Float) {
        // Speech RMS sits around 0.02…0.15. The old five-bar meter multiplied by
        // 12, which saturated above 0.083 — fine when the answer is "how many of
        // five lamps", useless for a waveform, where everything above a normal
        // speaking voice would be one flat top. Gain 8 keeps the loud end inside
        // the range, and the 0.7 exponent lifts the quiet end so a mumble still
        // has a shape instead of a flat line.
        let value = CGFloat(min(1, pow(max(0, raw) * 8, 0.7)))
        var next = history.isEmpty ? Array(repeating: CGFloat(0), count: barCount) : history
        next.removeFirst()
        next.append(value)
        history = next
    }
}


/// The notch variant: the same states, laid out left and right of the cut-out.
///
/// Display only — `ignoresMouseEvents` stays true and the panel is never key.
/// A notch recorder invites being made clickable; deliberately not here, because a
/// clickable panel in the dictation path is exactly the class of bug the
/// "never become key" rule exists to prevent.
struct NotchOverlayView: View {
    @ObservedObject var model: DictationOverlayController.Model

    var body: some View {
        GeometryReader { proxy in
            let cutout = model.notchCutout
            HStack(spacing: 0) {
                side(width: leftWidth(in: proxy.size, cutout: cutout)) {
                    WaveformView(level: model.level, barCount: 12, maxHeight: 12, tint: .primary)
                }
                if let cutout {
                    Color.clear.frame(width: cutout.width)
                }
                side(width: rightWidth(in: proxy.size, cutout: cutout)) {
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background {
            // Only the strips get a background; the cut-out itself stays
            // transparent, which is what makes the notch look intentional.
            if model.notchCutout == nil {
                NotchShape().fill(.regularMaterial)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    @ViewBuilder
    private func side<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(width: width, alignment: .center)
            .background {
                // Beside a real cut-out each strip carries its own material; the
                // pill case paints one background for the whole shape instead.
                if model.notchCutout != nil {
                    NotchShape().fill(.regularMaterial)
                }
            }
    }

    private func leftWidth(in size: CGSize, cutout: CGRect?) -> CGFloat {
        guard let cutout else { return size.width / 2 }
        return max(0, cutout.minX)
    }

    private func rightWidth(in size: CGSize, cutout: CGRect?) -> CGFloat {
        guard let cutout else { return size.width / 2 }
        return max(0, size.width - cutout.maxX)
    }

    /// Plain `String`, so every branch has to go through `String(localized:)`
    /// itself — `Text(statusText)` looks the value up verbatim and would have
    /// rendered German inside an English window.
    private var statusText: String {
        switch model.state {
        case .recording:
            if !model.partial.isEmpty { return String(model.partial.suffix(40)) }
            if !model.escapeAvailable {
                return model.locked ? String(localized: "Fixiert") : String(localized: "Aufnahme…")
            }
            return model.locked
                ? String(localized: "Fixiert — Esc verwirft")
                : String(localized: "Aufnahme… (Esc verwirft)")
        case .transcribing: return String(localized: "Transkribiere…")
        case .enhancing: return String(localized: "Verbessere…")
        case .formatting: return String(localized: "Formatiere…")
        case .commanding: return String(localized: "Führe Befehl aus…")
        case .loadingModel: return String(localized: "Modell lädt…")
        case .done(let words, let milestone):
            // The notch has no room for a symbol *and* a sentence, so the words
            // carry the moment here.
            return milestone ?? String(localized: "✓ \(UsageMetrics.integer(words)) Wörter")
        case .error(let message): return message
        case .notice(let message): return message
        }
    }
}

/// Square at the top, rounded at the bottom — the shape of the notch itself, so
/// the pill under a menu bar reads as the same object as the strip beside a real
/// cut-out.
struct NotchShape: Shape {
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

extension DictationOverlayController.OverlayState {
    /// A recording or its processing can be aborted; a failure or a notice is
    /// already over.
    var isCancellable: Bool {
        switch self {
        case .recording, .transcribing, .enhancing, .formatting, .commanding, .loadingModel: true
        case .done, .error, .notice: false
        }
    }

    /// One value per *kind* of state, for `.animation(_:value:)`.
    ///
    /// Deliberately without the payload: a growing partial transcript or a
    /// changing word count must not restart the capsule's shape change, which
    /// is what an `Equatable` on the whole state would do.
    var kindID: String {
        switch self {
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .enhancing: "enhancing"
        case .formatting: "formatting"
        case .commanding: "commanding"
        case .loadingModel: "loadingModel"
        case .done: "done"
        case .error: "error"
        case .notice: "notice"
        }
    }
}

/// Hosts the HUD. Takes the first click, so the "×" works in a panel that is
/// never key — without this the first click would only focus a window that
/// cannot take focus, and nothing would happen.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
