import Foundation

/// 타임라인에 거는 조건. 태그와 출처는 각각 하나만 고른다.
struct TimelineFilter: Equatable {
    var savedOnly = false
    var tag: String?
    /// `Card.displaySource` 기준
    var source: String?

    var isActive: Bool { savedOnly || tag != nil || source != nil }

    func matches(_ card: Card, isSaved: Bool) -> Bool {
        if savedOnly, !isSaved { return false }
        if let tag, !card.tags.contains(where: { $0.name == tag }) { return false }
        if let source, card.displaySource != source { return false }
        return true
    }
}

/// 기기에 받은 카드 안에서 찾는다. 네트워크를 쓰지 않는다.
enum CardSearch {
    /// 띄어 쓴 단어로 나눈다. 대소문자는 가리지 않는다.
    static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 제목·한줄요약·출처·태그·핵심에 모든 단어가 들어 있어야 한다
    static func matches(_ card: Card, points: [String], tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = ([card.title, card.summary, card.source] + card.tags.map(\.name) + points)
            .joined(separator: "\n")
            .lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

/// 필터 메뉴에 늘어놓는 항목 하나: 이름과 카드 수
struct FacetCount: Identifiable, Hashable {
    let name: String
    let count: Int
    /// 태그면 Notion 옵션 색
    var color: String?
    var id: String { name }
}

/// 태그·출처 목록은 앱에 고정하지 않고 받은 카드에서 뽑는다
enum Facets {
    /// 많은 순, 같으면 이름순
    static func tags(in cards: [Card]) -> [FacetCount] {
        var counts: [String: Int] = [:]
        var colors: [String: String] = [:]
        for card in cards {
            for tag in card.tags {
                counts[tag.name, default: 0] += 1
                colors[tag.name] = tag.color
            }
        }
        return sorted(counts).map { FacetCount(name: $0.key, count: $0.value, color: colors[$0.key]) }
    }

    static func sources(in cards: [Card]) -> [FacetCount] {
        var counts: [String: Int] = [:]
        for card in cards where !card.displaySource.isEmpty {
            counts[card.displaySource, default: 0] += 1
        }
        return sorted(counts).map { FacetCount(name: $0.key, count: $0.value) }
    }

    private static func sorted(_ counts: [String: Int]) -> [(key: String, value: Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }
}

extension DayGrouping {
    /// 하루에 이보다 많으면 접는다
    static let collapseThreshold = 10
    /// 접었을 때 보이는 수
    static let collapsedCount = 5

    /// 몰린 날은 앞의 몇 장만 보여 준다. 펼쳤거나 필터·검색 중이면 전부.
    static func collapse(_ cards: [Card], isExpanded: Bool) -> (shown: [Card], hiddenCount: Int) {
        guard !isExpanded, cards.count > collapseThreshold else { return (cards, 0) }
        return (Array(cards.prefix(collapsedCount)), cards.count - collapsedCount)
    }
}

/// 상세에서 이전·다음 글로 넘길 때의 이웃
enum ReadingOrder {
    static func neighbor(of id: String, in order: [String], offset: Int) -> String? {
        guard let index = order.firstIndex(of: id) else { return nil }
        let target = index + offset
        return order.indices.contains(target) ? order[target] : nil
    }
}

/// "새로 온 날" 표시의 기준이 되는 지난번 방문 시각을 관리한다
enum VisitTracker {
    /// 앱을 닫고 이 시간이 지나 다시 열면 새 방문으로 본다
    static let gap: TimeInterval = 30 * 60

    /// 앱이 화면에 나올 때 부른다. 새 방문이면 닫았던 시각이 지난번 방문이 된다.
    static func activate(_ meta: inout SyncMeta, now: Date) {
        guard let backgrounded = meta.backgroundedAt, now.timeIntervalSince(backgrounded) > gap else { return }
        meta.lastVisitAt = backgrounded
        meta.backgroundedAt = nil
    }

    static func background(_ meta: inout SyncMeta, now: Date) {
        meta.backgroundedAt = now
    }
}
