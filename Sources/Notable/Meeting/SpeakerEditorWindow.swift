import AppKit
import SwiftUI

/// The speaker dialog, opened from outside a window (Spec 36 §3.2).
///
/// The dialog itself is a sheet on the note list, which is the right place for
/// it — but the moment someone wants it is the moment the note is finished, and
/// then Notable is in the menu bar and the note list is closed. The
/// notification's "Sprecher benennen…" needs a way in that does not go through
/// that list, so the same view gets its own small window.
///
/// A plain `NSWindow` rather than a `Window` scene: the scenes are declared in
/// `NotableApp` and take no parameters, and this one is *about* one recording.
@MainActor
enum SpeakerEditorWindow {
    private static var window: NSWindow?

    /// Loads the recording and shows the dialog. A recording that no longer
    /// exists opens nothing — there is nothing to correct.
    static func present(recordingID: String) {
        Task {
            guard let loaded = try? await RecordingStore.shared.meeting(id: recordingID) else { return }
            show(loaded.recording)
        }
    }

    static func show(_ recording: RecordingStore.Recording) {
        close()
        let view = SpeakerEditorView(recording: recording, onClose: { close() })
            .environmentObject(AppContainer.shared.notes)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sprecher")
        window.contentView = NSHostingView(rootView: view)
        // The default would deallocate it the moment the red button is pressed,
        // while this type still holds the reference.
        window.isReleasedWhenClosed = false
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}
