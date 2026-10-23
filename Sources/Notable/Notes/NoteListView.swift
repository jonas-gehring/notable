import AppKit
import SwiftUI

/// The notes window, laid out like Notes or Voice Memos: folders on the left,
/// the notes of the chosen folder in the middle, the note itself on the right.
/// The search field in the toolbar looks at titles, folders and, through
/// SQLite's FTS index, every transcript, so finding a meeting by something
/// that was said needs no second window. A normal window, so the
/// non-activating panel rules of the dictation overlay do not apply.
struct NoteListView: View {
    @EnvironmentObject private var noteManager: NoteManager

    @State private var scope: NoteScope? = .all
    @State private var selectedID: String?
    @State private var query = ""
    @State private var transcriptHits: Set<String> = []
    @State private var errorMessage: String?
    @State private var renameTarget: RecordingStore.Recording?
    @State private var draftTitle = ""
    @State private var newFolderTarget: RecordingStore.Recording?
    @State private var newFolderName = ""
    @State private var chatNote: RecordingStore.Recording?
    @State private var speakerNote: RecordingStore.Recording?
    @FocusState private var searchFocused: Bool
    /// Observed rather than injected: the "notes" scene hands this view only its
    /// `NoteManager`, and the folder error has to re-render the list when it
    /// appears.
    @ObservedObject private var notesFolder = AppContainer.shared.notesFolder

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            noteList
        } detail: {
            detail
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Titel, Ordner oder Transkript"))
        .searchFocused($searchFocused)
        .toolbar { toolbarItems }
        // ⌘F focuses the search field; a zero-size button in the
        // key-equivalent chain, because the window has no Find menu of its own.
        .background(
            Button { searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: [.command])
                .opacity(0)
                .accessibilityHidden(true)
        )
        .windowMinimum(WindowSize.notes)
        .windowFrameAutosave(WindowSize.notes)
        .task { await noteManager.reload() }
        .task(id: query) {
            // Debounced: the FTS query runs once typing pauses, not per key.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            transcriptHits = trimmed.isEmpty ? [] : await noteManager.transcriptMatches(for: trimmed)
        }
        .onChange(of: scope) { _, _ in
            if let id = selectedID, !visible.contains(where: { $0.id == id }) { selectedID = nil }
        }
        .onDisappear { noteManager.isEditingUserNotes = false }
        .sheet(item: $chatNote) { note in
            MeetingChatView(recording: note)
        }
        .sheet(item: $speakerNote) { note in
            SpeakerEditorView(recording: note)
                .environmentObject(noteManager)
        }
        .alert("Fehler", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Titel bearbeiten", isPresented: renameBinding) {
            TextField("Titel", text: $draftTitle)
            Button("Umbenennen") { commitRename() }
            Button("Abbrechen", role: .cancel) { renameTarget = nil }
        }
        .alert("Neuer Ordner", isPresented: newFolderBinding) {
            TextField("Ordnername", text: $newFolderName)
            Button("Anlegen") { commitNewFolder() }
            Button("Abbrechen", role: .cancel) { newFolderTarget = nil }
        } message: {
            Text("Der Ordner wird im Notizen-Ordner angelegt und die Notiz dorthin verschoben.")
        }
    }

    // MARK: - Seitenleiste

    private var sidebar: some View {
        List(selection: $scope) {
            Section("Notizen") {
                Label("Alle Notizen", systemImage: "tray.full")
                    .tag(NoteScope.all)
                Label("Inbox", systemImage: "tray")
                    .tag(NoteScope.folder(NoteManager.inboxFolder))
            }
            if !noteManager.projectFolders.isEmpty {
                Section("Projekte") {
                    ForEach(noteManager.projectFolders, id: \.self) { folder in
                        Label(folder, systemImage: "folder")
                            .tag(NoteScope.folder(folder))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
    }

    // MARK: - Liste

    private var visible: [RecordingStore.Recording] {
        NoteBrowser.visible(noteManager.notes, scope: scope ?? .all, query: query, transcriptHits: transcriptHits)
    }

    private var selected: RecordingStore.Recording? {
        selectedID.flatMap { id in noteManager.notes.first { $0.id == id } }
    }

    @ViewBuilder
    private var noteList: some View {
        VStack(spacing: 0) {
            // The folder error stands where the folder is needed (Spec 38 §3.3).
            if let error = notesFolder.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
            }
            if noteManager.notes.isEmpty {
                ContentUnavailableView(
                    "Keine Notizen",
                    systemImage: "doc.text",
                    description: Text("Aufgezeichnete Meetings erscheinen hier.")
                )
            } else if visible.isEmpty {
                ContentUnavailableView(
                    "Keine Treffer",
                    systemImage: "magnifyingglass",
                    description: Text("Weder Titel noch Ordner noch Transkript passen zur Eingabe.")
                )
            } else {
                List(visible, selection: $selectedID) { note in
                    row(for: note)
                        .tag(note.id)
                        .contextMenu { noteMenu(for: note) }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
    }

    private func row(for note: RecordingStore.Recording) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(note.title ?? String(localized: "Ohne Titel"))
                    .font(.headline)
                    .lineLimit(1)
                if note.titleIsAuto {
                    Text("auto")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            if let subtitle = note.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(note.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Notiz

    @ViewBuilder
    private var detail: some View {
        if let note = selected {
            NoteDetailView(note: note, onError: { errorMessage = $0 })
                .id(note.id)
        } else {
            ContentUnavailableView(
                "Keine Notiz ausgewählt",
                systemImage: "doc.text",
                description: Text("Wähle in der Liste eine Notiz aus.")
            )
        }
    }

    // MARK: - Toolbar und Menü

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let note = selected { chatNote = note }
            } label: {
                Label("Chat mit dem Meeting", systemImage: "bubble.left.and.bubble.right")
            }
            .help("Chat mit dem Meeting")
            .disabled(selected == nil)

            Button {
                if let note = selected { speakerNote = note }
            } label: {
                Label("Sprecher benennen", systemImage: "person.2")
            }
            .help("Sprecher benennen")
            .disabled(selected == nil)

            Menu {
                if let note = selected { noteMenu(for: note) }
            } label: {
                Label("Verschieben / im Finder zeigen", systemImage: "ellipsis.circle")
            }
            .help("Verschieben / im Finder zeigen")
            .disabled(selected == nil)

            Button {
                openFolder()
            } label: {
                Label("Notizen-Ordner öffnen", systemImage: "folder")
            }
            .help("Notizen-Ordner öffnen")
        }
    }

    @ViewBuilder
    private func noteMenu(for note: RecordingStore.Recording) -> some View {
        Button("Titel bearbeiten") {
            draftTitle = note.title ?? ""
            renameTarget = note
        }
        Section("Verschieben nach") {
            if note.folder != NoteManager.inboxFolder {
                Button("Inbox") { perform { try await noteManager.move(note, toFolder: NoteManager.inboxFolder) } }
            }
            ForEach(noteManager.projectFolders, id: \.self) { folder in
                if folder != note.folder {
                    Button(folder) { perform { try await noteManager.move(note, toFolder: folder) } }
                }
            }
            Button("Neuer Ordner…") {
                newFolderName = ""
                newFolderTarget = note
            }
        }
        Divider()
        Button("Im Finder zeigen") { revealInFinder(note) }
    }

    // MARK: - Actions

    /// Creates the folder if it is missing. `ensureExists` throws and records
    /// (Spec 27) rather than being `try?`-ed, and what it records is the red
    /// line above the list.
    private func openFolder() {
        do {
            try notesFolder.ensureExists()
            NSWorkspace.shared.open(notesFolder.folderURL)
        } catch {
            errorMessage = notesFolder.lastError ?? error.localizedDescription
        }
    }

    private func commitRename() {
        guard let note = renameTarget else { return }
        let title = draftTitle
        renameTarget = nil
        perform { try await noteManager.rename(note, to: title) }
    }

    private func commitNewFolder() {
        guard let note = newFolderTarget else { return }
        let name = newFolderName
        newFolderTarget = nil
        perform {
            let key = try noteManager.createFolder(named: name)
            try await noteManager.move(note, toFolder: key)
        }
    }

    private func revealInFinder(_ note: RecordingStore.Recording) {
        guard let path = note.markdownPath else {
            errorMessage = String(localized: "Für diese Notiz ist keine Datei hinterlegt.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Runs an async note operation and surfaces any thrown error in the alert.
    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var newFolderBinding: Binding<Bool> {
        Binding(get: { newFolderTarget != nil }, set: { if !$0 { newFolderTarget = nil } })
    }
}

/// The right column: one note as you would read it. Summary first, then your
/// own notes, then the transcript by speaker, all read from SQLite (the
/// source of truth), never from the `.md` file.
private struct NoteDetailView: View {
    let note: RecordingStore.Recording
    let onError: (String) -> Void

    @EnvironmentObject private var noteManager: NoteManager
    @AppStorage(DefaultsKey.summarizationProvider.key) private var providerID = DefaultsKey.summarizationProvider.fallback
    @StateObject private var notesEditor = NotesEditorProxy()
    @State private var segments: [RecordingStore.Segment] = []
    @State private var editingNotes = false
    @State private var draftNotes = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if let summary = note.summary, !summary.isEmpty {
                    section("Zusammenfassung") { markdown(summary) }
                }
                section("Eigene Notizen") { ownNotes }
                section("Transkript") { transcript }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(note.title ?? String(localized: "Ohne Titel"))
        .task { segments = await noteManager.segments(of: note.id) }
        // An open draft holds an update back — a restart would discard it
        // (Spec 25). Leaving the note discards it anyway, so that clears it.
        .onChange(of: editingNotes) { _, editing in noteManager.isEditingUserNotes = editing }
        .onDisappear { if editingNotes { noteManager.isEditingUserNotes = false } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(note.title ?? String(localized: "Ohne Titel"))
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(note.startedAt.formatted(date: .long, time: .shortened))
                if let folder = note.folder, !folder.isEmpty {
                    Text(verbatim: "· \(folder)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !note.participants.isEmpty || !note.attendees.isEmpty {
                Text((note.participants.isEmpty ? note.attendees : note.participants).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    // MARK: Zusammenfassung und eigene Notizen

    private func markdown(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(NoteBrowser.blocks(fromMarkdown: source).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text):
                    inline(text)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, Theme.Spacing.xs)
                case let .bullet(text, level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                            .foregroundStyle(.secondary)
                        inline(text)
                    }
                    .padding(.leading, CGFloat(level) * 16)
                case let .paragraph(text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Bold, italics, code and links inside one line; anything that does not
    /// parse is shown as written rather than dropped.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }

    @ViewBuilder
    private var ownNotes: some View {
        if editingNotes {
            VStack(alignment: .leading, spacing: 6) {
                Text("Eigene Notizen (kommen als Header ins .md und fließen in die Zusammenfassung ein)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The live notes editor, not a plain TextEditor over raw Markdown:
                // there, Tab typed a tab character that CommonMark reads as a code
                // block (Spec 26, Stufe 2).
                NotesFormatBar(editor: notesEditor)
                NotesTextEditor(text: $draftNotes, proxy: notesEditor, isEditable: true)
                    .frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(.quaternary))
                NotesEditorShortcuts(editor: notesEditor)
                HStack {
                    Button("Speichern") {
                        perform { try await noteManager.saveUserNotes(draftNotes, for: note); editingNotes = false }
                    }
                    Button("Speichern & neu zusammenfassen") {
                        busy = true
                        perform {
                            try await noteManager.saveUserNotes(draftNotes, for: note)
                            try await noteManager.resummarizeWithNotes(note, providerID: providerID)
                            busy = false
                            editingNotes = false
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Abbrechen") { editingNotes = false }
                }
                .disabled(busy)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if let notes = note.userNotes, !notes.isEmpty {
                    markdown(notes)
                } else {
                    Text("Keine eigenen Notizen.")
                        .foregroundStyle(.secondary)
                }
                Button("Eigene Notizen bearbeiten") {
                    draftNotes = note.userNotes ?? ""
                    editingNotes = true
                }
            }
        }
    }

    // MARK: Transkript

    @ViewBuilder
    private var transcript: some View {
        let turns = NoteBrowser.turns(segments)
        if turns.isEmpty {
            Text("Kein Transkript gespeichert.")
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(turn.speaker ?? String(localized: "Unbekannt"))
                                .font(.callout.weight(.semibold))
                            Text(NoteBrowser.timestamp(turn.start))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        Text(turn.text)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                busy = false
                onError(error.localizedDescription)
            }
        }
    }
}
