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
/// `NotesRichText` is the translation layer.
struct LiveNotesView: View {
    @EnvironmentObject private var notes: LiveNotesController
    @EnvironmentObject private var meeting: MeetingController
    @StateObject private var editor = NotesEditorProxy()
    @AppStorage("meetingNotesFloating") private var floating = true
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        .onReceive(clock) { now = $0 }
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
                Text(notes.isActive ? notes.title : "Kein Meeting aktiv")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textEmphasis)
                    .lineLimit(1)
                Text(notes.isActive
                     ? "Notizen kommen als „Eigene Notizen“ in die Notiz und in die Zusammenfassung."
                     : "Notizen gehören zu einer laufenden Aufnahme.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSubtle)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if notes.isActive {
                Text(LiveNotes.timestamp(elapsed: notes.elapsed(at: now)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSubtle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Format bar

    /// The same set Apple Notes puts in its format menu, minus what makes no
    /// sense in a call: three heading levels and the three list kinds. Every
    /// button toggles — pressing it on a line that already has that format
    /// returns the line to body text, which is the only keyboard way back out
    /// of a list.
    private var formatBar: some View {
        HStack(spacing: 4) {
            formatButton("textformat.size.larger", .title, "Titel (⌘⌥1)")
            formatButton("textformat.size", .heading, "Überschrift (⌘⌥2)")
            formatButton("textformat.size.smaller", .subheading, "Unterüberschrift (⌘⌥3)")
            Divider().frame(height: 14)
            formatButton("list.bullet", .bullet, "Aufzählung (⌘⌥4)")
            formatButton("list.number", .numbered, "Nummerierte Liste (⌘⌥5)")
            formatButton("checklist", .checkbox(done: false), "Checkliste (⌘⌥6)")
            Spacer(minLength: 0)
            Button("Zeitstempel") { insertTimestamp() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Fügt die Laufzeit an der Schreibmarke ein (⌘T).")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.windowBackground)
    }

    private func formatButton(_ symbol: String, _ block: NotesBlock, _ help: String) -> some View {
        Button { editor.applyBlock(block); editor.focus() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textEmphasis)
        .help(help)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if notes.isActive {
                // The shortcuts live on hidden buttons so they work wherever the
                // focus sits in this window, without stealing keys from the
                // editor's own handling of Return, Tab and Backspace.
                Group {
                    shortcutButton("1", .title)
                    shortcutButton("2", .heading)
                    shortcutButton("3", .subheading)
                    shortcutButton("4", .bullet)
                    shortcutButton("5", .numbered)
                    shortcutButton("6", .checkbox(done: false))
                    Button("") { editor.toggleCheckboxAtCaret(); editor.focus() }
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("") { insertTimestamp() }
                        .keyboardShortcut("t", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

                Text("⌘⌥1–6 formatiert · ⌘⏎ hakt ab · ⌘T stempelt")
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

    private func shortcutButton(_ key: Character, _ block: NotesBlock) -> some View {
        Button("") { editor.applyBlock(block); editor.focus() }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
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

// MARK: - NSTextView bridge

/// Handle onto the live `NSTextView`. SwiftUI's `TextEditor` exposes neither the
/// caret nor text attributes, and a notes field you can only append to is the
/// wrong tool for a live call.
///
/// Every formatting operation follows the same three steps: read the editor out
/// as lines, transform them with the pure functions in `NotesMarkdown`, render
/// the result back and put the caret where the user left it. Going through
/// Markdown each time is what keeps the visible document and the stored buffer
/// from ever disagreeing.
@MainActor
final class NotesEditorProxy: ObservableObject {
    fileprivate weak var textView: NSTextView?
    /// Set by the editor so a programmatic re-render can publish immediately,
    /// rather than waiting for a change notification that will not come.
    fileprivate var publish: ((String) -> Void)?

    var caretUTF16Offset: Int? {
        guard let textView else { return nil }
        return textView.selectedRange().location
    }

    /// Character before the caret in the *rendered* text — what ⌘T needs to
    /// decide whether it must open a new line.
    var characterBeforeCaret: Character? {
        guard let textView else { return nil }
        return LiveNotes.character(in: textView.string, beforeUTF16Offset: textView.selectedRange().location)
    }

    /// Inserts at the caret, replacing any selection. Goes through
    /// `insertText(_:replacementRange:)` so undo and the change notification
    /// (which writes back into the binding) behave like normal typing.
    func insertAtCaret(_ string: String) {
        guard let textView else { return }
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    // MARK: Formatting

    /// Applies a block kind to every line the selection touches.
    func applyBlock(_ block: NotesBlock) {
        guard let textView, let storage = textView.textStorage else { return }
        let lines = NotesRichText.lines(from: storage)
        let selection = textView.selectedRange()
        let start = NotesRichText.position(in: storage, utf16Offset: selection.location)
        let end = NotesRichText.position(in: storage, utf16Offset: selection.location + selection.length)
        let updated = NotesMarkdown.applying(block, to: lines, in: start.paragraph...max(start.paragraph, end.paragraph))
        render(NotesMarkdown.serialize(updated), caretParagraph: start.paragraph, column: start.column)
    }

    /// ⌘⏎ and clicking the box both land here.
    func toggleCheckboxAtCaret() {
        guard let textView, let storage = textView.textStorage else { return }
        let position = NotesRichText.position(in: storage, utf16Offset: textView.selectedRange().location)
        toggleCheckbox(atParagraph: position.paragraph, keepingColumn: position.column)
    }

    fileprivate func toggleCheckbox(atParagraph paragraph: Int, keepingColumn column: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let lines = NotesRichText.lines(from: storage)
        let updated = NotesMarkdown.togglingCheckbox(at: paragraph, in: lines)
        guard updated != lines else { return }
        render(NotesMarkdown.serialize(updated), caretParagraph: paragraph, column: column)
    }

    /// Return: continue a list, or leave it when the item is empty.
    /// Returns `true` when it handled the key.
    fileprivate func handleReturn() -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        var lines = NotesRichText.lines(from: storage)
        let position = NotesRichText.position(in: storage, utf16Offset: textView.selectedRange().location)
        guard lines.indices.contains(position.paragraph) else { return false }
        let current = lines[position.paragraph]
        guard current.block != .body else { return false }  // let AppKit do plain Returns

        // Return on an empty list item ends the list instead of adding another
        // empty one — the behaviour every list editor has, and the reason you
        // never need the mouse to get out.
        if current.block.isListItem, current.text.isEmpty {
            lines[position.paragraph].block = .body
            render(NotesMarkdown.serialize(lines), caretParagraph: position.paragraph, column: 0)
            return true
        }

        // Split at the caret so Return in the middle of a line behaves normally.
        // `column` counts UTF-16 units (what NSTextView reports), so the cut has
        // to be found through the UTF-16 view — stepping Characters would land
        // in the wrong place as soon as a note contains an emoji.
        let content = current.text
        let utf16 = content.utf16
        let clamped = min(position.column, utf16.count)
        let cut = String.Index(utf16.index(utf16.startIndex, offsetBy: clamped), within: content) ?? content.endIndex
        lines[position.paragraph].text = String(content[content.startIndex..<cut])
        lines.insert(NotesLine(current.block.continuation, String(content[cut...])), at: position.paragraph + 1)
        render(NotesMarkdown.serialize(lines), caretParagraph: position.paragraph + 1, column: 0)
        return true
    }

    /// Backspace at the very start of a formatted line strips the format first,
    /// rather than merging into the line above — the same rule Apple Notes uses.
    fileprivate func handleBackspace() -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        var lines = NotesRichText.lines(from: storage)
        let position = NotesRichText.position(in: storage, utf16Offset: selection.location)
        guard position.column == 0,
              lines.indices.contains(position.paragraph),
              lines[position.paragraph].block != .body else { return false }
        lines[position.paragraph].block = .body
        render(NotesMarkdown.serialize(lines), caretParagraph: position.paragraph, column: 0)
        return true
    }

    /// Replaces the document and restores the caret. Wrapped in
    /// `shouldChangeText`/`didChangeText` so ⌘Z undoes a formatting change in one
    /// step, exactly like a typed one.
    private func render(_ markdown: String, caretParagraph: Int, column: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: whole, replacementString: nil) else { return }
        let rendered = NotesRichText.attributed(markdown: markdown)
        storage.setAttributedString(rendered)
        textView.didChangeText()
        let caret = NotesRichText.utf16Offset(in: rendered, paragraph: caretParagraph, column: column)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        // Keep typing in the format of the line the caret landed on.
        let rendered_lines = NotesRichText.lines(from: rendered)
        if rendered_lines.indices.contains(caretParagraph) {
            textView.typingAttributes = NotesRichText.attributes(for: rendered_lines[caretParagraph].block)
        }
        publish?(markdown)
    }
}

// MARK: - The text view

/// `NSTextView` that knows about checkboxes and refuses foreign formatting.
private final class NotesTextView: NSTextView {
    weak var proxy: NotesEditorProxy?

    /// Clicking a "☐" ticks it instead of placing the caret in front of it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: point), let storage = textStorage else {
            super.mouseDown(with: event)
            return
        }
        let position = NotesRichText.position(in: storage, utf16Offset: index)
        let paragraphs = storage.string.components(separatedBy: "\n")
        guard paragraphs.indices.contains(position.paragraph) else {
            super.mouseDown(with: event)
            return
        }
        let paragraph = paragraphs[position.paragraph]
        let isCheckbox = paragraph.hasPrefix("☐\t") || paragraph.hasPrefix("☑\t")
        // Measured from the real paragraph start: `position.column` is clamped to
        // 0 everywhere inside the marker, so it cannot tell a click *on* the box
        // from one just after it.
        let start = NotesRichText.paragraphStartOffset(in: storage, paragraph: position.paragraph)
        if isCheckbox, index - start < NotesRichText.markerLength(of: paragraph) {
            proxy?.toggleCheckbox(atParagraph: position.paragraph, keepingColumn: 0)
            return
        }
        super.mouseDown(with: event)
    }

    /// Index of the character under a point, or `nil` past the end of the text.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let inset = textContainerInset
        let adjusted = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        let glyph = layoutManager.glyphIndex(for: adjusted, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Notes are handed to a model verbatim; pasted fonts and colours have no
    /// business in the buffer, and a pasted heading font would lie about the
    /// block kind. Paste as plain text, always.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

private struct NotesTextEditor: NSViewRepresentable {
    @Binding var text: String
    let proxy: NotesEditorProxy
    let isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NotesTextView()
        textView.proxy = proxy
        textView.delegate = context.coordinator
        // Rich text so headings and list indents render; foreign formatting is
        // kept out by `paste` above rather than by disabling attributes.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Smart quotes/dashes rewrite what you typed; notes are fed to a model
        // verbatim, so leave the text alone.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textStorage?.setAttributedString(NotesRichText.attributed(markdown: text))
        textView.typingAttributes = NotesRichText.attributes(for: .body)
        textView.isEditable = isEditable

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        proxy.textView = textView
        proxy.publish = { [binding = $text] markdown in binding.wrappedValue = markdown }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NotesTextView else { return }
        proxy.textView = textView
        proxy.publish = { [binding = $text] markdown in binding.wrappedValue = markdown }
        // Only on a genuine external change (a new meeting clearing the buffer,
        // or a recovered spool): re-rendering what the user is typing would
        // reset the caret on every keystroke.
        if NotesRichText.markdown(from: textView.attributedString()) != text {
            textView.textStorage?.setAttributedString(NotesRichText.attributed(markdown: text))
        }
        textView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Serialise, never re-render: the visible document is authoritative
            // while the user types, and re-rendering here would fight the caret.
            text.wrappedValue = NotesRichText.markdown(from: textView.attributedString())
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let proxy = (textView as? NotesTextView)?.proxy else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return proxy.handleReturn()
            case #selector(NSResponder.deleteBackward(_:)):
                return proxy.handleBackspace()
            default:
                return false
            }
        }
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
