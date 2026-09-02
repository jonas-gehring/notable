import SwiftUI

/// One chat turn as shown/stored. Role reuses `ChatRole` from `ChatPrompt`.
struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let role: ChatRole
    let text: String
    let createdAt: Date
}

/// Drives "ask this meeting": loads history + transcript context, sends a
/// question through the chosen summarization provider (only transcript text
/// leaves the device, as with the summary), and persists every turn.
@MainActor
final class MeetingChatController: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking = false
    @Published var errorMessage: String?

    let recordingID: String
    private let store: RecordingStore
    private var context: ChatContext?

    init(recordingID: String, store: RecordingStore = .shared) {
        self.recordingID = recordingID
        self.store = store
    }

    /// True once the transcript context is available (a meeting with segments).
    var isReady: Bool { context?.segments.isEmpty == false }

    func load() async {
        let stored = (try? await store.chatMessages(for: recordingID)) ?? []
        messages = stored.compactMap { row in
            guard let role = ChatRole(rawValue: row.role) else { return nil }
            return ChatMessage(role: role, text: row.text, createdAt: row.createdAt)
        }
        if let loaded = try? await store.meeting(id: recordingID) {
            context = ChatContext(
                meetingTitle: loaded.recording.title,
                date: loaded.recording.startedAt,
                segments: loaded.segments.map {
                    ChatTranscriptSegment(speaker: $0.speaker, start: $0.start, text: $0.text)
                },
                userNotes: loaded.recording.userNotes,
                summary: loaded.recording.summary)
        }
    }

    func send(_ raw: String, providerID: String) async {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking, let context else { return }
        errorMessage = nil

        let userTurn = ChatMessage(role: .user, text: question, createdAt: Date())
        // History is everything before this question.
        let history = messages.map { ChatTurn(role: $0.role, text: $0.text) }
        messages.append(userTurn)
        try? await store.appendChatMessage(
            recordingID: recordingID, role: userTurn.role.rawValue,
            text: userTurn.text, createdAt: userTurn.createdAt)

        isThinking = true
        defer { isThinking = false }
        do {
            let answer = try await SummarizationService.complete(
                system: ChatPrompt.system,
                user: ChatPrompt.user(context: context, history: history, question: question),
                providerID: providerID)
            await UsageRecorder.record(
                answer.usage, provider: providerID,
                purpose: .chat, recordingID: recordingID, store: store)
            let trimmed = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantTurn = ChatMessage(role: .assistant, text: trimmed, createdAt: Date())
            messages.append(assistantTurn)
            try? await store.appendChatMessage(
                recordingID: recordingID, role: assistantTurn.role.rawValue,
                text: assistantTurn.text, createdAt: assistantTurn.createdAt)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() async {
        try? await store.clearChat(for: recordingID)
        messages = []
        errorMessage = nil
    }
}

/// A chat panel over one meeting's transcript. Presented as a sheet from the
/// note list.
struct MeetingChatView: View {
    let recording: RecordingStore.Recording
    @StateObject private var controller: MeetingChatController
    @AppStorage("summarizationProvider") private var providerID = SummarizationProviderID.anthropicAPI.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    init(recording: RecordingStore.Recording) {
        self.recording = recording
        _controller = StateObject(wrappedValue: MeetingChatController(recordingID: recording.id))
    }

    private let suggestions = ["Was waren die Action Items?", "Welche Entscheidungen wurden getroffen?", "Fasse die Kernpunkte zusammen."]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(width: 460, height: 520)
        .background(Theme.windowBackground)
        .task { await controller.load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat mit dem Meeting")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textEmphasis)
                Text(recording.title ?? "Meeting")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSubtle)
                    .lineLimit(1)
            }
            Spacer()
            if !controller.messages.isEmpty {
                Button("Verlauf löschen") { Task { await controller.clear() } }
                    .buttonStyle(.link)
            }
            Button("Fertig") { dismiss() }
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if controller.messages.isEmpty {
                        emptyState
                    }
                    ForEach(controller.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if controller.isThinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Denkt nach…").font(.system(size: 12)).foregroundStyle(Theme.textSubtle)
                        }
                    }
                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .onChange(of: controller.messages.count) { _, _ in
                if let last = controller.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.isReady
                ? "Frag alles über dieses Meeting."
                : "Für dieses Meeting gibt es kein Transkript.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSubtle)
            if controller.isReady {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textEmphasis)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Theme.surfaceSubtle : Theme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: isUser ? 0 : 1))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Frage stellen…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                .onSubmit { send(draft) }
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Theme.accent : Theme.textMuted)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(12)
        .disabled(!controller.isReady)
    }

    private var canSend: Bool {
        controller.isReady && !controller.isThinking
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String) {
        guard canSend || !text.isEmpty else { return }
        let question = text
        draft = ""
        Task { await controller.send(question, providerID: providerID) }
    }
}
