import SwiftUI

extension Color {
    /// Notion 옵션 색 이름을 같은 이름의 시스템 색으로 옮긴다
    static func notion(_ name: String) -> Color {
        switch name {
        case "blue": .blue
        case "purple": .purple
        case "red": .red
        case "green": .green
        case "orange": .orange
        case "pink": .pink
        case "brown": .brown
        case "yellow": .yellow
        default: .gray
        }
    }
}

/// 목록용 태그 한 줄: 색 점 + 이름. 좁으면 다음 줄로 넘어간다.
struct TagLine: View {
    let tags: [CardTag]

    var body: some View {
        tags.enumerated().reduce(Text(verbatim: "")) { line, item in
            let dot = Text(verbatim: "●").font(.caption2).foregroundStyle(Color.notion(item.element.color))
            let gap = item.offset == 0 ? "" : "    "
            // 점과 이름 사이는 줄이 갈리지 않는 공백
            return Text("\(line)\(gap)\(dot)\u{00A0}\(item.element.name)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("태그 " + tags.map(\.name).joined(separator: ", "))
    }
}

/// 상세용 태그 캡슐: 옅은 색 바탕 + 이름
struct TagCapsules: View {
    let tags: [CardTag]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag.name)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.notion(tag.color).opacity(0.18), in: .capsule)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("태그 " + tags.map(\.name).joined(separator: ", "))
    }
}

/// 왼쪽부터 채우고 넘치면 다음 줄로 넘기는 배치
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, rows.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (origins, maxWidth, y + rowHeight)
    }
}
