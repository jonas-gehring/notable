import AppKit
import SwiftUI

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
        case loadingModel
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
    }

    private let model = Model()
    /// Readable inside the module for one reason: `DictationOverlayTests` asserts
    /// that this panel can never become key. That invariant is what makes the
    /// paste-into-the-focused-field mechanic work at all, and it is exactly the
    /// kind of rule a future refactor breaks silently — so it is worth a test
    /// even at the price of a non-private property.
    private(set) var panel: NSPanel?
    private var flashHideTask: Task<Void, Never>?
    /// The style the current panel was built for. A change swaps the hosted view,
    /// so switching the setting takes effect on the next dictation without a
    /// restart.
    private var builtStyle: OverlayStyle?

    func show(_ state: OverlayState) {
        flashHideTask?.cancel()
        model.state = state
        if case .recording = state {
            model.partial = ""
        } else {
            model.level = 0
            model.locked = false
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
        panel.orderFrontRegardless() // never makeKey
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

    /// Like `flashError`, for something that is not an error.
    func flashNotice(_ message: String) {
        show(.notice(message))
        flashHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        model.level = 0
        model.partial = ""
        model.locked = false
        panel?.orderOut(nil)
    }

    /// Shows an error briefly, then hides — unless something newer was
    /// shown in the meantime (show() cancels the pending hide).
    func flashError(_ message: String) {
        show(.error(message))
        flashHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func ensurePanel(style: OverlayStyle) -> NSPanel {
        if let panel, builtStyle == style { return panel }
        if let panel {
            // Same panel, different view: everything below (non-activating,
            // ignores the mouse, never key) has to stay exactly as it is.
            panel.contentView = NSHostingView(rootView: content(for: style))
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
        panel.contentView = NSHostingView(rootView: content(for: style))
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

    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
    }

    private var pill: some View {
        HStack(spacing: 9) {
            content
            if model.provisional {
                Text("vorläufig")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.78))
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.30), radius: 10, y: 3)
        .animation(Self.reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.85),
                   value: model.locked)
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
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if model.locked {
                Text("Taste beendet · Esc verwirft")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Transkribiere…").font(.callout.weight(.medium))
        case .enhancing:
            Image(systemName: "wand.and.stars")
            // Names the fact, not the vendor: which provider gets the text is a
            // setting, and a wrong vendor name here would be worse than none.
            Text("Verbessere… (Text verlässt das Gerät)").font(.callout.weight(.medium))
        case .loadingModel:
            Image(systemName: "arrow.down.circle.fill")
            Text("Modell lädt — Diktat folgt…").font(.callout.weight(.medium))
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.callout.weight(.medium)).lineLimit(2)
        case .notice(let message):
            Image(systemName: "checkmark.circle.fill")
            Text(message).font(.callout.weight(.medium)).lineLimit(2)
        }
    }

    private var accessibilityText: String {
        switch model.state {
        case .recording: model.locked ? "Aufnahme fixiert" : "Aufnahme läuft"
        case .transcribing: "Transkribiere"
        case .enhancing: "Verbessere"
        case .loadingModel: "Modell lädt"
        case .error(let message): message
        case .notice(let message): message
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
    var tint: Color = .white

    @State private var history: [CGFloat] = []

    private static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< barCount, id: \.self) { index in
                let value = index < history.count ? history[index] : 0
                Capsule()
                    .fill(tint.opacity(0.30 + 0.70 * value))
                    .frame(width: 2.5, height: max(2.5, value * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .animation(Self.reduceMotion ? nil : .easeOut(duration: 0.12), value: history)
        .onAppear { if history.isEmpty { history = Array(repeating: 0, count: barCount) } }
        .onChange(of: level) { _, new in push(new) }
        .accessibilityHidden(true)
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

    private var statusText: String {
        switch model.state {
        case .recording:
            if !model.partial.isEmpty { return String(model.partial.suffix(40)) }
            return model.locked ? "Fixiert — Esc verwirft" : "Aufnahme… (Esc verwirft)"
        case .transcribing: return "Transkribiere…"
        case .enhancing: return "Verbessere…"
        case .loadingModel: return "Modell lädt…"
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
