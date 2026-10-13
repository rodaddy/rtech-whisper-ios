import Foundation
import SwiftData
import Testing

@testable import RtechWhisperKit

/// A fresh store file under the package's `.build` (gitignored), never `/tmp`.
private func scratchStoreURL() throws -> URL {
    let dir = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/test-stores/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "Chat.store")
}

/// Message rows on disk, read through a context of its own.
private func storedMessageCount(_ store: ChatStore) throws -> Int {
    try ModelContext(store.modelContainer).fetchCount(FetchDescriptor<StoredChatMessage>())
}

@Suite("Chat store")
struct ChatStoreTests {
    @Test func messagesSurviveReopeningTheFile() async throws {
        let url = try scratchStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let call = LLMToolCall(id: "c1", name: "create_note", arguments: #"{"title":"t","content":"c"}"#)
        let written = [
            ChatMessage(role: .user, content: "make a note", createdAt: Date(timeIntervalSince1970: 10)),
            ChatMessage(role: .assistant, content: "", toolCalls: [call], createdAt: Date(timeIntervalSince1970: 11)),
            ChatMessage(
                role: .tool, content: #"{"error":"nope"}"#, toolCallId: "c1", toolName: "create_note",
                displayText: "nope", isError: true, createdAt: Date(timeIntervalSince1970: 12)),
            ChatMessage(role: .assistant, content: "Done.", createdAt: Date(timeIntervalSince1970: 13)),
        ]
        let id: UUID
        do {
            let store = try ChatStore.persistent(url: url)
            id = try await store.createConversation(title: "make a note", now: Date(timeIntervalSince1970: 10)).id
            for message in written { try await store.append(message, to: id) }
        }

        let reopened = try ChatStore.persistent(url: url)
        #expect(try await reopened.messages(in: id) == written)
        let conversation = try #require(try await reopened.conversation(id))
        #expect(conversation.title == "make a note")
        #expect(conversation.updatedAt == Date(timeIntervalSince1970: 13))
    }

    @Test func conversationsListNewestFirstAndDeleteTakesTheirMessages() async throws {
        let store = try ChatStore.inMemory()
        let old = try await store.createConversation(title: "old", now: Date(timeIntervalSince1970: 1))
        let new = try await store.createConversation(title: "new", now: Date(timeIntervalSince1970: 2))
        try await store.append(ChatMessage(role: .user, content: "bump", createdAt: Date(timeIntervalSince1970: 3)), to: old.id)
        #expect(try await store.conversations().map(\.title) == ["old", "new"])

        try await store.rename(new.id, to: "renamed")
        try await store.delete(old.id)
        #expect(try await store.conversations().map(\.title) == ["renamed"])
        await #expect(throws: ChatStoreError.conversationNotFound(old.id)) { try await store.messages(in: old.id) }
        // The rows themselves are gone, not just unreachable (#192).
        #expect(try storedMessageCount(store) == 0)
    }

    @Test func theChatStoreIsItsOwnFile() {
        let config = ChatStore.configuration()
        #expect(config.name == "Chat")
        #expect(config.url.lastPathComponent == "Chat.store")
    }
}

@Suite("Chat store review fixes")
struct ChatStoreReviewFixTests {
    @Test func aFailedSaveLeavesNoPendingRowForTheNextSaveToWrite() async throws {
        let store = try ChatStore.inMemory()
        await store.setFailSaves(1)
        await #expect(throws: ChatStoreError.saveFailed) {
            try await store.createConversation(title: "same", now: Date())
        }
        let kept = try await store.createConversation(title: "same", now: Date())
        #expect(try await store.conversations().map(\.id) == [kept.id])

