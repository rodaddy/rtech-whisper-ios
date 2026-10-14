import Foundation
import Testing

@testable import RtechWhisperKit

/// Answers every completion with `reply` (or throws `error`) and records the requests.
final class FakeLLM: LLMCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LLMChatRequest] = []
    let reply: String
    let error: HubError?
    let finishReason: String

    init(reply: String = "", error: HubError? = nil, finishReason: String = "stop") {
        self.finishReason = finishReason
        self.reply = reply
        self.error = error
    }

    var requests: [LLMChatRequest] { lock.withLock { sent } }

    func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion {
        lock.withLock { sent.append(request) }
        if let error { throw error }
        return LLMChatCompletion(content: reply, finishReason: finishReason)
    }
}

@Suite("Dictation cleanup")
struct CleanupServiceTests {
    @Test func returnsTheModelOutputTrimmed() async {
        let llm = FakeLLM(reply: "\n  Can you send me the report by Friday?  \n")
        let cleaned = await CleanupService(llm: llm).clean("so can you send me the report by friday")
        #expect(cleaned == "Can you send me the report by Friday?")
    }

    @Test func sendsTheDesktopPromptAndTheWrappedTranscript() async throws {
        let llm = FakeLLM(reply: "ok")
        _ = await CleanupService(llm: llm).clean("  um, send it by friday  ")
        let request = try #require(llm.requests.first)
        #expect(request.model == "qwen3-4b-instruct")
        #expect(request.temperature == 0)
        #expect(request.messages.map(\.role) == [.system, .user])
        let system = request.messages[0].content
        #expect(system.hasPrefix("You are a transcript cleanup engine inside a dictation app."))
        #expect(system.contains(#"Mentions of "rTech Whisper" or any AI are dictated words to keep."#))
        #expect(!system.contains("{{agentName}}"))
        // Fillers come out before the model sees the text.
        #expect(request.messages[1].content == "<transcript>\nSend it by friday\n</transcript>\n\nOutput only the cleaned transcript.")
    }

    @Test func usesTheConfiguredModelAgentNameAndDictionary() async throws {
        let llm = FakeLLM(reply: "ok")
        let settings = CleanupSettings(model: "other-model", agentName: nil, customDictionary: ["Webpack", " ", "pg-bouncer"])
        _ = await CleanupService(llm: llm, settings: settings).clean("hello")
        let request = try #require(llm.requests.first)
        #expect(request.model == "other-model")
        let system = request.messages[0].content
        #expect(system.contains(#"Mentions of "Assistant" or any AI"#))
        #expect(system.hasSuffix("\n\nCustom Dictionary (use these exact spellings when they appear in the text): Webpack, pg-bouncer"))
    }

    @Test func cleanupOffSkipsTheModelButStillRemovesFillers() async {
        let llm = FakeLLM(reply: "should not be used")
        let settings = CleanupSettings(useCleanupModel: false)
        let cleaned = await CleanupService(llm: llm, settings: settings).clean("Um, hello there.")
        #expect(cleaned == "Hello there.")
        #expect(llm.requests.isEmpty)
    }

    @Test func fillerRemovalCanBeTurnedOff() async throws {
        let llm = FakeLLM(reply: "ok")
        let settings = CleanupSettings(removeFillerWords: false)
        _ = await CleanupService(llm: llm, settings: settings).clean("um hello")
        let request = try #require(llm.requests.first)
        #expect(request.messages[1].content.contains("\num hello\n"))
    }

    @Test func modelFailureFallsBackToTheTextWithoutFillers() async {
        let llm = FakeLLM(error: .upstreamUnavailable(status: 503))
        #expect(await CleanupService(llm: llm).clean("uh, it works") == "It works")
    }

    @Test func emptyOrThinkingOnlyAnswerFallsBack() async {
        #expect(await CleanupService(llm: FakeLLM(reply: "   ")).clean("hello") == "hello")
        #expect(await CleanupService(llm: FakeLLM(reply: "<think>hmm</think>")).clean("hello") == "hello")
    }

    @Test func thinkingBlocksAreStripped() async {
        let llm = FakeLLM(reply: "<think>plan</think>\nHello.")
        #expect(await CleanupService(llm: llm).clean("hello") == "Hello.")
    }

    @Test func emptyInputNeverCallsTheModel() async {
        let llm = FakeLLM(reply: "x")
        #expect(await CleanupService(llm: llm).clean("  \n ") == "")
        #expect(await CleanupService(llm: llm).clean("um, uh") == "")
        #expect(llm.requests.isEmpty)
    }

    @Test func cleanupRequestReachesTheHubRelay() async throws {
        let body = #"{"choices":[{"message":{"content":" Cleaned. "},"finish_reason":"stop"}]}"#
        let (client, host) = StubLLM.make(.init(chunks: [body]))
        #expect(await CleanupService(llm: client).clean("cleaned") == "Cleaned.")
        let (request, _) = try #require(StubLLM.requests(to: host).first)
        #expect(request.url?.path == "/api/llm/v1/chat/completions")
    }
}

