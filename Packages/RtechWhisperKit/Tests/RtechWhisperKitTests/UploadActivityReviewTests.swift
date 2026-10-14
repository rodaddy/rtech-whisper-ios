import AVFoundation
import Foundation
import Testing

@testable import RtechWhisperKit


/// An ordered log both a source and a relay write to.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

/// Hands out `DecodedAudio` and logs each read.
private actor LoggingSource: AudioSampleSource {
    nonisolated let durationSeconds: Double
    private let inner: BufferedAudioSource
    private let log: EventLog

    init(_ audio: DecodedAudio, log: EventLog) {
        durationSeconds = audio.durationSeconds
        inner = BufferedAudioSource(audio)
        self.log = log
    }

    func read(maxSamples: Int) async -> [Int16] {
        let samples = await inner.read(maxSamples: maxSamples)
        log.add("read \(samples.count)")
        return samples
    }
}

/// Answers from a script, logs and keeps each WAV.
private final class ScriptedRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<Transcript, HubError>]
    private(set) var sent: [Data] = []
    let log: EventLog

    init(_ replies: [Result<Transcript, HubError>], log: EventLog = EventLog()) {
        self.replies = replies
        self.log = log
    }

    func transcribe(_ wav: Data) throws(HubError) -> Transcript {
        let next = lock.withLock { () -> Result<Transcript, HubError> in
            sent.append(wav)
            return replies.isEmpty ? .success(Transcript(text: "", noSpeech: true)) : replies.removeFirst()
        }
        log.add("send \(pcm(wav).count)")
        return try next.get()
    }
}

/// Distinct samples, so a lost or repeated stretch changes the joined
/// output. They fade, so each cut still lands at the end of its window.
private func distinct(_ count: Int) -> [Int16] {
    (0..<count).map { Int16(($0 % 2 == 0 ? 1 : -1) * (30_000 - $0 / 2)) }
}

/// The samples in a sent WAV.
private func pcm(_ wav: Data) -> [Int16] {
    wav.dropFirst(WavEncoder.headerLength).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

private func said(_ text: String) -> Result<Transcript, HubError> { .success(Transcript(text: text, noSpeech: false)) }

@MainActor
private func job(
    _ source: @escaping @Sendable () -> any AudioSampleSource, relay: ScriptedRelay, maxChunkSeconds: Int = 1
) -> UploadJob {
    UploadJob(
        decode: { _ in source() },
        transcribe: { wav, _ throws(HubError) in try relay.transcribe(wav) },
        maxChunkSeconds: maxChunkSeconds,
        sleep: { _ in })
}

private let url = URL(fileURLWithPath: "/audio/interview.m4a")

@MainActor
@Suite struct UploadStreamingTests {
    @Test func eachChunkIsReadOnlyWhenItIsSent() async {
        let log = EventLog()
        let relay = ScriptedRelay([said("one"), said("two"), said("three")], log: log)
        let audio = DecodedAudio(samples: Array(repeating: 1, count: 40_000), durationSeconds: 2.5)
        let upload = job({ LoggingSource(audio, log: log) }, relay: relay)

        await upload.run(url: url)

        #expect(upload.result?.text == "one two three")
        // Each send is logged with its sample count, so a duplicated or lost stretch shows.
        #expect(
            log.all == ["read 16001", "send 15600", "read 15600", "send 15600", "read 8399", "send 8800", "read 0"])
    }

    @Test func aFileOverTheLengthCapFailsBeforeAnySend() async {
        let relay = ScriptedRelay([])
        let audio = DecodedAudio(samples: [1], durationSeconds: Double(UploadJob.maxDurationSeconds) + 1)
        let upload = job({ audio.source }, relay: relay)

        await upload.run(url: url)

        #expect(upload.state == .failed(fileName: "interview.m4a", .tooLong(maxSeconds: UploadJob.maxDurationSeconds)))
        #expect(relay.sent.isEmpty)
    }

    @Test func resumeCarriesOnFromTheFailedChunkKeepingEarlierText() async throws {
        let relay = ScriptedRelay([said("one"), .failure(.unauthorized), said("two"), said("three")])
        let input = distinct(40_000)
        let audio = DecodedAudio(samples: input, durationSeconds: 2.5)
        let upload = job({ audio.source }, relay: relay)
        var reported: [String] = []
        upload.onTranscribed = { reported.append($0.text) }

        await upload.run(url: url)
        #expect(upload.state == .failed(fileName: "interview.m4a", .hub(.unauthorized)))
        #expect(upload.canResume)

        await upload.resume()

        #expect(upload.result?.text == "one two three")
        #expect(reported == ["one two three"])
        // Fatal, so a resume that sent nothing fails here instead of trapping below.
        try #require(relay.sent.count == 4)
        #expect(relay.sent[1] == relay.sent[2])
        // Every sample sent once, in order, across the resume.
        #expect(Array([0, 2, 3].map { pcm(relay.sent[$0]) }.joined()) == input)
        #expect(!upload.canResume)
    }

    @Test func aSecondFailureDuringResumeResumesAgainLosingNothing() async throws {
        let relay = ScriptedRelay([
            said("one"), .failure(.unauthorized), said("two"), .failure(.unauthorized), said("three"),
        ])
        let input = distinct(40_000)
        let upload = job({ DecodedAudio(samples: input, durationSeconds: 2.5).source }, relay: relay)

        await upload.run(url: url)
        await upload.resume()
        #expect(upload.state == .failed(fileName: "interview.m4a", .hub(.unauthorized)))
        #expect(upload.canResume)
        await upload.resume()

        #expect(upload.result?.text == "one two three")
        try #require(relay.sent.count == 5)
        #expect(relay.sent[1] == relay.sent[2])
        #expect(relay.sent[3] == relay.sent[4])
        #expect(Array([0, 2, 4].map { pcm(relay.sent[$0]) }.joined()) == input)
    }
}

