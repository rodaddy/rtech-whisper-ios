import Foundation
import Testing

@testable import RtechWhisperKit

@MainActor
final class FakeReplyPlayer: ReplyAudioPlaying {
    var onFinish: (@MainActor () -> Void)?
    var played: [Data] = []
    var stops = 0
    func play(_ wav: Data) throws { played.append(wav) }
    func stop() { stops += 1 }
}

/// A fake relay: records every text sent and answers with `answer`.
final class FakeSpeechRelay: @unchecked Sendable {
    var sent: [String] = []
    var answer: Result<Data, HubError> = .success(Data("RIFF".utf8))
    var synthesize: ReplySpeaker.Synthesize {
        { text throws(HubError) in
            self.sent.append(text)
            return try self.answer.get()
        }
    }
}

@MainActor
@Suite("Reply speech")
struct ReplySpeechTests {
    let reply = ChatMessage(role: .assistant, content: "Hello there.")

    @Test func requestIsTextOnlySoTheHubUsesItsOwnVoice() throws {
        let body = SpeechRelay.requestBody(text: "  Hi  ")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["text": "Hi"])
        let long = SpeechRelay.requestBody(text: String(repeating: "a", count: 2500))
        let text = try #require(try JSONSerialization.jsonObject(with: long) as? [String: String])["text"]
        #expect(text?.count == SpeechRelay.maxCharacters)
    }

    @Test func decodesTheWavAndRejectsAnEmptyAnswer() throws {
        let wav = Data("RIFFwav".utf8)
        let body = Data(#"{"audio_base64":"\#(wav.base64EncodedString())","sample_rate":24000}"#.utf8)
        #expect(try SpeechRelay.audio(from: body) == wav)
        #expect(throws: HubError.self) { try SpeechRelay.audio(from: Data(#"{"audio_base64":""}"#.utf8)) }
    }

    @Test func speaksTheFinalReplyOnlyWhenEnabledAndAnswered() async {
        let relay = FakeSpeechRelay()
        let player = FakeReplyPlayer()
        var enabled = false
        let speaker = ReplySpeaker(synthesize: relay.synthesize, player: player, isEnabled: { enabled })
        let messages = [ChatMessage(role: .user, content: "hi"), ChatMessage(role: .assistant, content: "Early"), reply]

        await speaker.turnEnded(.answered, messages: messages)
        #expect(relay.sent.isEmpty)
        enabled = true
        await speaker.turnEnded(.failed, messages: messages)
        #expect(relay.sent.isEmpty)
        await speaker.turnEnded(.answered, messages: messages)
        #expect(relay.sent == ["Hello there."])
        #expect(player.played == [Data("RIFF".utf8)])
        #expect(speaker.speakingID == reply.id)
        #expect(!speaker.isLoading)
    }

    @Test func tappingAgainStopsAndFinishingClears() async {
        let player = FakeReplyPlayer()
        let speaker = ReplySpeaker(synthesize: FakeSpeechRelay().synthesize, player: player)
        await speaker.toggle(reply)
        #expect(speaker.speakingID == reply.id)
        await speaker.toggle(reply)
        #expect(speaker.speakingID == nil)
        #expect(player.stops == 1)

        await speaker.toggle(reply)
        player.onFinish?()
        #expect(speaker.speakingID == nil)
    }

    @Test func failureShowsANoticeAndNeverPlays() async {
        let relay = FakeSpeechRelay()
        relay.answer = .failure(.upstreamUnavailable(status: 504))
        let player = FakeReplyPlayer()
        let speaker = ReplySpeaker(synthesize: relay.synthesize, player: player)
        await speaker.speak(reply)
        #expect(speaker.failure == .synthesis(.upstreamUnavailable(status: 504)))
        #expect(speaker.speakingID == nil)
        #expect(player.played.isEmpty)
    }

    @Test func neverTakesTheAudioSessionFromALiveTake() async {
        let relay = FakeSpeechRelay()
        let player = FakeReplyPlayer()
        let speaker = ReplySpeaker(synthesize: relay.synthesize, player: player, otherCaptureActive: { true })
        await speaker.speak(reply)
        #expect(speaker.failure == .audioBusy)
        #expect(relay.sent.isEmpty)
        #expect(player.played.isEmpty)
    }

    @Test func readRepliesAloudIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "reply-speech-\(UUID())")!
        #expect(AISettingsStore(defaults: defaults).assistantSpeechEnabled == false)
    }
}
