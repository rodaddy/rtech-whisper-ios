import Foundation

/// The audio shape the hub relay accepts: WAV, PCM16, mono, 16000 Hz
/// (hub protocol section 10.1). Anything else gets a 415.
public enum WavEncoder {
    public static let relaySampleRate = 16_000
    /// Size of the canonical RIFF/WAVE header written by `pcm16MonoWav`.
    public static let headerLength = 44

    /// A canonical 44-byte-header WAV file holding `samples` as 16-bit
    /// little-endian mono PCM.
    public static func pcm16MonoWav(samples: [Int16], sampleRate: Int = relaySampleRate) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataLength = samples.count * blockAlign

        var data = Data(capacity: headerLength + dataLength)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + dataLength))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))              // fmt chunk size
        data.appendLE(UInt16(1))               // PCM
        data.appendLE(UInt16(channels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(UInt16(blockAlign))
        data.appendLE(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(dataLength))
        for sample in samples {
            data.appendLE(UInt16(bitPattern: sample))
        }
        return data
    }
}

/// Pure sample conversion from whatever the microphone delivers to the
/// relay's 16 kHz Int16 mono. The recorder does no math of its own.
public enum AudioConverter {
    /// Average several channels of equal length into one.
    public static func downmix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let count = channels.map(\.count).min() ?? 0
        let scale = 1 / Float(channels.count)
        return (0..<count).map { index in
            channels.reduce(Float(0)) { $0 + $1[index] } * scale
        }
    }

    /// Linearly resample mono Float32 audio at `inputRate` Hz to
    /// `outputRate` Hz. Output length is `floor(count * outputRate / inputRate)`.
    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double = Double(WavEncoder.relaySampleRate)) -> [Float] {
        guard !samples.isEmpty, inputRate > 0, outputRate > 0 else { return [] }
        if inputRate == outputRate { return samples }
        let outputCount = Int((Double(samples.count) * outputRate / inputRate).rounded(.down))
        let step = inputRate / outputRate
        let last = samples.count - 1
        return (0..<outputCount).map { index in
            let position = Double(index) * step
            let lower = min(Int(position), last)
            let upper = min(lower + 1, last)
            let fraction = Float(position - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    /// Float32 in [-1, 1] to Int16, clamping anything outside the range.
    /// NaN becomes silence.
    public static func toInt16(_ sample: Float) -> Int16 {
        guard !sample.isNaN else { return 0 }
        let scaled = (sample * 32_767).rounded()
        if scaled >= 32_767 { return .max }
        if scaled <= -32_768 { return .min }
        return Int16(scaled)
    }

    /// Mono Float32 at any rate to the relay's 16 kHz Int16 mono.
    public static func toRelayPCM(_ samples: [Float], sampleRate: Double) -> [Int16] {
        resample(samples, from: sampleRate).map(toInt16)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
