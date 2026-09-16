import AppKit
import SwiftUI

/// The note-management window: every meeting note, newest first, with inline
/// title editing, a folder-move picker, and reveal-in-Finder. A normal window,
/// so the non-activating panel rules of the dictation overlay do not apply.
struct NoteListView: View {
    @EnvironmentObject private var noteManager: NoteManager

    @State private var editingID: String?
    @State private var draftTitle = ""
    @State private var newFolderTarget: RecordingStore.Recording?
    @State private var newFolderName = ""
    @State private var errorMessage: String?
    @State private var notesEditingID: String?
    @State private var draftNotes = ""
    @StateObject private var notesEditor = NotesEditorProxy()
    @State private var busy = false
    @State private var chatNote: RecordingStore.Recording?
    @State private var speakerNote: RecordingStore.Recording?
    @AppStorage(DefaultsKey.summarizationProvider.key) private var providerID = DefaultsKey.summarizationProvider.fallback
    @State private var query = ""
    @State private var hoveredID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    /// Observed rather than injected: the "notes" scene hands this view only its
    /// `NoteManager`, and the folder error has to re-render this toolbar when it
    /// appears.
    @ObservedObject private var notesFolder = AppContainer.shared.notesFolder

    var body: some View {
        VStack(spacing: 0) {
            // The folder error stands where the folder is needed (Spec 38 §3.3).
            // It used to live inside a menu submenu — closed at exactly the
            // moment a note could not be written.
            if let error = notesFolder.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
            }
            list
        }
        .toolbar { toolbarItems }
        // ⌘F focuses the field. SwiftUI's own search-focus binding is macOS 15
        // and the deployment target is 14.4, so this is a zero-size button in
        // the key-equivalent chain instead.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command])
                .opacity(0)
                .accessibilityHidden(true)
        )
        .windowMinimum(WindowSize.notes)
        .windowFrameAutosave(WindowSize.notes)
        .task { await noteManager.reload() }
        // An open draft holds an update back — a restart would discard it
        // (Spec 25). Closing the window discards it anyway, so that clears it.
        .onChange(of: notesEditingID) { _, id in noteManager.isEditingUserNotes = id != nil }
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
        .alert("Neuer Ordner", isPresented: newFolderBinding) {
            TextField("Ordnername", text: $newFolderName)
            Button("Anlegen") { commitNewFolder() }
            Button("Abbrechen", role: .cancel) { newFolderTarget = nil }
        } message: {
            Text("Der Ordner wird im Notizen-Ordner angelegt und die Notiz dorthin verschoben.")
        }
    }

    // MARK: - Liste und Toolbar

    @ViewBuilder
    private var list: some View {
        if noteManager.notes.isEmpty {
            ContentUnavailableView(
                "Keine Notizen",
                systemImage: "doc.text",
                description: Text("Aufgezeichnete Meetings erscheinen hier.")
            )
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "Keine Treffer",
                systemImage: "magnifyingglass",
                description: Text("Kein Titel und kein Ordner passt zur Eingabe.")
            )
        } else {
            List(filtered) { note in
                row(for: note)
            }
            .listStyle(.inset)
        }
    }

    /// A local filter over what is on screen — title, subtitle, folder. The
    /// full-text search across every transcript is its own window (the second
    /// toolbar button), because it reads SQLite's FTS index rather than this
    /// list; the two are different questions and the toolbar says so.
    private var filtered: [RecordingStore.Recording] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return noteManager.notes }
        return noteManager.notes.filter { note in
            [note.title, note.subtitle, note.folder]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            TextField("Notizen filtern", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .focused($searchFocused)
        }
        ToolbarItem(placement: .automatic) {
            Button {
                openWindow(id: "search")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .help("Volltext über alle Transkripte durchsuchen")
            .accessibilityLabel("Volltext durchsuchen")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                openFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Notizen-Ordner öffnen")
            .accessibilityLabel("Notizen-Ordner öffnen")
        }
    }

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

    // MARK: - Row

    @ViewBuilder
    private func row(for note: RecordingStore.Recording) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            rowHeader(for: note)
            if notesEditingID == note.id {
                notesEditor(for: note)
            }
        }
        .padding(Theme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall)
            .fill(hoveredID == note.id ? Theme.hover : .clear))
        .onHover { inside in
            if inside {
                hoveredID = note.id
            } else if hoveredID == note.id {
                hoveredID = nil
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.appear, value: hoveredID)
        .transition(.opacity)
    }

    @ViewBuilder
    private func rowHeader(for note: RecordingStore.Recording) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if editingID == note.id {
                    TextField("Titel", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(note) }
                        .onExitCommand { editingID = nil }
                } else {
                    HStack(spacing: 6) {
                        Text(note.title ?? String(localized: "Ohne Titel"))
                            .font(.headline)
                        if note.titleIsAuto {
                            Text("auto")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let subtitle = note.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(note.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let folder = note.folder, !folder.isEmpty {
                        Text("· \(folder)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            rowActions(for: note)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowActions(for note: RecordingStore.Recording) -> some View {
        HStack(spacing: 2) {
            Button {
                chatNote = note
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.borderless)
            .help("Chat mit dem Meeting")
            .accessibilityLabel("Chat mit dem Meeting")

            Button {
                speakerNote = note
            } label: {
                Image(systemName: "person.2")
            }
            .buttonStyle(.borderless)
            .help("Sprecher benennen")
            .accessibilityLabel("Sprecher benennen")

            Button {
                toggleNotes(note)
            } label: {
                Image(systemName: (note.userNotes?.isEmpty == false) ? "note.text.badge.plus" : "note.text")
            }
            .buttonStyle(.borderless)
            .help("Eigene Notizen")
            .accessibilityLabel("Eigene Notizen bearbeiten")

            Button {
                beginRename(note)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Titel bearbeiten")
            .accessibilityLabel("Titel bearbeiten")

            Menu {
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 44)
            .help("Verschieben / im Finder zeigen")
            .accessibilityLabel("Verschieben / im Finder zeigen")
        }
    }

    // MARK: - Eigene Notizen

    @ViewBuilder
    private func notesEditor(for note: RecordingStore.Recording) -> some View {
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
                    perform { try await noteManager.saveUserNotes(draftNotes, for: note); notesEditingID = nil }
                }
                Button("Speichern & neu zusammenfassen") {
                    busy = true
                    perform {
                        try await noteManager.saveUserNotes(draftNotes, for: note)
                        try await noteManager.resummarizeWithNotes(note, providerID: providerID)
                        busy = false
                        notesEditingID = nil
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { notesEditingID = nil }
            }
            .disabled(busy)
        }
        .padding(.leading, Theme.Spacing.xs)
    }

    private func toggleNotes(_ note: RecordingStore.Recording) {
        if notesEditingID == note.id {
            notesEditingID = nil
        } else {
            draftNotes = note.userNotes ?? ""
            notesEditingID = note.id
        }
    }

    // MARK: - Actions

    private func beginRename(_ note: RecordingStore.Recording) {
        draftTitle = note.title ?? ""
        editingID = note.id
    }

    private func commitRename(_ note: RecordingStore.Recording) {
        let title = draftTitle
        editingID = nil
        perform { try await noteManager.rename(note, to: title) }
    }

    private func commitNewFolder() {
        guard let note = newFolderTarget else { return }
        let name = newFolderName
        newFolderTarget = nil
        perform {
            let key = try await noteManager.createFolder(named: name)
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
                busy = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var newFolderBinding: Binding<Bool> {
        Binding(get: { newFolderTarget != nil }, set: { if !$0 { newFolderTarget = nil } })
    }
}
