import Foundation

enum NotionError: Error, Equatable {
    /// 401. 토큰이 틀렸거나 폐기됐다
    case unauthorized
    /// 404. DB가 없거나 통합에 연결되지 않았다
    case notFound
    /// 429·529가 재시도 뒤에도 이어진다
    case rateLimited
    /// 인터넷에 닿지 못했다
    case network
    case http(status: Int, message: String)
    case invalidResponse
}

/// Notion API 클라이언트. 읽기만 한다.
struct NotionClient: Sendable {
    /// 데이터 소스 경로를 쓰는 최신 버전. 파이프라인은 2022-06-28 그대로다.
    static let apiVersion = "2026-03-11"
    private static let base = URL(string: "https://api.notion.com/v1/")!

    /// 응답과 요청(Authorization 헤더 포함)을 디스크 캐시에 남기지 않는 세션
    static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let token: String
    var session: URLSession = NotionClient.uncachedSession

    /// DB 이름과 데이터 소스 ID를 얻는다
    func database(id: String) async throws -> NotionDatabase {
        try await send("GET", "databases/\(id)")
    }

    /// 속성 구성을 얻는다
    func dataSource(id: String) async throws -> NotionDataSource {
        try await send("GET", "data_sources/\(id)")
    }

    /// 카드 목록 한 쪽(최대 100장). `editedAfter`를 주면 그 뒤에 바뀐 카드만 받는다.
    func query(dataSourceID: String, editedAfter: Date? = nil, cursor: String? = nil) async throws -> NotionQueryResponse {
        var body: [String: Any] = [
            "page_size": 100,
            "sorts": [["timestamp": "created_time", "direction": "descending"]],
        ]
        if let editedAfter {
            body["filter"] = [
                "timestamp": "last_edited_time",
                "last_edited_time": ["after": NotionDate.format(editedAfter)],
            ]
        }
        if let cursor { body["start_cursor"] = cursor }
        return try await send("POST", "data_sources/\(dataSourceID)/query", body: JSONSerialization.data(withJSONObject: body))
    }

    /// 카드 본문 블록
    func blocks(pageID: String) async throws -> [NotionBlock] {
        var all: [NotionBlock] = []
        var cursor: String?
        repeat {
            var path = "blocks/\(pageID)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let page: NotionBlockList = try await send("GET", path)
            all += page.results
            cursor = page.has_more ? page.next_cursor : nil
        } while cursor != nil
        return all
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw NotionError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        // 한도(429)나 과부하(529)면 Retry-After만큼 쉬고 다시 보낸다
        for attempt in 0..<4 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw NotionError.network
            }
            guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }

            switch http.statusCode {
            case 200..<300:
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    throw NotionError.invalidResponse
                }
            case 401:
                throw NotionError.unauthorized
            case 404:
                throw NotionError.notFound
            case 429, 529:
                guard attempt < 3 else { throw NotionError.rateLimited }
                let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
                try await Task.sleep(for: .seconds(min(max(wait, 1), 60)))
            default:
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message ?? ""
                throw NotionError.http(status: http.statusCode, message: message)
            }
        }
        throw NotionError.rateLimited
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }
}