        await store.setFailSaves(1)
        await #expect(throws: ChatStoreError.saveFailed) {
            try await store.append(ChatMessage(role: .user, content: "lost"), to: kept.id)
        }
        try await store.append(ChatMessage(role: .user, content: "kept"), to: kept.id)
        #expect(try await store.messages(in: kept.id).map(\.content) == ["kept"])
    }

    // #177: a failed append leaves updatedAt; a failed rename leaves the
    // title. A failed delete is covered by aFailedDeleteKeepsTheConversation.
    @Test func failedWritesLeaveTheConversationAsItWas() async throws {
        let store = try ChatStore.inMemory()
        let kept = try await store.createConversation(title: "kept", now: Date(timeIntervalSince1970: 1))
        try await store.append(ChatMessage(role: .user, content: "hi", createdAt: Date(timeIntervalSince1970: 2)), to: kept.id)
        await store.setFailSaves(2)
        await #expect(throws: ChatStoreError.saveFailed) {
            try await store.append(ChatMessage(role: .user, content: "lost", createdAt: Date(timeIntervalSince1970: 9)), to: kept.id)
        }
        await #expect(throws: ChatStoreError.saveFailed) { try await store.rename(kept.id, to: "lost") }
        let now = try #require(try await store.conversation(kept.id))
        #expect(now.title == "kept" && now.updatedAt == Date(timeIntervalSince1970: 2))
        #expect(try await store.messages(in: kept.id).map(\.content) == ["hi"])
    }

    // #237: a failed delete throws, keeps the conversation and its messages,
    // and does not trap in SwiftData (rolling back a cascade delete did);
    // a later delete with saves working still removes both.
    @Test func aFailedDeleteKeepsTheConversation() async throws {
        let store = try ChatStore.inMemory()
        let kept = try await store.createConversation(title: "kept", now: Date(timeIntervalSince1970: 1))
        try await store.append(ChatMessage(role: .user, content: "one"), to: kept.id)
        try await store.append(ChatMessage(role: .assistant, content: "two"), to: kept.id)
        await store.setFailSaves(1)
        await #expect(throws: ChatStoreError.saveFailed) { try await store.delete(kept.id) }
        #expect(try await store.conversations().map(\.id) == [kept.id])
        #expect(try await store.messages(in: kept.id).map(\.content) == ["one", "two"])
        #expect(try storedMessageCount(store) == 2)

        // The store keeps working after the failure.
        try await store.append(ChatMessage(role: .user, content: "three"), to: kept.id)
        #expect(try await store.messages(in: kept.id).map(\.content) == ["one", "two", "three"])
        try await store.delete(kept.id)
        #expect(try await store.conversations().isEmpty)
        #expect(try storedMessageCount(store) == 0)
    }

    // #211: appending a stored message id again throws and changes nothing.
    @Test func appendingAStoredIdAgainThrows() async throws {
        let store = try ChatStore.inMemory()
        let a = try await store.createConversation(title: "a", now: Date())
        let b = try await store.createConversation(title: "b", now: Date())
        let first = ChatMessage(role: .user, content: "one"), second = ChatMessage(role: .user, content: "two")
        try await store.append(first, to: a.id)
        try await store.append(second, to: a.id)
        await #expect(throws: ChatStoreError.duplicateMessage(first.id)) { try await store.append(first, to: a.id) }
        await #expect(throws: ChatStoreError.duplicateMessage(first.id)) { try await store.append(first, to: b.id) }
        #expect(try await store.messages(in: a.id).map(\.content) == ["one", "two"])
        #expect(try await store.messages(in: b.id).isEmpty)
    }

    // #124: a row whose role or tool calls do not decode is reported, not
    // read back as an assistant message with no calls.
    @Test func aDamagedRowThrowsInsteadOfGuessing() throws {
        let call = LLMToolCall(id: "c", name: "get_note", arguments: "{}")
        let badRole = try StoredChatMessage(ChatMessage(role: .tool, content: "x"), position: 0)
        badRole.roleRaw = "robot"
        #expect(throws: ChatStoreError.damagedMessage(badRole.id)) { try badRole.record() }
        let badCalls = try StoredChatMessage(ChatMessage(role: .assistant, content: "", toolCalls: [call]), position: 1)
        badCalls.toolCallsJSON = Data("not json".utf8)
        #expect(throws: ChatStoreError.damagedMessage(badCalls.id)) { try badCalls.record() }
        #expect(try StoredChatMessage(ChatMessage(role: .assistant, content: "", toolCalls: [call]), position: 2).record().toolCalls == [call])
    }
}