/// A fresh directory in the test process's temporary area, removed on deinit.
private final class FixtureDirectory {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "UploadActivityReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// A 16-bit 44.1 kHz WAV with `channels`; `fill` gives each channel's sample at a frame.
    func wav(seconds: Double, channels: AVAudioChannelCount, fill: (Int, Int) -> Float) throws -> URL {
        let file = url.appending(path: "\(UUID().uuidString).wav")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) { data[channel][frame] = fill(channel, frame) }
        }
        let writer = try AVAudioFile(
            forWriting: file,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
        writer.close()
        return file
    }

    /// A 16-bit 44.1 kHz mono CAF; `fill` gives the sample at a frame.
    func caf(seconds: Double, fill: (Int) -> Float) throws -> URL {
        let file = url.appending(path: "\(UUID().uuidString).caf")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) { data[0][frame] = fill(frame) }
        let writer = try AVAudioFile(
            forWriting: file,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
        writer.close()
        return file
    }

    /// A 44.1 kHz mono AAC `.m4a`; `fill` gives the sample at a frame.
    func m4a(seconds: Double, fill: (Int) -> Float) throws -> URL {
        let file = url.appending(path: "\(UUID().uuidString).m4a")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) { data[0][frame] = fill(frame) }
        let writer = try AVAudioFile(
            forWriting: file,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
        writer.close()
        return file
    }
}

