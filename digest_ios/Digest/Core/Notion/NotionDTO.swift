import Foundation

/// 파이프라인(`summarize_unread.py`)이 쓰는 DB 속성 이름
enum NotionSchema {
    static let title = "제목"
    static let date = "날짜"
    static let tags = "태그"
    static let source = "출처"
    static let link = "링크"
    static let summary = "한줄요약"

    /// 연결할 때 있는지 확인하는 속성과 그 종류
    static let required: [(name: String, type: String)] = [
        (title, "title"), (date, "date"), (tags, "multi_select"),
        (source, "rich_text"), (link, "url"), (summary, "rich_text"),
    ]
}

struct NotionRichText: Decodable {
    let plain_text: String
    let href: String?
}

extension Array where Element == NotionRichText {
    var plainText: String { map(\.plain_text).joined() }
}

struct NotionOption: Decodable {
    let name: String
    let color: String?
}

struct NotionDateValue: Decodable {
    let start: String?
}

/// 페이지 속성 값. 쓰는 종류만 읽고, 모르는 종류나 모양이 달라도 실패하지 않는다.
struct NotionPropertyValue: Decodable {
    var title: [NotionRichText]?
    var richText: [NotionRichText]?
    var date: NotionDateValue?
    var multiSelect: [NotionOption]?
    var url: String?

    private enum CodingKeys: String, CodingKey {
        case title, date, url
        case richText = "rich_text"
        case multiSelect = "multi_select"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent([NotionRichText].self, forKey: .title)
        richText = try? c.decodeIfPresent([NotionRichText].self, forKey: .richText)
        date = try? c.decodeIfPresent(NotionDateValue.self, forKey: .date)
        multiSelect = try? c.decodeIfPresent([NotionOption].self, forKey: .multiSelect)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }
}

struct NotionPage: Decodable {
    let id: String
    let created_time: String
    let last_edited_time: String
    let in_trash: Bool?
    let url: String?
    let properties: [String: NotionPropertyValue]
}

struct NotionQueryResponse: Decodable {
    let results: [NotionPage]
    let next_cursor: String?
    let has_more: Bool
}

struct NotionDatabase: Decodable {
    struct DataSourceRef: Decodable {
        let id: String
        let name: String?
    }

    let title: [NotionRichText]?
    let data_sources: [DataSourceRef]?
}

struct NotionDataSource: Decodable {
    struct Property: Decodable {
        let type: String
    }

    let properties: [String: Property]
}

/// 블록 하나. 종류 이름과 같은 키 아래에 rich_text가 들어 있다.
struct NotionBlock: Decodable {
    let type: String
    let richText: [NotionRichText]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Payload: Decodable {
        let rich_text: [NotionRichText]?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = try c.decode(String.self, forKey: AnyKey("type"))
        richText = (try? c.decodeIfPresent(Payload.self, forKey: AnyKey(type)))?.rich_text ?? []
    }
}

struct NotionBlockList: Decodable {
    let results: [NotionBlock]
    let next_cursor: String?
    let has_more: Bool
}

enum NotionDate {
    /// Notion 시각은 "2026-11-14T19:00:00.000Z" 모양이다
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }

    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}

extension Card {
    /// Notion 페이지를 카드로 바꾼다. 시각을 읽지 못하면 nil.
    init?(page: NotionPage) {
        guard let created = NotionDate.parse(page.created_time),
              let edited = NotionDate.parse(page.last_edited_time) else { return nil }
        let p = page.properties
        self.init(
            id: page.id,
            createdAt: created,
            editedAt: edited,
            title: p[NotionSchema.title]?.title?.plainText ?? "",
            publishedDay: p[NotionSchema.date]?.date?.start.map { String($0.prefix(10)) },
            tags: (p[NotionSchema.tags]?.multiSelect ?? []).map { CardTag(name: $0.name, color: $0.color ?? "default") },
            source: p[NotionSchema.source]?.richText?.plainText ?? "",
            link: p[NotionSchema.link]?.url.flatMap { URL(string: $0) },
            summary: p[NotionSchema.summary]?.richText?.plainText ?? "",
            notionURL: page.url.flatMap { URL(string: $0) }
        )
    }
}

extension CardBody {
    /// 블록 목록을 본문으로 바꾼다. 링크만 있는 문단("원문 보기")과 빈 블록은 뺀다.
    init(blocks: [NotionBlock], cardEditedAt: Date) {
        var result: [Block] = []
        for block in blocks {
            let text = block.richText.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let kind: Kind
            switch block.type {
            case "bulleted_list_item", "to_do", "toggle": kind = .bullet
            case "numbered_list_item": kind = .numbered
            case "callout": kind = .callout
            case "quote": kind = .quote
            case "heading_1", "heading_2", "heading_3": kind = .heading
            case "paragraph":
                if block.richText.allSatisfy({ $0.href != nil }) { continue }
                kind = .paragraph
            default: kind = .paragraph
            }
            result.append(Block(kind: kind, text: text))
        }
        self.init(cardEditedAt: cardEditedAt, blocks: result)
    }
}
