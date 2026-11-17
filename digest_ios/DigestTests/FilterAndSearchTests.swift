import Foundation
import Testing
@testable import Digest

/// 필터, 검색, 몰린 날 접기, 이전·다음 글, 새로 온 날 기준
struct FilterAndSearchTests {
    static func card(_ id: String, title: String = "제목", summary: String = "요약", source: String = "출처",
                     tags: [String] = [], created: Date = Date(timeIntervalSince1970: 1_794_682_800)) -> Card {
        Card(id: id, createdAt: created, editedAt: created, title: title, publishedDay: nil,
             tags: tags.map { CardTag(name: $0, color: "blue") }, source: source, link: nil, summary: summary, notionURL: nil)
    }

    // MARK: 필터

    @Test func inactiveFilterMatchesEverything() {
        let filter = TimelineFilter()
        #expect(filter.isActive == false)
        #expect(filter.matches(Self.card("a"), isSaved: false))
    }

    @Test func savedTagAndSourceConditionsAllApply() {
        let card = Self.card("a", source: "당근 테크 블로그 - Medium", tags: ["개발", "AI"])
        #expect(TimelineFilter(savedOnly: true).matches(card, isSaved: false) == false)
        #expect(TimelineFilter(savedOnly: true).matches(card, isSaved: true))
        #expect(TimelineFilter(tag: "AI").matches(card, isSaved: false))
        #expect(TimelineFilter(tag: "디자인").matches(card, isSaved: false) == false)
        // 출처는 꼬리를 뗀 이름으로 비교한다
        #expect(TimelineFilter(source: "당근 테크 블로그").matches(card, isSaved: false))
        #expect(TimelineFilter(tag: "AI", source: "토스").matches(card, isSaved: false) == false)
    }

    // MARK: 검색

    @Test func searchLooksAtTitleSummarySourceTagsAndPoints() {
        let card = Self.card("a", title: "쿠버네티스 프로브", summary: "무중단 배포 설정", source: "Beomy RSS Feed", tags: ["인프라"])
        func found(_ query: String, points: [String] = []) -> Bool {
            CardSearch.matches(card, points: points, tokens: CardSearch.tokens(query))
        }
        #expect(found("쿠버네티스"))
        #expect(found("무중단"))
        #expect(found("beomy"))          // 대소문자를 가리지 않는다
        #expect(found("인프라"))
        #expect(found("readiness") == false)
        #expect(found("readiness", points: ["Readiness 프로브가 트래픽을 막는다"]))
    }

    @Test func everyWordMustMatch() {
        let card = Self.card("a", title: "쿠버네티스 프로브", summary: "무중단 배포 설정")
        #expect(CardSearch.matches(card, points: [], tokens: CardSearch.tokens("  쿠버네티스   배포 ")))
        #expect(CardSearch.matches(card, points: [], tokens: CardSearch.tokens("쿠버네티스 스벨트")) == false)
        #expect(CardSearch.tokens("   ").isEmpty)
        #expect(CardSearch.matches(card, points: [], tokens: []))
    }

    // MARK: 필터 메뉴 목록

    @Test func facetsAreSortedByCountThenName() {
        let cards = [
            Self.card("1", source: "토스 - Medium", tags: ["개발", "AI"]),
            Self.card("2", source: "토스", tags: ["개발"]),
            Self.card("3", source: "가나다 RSS Feed", tags: ["AI", "보안"]),
            Self.card("4", source: "", tags: []),
        ]
        #expect(Facets.tags(in: cards).map(\.name) == ["AI", "개발", "보안"])
        #expect(Facets.tags(in: cards).map(\.count) == [2, 2, 1])
        // 꼬리를 뗀 이름으로 합친다. 빈 출처는 뺀다.
        #expect(Facets.sources(in: cards).map(\.name) == ["토스", "가나다"])
        #expect(Facets.sources(in: cards).first?.count == 2)
    }

    // MARK: 몰린 날 접기

    @Test func daysWithMoreThanTenCardsCollapseToFive() {
        let ten = (0..<10).map { Self.card("\($0)") }
        let forty = (0..<40).map { Self.card("\($0)") }
        #expect(DayGrouping.collapse(ten, isExpanded: false).hiddenCount == 0)
        let collapsed = DayGrouping.collapse(forty, isExpanded: false)
        #expect(collapsed.shown.map(\.id) == ["0", "1", "2", "3", "4"])
        #expect(collapsed.hiddenCount == 35)
        #expect(DayGrouping.collapse(forty, isExpanded: true).shown.count == 40)
    }

    // MARK: 이전·다음 글

    @Test func neighborsStopAtBothEnds() {
        let order = ["a", "b", "c"]
        #expect(ReadingOrder.neighbor(of: "a", in: order, offset: -1) == nil)
        #expect(ReadingOrder.neighbor(of: "a", in: order, offset: 1) == "b")
        #expect(ReadingOrder.neighbor(of: "c", in: order, offset: -1) == "b")
        #expect(ReadingOrder.neighbor(of: "c", in: order, offset: 1) == nil)
        #expect(ReadingOrder.neighbor(of: "x", in: order, offset: 1) == nil)
        #expect(ReadingOrder.neighbor(of: "a", in: [], offset: 1) == nil)
    }

    // MARK: 새로 온 날 기준

    @Test func visitRollsOverOnlyAfterThirtyMinutesAway() {
        let closed = Date(timeIntervalSince1970: 1_000_000)
        var meta = SyncMeta()
        // 첫 방문: 기준이 없다
        VisitTracker.activate(&meta, now: closed)
        #expect(meta.lastVisitAt == nil)

        VisitTracker.background(&meta, now: closed)
        // 10분 뒤에 돌아오면 같은 방문이다
        VisitTracker.activate(&meta, now: closed.addingTimeInterval(10 * 60))
        #expect(meta.lastVisitAt == nil)
        #expect(meta.backgroundedAt == closed)

        // 한 시간 뒤에 돌아오면 닫았던 시각이 지난번 방문이 된다
        VisitTracker.activate(&meta, now: closed.addingTimeInterval(3600))
        #expect(meta.lastVisitAt == closed)
        #expect(meta.backgroundedAt == nil)
    }

    @Test func syncMetaSurvivesMissingAndUnknownFields() throws {
        let json = #"{"databaseTitle": "Reeder 읽기 요약", "somethingNew": 1}"#
        let meta = try JSONDecoder().decode(SyncMeta.self, from: Data(json.utf8))
        #expect(meta.databaseTitle == "Reeder 읽기 요약")
        #expect(meta.dataSourceID == nil)
        #expect(meta.lastSyncAt == nil)
    }
}
