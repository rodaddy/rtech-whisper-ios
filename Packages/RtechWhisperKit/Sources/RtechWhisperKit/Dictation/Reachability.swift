import Foundation

/// Reports when the network comes and goes, so the queue can drain as soon as
/// the hub may be reachable again. Tests drive a fake.
public protocol ReachabilityMonitoring: AnyObject, Sendable {
    /// Begin reporting. `onChange(true)` means a usable path appeared.
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

#if canImport(Network)
import Network

/// The real monitor, via `NWPathMonitor`.
///
/// Not unit-tested: it reports the host's real network.
public final class PathReachability: ReachabilityMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.rtech-consulting.whisper.reachability")

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}
#endif

/// Asks for microphone access. The system prompt appears only the first time.
public typealias RequestMicrophone = @Sendable () async -> Bool

#if canImport(AVFAudio)
import AVFAudio

public enum MicrophonePermission {
    /// The real request, via `AVAudioApplication`. Not unit-tested: it needs a
    /// signed host and a person to answer the prompt.
    public static let request: RequestMicrophone = {
        await AVAudioApplication.requestRecordPermission()
    }
}
#endif
