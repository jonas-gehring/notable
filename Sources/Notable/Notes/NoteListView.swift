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
    @State private var busy = false
    @State private var chatNote: RecordingStore.Recording?
    @AppStorage("summarizationProvider") private var providerID = SummarizationProviderID.anthropicAPI.rawValue

    var body: some View {
        Group {
            if noteManager.notes.isEmpty {
                ContentUnavailableView(
                    "Keine Notizen",
                    systemImage: "doc.text",
                    description: Text("Aufgezeichnete Meetings erscheinen hier.")
                )
            } else {
                List(noteManager.notes) { note in
                    row(for: note)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .task { await noteManager.reload() }
        .sheet(item: $chatNote) { note in
            MeetingChatView(recording: note)
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

    // MARK: - Row

    @ViewBuilder
    private func row(for note: RecordingStore.Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            rowHeader(for: note)
            if notesEditingID == note.id {
                notesEditor(for: note)
            }
        }
        .padding(.vertical, 4)
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
                        Text(note.title ?? "Ohne Titel")
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
                    ForEach(noteManager.projectFolders(), id: \.self) { folder in
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
        }
    }

    // MARK: - Eigene Notizen

    @ViewBuilder
    private func notesEditor(for note: RecordingStore.Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Eigene Notizen (kommen als Header ins .md und fließen in die Zusammenfassung ein)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draftNotes)
                .font(.body)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
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
        .padding(.leading, 4)
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
