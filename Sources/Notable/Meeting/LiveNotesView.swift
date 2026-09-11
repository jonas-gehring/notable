import AppKit
import SwiftUI

/// The window you type into while the call runs. Floats above the meeting app
/// (including a full-screen Zoom/Teams) so it stays reachable without leaving
/// the call, and its editor is a normal first responder — which means the
/// dictation hotkey works into it: hold, speak, release, and the polished text
/// lands in the notes.
///
/// Unlike `DictationOverlay` this window *must* become key (you type in it).
/// That is safe: the "never become key" rule protects the paste-into-the-focused
/// -field mechanic of the overlay, and here the notes editor *is* the field the
/// user means.
///
/// The editor is WYSIWYG: headings are bigger, bullets are real "•", checkboxes
/// are tickable "☐". No Markdown is visible — but the buffer
/// `LiveNotesController` owns stays Markdown, so the spool mirror, the crash
/// recovery and the verbatim hand-off to the summarizer are unchanged.
/// `NotesRichText` is the translation layer; the editor itself is shared with
/// the note list (`NotesTextEditor`).
struct LiveNotesView: View {
    @EnvironmentObject private var notes: LiveNotesController
    @EnvironmentObject private var meeting: MeetingController
    @StateObject private var editor = NotesEditorProxy()
    @AppStorage(DefaultsKey.meetingNotesFloating.key) private var floating = DefaultsKey.meetingNotesFloating.fallback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if notes.isActive { formatBar; Divider() }
            NotesTextEditor(text: $notes.text, proxy: editor, isEditable: notes.isActive)
                .frame(minHeight: 180)
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 300)
        .background(Theme.windowBackground)
        .background(FloatingWindowConfigurator(floating: floating))
        .onChange(of: notes.isActive) { _, active in
            if active { editor.focus() }
        }
        .task { if notes.isActive { editor.focus() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: notes.isActive ? "record.circle" : "note.text")
                .foregroundStyle(notes.isActive ? Theme.accent : Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(notes.isActive ? notes.title : String(localized: "Kein Meeting aktiv"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textEmphasis)
                    .lineLimit(1)
                Text(notes.isActive
                     ? String(localized: "Notizen kommen als „Eigene Notizen“ in die Notiz und in die Zusammenfassung.")
                     : String(localized: "Notizen gehören zu einer laufenden Aufnahme."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSubtle)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if notes.isActive {
                // Its own small view, so the second hand does not re-evaluate
                // the whole window. `body` here contains the editor bridge, and
                // `NotesTextEditor.updateNSView` serializes the entire attributed
                // document back to Markdown for a comparison — once per second,
                // while someone is typing into it, and formerly also with no
                // meeting running at all.
                ElapsedLabel(notes: notes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Format bar

    private var formatBar: some View {
        NotesFormatBar(editor: editor) {
            Button("Zeitstempel") { insertTimestamp() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Fügt die Laufzeit an der Schreibmarke ein (⌘T).")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.windowBackground)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if notes.isActive {
                NotesEditorShortcuts(editor: editor)
                Button("") { insertTimestamp() }
                    .keyboardShortcut("t", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)

                Text("⌘⌥1–6 formatiert · Tab rückt ein · ⌘⏎ hakt ab · ⌘T stempelt")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                Button("Meeting beenden") { meeting.toggle() }
                    .disabled(meeting.state == .processing)
            } else {
                Button("Meeting aufzeichnen") { meeting.toggle() }
                    .disabled(meeting.state == .processing)
                // Where the notes just went — the buffer clears the moment the
                // meeting ends, so say what happened to it.
                if let url = meeting.lastNoteURL {
                    Button("Letzte Notiz öffnen") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: 0)
                Toggle("Immer im Vordergrund", isOn: $floating)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// ⌘T drops the elapsed time in at the caret. The leading-newline decision is
    /// pure (`LiveNotes.timestampInsertion`) and unit-tested; the caret lookup
    /// reads the *rendered* text, because markers shift every offset away from
    /// what the Markdown buffer would report.
    private func insertTimestamp() {
        guard notes.isActive else { return }
        let insertion = LiveNotes.timestampInsertion(
            elapsed: notes.elapsed(at: Date()),
            characterBeforeCaret: editor.characterBeforeCaret
        )
        editor.insertAtCaret(insertion)
        // Clicking the button moved first responder off the editor; typing
        // should continue right after the stamp, not nowhere.
        editor.focus()
    }
}

/// Lifts the notes window above other apps — including a full-screen call —
/// because a note window you have to hunt for behind Zoom is a note window you
/// do not use. `Window` scenes gained a SwiftUI `windowLevel` modifier only in
/// macOS 15; the deployment target is 14.4, so reach for the `NSWindow`.
private struct FloatingWindowConfigurator: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // The view has no window during the first update pass.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = floating ? .floating : .normal
            window.collectionBehavior = floating
                ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                : [.managed]
        }
    }
}


/// The elapsed-time readout, ticking on its own.
///
/// Split out of `LiveNotesView` so the clock redraws a `Text` rather than the
/// whole window — and so it only runs while a meeting does.
private struct ElapsedLabel: View {
    @ObservedObject var notes: LiveNotesController
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(LiveNotes.timestamp(elapsed: notes.elapsed(at: now)))
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textSubtle)
            .onReceive(clock) { now = $0 }
    }
}
