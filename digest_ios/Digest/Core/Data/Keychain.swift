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

    /// nil이나 빈 글자를 주면 지운다. 저장(또는 삭제)에 성공했는지 돌려준다.
    /// 있던 값은 지우고 다시 넣지 않고 그 자리에서 바꾼다. 쓰기에 실패해도 옛 값이 남는다.
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // 이 기기에만 둔다. 백업을 다른 기기로 옮겨도 토큰은 따라가지 않는다.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(key).merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status == errSecSuccess
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

    /// 둘 다 저장돼야 성공이다. DB를 먼저 넣어, 실패해도 쓰던 토큰은 남게 한다.
    @discardableResult
    func save() -> Bool {
        Keychain.set(databaseID, for: Self.databaseKey) && Keychain.set(token, for: Self.tokenKey)
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