@Suite struct AudioFileReaderTests {
    @Test func readsAtMostTheAskedSamplesUntilTheEnd() async throws {
        let dir = try FixtureDirectory()
        let file = try dir.wav(seconds: 3, channels: 1) { _, frame in sin(Float(frame) * 0.06) * 0.5 }
        let reader = try AudioFileReader(url: file)
        #expect(abs(reader.durationSeconds - 3) < 0.01)

        // Bounded, so a reader that never reports the end fails rather than hangs.
        var chunks: [[Int16]] = []
        var ended = false
        for _ in 0..<10 {
            let chunk = try await reader.read(maxSamples: 16_000)
            if chunk.isEmpty {
                ended = true
                break
            }
            chunks.append(chunk)
        }
        #expect(ended)
        #expect(chunks.allSatisfy { $0.count <= 16_000 })
        // Exact: slack would hide a dropped tail. The end of the file
        // (`eofErr`) is the end of the audio, not a read error.
        #expect(chunks.reduce(0) { $0 + $1.count } == 48_000)
        let whole = try await AudioFileReader(url: file).read(maxSamples: .max)
        #expect(Array(chunks.joined()) == whole)
        #expect(try await reader.read(maxSamples: 16_000) == [])
    }

    @Test func onlyCoreAudiosEndOfFileCountsAsTheEnd() {
        #expect(AudioFileReader.isEndOfFile(NSError(domain: NSOSStatusErrorDomain, code: -39)))
        #expect(!AudioFileReader.isEndOfFile(NSError(domain: NSOSStatusErrorDomain, code: -50)))
        #expect(!AudioFileReader.isEndOfFile(CocoaError(.fileReadCorruptFile)))
    }

    // ios-pr-199: a file whose audio stops short of its header's length.
    @Test func aFileCutShortOfItsHeaderIsAReadError() async throws {
        let dir = try FixtureDirectory()
        let file = try dir.caf(seconds: 3) { frame in sin(Float(frame) * 0.06) * 0.5 }
        // Cut the audio data about in half; the header still gives 3 s.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size / 2))
        try handle.close()

        let reader = try AudioFileReader(url: file)
        #expect(abs(reader.durationSeconds - 3) < 0.01)
        var samples = 0
        var failure: (any Error)?
        for _ in 0..<10 {
            do {
                let chunk = try await reader.read(maxSamples: 16_000)
                if chunk.isEmpty { break }
                samples += chunk.count
            } catch {
                failure = error
                break
            }
        }
        // The audio before the cut still comes out, then the damage is raised.
        #expect(samples > 16_000 && samples < 32_000)
        #expect(failure as? AudioFileDecoderError == .endedEarly)
    }

    // One rule for every format, VBR included: a whole packet short is early.
    @Test func aVBRFileAWholePacketShortIsAnEarlyEnd() {
        // AAC: 1,024 frames per packet.
        #expect(AudioFileReader.endedEarly(at: 88_200 - 1_024, length: 88_200, framesPerPacket: 1_024))
        #expect(!AudioFileReader.endedEarly(at: 88_200 - 1_023, length: 88_200, framesPerPacket: 1_024))
        #expect(!AudioFileReader.endedEarly(at: 88_200, length: 88_200, framesPerPacket: 1_024))
        // No second, 2% or five-second allowance any more.
        #expect(AudioFileReader.endedEarly(at: 88_200 - 44_100, length: 88_200, framesPerPacket: 1_024))
    }

    // ios-pr-199-r3: exact to one packet, not one read block.
    @Test func aPCMLengthIsExactToOnePacket() {
        // A 2 s PCM file cut to 1 s is early; so is a 4 h one short by 288 s.
        #expect(AudioFileReader.endedEarly(at: 44_100, length: 88_200, framesPerPacket: 1))
        let fourHours: AVAudioFramePosition = 44_100 * 3_600 * 4
        #expect(AudioFileReader.endedEarly(at: fourHours - fourHours / 50, length: fourHours, framesPerPacket: 1))
        // Ending on the length is not; one PCM frame short is.
        #expect(!AudioFileReader.endedEarly(at: 88_200, length: 88_200, framesPerPacket: 1))
        #expect(AudioFileReader.endedEarly(at: 88_200 - 1, length: 88_200, framesPerPacket: 1))
        #expect(AudioFileReader.endedEarly(at: 88_200 - 32_768, length: 88_200, framesPerPacket: 1))
        // A 64-frame IMA4 packet: less than a packet short is not early, a whole packet is.
        #expect(!AudioFileReader.endedEarly(at: 88_200 - 63, length: 88_200, framesPerPacket: 64))
        #expect(AudioFileReader.endedEarly(at: 88_200 - 64, length: 88_200, framesPerPacket: 64))
        // A format that gives no frames per packet (0) counts as one frame.
        #expect(AudioFileReader.endedEarly(at: 88_200 - 1, length: 88_200, framesPerPacket: 0))
        #expect(!AudioFileReader.endedEarly(at: 88_200, length: 88_200, framesPerPacket: 0))
    }

