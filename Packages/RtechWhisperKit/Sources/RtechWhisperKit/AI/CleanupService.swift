import Foundation
import Synchronization

/// The dictation-cleanup settings, with the desktop's defaults.
public struct CleanupSettings: Sendable, Equatable {
    /// Send the transcript through the cleanup model (desktop default: on).
    public var useCleanupModel: Bool
    public var model: String
    /// Strip filler words before anything else (desktop default: on).
    public var removeFillerWords: Bool
    public var fillerWords: [String]
    /// The assistant's name, kept as dictated text by the prompt.
    public var agentName: String?
    /// Exact spellings the model should use.
    public var customDictionary: [String]

    public init(
        useCleanupModel: Bool = true,
        model: String = LLMClient.defaultModel,
        removeFillerWords: Bool = true,
        fillerWords: [String] = FillerWords.defaults,
        agentName: String? = CleanupSettings.defaultAgentName,
        customDictionary: [String] = []
    ) {
        self.useCleanupModel = useCleanupModel
        self.model = model
        self.removeFillerWords = removeFillerWords
        self.fillerWords = fillerWords
        self.agentName = agentName
        self.customDictionary = customDictionary
    }

    /// The desktop's default agent name (`src/utils/agentName.ts`).
    public static let defaultAgentName = "rTech Whisper"
}

/// Cleans a raw dictation the way the desktop does: trim, drop filler words,
/// then (when `useCleanupModel` is on) ask the cleanup model through the hub.
/// It never loses the dictation: when the model fails or answers nothing,
/// the text without fillers comes back instead, as on the desktop.
public struct CleanupService: Sendable {
    /// Cleanup is a deterministic transform (desktop: zero temperature).
    static let temperature = 0.0
    static let maxTokens = 4_096

    /// How long cleanup waits for the model before it keeps the text without
    /// it (the desktop's 30 s). `LLMClient.requestTimeout` stays 180 s for
    /// note actions and titles; a dictation is held in `.cleaning` until this
    /// answers, so cleanup gets its own, shorter deadline.
    public static let deadline: Duration = .seconds(30)

    public let settings: CleanupSettings
    private let llm: any LLMCompleting
    private let deadline: Duration

    public init(
        llm: any LLMCompleting, settings: CleanupSettings = CleanupSettings(),
        deadline: Duration = CleanupService.deadline
    ) {
        self.llm = llm
        self.settings = settings
        self.deadline = deadline
    }

    public func clean(_ rawText: String) async -> String {
        await cleanReportingFailure(rawText).text
    }

    /// `clean`, plus whether the model was asked and failed: the relay threw
    /// or cut the answer off. The desktop tells the person when that happens
    /// ("Cleanup failed"); the text is the same fallback either way.
    public func cleanReportingFailure(_ rawText: String) async -> (text: String, modelFailed: Bool) {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (text, false) }
        if settings.removeFillerWords {
            text = FillerWords.remove(from: text, words: settings.fillerWords)
        }
        guard settings.useCleanupModel, !text.isEmpty else { return (text, false) }

        let request = LLMChatRequest(
            model: settings.model,
            messages: [
                .system(CleanupPrompt.system(agentName: settings.agentName, customDictionary: settings.customDictionary)),
                .user(CleanupPrompt.wrap(text))
            ],
            temperature: Self.temperature,
            maxTokens: Self.maxTokens
        )
        guard let completion = await Self.complete(request, with: llm, within: deadline) else { return (text, true) }
        // A reply cut off at the token limit is missing the end of the dictation.
        guard completion.finishReason != "length" else { return (text, true) }
        let cleaned = ThinkingTags.strip(completion.content)
        return (cleaned.isEmpty ? text : cleaned, false)
    }

    /// The model's answer, or `nil` when it failed or did not answer within
    /// `deadline`. On the deadline the request is cancelled and this returns
    /// at once, even if the relay call ignores the cancellation.
    static func complete(
        _ request: LLMChatRequest, with llm: any LLMCompleting, within deadline: Duration
    ) async -> LLMChatCompletion? {
        let first = FirstAnswer()
        let work = Task { first.resolve(try? await llm.complete(request)) }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            first.resolve(nil)
        }
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { first.wait(with: $0) }
        } onCancel: {
            first.resolve(nil)
        }
        work.cancel()
        timer.cancel()
        return answer
    }
}

/// The first of several racing results; later ones are dropped.
private final class FirstAnswer: Sendable {
    private struct Slot {
        var waiter: CheckedContinuation<LLMChatCompletion?, Never>?
        var answer: LLMChatCompletion??
    }
    private let slot = Mutex(Slot())

    func resolve(_ answer: LLMChatCompletion?) {
        let waiter = slot.withLock { slot -> CheckedContinuation<LLMChatCompletion?, Never>? in
            guard slot.answer == nil else { return nil }
            slot.answer = .some(answer)
            defer { slot.waiter = nil }
            return slot.waiter
        }
        waiter?.resume(returning: answer)
    }

    func wait(with continuation: CheckedContinuation<LLMChatCompletion?, Never>) {
        let ready = slot.withLock { slot -> LLMChatCompletion?? in
            if let answer = slot.answer { return .some(answer) }
            slot.waiter = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }
}
