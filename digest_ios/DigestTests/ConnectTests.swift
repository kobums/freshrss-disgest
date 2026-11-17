import Foundation
import Testing
@testable import Digest

/// 연결 확인, 주소에서 DB ID 뽑기, 읽는 중에 온 새 카드 처리
struct ConnectTests {
    static let pipelineSchema = [
        "제목": "title", "날짜": "date", "태그": "multi_select",
        "출처": "rich_text", "링크": "url", "한줄요약": "rich_text",
    ]

    @Test func pipelineSchemaPasses() {
        #expect(ConnectCheck.failure(in: Self.pipelineSchema) == nil)
        // 속성이 더 있어도 괜찮다
        var extended = Self.pipelineSchema
        extended["메모"] = "rich_text"
        #expect(ConnectCheck.failure(in: extended) == nil)
    }

    @Test func missingPropertiesAreNamed() {
        var schema = Self.pipelineSchema
        schema["한줄요약"] = nil
        #expect(ConnectCheck.failure(in: schema) == .missing(["한줄요약"]))
        #expect(ConnectFailure.missing(["한줄요약"]).message.contains("'한줄요약' 속성이 없어요"))
        #expect(ConnectCheck.failure(in: ["이름": "title"]) == .missing(["제목", "날짜", "태그", "출처", "링크", "한줄요약"]))
    }

    @Test func wrongPropertyTypeIsReported() {
        var schema = Self.pipelineSchema
        schema["링크"] = "rich_text"
        #expect(ConnectCheck.failure(in: schema) == .wrongType(["링크"]))
    }

    @Test func notionErrorsMapToConnectFailures() {
        #expect(ConnectFailure(.unauthorized) == .unauthorized)
        #expect(ConnectFailure(.notFound) == .notFound)
        #expect(ConnectFailure(.network) == .network)
        #expect(ConnectFailure(.unauthorized).message == "토큰이 맞지 않아요.")
        #expect(ConnectFailure(.network).message == "연결할 수 없어요. 잠시 뒤 다시 시도하세요.")
        // 그 밖의 오류도 빈 문구가 되지 않는다
        #expect(ConnectFailure(.rateLimited).message.isEmpty == false)
        #expect(ConnectFailure.other("").message.isEmpty == false)
    }

    @Test func databaseIDIsExtractedFromAddressOrID() {
        let id = "ba591c8b4bda4127b1a75fa6dc455f85"
        #expect(Connection.databaseID(from: id) == id)
        #expect(Connection.databaseID(from: "  BA591C8B-4BDA-4127-B1A7-5FA6DC455F85\n") == id)
        // 주소 뒤의 보기 ID(?v=)가 아니라 앞의 DB ID를 쓴다
        #expect(Connection.databaseID(from: "https://www.notion.so/workspace/\(id)?v=11111111111111111111111111111111") == id)
        #expect(Connection.databaseID(from: "https://www.notion.so/Reeder-\(id)") == id)
        #expect(Connection.databaseID(from: "읽기 요약") == nil)
        #expect(Connection.databaseID(from: "") == nil)
    }

    // MARK: 읽는 중에 온 새 카드

    static func section(_ day: TimeInterval, _ ids: [String]) -> DaySection {
        DaySection(day: Date(timeIntervalSince1970: day), cards: ids.map { FilterAndSearchTests.card($0) })
    }

    @Test func newCardsWaitWhileReadingBelowTheTop() {
        let shown = [Self.section(0, ["a", "b"])]
        let latest = [Self.section(86400, ["c", "d"]), Self.section(0, ["a", "b"])]
        #expect(TimelineUpdate.newCount(shown: shown, latest: latest) == 2)
        #expect(TimelineUpdate.appliesNow(shown: shown, latest: latest, isAtTop: false) == false)
        // 맨 위에 있으면 바로 끼워 넣는다
        #expect(TimelineUpdate.appliesNow(shown: shown, latest: latest, isAtTop: true))
    }

    @Test func editsDeletionsAndFirstLoadApplyImmediately() {
        let shown = [Self.section(0, ["a", "b"])]
        // 지운 것뿐이면 새 카드가 없다
        #expect(TimelineUpdate.appliesNow(shown: shown, latest: [Self.section(0, ["a"])], isAtTop: false))
        // 처음 채울 때
        #expect(TimelineUpdate.appliesNow(shown: [], latest: shown, isAtTop: false))
        #expect(TimelineUpdate.newCount(shown: shown, latest: shown) == 0)
    }
}
