import SwiftUI

/// 첫 화면. 날짜별로 묶은 카드 한 줄기.
/// 내비게이션 바는 숨기고 제목을 목록 첫 줄에 둔다. 설정은 그 줄 오른쪽,
/// 왼쪽 아래는 무엇을 볼지(필터), 오른쪽 아래는 찾기(검색).
struct TimelineScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    @State private var filter = TimelineFilter()
    @State private var query = ""
    @State private var searchPresented = false
    /// 몰린 날 가운데 펼친 날
    @State private var expandedDays: Set<Date> = []
    @State private var webLink: WebLink?
    /// 화면에 그리고 있는 묶음. 아래쪽을 읽는 중에 새 카드가 오면 바로 끼워 넣지 않고 붙들어 둔다.
    @State private var shown: [DaySection] = []
    @State private var isAtTop = true

    var body: some View {
        let store = app.cards
        let tokens = CardSearch.tokens(query)
        let narrowed = filter.isActive || !tokens.isEmpty
        let sections = narrowed ? narrowedSections(tokens: tokens) : shown
        let heldCount = narrowed ? 0 : TimelineUpdate.newCount(shown: shown, latest: store.sections)
        // 상세에서 이전·다음 글로 넘길 순서. 접힌 카드도 포함한다.
        let order = sections.flatMap(\.cards).map(\.id)

        ScrollViewReader { proxy in
        List {
            ScreenTitle(title: "읽기 요약", subtitle: subtitle) {
                Button("설정", systemImage: "gearshape") {
                    app.path.append(.settings)
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .tint(.primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            // 제목 위에 여백을 두지 않는다
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 6))
            .listRowSeparator(.hidden)
            .id(Self.topID)

            if filter.isActive {
                FilterChips(filter: $filter)
                    .listRowSeparator(.hidden)
            }
            if store.state == .failed(.unauthorized), !store.isEmpty {
                reconnectRow
            }
            if isFirstLoad {
                placeholderRows
            }
            ForEach(sections) { section in
                let collapsed = DayGrouping.collapse(section.cards, isExpanded: narrowed || isExpanded(section.day))
                Section {
                    ForEach(collapsed.shown) { card in
                        row(card, order: order)
                    }
                    if collapsed.hiddenCount > 0 {
                        Button {
                            withAnimation { _ = expandedDays.insert(section.day) }
                        } label: {
                            HStack(spacing: 6) {
                                Text("나머지 \(collapsed.hiddenCount)개 보기")
                                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                            }
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                } header: {
                    DayHeader(title: DayGrouping.label(for: section.day), count: section.cards.count, isNew: app.isNew(section))
                        .id(section.day)
                }
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 60
        } action: { _, atTop in
            isAtTop = atTop
            // 맨 위로 돌아오면 붙들어 둔 새 카드를 끼워 넣는다
            if atTop, shown != store.sections { shown = store.sections }
        }
        .overlay(alignment: .top) {
            if heldCount > 0 {
                Button("새 요약 \(heldCount)개", systemImage: "arrow.up") {
                    shown = store.sections
                    Task { withAnimation { proxy.scrollTo(Self.topID, anchor: .top) } }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glassProminent)
                // 붙어 있는 날짜 머리글 아래에 띄운다
                .padding(.top, 48)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: heldCount)
        .rootWithoutNavigationBar()
        #if DEBUG
        .task(id: shown.count) {
            // 목록이 그려진 뒤에 움직인다
            try? await Task.sleep(for: .milliseconds(400))
            scrollToDebugDay(proxy)
        }
        #endif
        }
        .onChange(of: store.sections, initial: true) { _, latest in
            if TimelineUpdate.appliesNow(shown: shown, latest: latest, isAtTop: isAtTop) { shown = latest }
        }
        .listStyle(.plain)
        // 바는 숨기지만 뒤로 가기와 손쉬운 사용이 읽는 이름은 남긴다
        .navigationTitle("읽기 요약")
        .refreshable { await app.refresh() }
        .searchable(text: $query, isPresented: $searchPresented, prompt: "제목, 요약, 출처 검색")
        .searchToolbarBehavior(.minimize)
        .toolbar { toolbar }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .detail(let cardID): CardDetailScreen(cardID: cardID)
            case .settings: SettingsScreen()
            }
        }
        .webSheet($webLink)
        .overlay {
            if store.isEmpty {
                if !isFirstLoad { emptyState }
            } else if sections.isEmpty {
                noMatchState(searching: !tokens.isEmpty)
            }
        }
        .sensoryFeedback(.selection, trigger: app.saved.count)
        #if DEBUG
        .task { applyDebugArguments() }
        #endif
    }

    private static let topID = "top"

    /// 아직 한 번도 받지 못했다. 연결한 직후나 첫 실행.
    private var isFirstLoad: Bool {
        let store = app.cards
        guard store.isEmpty else { return false }
        return store.state == .syncing || (store.state == .idle && store.meta.lastSyncAt == nil)
    }

    // MARK: - 목록

    /// 필터와 검색을 건 뒤 다시 날짜로 묶는다
    private func narrowedSections(tokens: [String]) -> [DaySection] {
        let cards = app.cards.cards.filter { card in
            filter.matches(card, isSaved: app.saved.isSaved(card.id))
                && CardSearch.matches(card, points: tokens.isEmpty ? [] : app.bodies.body(for: card)?.points ?? [], tokens: tokens)
        }
        return DayGrouping.sections(from: cards)
    }

    private func isExpanded(_ day: Date) -> Bool {
        #if DEBUG
        if DebugLaunch.flag("expandDays") { return true }
        #endif
        return expandedDays.contains(day)
    }

    private func row(_ card: Card, order: [String]) -> some View {
        let isSaved = app.saved.isSaved(card.id)
        return Button {
            app.open(card, order: order)
        } label: {
            CardRow(card: card, isSaved: isSaved)
        }
        // 기본 스타일은 글자 전체를 강조색으로 칠한다
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button(isSaved ? "저장 해제" : "저장", systemImage: isSaved ? "bookmark.slash" : "bookmark") {
                app.saved.toggle(card.id)
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .trailing) {
            if card.link != nil {
                Button("원문", systemImage: "safari") { openOriginal(card) }
                    .tint(.blue)
            }
        }
        .contextMenu {
            Button(isSaved ? "저장 해제" : "저장", systemImage: isSaved ? "bookmark.slash" : "bookmark") {
                app.saved.toggle(card.id)
            }
            if card.link != nil {
                Button("원문 보기", systemImage: "safari") { openOriginal(card) }
            }
            CardActions(card: card)
        }
        .accessibilityAction(named: isSaved ? "저장 해제" : "저장") { app.saved.toggle(card.id) }
        .accessibilityAction(named: "원문 보기") { openOriginal(card) }
    }

    private func openOriginal(_ card: Card) {
        guard let url = card.link else { return }
        if let link = WebLink(url) {
            webLink = link
        } else {
            openURL(url)
        }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            FilterMenu(filter: $filter, tags: app.cards.tagCounts, sources: app.cards.sourceCounts)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
    }

    /// 제목 아래 상태 한 줄
    private var subtitle: String {
        let store = app.cards
        switch store.state {
        case _ where isFirstLoad:
            return "받아오는 중…"
        case .failed(.unauthorized), .failed(.notFound):
            return "Notion 연결 확인 필요"
        case .failed:
            guard let last = store.meta.lastSyncAt else { return "오프라인" }
            let style = Date.FormatStyle(locale: Locale(identifier: "ko_KR")).month().day().hour(.twoDigits(amPM: .omitted)).minute()
            return "오프라인 · \(last.formatted(style)) 기준"
        default:
            // 부제가 비었다가 생기면 제목 줄 높이가 바뀌어 목록이 밀린다. 늘 한 줄을 둔다.
            // 첫 방문에는 전부가 새 글이라 개수만 알린다
            guard app.newSince != nil else { return "요약 \(store.cards.count)개" }
            let newCount = app.newCount
            return newCount > 0 ? "새 요약 \(newCount)개" : "새 요약 없음"
        }
    }

    // MARK: - 상태 화면

    /// 토큰이 무효가 됐을 때 목록 맨 위에 두는 줄
    private var reconnectRow: some View {
        Button {
            app.path.append(.settings)
        } label: {
            Label("Notion 연결을 확인해 주세요", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    /// 첫 동기화 동안 자리를 잡아 두는 카드
    private var placeholderRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            CardRow(card: Card(
                id: "", createdAt: .now, editedAt: .now,
                title: "제목이 들어갈 자리입니다 조금 길게",
                publishedDay: nil,
                tags: [CardTag(name: "개발", color: "default"), CardTag(name: "인프라", color: "default")],
                source: "출처 이름",
                link: nil,
                summary: "한줄요약이 들어갈 자리입니다. 보통 여든 자 안팎이라 서너 줄을 차지하므로 그만큼 자리를 잡아 둡니다.",
                notionURL: nil
            ))
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch app.cards.state {
        case .failed(.unauthorized):
            ContentUnavailableView {
                Label("Notion 연결을 확인해 주세요", systemImage: "key.slash")
            } description: {
                Text("토큰이 맞지 않아요.")
            } actions: {
                Button("설정 열기") { app.path.append(.settings) }
            }
        case .failed(.notFound):
            ContentUnavailableView {
                Label("데이터베이스를 찾지 못했어요", systemImage: "questionmark.folder")
            } description: {
                Text("Notion에서 DB의 ··· → 연결에 이 통합을 추가했는지 확인하세요.")
            } actions: {
                Button("설정 열기") { app.path.append(.settings) }
            }
        case .failed:
            ContentUnavailableView {
                Label("불러오지 못했어요", systemImage: "wifi.slash")
            } description: {
                Text("인터넷 연결을 확인하세요.")
            } actions: {
                Button("다시 시도") { Task { await app.refresh() } }
            }
        default:
            ContentUnavailableView("아직 요약이 없어요", systemImage: "tray", description: Text("매일 새벽 4시에 쌓입니다."))
        }
    }

    @ViewBuilder
    private func noMatchState(searching: Bool) -> some View {
        if searching {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("조건에 맞는 글이 없어요", systemImage: "line.3.horizontal.decrease")
            } actions: {
                Button("필터 지우기") { filter = TimelineFilter() }
            }
        }
    }

    #if DEBUG
    /// `-scrollToDay 2026-11-07`: 그 날짜 묶음이 맨 위에 오게 한다
    private func scrollToDebugDay(_ proxy: ScrollViewProxy) {
        guard let text = DebugLaunch.string("scrollToDay") else { return }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              app.cards.sections.contains(where: { $0.day == day }) else { return }
        proxy.scrollTo(day, anchor: DebugLaunch.string("scrollAnchor") == "bottom" ? .bottom : .top)
    }

    private func applyDebugArguments() {
        if DebugLaunch.flag("filterSaved") { filter.savedOnly = true }
        if let tag = DebugLaunch.string("filterTag") { filter.tag = tag }
        if let source = DebugLaunch.string("filterSource") { filter.source = source }
        if let text = DebugLaunch.string("searchText") {
            query = text
            searchPresented = true
        }
    }
    #endif
}

/// 왼쪽 아래 필터 버튼과 그 메뉴
struct FilterMenu: View {
    @Binding var filter: TimelineFilter
    let tags: [FacetCount]
    let sources: [FacetCount]

    var body: some View {
        Menu {
            Toggle("저장한 글만", systemImage: "bookmark", isOn: $filter.savedOnly)
            Divider()
            Picker("태그", systemImage: "tag", selection: $filter.tag) {
                Text("전체").tag(String?.none)
                ForEach(tags) { tag in
                    Text("\(tag.name)  \(tag.count)").tag(String?.some(tag.name))
                }
            }
            .pickerStyle(.menu)
            Picker("출처", systemImage: "newspaper", selection: $filter.source) {
                Text("전체").tag(String?.none)
                ForEach(sources) { source in
                    Text("\(source.name)  \(source.count)").tag(String?.some(source.name))
                }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Divider()
                Button("필터 지우기", systemImage: "xmark.circle") {
                    filter = TimelineFilter()
                }
            }
        } label: {
            Label("필터", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .tint(filter.isActive ? .accentColor : nil)
    }
}

/// 걸린 조건을 목록 맨 위에 칩으로 보여 준다. 누르면 그 조건이 꺼진다.
struct FilterChips: View {
    @Binding var filter: TimelineFilter

    var body: some View {
        FlowLayout(spacing: 8) {
            if filter.savedOnly {
                chip("저장한 글") { filter.savedOnly = false }
            }
            if let tag = filter.tag {
                chip(tag) { filter.tag = nil }
            }
            if let source = filter.source {
                chip(source) { filter.source = nil }
            }
        }
    }

    private func chip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("\(title) 필터 끄기")
    }
}
