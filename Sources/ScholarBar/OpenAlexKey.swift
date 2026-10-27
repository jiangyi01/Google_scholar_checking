import Foundation
import Security

/// The optional OpenAlex API key the user pastes in Settings. It is a
/// credential (it carries the user's own daily budget), so it lives in the
/// login Keychain rather than in UserDefaults or state.json.
///
/// The app is ad-hoc signed, so after a rebuild macOS may ask once whether
/// ScholarBar may read the item an earlier build saved. The value is cached
/// for the rest of the launch so that question comes up at most once; with no
/// key saved nothing is stored and nothing is ever asked.
enum OpenAlexKey {
    private static let service = "com.yijiang.scholarbar.openalex"
    private static let account = "api_key"
    /// .some(nil) = looked, nothing there. nil = not looked yet.
    private static var cached: String??

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String? {
        if let cached { return cached }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var value: String?
        switch status {
        case errSecSuccess:
            value = (item as? Data).flatMap { clean(String(decoding: $0, as: UTF8.self)) }
        case errSecItemNotFound:
            value = nil
        case errSecInteractionNotAllowed:
            // Keychain still locked (very early at login): try again next time.
            NSLog("ScholarBar: Keychain locked; OpenAlex key not read yet")
            return nil
        default:
            // Includes the user clicking "Deny": don't ask again this launch.
            NSLog("ScholarBar: reading the OpenAlex key failed (OSStatus \(status))")
        }
        cached = .some(value)
        return value
    }

    /// nil/empty deletes.
    static func save(_ key: String?) {
        let value = clean(key)
        if let cached, cached == value { return }
        let status: OSStatus
        if let value {
            let data = Data(value.utf8)
            var s = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if s == errSecItemNotFound {
                var add = baseQuery
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = "ScholarBar – OpenAlex API key"
                s = SecItemAdd(add as CFDictionary, nil)
            }
            status = s
        } else {
            let s = SecItemDelete(baseQuery as CFDictionary)
            status = s == errSecItemNotFound ? errSecSuccess : s
        }
        if status == errSecSuccess {
            cached = .some(value)
        } else {
            NSLog("ScholarBar: saving the OpenAlex key failed (OSStatus \(status))")
            // Unknown what the Keychain holds now; read it again next time.
            cached = nil
        }
    }

    /// Trims whitespace and wrapping quotes from a paste; nil when nothing is left.
    private static func clean(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespacesAndNewlines))
        return t.isEmpty ? nil : t
    }
}
