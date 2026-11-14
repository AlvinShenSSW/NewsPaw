import Foundation
import Security

/// The device keychain as a key store (spec N08; RD13 decision 2).
///
/// Each key is a generic-password item: service
/// `io.newspaw.reader.model-key.<partition>`, account a random UUID (the
/// slot's `key_ref`), readable after the first unlock and on this device
/// only, never synchronised. Every query asks for the data-protection
/// keychain, so a macOS build of the package can never fall back to the
/// file-based login keychain (there it is refused with -34018).
public final class KeychainKeyStore: KeyStore {
    public let partition: Partition
    /// The keychain service of this store's items. Only this partition's.
    let service: String

    public init(partition: Partition) {
        self.partition = partition
        service = Self.service(for: partition)
    }

    #if DEBUG
    /// A store whose service ends with `.<suffix>`: under a UI-test library
    /// directory the app passes the directory's name, so that each test's
    /// keys are its own and never the owner's. Debug builds only.
    public init(partition: Partition, uiTestSuffix suffix: String) {
        self.partition = partition
        service = Self.service(for: partition) + "." + suffix
    }
    #endif

    static func service(for partition: Partition) -> String {
        "io.newspaw.reader.model-key." + partition.rawValue
    }

    private func query(_ reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func add(_ key: SecretKey) throws -> String {
        let reference = UUID().uuidString
        var attributes = query(reference)
        attributes[kSecValueData as String] = Data(key.exposedValue.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.refused(status: status)
        }
        return reference
    }

    public func read(_ reference: String) throws -> SecretKey? {
        var search = query(reference)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // An item that no longer meets the key rule is treated as no
            // key: it is never sent.
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8),
                  case .success(let key) = SecretKey.validate(text)
            else { return nil }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.refused(status: status)
        }
    }

    public func remove(_ reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.refused(status: status)
        }
    }
}
