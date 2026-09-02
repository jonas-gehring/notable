import XCTest

/// Spec 02 — chat_messages persistence (append / read ordered / clear), with the
/// recordings foreign key satisfied.
final class ChatStoreTests: XCTestCase {
    private func makeStore() -> RecordingStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return RecordingStore(directory: dir)
    }

    func testAppendReadClear() async throws {
        let store = makeStore()
        try await store.insert(.init(id: "m1", kind: .meeting, startedAt: Date()))

        let base = Date(timeIntervalSince1970: 1_000)
        try await store.appendChatMessage(recordingID: "m1", role: "user", text: "Was war beschlossen?", createdAt: base)
        try await store.appendChatMessage(recordingID: "m1", role: "assistant", text: "Budget freigegeben.", createdAt: base.addingTimeInterval(1))

        let messages = try await store.chatMessages(for: "m1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].text, "Was war beschlossen?")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].text, "Budget freigegeben.")

        try await store.clearChat(for: "m1")
        let after = try await store.chatMessages(for: "m1")
        XCTAssertTrue(after.isEmpty)
    }

    func testChatIsScopedPerRecording() async throws {
        let store = makeStore()
        try await store.insert(.init(id: "a", kind: .meeting, startedAt: Date()))
        try await store.insert(.init(id: "b", kind: .meeting, startedAt: Date()))
        try await store.appendChatMessage(recordingID: "a", role: "user", text: "nur a", createdAt: Date(timeIntervalSince1970: 1))
        let forA = try await store.chatMessages(for: "a")
        let forB = try await store.chatMessages(for: "b")
        XCTAssertEqual(forA.count, 1)
        XCTAssertTrue(forB.isEmpty)
    }
}
