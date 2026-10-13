import AVFoundation
import Foundation

public enum AudioFileDecoderError: LocalizedError, Equatable {
    /// `AVFoundation` could not convert the file's format to the relay's.
    case unsupportedFormat
    /// The converter stopped with this description.
    case conversionFailed(String)
    /// The file's audio stopped well short of the length its header gives,
    /// as a recording cut off by a crash or a partial copy does.
    case endedEarly

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This audio format cannot be converted."
        case .conversionFailed(let detail): "The audio could not be converted. \(detail)"
        case .endedEarly: "The file ends before the length it says it has."
        }
    }
}

/// The file types the Upload screen offers and how a picked file is opened.
public enum AudioFileDecoder {
    /// The file types the Upload screen offers, as the desktop's picker does.
    public static let fileExtensions = ["m4a", "mp3", "wav", "caf", "aac"]

    /// Opens `url` for reading one chunk at a time.
    public static func open(_ url: URL) throws -> AudioFileReader {
        try AudioFileReader(url: url)
    }
}

/// Reads any audio file `AVAudioFile` opens (m4a, mp3, wav, caf, aac, ...)
/// and converts it to the relay's 16 kHz Int16 mono with `AVAudioConverter`,
/// a block at a time, so only the chunk being sent is ever in memory. Every
/// channel is mixed into the mono track, not just the first.
public actor AudioFileReader: AudioSampleSource {
    public nonisolated let durationSeconds: Double

    private static let framesPerRead: AVAudioFrameCount = 32_768

    private let url: URL
    private let scoped: Bool
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let inBuffer: AVAudioPCMBuffer
    private let outBuffer: AVAudioPCMBuffer
    /// Converted samples not yet handed out, and how the file ended.
    private var drain = BlockDrain()

    public init(url: URL) throws {
        // A `.fileImporter` URL is security-scoped; one that is not answers
        // false. Access lasts as long as the reader.
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let file = try AVAudioFile(forReading: url)
            let input = file.processingFormat
            guard
                let output = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: Double(WavEncoder.relaySampleRate),
                    channels: 1, interleaved: true),
                let converter = AVAudioConverter(from: input, to: output),
                let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: Self.framesPerRead),
                let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: output,
                    frameCapacity: AVAudioFrameCount(Double(Self.framesPerRead) * output.sampleRate / input.sampleRate)
                        + 1024)
            else { throw AudioFileDecoderError.unsupportedFormat }
            // The default keeps only channel 0, which drops the right-hand
            // speaker of a two-channel interview.
            converter.downmix = true
            self.durationSeconds = input.sampleRate > 0 ? Double(file.length) / input.sampleRate : 0
            self.file = file
            self.converter = converter
            self.inBuffer = inBuffer
            self.outBuffer = outBuffer
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.url = url
        self.scoped = scoped
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    public func read(maxSamples: Int) throws -> [Int16] {
        try drain.read(maxSamples: maxSamples) { pending in try convertBlock(into: &pending) }
    }

    /// Converts one output buffer's worth, appending it to `pending`, even
    /// when the read that fed it failed. True once the file has ended.
    private func convertBlock(into pending: inout [Int16]) throws -> Bool {
        let file = file
        let inBuffer = inBuffer
        var readError: (any Error)?
        var inputDone = false
        outBuffer.frameLength = 0
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            guard !inputDone else {
                outStatus.pointee = .noDataNow
                return nil
            }
            inBuffer.frameLength = 0
            // Read until the file says it has ended, by `eofErr` or an empty
            // read, then check where it ended against `file.length`.
            var thrown: (any Error)?
            do {
                try file.read(into: inBuffer, frameCount: Self.framesPerRead)
            } catch {
                thrown = error
            }
            if thrown != nil || inBuffer.frameLength == 0 {
                readError = Self.endOfInputError(
                    thrown, at: file.framePosition, length: file.length,
                    framesPerPacket: AVAudioFramePosition(file.fileFormat.streamDescription.pointee.mFramesPerPacket))
                inputDone = true
                outStatus.pointee = .endOfStream
                return nil
            }
            // One file block per call, so the output buffer never overflows.
            inputDone = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        // Keep what converted, including a tail flushed at the end of the
        // stream, before raising the read error.
        if outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData {
            pending.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
        }
        if let readError { throw readError }
        if status == .error {
            throw AudioFileDecoderError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }
        return status == .endOfStream
    }

    /// Whether `error` is Core Audio's `eofErr` (-39): the file has no more frames.
    static func isEndOfFile(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == -39
    }

    /// The error the input ends with once a read has thrown `error` or
    /// returned no frames (`error` nil), or nil for a clean end. `eofErr`
    /// and an empty read both mean the file has no more frames, so both are
    /// checked against the length; any other error is passed on.
    static func endOfInputError(
        _ error: (any Error)?, at position: AVAudioFramePosition, length: AVAudioFramePosition,
        framesPerPacket: AVAudioFramePosition
    ) -> (any Error)? {
        if let error, !isEndOfFile(error) { return error }
        return endedEarly(at: position, length: length, framesPerPacket: framesPerPacket)
            ? AudioFileDecoderError.endedEarly : nil
    }

    /// Whether the file ended at `position` short of its `length`: one rule
    /// for every format. A shortfall of a whole packet or more is an early
    /// end; less than a packet is not, since a file's last packet may be
    /// partial. A format that gives no frames per packet (0) counts as one
    /// frame per packet, as PCM is.
    static func endedEarly(
        at position: AVAudioFramePosition, length: AVAudioFramePosition, framesPerPacket: AVAudioFramePosition
    ) -> Bool {
        length - position >= max(1, framesPerPacket)
    }
}

/// Converted samples waiting to be handed out, filled a block at a time.
/// A block that fails does not lose the audio converted before it: that
/// audio is handed out first, and the error is raised once it is gone, then
/// on every read after, so a retry never converts past the damage.
struct BlockDrain {
    private var pending: [Int16] = []
    private var finished = false
    private var failure: (any Error)?

    /// At most `maxSamples` samples, converting blocks with `nextBlock` until
    /// there are enough or the audio ended or failed. `nextBlock` appends a
    /// block to its argument and returns true at the end of the audio; it
    /// may append and then throw.
    mutating func read(maxSamples: Int, nextBlock: (inout [Int16]) throws -> Bool) throws -> [Int16] {
        while pending.count < maxSamples, !finished, failure == nil {
            do {
                if try nextBlock(&pending) { finished = true }
            } catch {
                failure = error
            }
        }
        if pending.isEmpty, let failure { throw failure }
        let count = min(max(0, maxSamples), pending.count)
        let out = Array(pending.prefix(count))
        pending.removeFirst(count)
        return out
    }
}
