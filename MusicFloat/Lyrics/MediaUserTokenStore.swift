import Foundation
import Security
import OSLog

/// Stores the user's Apple Music `media-user-token` (the cookie from
/// `.music.apple.com` after sign-in) in the macOS Keychain.
///
/// Keychain over UserDefaults because the token grants read access to the
/// user's Apple Music library and any cached web requests they could make
/// while signed in — same blast radius as a session cookie, so it stays
/// out of plain-text plists.
enum MediaUserTokenStore {
    private static let service = "cv.MusicFloat.AppleMusicWeb"
    private static let account = "media-user-token"

    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            clear()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Try update first; if nothing to update, add.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                AppTelemetry.settings.error("MediaUserTokenStore add failed status=\(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            AppTelemetry.settings.error("MediaUserTokenStore update failed status=\(updateStatus)")
        }
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppTelemetry.settings.error("MediaUserTokenStore clear failed status=\(status)")
        }
    }

    static var isConfigured: Bool {
        read()?.isEmpty == false
    }
}
