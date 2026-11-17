import SwiftUI

/// 상세: 제목, 한줄요약, 핵심. 아래 툴바에서 원문을 열고 이전·다음 글로 넘긴다.
struct CardDetailScreen: View {
    @Environment(AppState.self) private var app

    /// 지금 보고 있는 카드. 이전·다음을 누르면 화면을 새로 밀지 않고 이 값만 바꾼다.
    @State private var cardID: String
    @State private var webLink: WebLink?

    init(cardID: String) {
        _cardID = State(initialValue: cardID)
    }

    private var card: Card? {
        app.cards.card(id: cardID)
    }

    var body: some View {
        Group {
            if let card {
                content(card)
            } else {
                ContentUnavailableView("글을 찾을 수 없어요", systemImage: "doc.questionmark", description: Text("Notion에서 지워진 카드예요."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .webSheet($webLink)
        // 읽는 중에 카드가 고쳐지면 받아 둔 핵심이 낡은 것이 되므로 다시 받는다
        .task(id: BodyKey(cardID: cardID, editedAt: card?.editedAt)) {
            if let card { await app.loadBody(for: card) }
        }
    }

    private func content(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(metaLine(card))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(card.title)
                        .font(.title2.bold())
                    if !card.tags.isEmpty {
                        TagCapsules(tags: card.tags)
                    }
                }
                if !card.summary.isEmpty {
                    SummaryCallout(text: card.summary)
                }
                bodySection(card)
                Text("AI가 요약한 내용이라 원문과 다를 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        // 다른 글로 넘기면 스크롤을 맨 위로 돌린다
        .id(card.id)
    }

    @ViewBuilder
    private func bodySection(_ card: Card) -> some View {
        if let body = app.bodies.body(for: card) {
            let blocks = body.displayBlocks(summary: card.summary)
            if blocks.isEmpty {
                Text("핵심이 없는 글이에요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                BodyBlocks(blocks: blocks)
            }
        } else if app.bodies.hasFailed(card) {
            VStack(alignment: .leading, spacing: 10) {
                Text("핵심을 불러오지 못했어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("다시 시도") {
                    Task { await app.loadBody(for: card) }
                }
                .buttonStyle(.bordered)
            }
        } else {
            // 받는 동안 자리를 잡아 둔다
            BodyBlocks(blocks: (0..<3).map { _ in
                CardBody.Block(kind: .bullet, text: "핵심이 들어갈 자리입니다. 보통 예순 자 안팎이라 두세 줄을 차지합니다.")
            })
            .redacted(reason: .placeholder)
            .accessibilityLabel("핵심을 받아오는 중")
        }
    }

    /// "출처 · 2026년 10월 14일"
    private func metaLine(_ card: Card) -> String {
        var parts = [card.displaySource].filter { !$0.isEmpty }
        if let published = card.publishedDate() {
            let style = Date.FormatStyle(locale: Locale(identifier: "ko_KR")).year().month().day()
            parts.append(published.formatted(style))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let previous = ReadingOrder.neighbor(of: cardID, in: app.readingOrder, offset: -1)
        let next = ReadingOrder.neighbor(of: cardID, in: app.readingOrder, offset: 1)
        let isSaved = app.saved.isSaved(cardID)

        ToolbarItemGroup(placement: .topBarTrailing) {
            if let card {
                Button(isSaved ? "저장 해제" : "저장", systemImage: isSaved ? "bookmark.fill" : "bookmark") {
                    app.saved.toggle(card.id)
                }
                .sensoryFeedback(.selection, trigger: isSaved)
                CardActionsMenu(card: card)
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("원문 보기") {
                openOriginal()
            }
            .buttonStyle(.glassProminent)
            .disabled(card?.link == nil)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button("이전 글", systemImage: "chevron.up") {
                if let previous { cardID = previous }
            }
            .disabled(previous == nil)
            Button("다음 글", systemImage: "chevron.down") {
                if let next { cardID = next }
            }
            .disabled(next == nil)
        }
    }

    /// 원문은 앱 안 Safari로만 연다. 웹 주소가 아니면 열지 않는다.
    private func openOriginal() {
        webLink = card?.link.flatMap(WebLink.init)
    }
}

private struct BodyKey: Hashable {
    let cardID: String
    let editedAt: Date?
}

/// 본문 블록 묶음. 핵심(불릿)이 대부분이고, Notion에서 덧붙인 문단·소제목도 그린다.
struct BodyBlocks: View {
    let blocks: [CardBody.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block.kind {
                case .bullet:
                    marked("•", block.text)
                case .numbered:
                    marked("\(numberedIndex(at: index)).", block.text)
                case .heading:
                    Text(block.text).font(.headline).padding(.top, 4)
                case .quote:
                    Text(block.text).font(.body).italic().lineSpacing(5).foregroundStyle(.secondary)
                case .callout:
                    SummaryCallout(text: block.text)
                case .paragraph:
                    Text(block.text).font(.body).lineSpacing(5)
                }
            }
        }
    }

    private func marked(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marker)
                .font(.body.weight(.bold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .lineSpacing(5)
        }
    }

    /// 이어진 번호 목록 안에서 몇 번째인지
    private func numberedIndex(at index: Int) -> Int {
        var count = 1
        var i = index - 1
        while i >= 0, blocks[i].kind == .numbered {
            count += 1
            i -= 1
        }
        return count
    }
}

/// 카드에 할 수 있는 일: 공유 · 요약 복사 · Notion에서 열기
struct CardActionsMenu: View {
    let card: Card

    var body: some View {
        Menu("더 보기", systemImage: "ellipsis") {
            CardActions(card: card)
        }
    }
}

/// 메뉴 항목. 상세의 더 보기 메뉴와 목록의 길게 누르기 메뉴가 같이 쓴다.
struct CardActions: View {
    let card: Card
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let link = card.link {
            ShareLink(item: link, subject: Text(card.title), message: Text(card.summary)) {
                Label("공유", systemImage: "square.and.arrow.up")
            }
        }
        Button("요약 복사", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = app.shareText(for: card)
        }
        if let notionURL = card.notionURL {
            Button("Notion에서 열기", systemImage: "arrow.up.forward.app") {
                openURL(notionURL)
            }
        }
    }
}
