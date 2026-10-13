import Foundation
import Testing

@testable import RtechWhisperKit

private func call(_ id: String, _ name: String) -> LLMToolCall {
    LLMToolCall(id: id, name: name, arguments: "{}")
}

private func result(_ callId: String, _ name: String, _ json: String, display: String? = nil, isError: Bool = false) -> ChatMessage {
    ChatMessage(role: .tool, content: json, toolCallId: callId, toolName: name, displayText: display, isError: isError)
}

@Suite("Chat transcript")
struct ChatTranscriptTests {
    @Test func toolResultsHangUnderTheAssistantMessageThatAskedForThem() {
        let user = ChatMessage(role: .user, content: "find it")
        let ask = ChatMessage(role: .assistant, content: "", toolCalls: [call("c1", "search_notes"), call("c2", "get_note")])
        let hit = result("c1", "search_notes", "[]", display: "No notes found")
        let read = result("c2", "get_note", #"{"id":"n-1","title":"Plan"}"#, display: "Retrieved note: \"Plan\"")
        let answer = ChatMessage(role: .assistant, content: "Here it is.")

        let entries = ChatTranscript.entries([user, ask, hit, read, answer])

        #expect(entries.map(\.message) == [user, ask, answer])
        #expect(entries[0].toolResults.isEmpty)
        #expect(entries[1].toolResults == [hit, read])
        #expect(entries[1].pendingCalls.isEmpty)
        #expect(entries[2].toolResults.isEmpty)
    }

    @Test func aCallWithoutAResultIsPending() {
        let ask = ChatMessage(role: .assistant, content: "", toolCalls: [call("c1", "search_notes"), call("c2", "create_note")])
        let entries = ChatTranscript.entries([ask, result("c1", "search_notes", "[]")])
        #expect(entries[0].pendingCalls == [call("c2", "create_note")])
    }

    @Test func aToolMessageBeforeAnyAssistantMessageIsDropped() {
        let entries = ChatTranscript.entries([result("c0", "get_note", "{}"), ChatMessage(role: .user, content: "hi")])
        #expect(entries.count == 1)
        #expect(entries[0].message.role == .user)
    }

    @Test func chipsComeFromCreatedUpdatedAndReadNotes() {
        let chips = ChatTranscript.noteChips(from: [
            result("c1", "create_note", #"{"id":"n-1","title":"Groceries","folder":"Personal"}"#),
            result("c2", "update_note", #"{"id":"n-2","title":"Plan"}"#),
            result("c3", "get_note", #"{"id":"n-3","title":"Ideas","content":"..."}"#),
            result("c4", "list_folders", #"[{"id":"f-1","name":"Personal"}]"#),
        ])
        #expect(chips == [
            NoteChip(noteId: "n-1", title: "Groceries"),
            NoteChip(noteId: "n-2", title: "Plan"),
            NoteChip(noteId: "n-3", title: "Ideas"),
        ])
    }

    @Test func searchChipsAreCappedAndDedupedAgainstTheOtherTools() {
        let hits = (1...8).map { #"{"id":"n-\#($0)","title":"Note \#($0)"}"# }.joined(separator: ",")
        let chips = ChatTranscript.noteChips(from: [
            result("c1", "search_notes", "[\(hits)]"),
            result("c2", "get_note", #"{"id":"n-2","title":"Note 2"}"#),
            result("c3", "get_note", #"{"id":"n-9","title":"Note 9"}"#),
        ])
        #expect(chips.map(\.noteId) == ["n-1", "n-2", "n-3", "n-4", "n-5", "n-9"])
    }

    @Test func aFailedToolAndAResultWithoutAnIdGiveNoChip() {
        let chips = ChatTranscript.noteChips(from: [
            result("c1", "create_note", #"{"error":"title is required"}"#, isError: true),
            result("c2", "get_note", #"{"title":"No id"}"#),
            result("c3", "update_note", "not json"),
        ])
        #expect(chips.isEmpty)
    }

    @Test func aNullTitleFallsBackToTheDisplayTextThenUntitled() {
        let chips = ChatTranscript.noteChips(from: [
            result("c1", "get_note", #"{"id":"n-1","title":null}"#, display: "Retrieved note: \"From display\""),
            result("c2", "get_note", #"{"id":"n-2","title":""}"#, display: "Retrieved note: \"Untitled\""),
            result("c3", "update_note", #"{"id":"n-3"}"#),
            result("c4", "create_note", #"{"id":"n-4","title":"   "}"#, display: "Created note: \"   \""),
        ])
        // One untitled label everywhere, and never a blank capsule.
        #expect(chips.map(\.title) == ["From display", NoteRecord.untitled, NoteRecord.untitled, NoteRecord.untitled])
    }

    @Test func aLaterResultForTheSameNoteRenamesItsChipInPlace() {
        let chips = ChatTranscript.noteChips(from: [
            result("c1", "get_note", #"{"id":"n-1","title":"Old name"}"#),
            result("c2", "get_note", #"{"id":"n-2","title":"Other"}"#),
            result("c3", "update_note", #"{"id":"n-1","title":"New name"}"#),
        ])
        #expect(chips == [NoteChip(noteId: "n-1", title: "New name"), NoteChip(noteId: "n-2", title: "Other")])
    }

    @Test func aTitleStartingWithACombiningMarkDoesNotTrap() {
        let chips = ChatTranscript.noteChips(from: [
            result("c1", "get_note", #"{"id":"n-1","title":"́cafe"}"#, display: "Retrieved note: \"\u{301}cafe\""),
            result("c2", "get_note", #"{"id":"n-2","title":null}"#, display: "Retrieved note: \"\u{301}cafe\""),
            result("c3", "get_note", #"{"id":"n-3","title":null}"#, display: "\""),
        ])
        #expect(chips.map(\.title) == ["\u{301}cafe", "\u{301}cafe", NoteRecord.untitled])
        #expect(ChatTranscript.titleFromDisplay("\"") == nil)
        #expect(ChatTranscript.titleFromDisplay("Retrieved note: \"\u{200D}x\"") == "\u{200D}x")
    }

    @Test func runningToolsReadAsTheDesktopStatusLines() {
        #expect(ToolStatus.running("search_notes") == "Searching notes...")
        #expect(ToolStatus.running("update_note") == "Updating note...")
        #expect(ToolStatus.running("create_note") == "Creating note...")
        #expect(ToolStatus.running("get_note") == "Reading note...")
        #expect(ToolStatus.running("web_search") == "web_search")
        #expect(ToolStatus.symbol("search_notes") == "magnifyingglass")
        #expect(ToolStatus.symbol("unknown") == "wrench")
        #expect(ToolStatus.interrupted("search_notes") == "Search notes did not finish")
        #expect(ToolStatus.interrupted("update_note") == "Update note did not finish")
        #expect(ToolStatus.interrupted("web_search") == "web_search did not finish")
    }
}

@Suite("Conversation grouping")
struct ConversationGroupingTests {
    /// UTC, so the days fall the same in every time zone the tests run in.
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// A Tuesday at 22:13 UTC.
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation(_ title: String, daysAgo: Double) -> ChatConversation {
        let at = now.addingTimeInterval(-daysAgo * 86_400)
        return ChatConversation(id: UUID(), title: title, createdAt: at, updatedAt: at)
    }

    @Test func conversationsFallIntoTodayYesterdayWeekAndOlder() {
        let groups = ConversationGrouping.group([
            conversation("just now", daysAgo: 0),
            conversation("this morning", daysAgo: 0.3),
            conversation("yesterday", daysAgo: 1),
            conversation("three days", daysAgo: 3),
            conversation("six days", daysAgo: 6.5),
            conversation("eight days", daysAgo: 8),
            conversation("last month", daysAgo: 40),
        ], now: now, calendar: calendar)

        #expect(groups.map(\.label) == ["Today", "Yesterday", "Previous 7 Days", "Older"])
        #expect(groups.map { $0.conversations.map(\.title) } == [
            ["just now", "this morning"], ["yesterday"], ["three days", "six days"], ["eight days", "last month"],
        ])
    }

    @Test func groupsAreOrderedNewestFirstWhateverTheInputOrder() {
        let groups = ConversationGrouping.group([
            conversation("old", daysAgo: 30),
            conversation("new", daysAgo: 0),
            conversation("newer", daysAgo: 0.1),
        ], now: now, calendar: calendar)
        #expect(groups.map(\.label) == ["Today", "Older"])
        #expect(groups[0].conversations.map(\.title) == ["new", "newer"])
    }

    @Test func noConversationsMeansNoGroups() {
        #expect(ConversationGrouping.group([], now: now, calendar: calendar).isEmpty)
    }
}

@Test func theTabsAreHomeNotesChatMore() {
    #expect(AppTab.allCases == [.home, .notes, .brainDump, .chat, .more])
}