    // A read that returns no frames and no error is checked like `eofErr`.
    @Test func aZeroFrameReadShortOfTheLengthIsAnEarlyEnd() {
        let early = AudioFileReader.endOfInputError(nil, at: 44_100, length: 88_200, framesPerPacket: 1)
        #expect(early as? AudioFileDecoderError == .endedEarly)
        #expect(AudioFileReader.endOfInputError(nil, at: 88_200, length: 88_200, framesPerPacket: 1) == nil)
        let eof = NSError(domain: NSOSStatusErrorDomain, code: -39)
        let eofEarly = AudioFileReader.endOfInputError(eof, at: 44_100, length: 88_200, framesPerPacket: 1)
        #expect(eofEarly as? AudioFileDecoderError == .endedEarly)
        #expect(AudioFileReader.endOfInputError(eof, at: 88_200, length: 88_200, framesPerPacket: 1) == nil)
        let other = NSError(domain: NSOSStatusErrorDomain, code: -50)
        #expect(AudioFileReader.endOfInputError(other, at: 88_200, length: 88_200, framesPerPacket: 1) as? NSError == other)
    }

    // A real AAC .m4a reads to its end with no error and all its audio.
    @Test func anAACFileReadsToItsEnd() async throws {
        let dir = try FixtureDirectory()
        let file = try dir.m4a(seconds: 5) { frame in sin(Float(frame) * 0.06) * 0.5 }
        let reader = try AudioFileReader(url: file)
        let samples = try await reader.read(maxSamples: .max)
        let expected = reader.durationSeconds * 16_000
        #expect(abs(reader.durationSeconds - 5) < 0.1)
        #expect(abs(Double(samples.count) - expected) <= expected * 0.01)
        #expect(try await reader.read(maxSamples: 16_000) == [])
    }

    // ios-pr-199-r3: a cut smaller than one read block (32,768 frames) was never reported.
    @Test func aCAFCutByLessThanOneReadBlockIsAReadError() async throws {
        let dir = try FixtureDirectory()
        let file = try dir.caf(seconds: 10) { frame in sin(Float(frame) * 0.06) * 0.5 }
        // Drop the last 0.5 s (22,050 16-bit frames); the header still gives 10 s.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size - 22_050 * 2))
        try handle.close()

        let reader = try AudioFileReader(url: file)
        #expect(abs(reader.durationSeconds - 10) < 0.01)
        let samples = try await reader.read(maxSamples: .max)
        #expect(samples.count > 16_000 * 9)
        await #expect(throws: AudioFileDecoderError.endedEarly) { try await reader.read(maxSamples: 16_000) }
    }

    @Test func aLongCAFCutByLessThanTwoPercentIsAReadError() async throws {
        let dir = try FixtureDirectory()
        let file = try dir.caf(seconds: 120) { frame in sin(Float(frame) * 0.06) * 0.5 }
        // Drop the last 1% (1.2 s, 52,920 16-bit frames); the header still gives 120 s.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size - 52_920 * 2))
        try handle.close()

        let reader = try AudioFileReader(url: file)
        #expect(abs(reader.durationSeconds - 120) < 0.01)
        let samples = try await reader.read(maxSamples: .max)
        #expect(samples.count > 16_000 * 118)
        await #expect(throws: AudioFileDecoderError.endedEarly) { try await reader.read(maxSamples: 16_000) }
    }

