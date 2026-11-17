import SwiftUI

/// 타임라인의 카드 한 장: 출처 → 제목 → 한줄요약 → 태그
struct CardRow: View {
    let card: Card
    var isSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("저장한 글")
                }
            }
            Text(card.title)
                .font(.headline)
                .lineLimit(3)
            // 목록만 훑어도 요약이 읽히도록 자르지 않는다. 보조색은 대비가 낮아 본문에 쓰지 않는다.
            if !card.summary.isEmpty {
                Text(card.summary)
                    .font(.subheadline)
                    .lineSpacing(3)
            }
            if !card.tags.isEmpty {
                TagLine(tags: card.tags)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// "출처" 또는 오래된 글이면 "출처 · 2020년 3월 글"
    private var sourceLine: String {
        [card.displaySource, card.oldPostLabel()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 날짜 묶음 머리글: "오늘 · 3개". 지난번 방문 뒤에 온 날이면 앞에 강조색 점.
struct DayHeader: View {
    let title: String
    let count: Int
    var isNew = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if isNew {
                Circle()
                    .fill(.tint)
                    .frame(width: 9, height: 9)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    .accessibilityLabel("새로 온 요약")
            }
            // 목록 머리글은 기본이 흐린 색이라 색을 직접 준다
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)
            Spacer()
            Text("\(count)개")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
