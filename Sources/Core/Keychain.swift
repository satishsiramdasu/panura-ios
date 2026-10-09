import Foundation
import Security

/// Passwords, and nothing else.
///
/// Server credentials cannot live in `UserDefaults` beside the rest of the
/// preferences: that file is plain plist in the app container, readable by
/// anything that gets at a backup. The rest of a saved server — name, host,
/// port, path, username — is ordinary settings data and stays where settings
/// live. Only the password comes here.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the browser may want to
/// reconnect while the screen is locked (a video playing on in the background),
/// so `WhenUnlocked` is too strict — but `ThisDeviceOnly` keeps it out of the
/// iCloud keychain and off any other device, which is the right answer for a
/// credential to a box on somebody's own network.
enum Keychain {
    private static let service = "app.panura.servers"

    static func set(_ password: String, for account: String) {
        remove(account)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