    @Test func stereoFileKeepsTheRightChannel() async throws {
        let dir = try FixtureDirectory()
        // A speaker on the right only; the left is silent.
        let file = try dir.wav(seconds: 1, channels: 2) { channel, frame in
            channel == 1 ? sin(Float(frame) * 0.06) * 0.5 : 0
        }
        let reader = try AudioFileReader(url: file)
        let mono = try await reader.read(maxSamples: 32_000)
        #expect(mono.count > 15_000)
        #expect((mono.map { abs(Int($0)) }.max() ?? 0) > 3_000)
    }
}

@Suite struct DictationReviewTests {
    @Test func aWhitespaceTrimAloneIsNotCleaned() async {
        let processor = DictationPostProcessor(clean: { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let processed = await processor.process(" hello there\n")
        #expect(processed.text == "hello there")
        #expect(!processed.wasCleaned)
        #expect(await DictationPostProcessor(clean: { _ in "Hello there." }).process(" hello there").wasCleaned)
    }

    @Test func transcribingStaysFreshThroughTheHubBudget() {
        // The hub's 180 s plus at least 30 s for the upload itself.
        #expect(DictationActivityContent.transcribingStaleAfter >= 180 + 30)
        // And never stale while the take is still inside its own request timeout.
        #expect(DictationActivityContent.transcribingStaleAfter >= TranscriptionClient.requestTimeout)
    }

    @Test func aSecondSaveTapWhileSavingIsIgnored() {
        var status = SaveNoteStatus.idle
        var began = status.beginSaving("text") != nil
        #expect(began)
        #expect(status.isSaving)
        began = status.beginSaving("text") != nil
        #expect(!began)
        status = .saved("text")
        began = status.beginSaving("text") != nil
        #expect(!began)
        status = .failed("offline")
        began = status.beginSaving("text") != nil
        #expect(began)
    }
}

/// Records the order operations finish in.
private actor Order {
    private(set) var finished: [Int] = []
    func add(_ value: Int) { finished.append(value) }
}

@MainActor
@Suite struct SerialTaskChainTests {
    @Test func laterWorkWaitsForEarlierWork() async {
        let chain = SerialTaskChain()
        let order = Order()
        chain.enqueue {
            try? await Task.sleep(for: .milliseconds(50))
            await order.add(1)
        }
        chain.enqueue { await order.add(2) }
        chain.enqueue { await order.add(3) }
        await chain.drain()
        #expect(await order.finished == [1, 2, 3])
    }

    // A quick op releases the next at once, not after maxWait.
    @Test func aQuickOperationReleasesTheNextWithoutWaitingOutMaxWait() async {
        let chain = SerialTaskChain(maxWait: .seconds(30))
        let order = Order()
        let clock = ContinuousClock()
        let began = clock.now
        chain.enqueue { await order.add(1) }
        chain.enqueue { await order.add(2) }
        chain.enqueue { await order.add(3) }
        await chain.drain()
        #expect(await order.finished == [1, 2, 3])
        #expect(clock.now - began < .seconds(5))
    }

    @Test func aStalledOperationHoldsLaterWorkOnlyForMaxWaitThenKeepsOrder() async {
        let chain = SerialTaskChain(maxWait: .milliseconds(100))
        let order = Order()
        // Cancelled at the end, so no hour-long sleep outlives the test.
        let stall = Task.detached { try? await Task.sleep(for: .seconds(3_600)) }
        chain.enqueue { await stall.value }
        chain.enqueue { await order.add(2) }
        // After the timeout the chain still runs in order: a slow op, then a fast one.
        chain.enqueue {
            try? await Task.sleep(for: .milliseconds(50))
            await order.add(3)
        }
        chain.enqueue { await order.add(4) }
        // Polled, not drained: a chain that waits for good would hang the test.
        for _ in 0..<100 {
            if await order.finished.count == 3 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        stall.cancel()
        #expect(await order.finished == [2, 3, 4])
    }
}
