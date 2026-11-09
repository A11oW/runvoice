import Foundation
import Security

/// Небольшая обёртка над Keychain для ключа прямого API.
enum Keychain {
    static let service = "ai.opencode.runvoice"
    static let directAPIKeyAccount = "direct-api-key"
    private static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecParam {
            // Некоторые старые связки ключей не позволяют менять accessibility
            // у существующего элемента; данные сохраняем без потери.
            attributes.removeValue(forKey: kSecAttrAccessible as String)
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            Log.write("keychain: не удалось обновить accessibility")
        }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = accessibility
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.write("keychain: ошибка добавления \(addStatus)")
            }
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
