import Foundation
import Observation

/// The phone's link to the hub: whether a key is stored, whether it works,
/// and the device it names. The onboarding view renders `state` and calls
/// `connect`, `restore`, and `forget`.
@MainActor
@Observable
public final class HubConnection {
    public enum State: Equatable, Sendable {
        /// No key stored: show onboarding.
        case needsKey
        /// A whoami call is in flight.
        case checking
        /// The stored key works and names this device.
        case connected(HubDevice)
        /// A key is stored but the last check failed. The key is kept, because
        /// the phone may simply be offline; the user can retry or forget it.
        case stored(HubError)
    }

    /// Why the last `connect` attempt did not connect.
    public enum ConnectFailure: Equatable, Sendable {
        case hub(HubError)
        /// The hub accepted the key but this phone could not store it.
        case keyNotSaved
    }

    public private(set) var state: State = .needsKey
    /// The failure from the last `connect` attempt, for the onboarding view.
    public private(set) var lastError: ConnectFailure?

    private let client: HubClient
    private let store: any DeviceKeyStore

    public init(client: HubClient, store: any DeviceKeyStore) {
        self.client = client
        self.store = store
    }

    /// On launch: check a stored key against the hub, or ask for one.
    public func restore() async {
        guard let key = try? store.load() else {
            state = .needsKey
            return
        }
        state = .checking
        do {
            state = .connected(try await client.whoami(key: key))
        } catch {
            state = .stored(error)
        }
    }

    /// Validate a pasted key with the hub, and store it only if the hub
    /// accepts it.
    public func connect(pastedKey: String) async {
        let key = DeviceKey.normalized(pastedKey)
        lastError = nil
        state = .checking
        let device: HubDevice
        do {
            device = try await client.whoami(key: key)
        } catch {
            lastError = .hub(error)
            state = .needsKey
            return
        }
        do {
            try store.save(key)
        } catch {
            lastError = .keyNotSaved
            state = .needsKey
            return
        }
        state = .connected(device)
    }

    /// Remove the stored key and go back to onboarding.
    public func forget() {
        try? store.delete()
        lastError = nil
        state = .needsKey
    }
}
