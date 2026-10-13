import Foundation

/// Dictation's `Transcribe`, sending the dictionary hint as the relay's
/// `prompt`, as uploads do. The hint is read on every send, so a word added
/// to the dictionary applies to the next take and to queued retries.
public func prompted(
    _ transcribe: @escaping TranscribeWithPrompt,
    hint: @escaping @MainActor @Sendable () -> String?
) -> Transcribe {
    { wav throws(HubError) in
        let prompt = await hint()
        return try await transcribe(wav, prompt)
    }
}
