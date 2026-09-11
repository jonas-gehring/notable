import AppKit
import SwiftUI

// The one notes editor. The live notes window and the note list both use it
// (Spec 26, Stufe 2): the note list used to edit "Eigene Notizen" in a plain
// `TextEditor` as raw Markdown, where Tab typed a tab character that CommonMark
// reads as the start of a code block. One implementation per concept, as in
// Spec 22.

// MARK: - Proxy

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

    typealias Position = (paragraph: Int, column: Int)

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
        transformSelection { NotesMarkdown.applying(block, to: $0, in: $1) }
    }

    /// ⌘] and the format-bar button; Tab on a list item lands here too.
    func indent() {
        transformSelection { NotesMarkdown.indenting($0, in: $1) }
    }

    /// ⌘[ and the format-bar button; ⇧Tab on a list item lands here too.
    func outdent() {
        transformSelection { NotesMarkdown.outdenting($0, in: $1) }
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
        render(NotesMarkdown.serialize(updated), caret: (paragraph, column))
    }

    /// The selection as a paragraph range, transformed, rendered back, and the
    /// selection restored — a multi-line indent keeps the lines selected, so a
    /// second Tab indents them again.
    private func transformSelection(_ transform: ([NotesLine], ClosedRange<Int>) -> [NotesLine]) {
        guard let textView, let storage = textView.textStorage else { return }
        let lines = NotesRichText.lines(from: storage)
        let selection = textView.selectedRange()
        let start = NotesRichText.position(in: storage, utf16Offset: selection.location)
        let end = NotesRichText.position(in: storage, utf16Offset: NSMaxRange(selection))
        let markdown = NotesMarkdown.serialize(transform(lines, start.paragraph...max(start.paragraph, end.paragraph)))
        // Tab on the first item of a list changes nothing; an undo step for
        // nothing would be noise.
        guard markdown != NotesMarkdown.serialize(lines) else { return }
        render(markdown, caret: start, selectionEnd: selection.length > 0 ? end : nil)
    }

    // MARK: Keys

    /// Tab / ⇧Tab. Returns `false` when the selection holds no list item, so
    /// Tab in body text still types a tab. ⇧Tab in body text does nothing — its
    /// default would move the focus out of the editor.
    fileprivate func handleTab(outdent: Bool) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let lines = NotesRichText.lines(from: storage)
        let selection = textView.selectedRange()
        let start = NotesRichText.position(in: storage, utf16Offset: selection.location).paragraph
        let end = NotesRichText.position(in: storage, utf16Offset: NSMaxRange(selection)).paragraph
        let touchesList = (start...max(start, end)).contains { lines.indices.contains($0) && lines[$0].block.isListItem }
        guard touchesList else { return outdent }
        if outdent { self.outdent() } else { indent() }
        return true
    }

    /// Return: continue a list at the same level, or step out when the item is
    /// empty. Returns `true` when it handled the key.
    fileprivate func handleReturn() -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        var lines = NotesMarkdown.normalized(NotesRichText.lines(from: storage))
        let position = NotesRichText.position(in: storage, utf16Offset: textView.selectedRange().location)
        guard lines.indices.contains(position.paragraph) else { return false }
        let current = lines[position.paragraph]
        guard current.block != .body else { return false }  // let AppKit do plain Returns

        // Return on an empty list item steps out — one level up, or out of the
        // list at level 0: the behaviour every list editor has, and the reason
        // you never need the mouse to get out.
        if current.block.isListItem, current.text.isEmpty {
            let updated = NotesMarkdown.leavingEmptyItem(at: position.paragraph, in: lines)
            render(NotesMarkdown.serialize(updated), caret: (position.paragraph, 0))
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
        lines.insert(NotesLine(current.block.continuation, String(content[cut...]), indent: current.indent),
                     at: position.paragraph + 1)
        render(NotesMarkdown.serialize(lines), caret: (position.paragraph + 1, 0))
        return true
    }

    /// Backspace at the very start of a formatted line steps out first — a
    /// nested item moves up a level, anything else loses its format — rather
    /// than merging into the line above; the same rule Apple Notes uses.
    fileprivate func handleBackspace() -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let lines = NotesRichText.lines(from: storage)
        let position = NotesRichText.position(in: storage, utf16Offset: selection.location)
        guard position.column == 0,
              lines.indices.contains(position.paragraph),
              lines[position.paragraph].block != .body else { return false }
        let updated = NotesMarkdown.backspacingAtLineStart(at: position.paragraph, in: lines)
        render(NotesMarkdown.serialize(updated), caret: (position.paragraph, 0))
        return true
    }

    /// Replaces the document and restores the caret (or selection). Wrapped in
    /// `shouldChangeText`/`didChangeText` so ⌘Z undoes a formatting change in
    /// one step, exactly like a typed one.
    private func render(_ markdown: String, caret: Position, selectionEnd: Position? = nil) {
        guard let textView, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: whole, replacementString: nil) else { return }
        let rendered = NotesRichText.attributed(markdown: markdown)
        storage.setAttributedString(rendered)
        textView.didChangeText()
        let start = NotesRichText.utf16Offset(in: rendered, paragraph: caret.paragraph, column: caret.column)
        let end = selectionEnd.map { NotesRichText.utf16Offset(in: rendered, paragraph: $0.paragraph, column: $0.column) } ?? start
        textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        // Keep typing in the format — and at the level — of the caret's line.
        let renderedLines = NotesRichText.lines(from: rendered)
        if renderedLines.indices.contains(caret.paragraph) {
            let line = renderedLines[caret.paragraph]
            textView.typingAttributes = NotesRichText.attributes(for: line.block, indent: line.indent)
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
        // Measured from the real paragraph start: `position.column` is clamped to
        // 0 everywhere inside the marker, so it cannot tell a click *on* the box
        // from one just after it — or from one on the tabs of its level.
        let start = NotesRichText.paragraphStartOffset(in: storage, paragraph: position.paragraph)
        if NotesRichText.isCheckboxHit(in: paragraphs[position.paragraph], atOffset: index - start) {
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

// MARK: - The editor

struct NotesTextEditor: NSViewRepresentable {
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
            // Tab used to fall through to NSTextView and insert "\t" before the
            // marker — "\t•\tText", which read back as body text with a literal
            // "•" in it. On a list item it now nests (Spec 26).
            case #selector(NSResponder.insertTab(_:)):
                return proxy.handleTab(outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return proxy.handleTab(outdent: true)
            default:
                return false
            }
        }
    }
}

