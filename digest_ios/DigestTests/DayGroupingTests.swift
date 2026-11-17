import Foundation
import Testing
@testable import Digest

/// 날짜로 묶고 줄 세우는 규칙, 카드에 붙는 표시
struct DayGroupingTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 4, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func card(_ id: String, created: Date, published: String?, title: String = "제목", source: String = "출처") -> Card {
        Card(id: id, createdAt: created, editedAt: created, title: title, publishedDay: published,
             tags: [], source: source, link: nil, summary: "요약", notionURL: nil)
    }

    @Test func groupsByCreatedDayNewestFirst() {
        let cards = [
            Self.card("a", created: Self.date(2026, 11, 13), published: "2026-11-12"),
            Self.card("b", created: Self.date(2026, 11, 15), published: "2026-11-14"),
            Self.card("c", created: Self.date(2026, 11, 15, 4, 3), published: "2026-11-14"),
        ]
        let sections = DayGrouping.sections(from: cards, calendar: Self.calendar)
        #expect(sections.map(\.day) == [Self.date(2026, 11, 15, 0), Self.date(2026, 11, 13, 0)])
        #expect(sections.map(\.cards.count) == [2, 1])
    }

    /// 새벽 4시(KST)는 UTC로 전날 19시다. 기기 시간대의 날짜로 묶여야 한다.
    @Test func usesLocalDayNotUTCDay() {
        let created = Date(timeIntervalSince1970: 1_794_682_800)  // 2026-11-14T19:00Z = 11-15 04:00 KST
        let sections = DayGrouping.sections(from: [Self.card("a", created: created, published: nil)], calendar: Self.calendar)
        #expect(sections.first?.day == Self.date(2026, 11, 15, 0))
    }

    @Test func sortsFreshPostsBeforeBackfilledOnes() {
        let created = Self.date(2026, 11, 7)
        let cards = [
            Self.card("old", created: created, published: "2017-08-03"),
            Self.card("fresh", created: created, published: "2026-11-06"),
            Self.card("none", created: created, published: nil),
            Self.card("mid", created: created, published: "2021-01-01"),
        ]
        #expect(DayGrouping.sorted(cards, calendar: Self.calendar).map(\.id) == ["fresh", "mid", "old", "none"])
    }

    @Test func labelsTodayYesterdayAndOlderDays() {
        let now = Self.date(2026, 11, 17, 9)
        let calendar = Self.calendar
        #expect(DayGrouping.label(for: Self.date(2026, 11, 17, 0), now: now, calendar: calendar) == "오늘")
        #expect(DayGrouping.label(for: Self.date(2026, 11, 16, 0), now: now, calendar: calendar) == "어제")
        #expect(DayGrouping.label(for: Self.date(2026, 11, 13, 0), now: now, calendar: calendar) == "11월 13일 금요일")
        #expect(DayGrouping.label(for: Self.date(2025, 12, 30, 0), now: now, calendar: calendar) == "2025년 12월 30일 화요일")
    }

    @Test func oldPostLabelAppearsOnlyWhenPublishedMoreThanAWeekBefore() {
        let now = Self.date(2026, 11, 17, 9)
        let calendar = Self.calendar
        let created = Self.date(2026, 11, 15)
        func label(_ published: String?) -> String? {
            Self.card("x", created: created, published: published).oldPostLabel(now: now, calendar: calendar)
        }
        #expect(label("2026-11-14") == nil)
        #expect(label("2026-11-08") == nil)          // 정확히 7일
        #expect(label("2026-11-07") == "11월 7일 글")  // 8일
        #expect(label("2026-03-05") == "3월 5일 글")
        #expect(label("2020-03-18") == "2020년 3월 글")
        #expect(label(nil) == nil)
    }

    @Test func displaySourceDropsFeedSuffixes() {
        func name(_ source: String) -> String { Self.card("x", created: .now, published: nil, source: source).displaySource }
        #expect(name("당근 테크 블로그 - Medium") == "당근 테크 블로그")
        #expect(name("Banksalad RSS Feed") == "Banksalad")
        #expect(name("MUSINSA techblog — 무신사 테크 블로그 - Medium") == "MUSINSA techblog — 무신사 테크 블로그")
        #expect(name("우아한형제들 기술블로그") == "우아한형제들 기술블로그")
    }

    @Test func mergeOverwritesEditedCardsAndRemovesTrashed() async {
        let existing = [
            Self.card("a", created: Self.date(2026, 11, 13), published: nil, title: "옛 제목"),
            Self.card("b", created: Self.date(2026, 11, 14), published: nil),
        ]
        let fetched = [
            Self.card("a", created: Self.date(2026, 11, 13), published: nil, title: "새 제목"),
            Self.card("c", created: Self.date(2026, 11, 15), published: nil),
        ]
        let merged = await CardStore.merge(existing, with: fetched, removing: ["b"])
        #expect(Set(merged.map(\.id)) == ["a", "c"])
        #expect(merged.first { $0.id == "a" }?.title == "새 제목")
    }
}
