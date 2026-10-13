import Foundation
import Testing

@testable import RtechWhisperKit

@MainActor
@Suite("Chat conversations list")
struct ChatConversationsViewModelTests {
    @Test func listsWhatTheStoreHoldsMostRecentFirst() async throws {
        let store = try ChatStore.inMemory()
        let older = try await store.createConversation(title: "older", now: Date(timeIntervalSince1970: 100))
        let newer = try await store.createConversation(title: "newer", now: Date(timeIntervalSince1970: 200))
        let list = ChatConversationsViewModel(store: store)

        await list.reload()

        #expect(list.conversations.map(\.id) == [newer.id, older.id])
        #expect(list.storeFailed == false)
    }

    @Test func deleteRemovesTheConversationFromTheListAndTheStore() async throws {
        let store = try ChatStore.inMemory()
        let keep = try await store.createConversation(title: "keep")
        let gone = try await store.createConversation(title: "gone")
        let list = ChatConversationsViewModel(store: store)
        await list.reload()

        await list.delete(gone.id)

        #expect(list.conversations.map(\.id) == [keep.id])
        #expect(try await store.conversation(gone.id) == nil)
    }

    @Test func renameChangesTheTitleAndIgnoresABlankOne() async throws {
        let store = try ChatStore.inMemory()
        let conversation = try await store.createConversation(title: "first words")
        let list = ChatConversationsViewModel(store: store)
        await list.reload()

        await list.rename(conversation.id, to: "  Plans  ")
        #expect(list.conversations.first?.title == "Plans")
        #expect(try await store.conversation(conversation.id)?.title == "Plans")

        await list.rename(conversation.id, to: "   ")
        #expect(list.conversations.first?.title == "Plans")
    }

    @Test func aConversationTheSessionCreatesAppearsOnReload() async throws {
        let store = try ChatStore.inMemory()
        let list = ChatConversationsViewModel(store: store)
        await list.reload()
        #expect(list.conversations.isEmpty)

        let session = ChatSession(llm: FakeChatLLM([FakeChatLLM.text("Hi.")]), store: store)
        await session.send("hello there")
        await list.reload()

        #expect(list.conversations.map(\.title) == ["hello there"])
        // Grouped as of its own stamp, so a run across midnight cannot flake.
        let stamped = try #require(list.conversations.first?.updatedAt)
        #expect(list.groups(now: stamped).map(\.label) == ["Today"])
    }
}

@MainActor
@Suite("Chat conversations list: store failures")
struct ChatConversationsFailureTests {
    @Test func aFailedDeleteKeepsTheRowAndSaysSo() async throws {
        let store = try ChatStore.inMemory()
        let conversation = try await store.createConversation(title: "keep me")
        let list = ChatConversationsViewModel(store: store)
        await list.reload()

        await store.setFailSaves(1)
        let deleted = await list.delete(conversation.id)

        #expect(deleted == false)
        #expect(list.storeFailed)
        #expect(list.conversations.map(\.id) == [conversation.id])
        #expect(await list.delete(conversation.id))
        #expect(list.storeFailed == false)
    }

    @Test func aFailedRenameReturnsNothing() async throws {
        let store = try ChatStore.inMemory()
        let conversation = try await store.createConversation(title: "old")
        let list = ChatConversationsViewModel(store: store)
        await list.reload()

        await store.setFailSaves(1)
        #expect(await list.rename(conversation.id, to: "new") == nil)
        #expect(list.storeFailed)
        #expect(list.conversations.first?.title == "old")
        #expect(await list.rename(conversation.id, to: " new ") == "new")
    }

    @Test func theListIsNotLoadedUntilAReloadReadsTheStore() async throws {
        let list = ChatConversationsViewModel(store: try ChatStore.inMemory())
        #expect(list.hasLoaded == false)
        await list.reload()
        #expect(list.hasLoaded)
    }

    @Test func renamingTheOpenConversationRetitlesTheSession() async throws {
        let store = try ChatStore.inMemory()
        let session = ChatSession(llm: FakeChatLLM([FakeChatLLM.text("Hi.")]), store: store)
        await session.send("hello there")
        let list = ChatConversationsViewModel(store: store)
        await list.reload()
        let id = try #require(session.conversation?.id)

        let title = try #require(await list.rename(id, to: "Greetings"))
        session.renamed(id, to: title)
        session.renamed(UUID(), to: "someone else")

        #expect(session.conversation?.title == "Greetings")
    }
}