// MARK: - Shared controls

/// The format controls both notes editors share: the same set Apple Notes puts
/// in its format menu, minus what makes no sense in a call — three heading
/// levels, the three list kinds, and indent/outdent. Every block button toggles:
/// pressing it on a line that already has that format returns the line to body
/// text, which is the only keyboard way back out of a list.
struct NotesFormatBar<Trailing: View>: View {
    let editor: NotesEditorProxy
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            blockButton("textformat.size.larger", .title, "Titel (⌘⌥1)")
            blockButton("textformat.size", .heading, "Überschrift (⌘⌥2)")
            blockButton("textformat.size.smaller", .subheading, "Unterüberschrift (⌘⌥3)")
            Divider().frame(height: 14)
            blockButton("list.bullet", .bullet, "Aufzählung (⌘⌥4)")
            blockButton("list.number", .numbered, "Nummerierte Liste (⌘⌥5)")
            blockButton("checklist", .checkbox(done: false), "Checkliste (⌘⌥6)")
            Divider().frame(height: 14)
            iconButton("decrease.indent", "Ausrücken (⌘[)") { editor.outdent() }
            iconButton("increase.indent", "Einrücken (⌘])") { editor.indent() }
            Spacer(minLength: 0)
            trailing
        }
    }

    private func blockButton(_ symbol: String, _ block: NotesBlock, _ help: LocalizedStringKey) -> some View {
        iconButton(symbol, help) { editor.applyBlock(block) }
    }

    /// `help` doubles as the accessibility label: an icon-only button is
    /// otherwise announced as "Taste" and nothing else.
    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button { action(); editor.focus() } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textEmphasis)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

extension NotesFormatBar where Trailing == EmptyView {
    init(editor: NotesEditorProxy) {
        self.init(editor: editor) { EmptyView() }
    }
}

/// The keyboard shortcuts of the format bar. They live on hidden buttons so
/// they work wherever the focus sits in the window, without stealing keys from
/// the editor's own handling of Return, Tab and Backspace.
struct NotesEditorShortcuts: View {
    let editor: NotesEditorProxy

    var body: some View {
        Group {
            block("1", .title)
            block("2", .heading)
            block("3", .subheading)
            block("4", .bullet)
            block("5", .numbered)
            block("6", .checkbox(done: false))
            Button("") { editor.toggleCheckboxAtCaret(); editor.focus() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { editor.indent(); editor.focus() }
                .keyboardShortcut("]", modifiers: .command)
            Button("") { editor.outdent(); editor.focus() }
                .keyboardShortcut("[", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func block(_ key: Character, _ block: NotesBlock) -> some View {
        Button("") { editor.applyBlock(block); editor.focus() }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
    }
}
