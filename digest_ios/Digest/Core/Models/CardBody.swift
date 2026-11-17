import Foundation

/// 카드 본문. 파이프라인은 callout(한줄요약) → 불릿(핵심) → 원문 링크 문단 순서로 쓴다.
/// Notion에서 카드에 메모를 덧붙여도 읽히도록 다른 블록도 글자로 받아 둔다.
struct CardBody: Codable, Hashable {
    enum Kind: String, Codable {
        case bullet, numbered, paragraph, heading, quote, callout
    }

    struct Block: Codable, Hashable {
        var kind: Kind
        var text: String
    }

    /// 받은 시점의 카드 수정 시각. 카드가 그 뒤에 고쳐졌으면 다시 받는다.
    var cardEditedAt: Date
    var blocks: [Block]

    /// 핵심(불릿)만
    var points: [String] {
        blocks.filter { $0.kind == .bullet }.map(\.text)
    }

    /// 상세에 그릴 블록. 한줄요약과 같은 문장인 callout은 위에 이미 보이므로 뺀다.
    func displayBlocks(summary: String) -> [Block] {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return blocks.filter { !($0.kind == .callout && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == summary) }
    }
}
