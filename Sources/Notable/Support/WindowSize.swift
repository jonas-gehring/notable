import AppKit
import SwiftUI

/// Every window's size in one place (Spec 33 §3.4).
///
/// Each window used to carry three numbers that did not agree: a `defaultSize`
/// on the scene, a `frame(minWidth:minHeight:)` in the view, and whatever the
/// user dragged it to — which was forgotten on the next open, because nothing
/// saved a frame. The scene and the view now read the same two sizes, and
/// `windowFrameAutosave` remembers where the window was.
enum WindowSize {
    struct Spec: Sendable {
        let id: String
        let ideal: CGSize
        let minimum: CGSize
    }

    static let notes = Spec(id: "notes", ideal: CGSize(width: 980, height: 620), minimum: CGSize(width: 760, height: 420))
    static let stats = Spec(id: "stats", ideal: CGSize(width: 640, height: 620), minimum: CGSize(width: 620, height: 600))
    static let meetingNotes = Spec(id: "meetingNotes", ideal: CGSize(width: 380, height: 320), minimum: CGSize(width: 380, height: 300))
    static let settings = Spec(id: "settings", ideal: CGSize(width: 760, height: 520), minimum: CGSize(width: 700, height: 460))

    static let all = [notes, stats, meetingNotes, settings]
}

extension View {
    /// The view's minimum, from the same table as the scene's default size.
    func windowMinimum(_ spec: WindowSize.Spec) -> some View {
        frame(minWidth: spec.minimum.width, minHeight: spec.minimum.height)
    }

    /// Remembers the window's frame under a stable name and restores it on the
    /// next open.
    func windowFrameAutosave(_ spec: WindowSize.Spec) -> some View {
        background(WindowAutosaveAccessor(name: "Notable.window.\(spec.id)"))
    }
}

/// Reaches the hosting `NSWindow`, which SwiftUI does not expose, to set its
/// autosave name once it exists.
private struct WindowAutosaveAccessor: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [name] in
            apply(name, to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(name, to: view.window)
    }

    private func apply(_ name: String, to window: NSWindow?) {
        guard let window, window.frameAutosaveName != name else { return }
        // Restore first — `setFrameAutosaveName` would otherwise save the
        // default frame over the one the user left.
        window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
    }
}
