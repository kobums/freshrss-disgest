import Foundation

/// 연결을 시도했다가 막힌 까닭. 연결 화면이 그대로 문구로 보여 준다.
enum ConnectFailure: Error, Equatable {
    case emptyToken
    /// 입력에서 DB ID 32자리를 찾지 못했다
    case badDatabaseID
    case unauthorized
    case notFound
    /// 파이프라인이 쓰는 속성이 없다
    case missing([String])
    /// 속성은 있는데 종류가 다르다 (예: `링크`가 URL이 아님)
    case wrongType([String])
    case network
    case other(String)

    init(_ error: NotionError) {
        switch error {
        case .unauthorized: self = .unauthorized
        case .notFound: self = .notFound
        case .network: self = .network
        default: self = .other(error.userMessage)
        }
    }

    var message: String {
        switch self {
        case .emptyToken:
            "토큰을 넣어 주세요."
        case .badDatabaseID:
            "데이터베이스 주소나 ID를 알아보지 못했어요. Notion에서 DB의 링크를 복사해 붙여 넣으세요."
        case .unauthorized:
            "토큰이 맞지 않아요."
        case .notFound:
            "데이터베이스를 찾지 못했어요. Notion에서 DB의 ··· → 연결에 이 통합을 추가했는지 확인하세요."
        case .missing(let names):
            "\(Self.quoted(names)) 속성이 없어요. 요약이 쌓이는 DB가 맞는지 확인하세요."
        case .wrongType(let names):
            "\(Self.quoted(names)) 속성의 종류가 달라요. 요약이 쌓이는 DB가 맞는지 확인하세요."
        case .network:
            "연결할 수 없어요. 잠시 뒤 다시 시도하세요."
        case .other(let detail):
            detail.isEmpty ? "연결하지 못했어요. 잠시 뒤 다시 시도하세요." : detail
        }
    }

    private static func quoted(_ names: [String]) -> String {
        names.map { "'\($0)'" }.joined(separator: ", ")
    }
}

enum ConnectCheck {
    /// 데이터 소스의 속성 구성(이름 → 종류)이 파이프라인이 쓰는 것과 맞는지 본다. 맞으면 nil.
    static func failure(in properties: [String: String]) -> ConnectFailure? {
        let missing = NotionSchema.required.filter { properties[$0.name] == nil }.map(\.name)
        if !missing.isEmpty { return .missing(missing) }
        let wrong = NotionSchema.required.filter { properties[$0.name] != $0.type }.map(\.name)
        if !wrong.isEmpty { return .wrongType(wrong) }
        return nil
    }
}

extension NotionError {
    /// 설정 화면에 보여 주는 한 줄
    var userMessage: String {
        switch self {
        case .unauthorized:
            "토큰이 맞지 않아요. 토큰을 바꿔 주세요."
        case .notFound:
            "데이터베이스를 찾지 못했어요. Notion에서 DB의 ··· → 연결에 이 통합을 추가했는지 확인하세요."
        case .rateLimited:
            "Notion이 잠시 요청을 받지 않아요. 조금 뒤에 다시 시도하세요."
        case .network:
            "인터넷에 연결할 수 없어요."
        case .http(let status, _):
            "Notion에서 오류가 왔어요. (\(status))"
        case .invalidResponse:
            "Notion 응답을 읽지 못했어요."
        }
    }
}

/// 읽는 중에 새 카드가 왔을 때 목록을 바로 바꿀지 정한다
enum TimelineUpdate {
    /// 화면에 아직 없는 카드 수
    static func newCount(shown: [DaySection], latest: [DaySection]) -> Int {
        let known = Set(shown.flatMap(\.cards).map(\.id))
        return latest.reduce(0) { $0 + $1.cards.count(where: { !known.contains($0.id) }) }
    }

    /// 맨 위에 있거나 새 카드가 없으면(고친 것·지운 것뿐이면) 바로 바꾼다.
    /// 아래쪽을 읽는 중에 새 카드가 오면 위치가 밀리지 않게 붙들어 둔다.
    static func appliesNow(shown: [DaySection], latest: [DaySection], isAtTop: Bool) -> Bool {
        isAtTop || shown.isEmpty || newCount(shown: shown, latest: latest) == 0
    }
}
