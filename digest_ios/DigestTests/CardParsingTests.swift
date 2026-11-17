import Foundation
import Testing
@testable import Digest

/// Notion 응답(API 2026-03-11)을 카드로 바꾸는 부분
struct CardParsingTests {
    /// 실제 응답에서 필요한 부분만 남긴 표본
    static let queryJSON = """
    {
      "object": "list",
      "results": [
        {
          "object": "page",
          "id": "4183ae0b-75f5-814b-96a0-dd82d8e32565",
          "created_time": "2026-11-14T19:00:00.000Z",
          "last_edited_time": "2026-11-14T19:01:00.000Z",
          "in_trash": false,
          "is_archived": false,
          "url": "https://www.notion.so/4183ae0b75f5814b96a0dd82d8e32565",
          "parent": {"type": "data_source_id", "data_source_id": "x", "database_id": "y"},
          "properties": {
            "태그": {"id": "a", "type": "multi_select", "multi_select": [
              {"id": "1", "name": "개발", "color": "blue"},
              {"id": "2", "name": "AI", "color": "purple"}
            ]},
            "출처": {"id": "b", "type": "rich_text", "rich_text": [
              {"type": "text", "text": {"content": "당근 테크 블로그 - Medium", "link": null}, "plain_text": "당근 테크 블로그 - Medium", "href": null}
            ]},
            "한줄요약": {"id": "c", "type": "rich_text", "rich_text": [
              {"type": "text", "plain_text": "앞부분 ", "href": null},
              {"type": "text", "plain_text": "뒷부분", "href": null}
            ]},
            "날짜": {"id": "d", "type": "date", "date": {"start": "2026-11-14", "end": null, "time_zone": null}},
            "링크": {"id": "e", "type": "url", "url": "http://example.com/post"},
            "제목": {"id": "title", "type": "title", "title": [
              {"type": "text", "plain_text": "제목입니다", "href": null}
            ]},
            "나중에 추가한 체크박스": {"id": "f", "type": "checkbox", "checkbox": true}
          }
        },
        {
          "object": "page",
          "id": "empty-card",
          "created_time": "2026-11-13T19:00:00.000Z",
          "last_edited_time": "2026-11-13T19:00:00.000Z",
          "in_trash": true,
          "url": null,
          "properties": {
            "태그": {"type": "multi_select", "multi_select": []},
            "출처": {"type": "rich_text", "rich_text": []},
            "한줄요약": {"type": "rich_text", "rich_text": []},
            "날짜": {"type": "date", "date": null},
            "링크": {"type": "url", "url": null},
            "제목": {"type": "title", "title": []}
          }
        }
      ],
      "next_cursor": null,
      "has_more": false
    }
    """

    static let blocksJSON = """
    {
      "results": [
        {"type": "callout", "callout": {"rich_text": [{"plain_text": "한줄요약 문장", "href": null}], "icon": {"type": "emoji", "emoji": "💡"}}},
        {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": [{"plain_text": "핵심 하나", "href": null}]}},
        {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": [{"plain_text": "핵심 ", "href": null}, {"plain_text": "둘", "href": null}]}},
        {"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "원문 보기", "href": "https://example.com"}]}},
        {"type": "paragraph", "paragraph": {"rich_text": [{"plain_text": "내가 덧붙인 메모", "href": null}]}},
        {"type": "paragraph", "paragraph": {"rich_text": []}},
        {"type": "divider", "divider": {}},
        {"type": "heading_2", "heading_2": {"rich_text": [{"plain_text": "소제목", "href": null}]}}
      ],
      "next_cursor": null,
      "has_more": false
    }
    """

    private func cards() throws -> [Card?] {
        let response = try JSONDecoder().decode(NotionQueryResponse.self, from: Data(Self.queryJSON.utf8))
        return response.results.map(Card.init(page:))
    }

    @Test func readsAllSixProperties() throws {
        let card = try #require(try cards()[0])
        #expect(card.id == "4183ae0b-75f5-814b-96a0-dd82d8e32565")
        #expect(card.title == "제목입니다")
        #expect(card.summary == "앞부분 뒷부분")
        #expect(card.source == "당근 테크 블로그 - Medium")
        #expect(card.publishedDay == "2026-11-14")
        #expect(card.link == URL(string: "http://example.com/post"))
        #expect(card.tags == [CardTag(name: "개발", color: "blue"), CardTag(name: "AI", color: "purple")])
        #expect(card.notionURL != nil)
    }

    @Test func readsTimestampsWithFractionalSeconds() throws {
        let card = try #require(try cards()[0])
        #expect(card.createdAt == Date(timeIntervalSince1970: 1_794_682_800))  // 2026-11-14T19:00:00Z
        #expect(card.editedAt.timeIntervalSince(card.createdAt) == 60)
    }

    @Test func emptyPropertiesBecomeEmptyValues() throws {
        let card = try #require(try cards()[1])
        #expect(card.title.isEmpty)
        #expect(card.summary.isEmpty)
        #expect(card.tags.isEmpty)
        #expect(card.publishedDay == nil)
        #expect(card.link == nil)
    }

    @Test func trashedFlagIsRead() throws {
        let response = try JSONDecoder().decode(NotionQueryResponse.self, from: Data(Self.queryJSON.utf8))
        #expect(response.results.map { $0.in_trash == true } == [false, true])
    }

    @Test func bodyKeepsPointsAndDropsLinkOnlyParagraph() throws {
        let list = try JSONDecoder().decode(NotionBlockList.self, from: Data(Self.blocksJSON.utf8))
        let body = CardBody(blocks: list.results, cardEditedAt: .now)
        #expect(body.points == ["핵심 하나", "핵심 둘"])
        #expect(body.blocks.map(\.kind) == [.callout, .bullet, .bullet, .paragraph, .heading])
        #expect(body.blocks.contains { $0.text == "원문 보기" } == false)
        #expect(body.blocks.contains { $0.text == "내가 덧붙인 메모" })
    }

    @Test func calloutEqualToSummaryIsHiddenInDetail() throws {
        let list = try JSONDecoder().decode(NotionBlockList.self, from: Data(Self.blocksJSON.utf8))
        let body = CardBody(blocks: list.results, cardEditedAt: .now)
        #expect(body.displayBlocks(summary: " 한줄요약 문장 ").first?.kind == .bullet)
        #expect(body.displayBlocks(summary: "다른 문장").first?.kind == .callout)
    }

    @Test func databaseIDIsExtractedFromAddressOrID() {
        let id = "ba591c8b4bda4127b1a75fa6dc455f85"
        #expect(Connection.databaseID(from: id) == id)
        #expect(Connection.databaseID(from: "  BA591C8B-4BDA-4127-B1A7-5FA6DC455F85 ") == id)
        #expect(Connection.databaseID(from: "https://www.notion.so/me/Reeder-\(id)?v=11111111111111111111111111111111") == id)
        // 이름 끝이 16진수 글자(feed)여도 ID에 섞이지 않는다
        #expect(Connection.databaseID(from: "https://www.notion.so/my-feed-\(id)") == id)
        #expect(Connection.databaseID(from: "https://www.notion.so/\(id)?v=22222222222222222222222222222222") == id)
        #expect(Connection.databaseID(from: "notion") == nil)
    }
}
