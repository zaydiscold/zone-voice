// by zayd/cold @ zayd.wtf

import Foundation
import Security
import ZoneCore

/// Zone Link's secrets in the Keychain: the phone's iroh secret key and, per computer, the
/// pairing secret until it is used and the Flash key after.
///
/// Items stay on this device (they are never in a backup or synced to another iPhone) and can
/// be read after the first unlock, so a sync that starts in the background with the phone
/// locked still has the key.
public struct LinkKeychain: LinkSecretStore {
    public let service: String

    public init(service: String = "wtf.zayd.zone.link") {
        self.service = service
    }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    public func secret(_ name: String) -> Data? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public func setSecret(_ value: Data?, for name: String) -> Bool {
        let query = query(name)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }
}