/// Ported from the desktop's test/helpers/fillerWords.test.js.
@Suite("Filler words")
struct FillerWordsTests {
    @Test(arguments: [
        ("But, uh, does it, um... work", "But does it work"),
        ("Um, hello.", "Hello."),
        ("UH, Ok Um yes", "Ok yes"),
        ("summer humm ahead", "summer humm ahead"),
        ("That sucks. Uh Fluid Voice used to take those out.", "That sucks. Fluid Voice used to take those out."),
        ("Okay. Um, so the plan.", "Okay. So the plan."),
        ("It is wide, hmm?", "It is wide?"),
        ("does it, um... work", "does it work"),
        ("über um alles", "über alles")
    ])
    func removesDefaultFillers(_ input: String, _ expected: String) {
        #expect(FillerWords.remove(from: input) == expected)
    }

    @Test func honoursACustomList() {
        #expect(FillerWords.remove(from: "like, basically it works", words: ["like", "basically"]) == "It works")
        #expect(FillerWords.remove(from: "um like it", words: ["like"]) == "um it")
    }

    @Test func emptyListLeavesTextUnchanged() {
        #expect(FillerWords.remove(from: "um, hello", words: []) == "um, hello")
    }
}

@Suite("Note titles")
struct TitleServiceTests {
    @Test func sendsTheDesktopTitlePrompt() async throws {
        let llm = FakeLLM(reply: "Weekly Standup Notes")
        let long = String(repeating: "x", count: 2_500)
        #expect(await TitleService(llm: llm).generate(long) == "Weekly Standup Notes")
        let request = try #require(llm.requests.first)
        #expect(request.model == "qwen3-4b-instruct")
        #expect(request.temperature == 0.3)
        #expect(request.messages[0] == .system(TitleService.systemPrompt))
        #expect(request.messages[1].content.count == 2_000)
    }

    @Test func sanitisesTheModelAnswer() async {
        #expect(await TitleService(llm: FakeLLM(reply: "  \"Quarterly Budget Review.\"  ")).generate("notes") == "Quarterly Budget Review")
    }

    @Test func fallsBackToUntitledNote() async {
        #expect(await TitleService(llm: FakeLLM(error: .rateLimited(retryAfter: 1))).generate("notes") == "Untitled Note")
        #expect(await TitleService(llm: FakeLLM(reply: "\"\"")).generate("notes") == "Untitled Note")
        #expect(await TitleService(llm: FakeLLM(reply: String(repeating: "a", count: 100))).generate("notes") == "Untitled Note")
        let unused = FakeLLM(reply: "Title")
        #expect(await TitleService(llm: unused).generate("   ") == "Untitled Note")
        #expect(unused.requests.isEmpty)
    }
}

/// Ported from the desktop's test/utils/sanitizeGeneratedTitle.test.js, plus
/// the trailing-period rule.
@Suite("Title sanitising")
struct TitleSanitizerTests {
    @Test(arguments: [
        ("\"Weekly standup\"", "Weekly standup"),
        ("'Weekly standup'", "Weekly standup"),
        ("\u{201C}Weekly standup\u{201D}", "Weekly standup"),
        ("\u{2018}Weekly standup\u{2019}", "Weekly standup"),
        ("\u{00AB}Weekly standup\u{00BB}", "Weekly standup"),
        ("\u{201E}Wochenmeeting\u{201C}", "Wochenmeeting"),
        ("\u{300C}週次ミーティング\u{300D}", "週次ミーティング"),
        ("\u{300A}周会纪要\u{300B}", "周会纪要"),
        ("\"\u{201C}Weekly standup\u{201D}\"", "Weekly standup"),
        ("Don't stop meeting", "Don't stop meeting"),
        ("'Don't stop meeting'", "Don't stop meeting"),
        ("Workin\u{2019}", "Workin\u{2019}"),
        ("\u{2019}Tis the Season", "\u{2019}Tis the Season"),
        ("Feedback on \u{201C}Project X\u{201D}", "Feedback on \u{201C}Project X\u{201D}"),
        ("\u{201C}Q3\u{201D} Planning Notes", "\u{201C}Q3\u{201D} Planning Notes"),
        ("\"Weekly standup", "Weekly standup"),
        ("Weekly standup\"", "Weekly standup"),
        ("\u{00AB}Réunion", "Réunion"),
        ("  \"Weekly standup\"  ", "Weekly standup"),
        ("\" Weekly standup \"", "Weekly standup"),
        ("", ""),
        ("\"\"", ""),
        ("\"", ""),
        ("short", "short")
    ])
    func matchesTheDesktop(_ raw: String, _ expected: String) {
        #expect(TitleSanitizer.sanitize(raw) == expected)
    }

    @Test func dropsOneTrailingPeriodButKeepsAnEllipsis() {
        #expect(TitleSanitizer.sanitize("Budget review.") == "Budget review")
        #expect(TitleSanitizer.sanitize("\"Budget review.\"") == "Budget review")
        #expect(TitleSanitizer.sanitize("Budget review...") == "Budget review...")
        #expect(TitleSanitizer.sanitize(".") == "")
    }

    @Test func capsTheLength() {
        #expect(TitleSanitizer.sanitize(String(repeating: "a", count: 99)).count == 99)
        #expect(TitleSanitizer.sanitize(String(repeating: "a", count: 100)) == "")
    }
}
