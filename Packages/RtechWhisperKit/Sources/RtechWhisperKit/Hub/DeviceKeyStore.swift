import Foundation
import Security

/// Holds the one device key this phone uses to talk to the hub.
public protocol DeviceKeyStore: Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

public enum DeviceKeyStoreError: Error, Equatable, Sendable {
    /// A Security framework call failed with this `OSStatus`.
    case keychain(OSStatus)
    /// The stored item was not UTF-8 text.
    case unreadable
}

/// A store that lives only as long as the process. For tests and previews.
public final class InMemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() throws -> String? {
        lock.withLock { key }
    }

    public func save(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    public func delete() throws {
        lock.withLock { key = nil }
    }
}

/// The real store: one generic-password Keychain item, readable after the
/// first unlock and never synced or restored to another device.
///
/// Not unit-tested: the Keychain needs a signed host. Tests use
/// `InMemoryDeviceKeyStore` behind the `DeviceKeyStore` protocol.
public struct KeychainDeviceKeyStore: DeviceKeyStore {
    public static let service = "com.rtech-consulting.whisper.hub"

    public let account: String

    public init(account: String = "device-key") {
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw DeviceKeyStoreError.unreadable
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw DeviceKeyStoreError.keychain(status)
        }
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(update) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DeviceKeyStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw DeviceKeyStoreError.keychain(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyStoreError.keychain(status)
        }
    }
}
