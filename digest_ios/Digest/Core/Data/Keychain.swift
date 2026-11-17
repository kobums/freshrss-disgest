import Foundation
import Security

/// 키체인에 글자 하나를 넣고 꺼내는 얇은 포장
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.gowoobro.digest"

    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func string(for key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil이나 빈 글자를 주면 지운다
    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        // 잠금 화면에서 백그라운드 새로고침이 돌 때도 읽을 수 있게 한다
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Notion 연결 정보. 키체인에만 둔다.
struct Connection: Equatable {
    var token: String
    var databaseID: String

    private static let tokenKey = "notionToken"
    private static let databaseKey = "notionDatabase"

    static func load() -> Connection? {
        guard let token = Keychain.string(for: tokenKey),
              let database = Keychain.string(for: databaseKey) else { return nil }
        return Connection(token: token, databaseID: database)
    }

    func save() {
        Keychain.set(token, for: Self.tokenKey)
        Keychain.set(databaseID, for: Self.databaseKey)
    }

    static func clear() {
        Keychain.set(nil, for: tokenKey)
        Keychain.set(nil, for: databaseKey)
    }

    /// Notion 주소나 ID에서 DB ID 32자리를 뽑는다. 못 찾으면 nil.
    /// 주소 뒤의 `?v=…`(보기 ID)보다 앞에 나오는 것을 쓴다.
    static func databaseID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = "(?<![0-9a-f])([0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f])"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[range].replacingOccurrences(of: "-", with: "")
    }
}
