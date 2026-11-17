import Foundation

/// Notion 태그 옵션 하나. 색은 Notion이 준 이름 그대로 둔다(blue, purple …).
struct CardTag: Codable, Hashable {
    var name: String
    var color: String
}

/// 요약된 글 1건. Notion 페이지 1개와 같다.
struct Card: Codable, Identifiable, Hashable {
    var id: String
    /// 요약이 만들어진 시각. "오늘 온 요약"을 가르는 기준이다.
    var createdAt: Date
    var editedAt: Date
    var title: String
    /// 원문 발행일 "yyyy-MM-dd" (Notion `날짜` 속성). 요약된 날이 아니다.
    var publishedDay: String?
    var tags: [CardTag]
    var source: String
    var link: URL?
    var summary: String
    var notionURL: URL?
}

extension Card {
    /// 발행일을 기기 달력의 그날 0시로 바꾼 값
    func publishedDate(calendar: Calendar = .current) -> Date? {
        guard let publishedDay else { return nil }
        let parts = publishedDay.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 피드 이름에 붙는 꼬리를 뗀 출처 이름
    var displaySource: String {
        var name = source.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Medium", " RSS Feed"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    /// 발행일이 요약된 날보다 7일 넘게 앞서면 "3월 5일 글"(올해) 또는 "2020년 3월 글".
    /// 기술 글은 오래되면 내용이 달라져 있을 수 있어 목록에 적는다.
    func oldPostLabel(now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let published = publishedDate(calendar: calendar) else { return nil }
        let createdDay = calendar.startOfDay(for: createdAt)
        guard let gap = calendar.dateComponents([.day], from: published, to: createdDay).day, gap > 7 else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: published)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        if year == calendar.component(.year, from: now) {
            return "\(month)월 \(day)일 글"
        }
        return "\(year)년 \(month)월 글"
    }
}

/// 같은 날 만들어진 카드 묶음
struct DaySection: Identifiable, Hashable {
    /// 그날 0시 (기기 시간대)
    let day: Date
    var cards: [Card]
    var id: Date { day }
}

enum DayGrouping {
    /// 날짜는 최신순, 같은 날 안에서는 발행일 최신순.
    /// 새 글이 앞에 오고, 뒤늦게 들어온 옛 글이 뒤로 간다.
    static func sections(from cards: [Card], calendar: Calendar = .current) -> [DaySection] {
        let grouped = Dictionary(grouping: cards) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            DaySection(day: day, cards: sorted(grouped[day] ?? [], calendar: calendar))
        }
    }

    static func sorted(_ cards: [Card], calendar: Calendar = .current) -> [Card] {
        cards.sorted { a, b in
            let pa = a.publishedDate(calendar: calendar) ?? .distantPast
            let pb = b.publishedDate(calendar: calendar) ?? .distantPast
            if pa != pb { return pa > pb }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.title < b.title
        }
    }

    /// "오늘", "어제", "11월 13일 목요일". 올해가 아니면 연도를 붙인다.
    static func label(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "어제"
        }
        var style = Date.FormatStyle(locale: Locale(identifier: "ko_KR"), calendar: calendar, timeZone: calendar.timeZone)
            .month().day().weekday(.wide)
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }
}
