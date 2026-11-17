import Foundation
import Observation

/// 타임라인에서 밀어 넣는 화면
enum Route: Hashable {
    case detail(cardID: String)
    case settings
}

@MainActor
@Observable
final class AppState {
    private(set) var connection: Connection?
    let cards: CardStore
    let bodies: BodyStore
    let saved: SavedStore
    var path: [Route] = []

    /// 이 시각 뒤에 만들어진 카드가 "새로 온 요약"이다. 첫 방문에는 nil.
    private(set) var newSince: Date?

    /// 상세에서 이전·다음 글로 넘길 순서. 상세로 들어갈 때의 목록 그대로다(필터·검색 결과 포함).
    private(set) var readingOrder: [String] = []

    /// `launch()`가 저장된 카드를 읽은 뒤에만 앱 복귀 처리를 한다
    private var didLaunch = false

    /// 표본 카드로 실행 중 (Debug 실행 인자 `-mockData YES`)
    let isMock: Bool

    /// 앱으로 돌아왔을 때 이 시간이 지났으면 다시 받는다
    static let refreshInterval: TimeInterval = 30 * 60

    init() {
        #if DEBUG
        DebugLaunch.prepare()
        isMock = DebugLaunch.mockData
        #else
        isMock = false
        #endif
        connection = isMock ? nil : Connection.load()
        cards = CardStore(persists: !isMock)
        bodies = BodyStore(persists: !isMock)
        saved = SavedStore(persists: !isMock)
        beginVisit()
    }

    var needsConnection: Bool {
        #if DEBUG
        if DebugLaunch.initialScreen == "connect", connection == nil { return true }
        #endif
        return connection == nil && !isMock
    }

    /// 저장된 카드를 먼저 보여 주고, 그 뒤에 Notion과 맞춘다
    func launch() async {
        #if DEBUG
        if isMock {
            let mock = MockData.cards()
            cards.replace(with: mock)
            bodies.replace(with: MockData.bodies(for: mock))
            saved.replace(with: ["mock-2"])
            cards.updateMeta {
                $0.databaseTitle = "Reeder 읽기 요약"
                $0.lastSyncAt = .now
            }
            newSince = Calendar.current.startOfDay(for: .now)
            if DebugLaunch.flag("simulateNewCards") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    cards.replace(with: MockData.arrivals() + mock)
                }
            }
            applyDebugScreen()
            return
        }
        #endif
        cards.loadFromDisk()
        bodies.loadFromDisk()
        saved.loadFromDisk()
        didLaunch = true
        #if DEBUG
        applyDebugScreen()
        #endif
        await refresh()
    }

    func refresh(full: Bool = false) async {
        guard let connection, !isMock else { return }
        let client = client(for: connection)
        await cards.sync(using: client, databaseID: connection.databaseID, forceFull: full)
        guard cards.state == .idle else { return }
        bodies.prune(keeping: Set(cards.cards.map(\.id)))
        // 최신 카드부터 핵심을 미리 받는다
        bodies.startPrefetch(cards.cards, using: client)
    }

    func client(for connection: Connection) -> NotionClient {
        var client = NotionClient(token: connection.token)
        #if DEBUG
        if DebugLaunch.flag("offline") { client.session = DebugLaunch.offlineSession }
        #endif
        return client
    }

    /// 앱으로 돌아왔을 때: 마지막 동기화가 오래됐거나 아직 한 번도 못 받았으면 다시 받는다.
    /// 그럴 때가 아니어도, 네트워크 오류로 멈춘 핵심 미리 받기는 이어서 받는다.
    func didBecomeActive() async {
        beginVisit()
        guard didLaunch, let connection else { return }
        let isStale = cards.meta.lastSyncAt.map { Date.now.timeIntervalSince($0) > Self.refreshInterval } ?? true
        if isStale {
            await refresh()
        } else if cards.state == .idle, !bodies.isPrefetching {
            bodies.startPrefetch(cards.cards, using: client(for: connection))
        }
    }

    func didEnterBackground() {
        bodies.saveNow()
        cards.updateMeta { VisitTracker.background(&$0, now: .now) }
    }

    // MARK: - 연결

    /// 토큰과 DB를 확인하고 통과하면 키체인에 넣는다. 막히면 그 까닭을 돌려준다.
    func connect(token rawToken: String, databaseInput: String) async -> ConnectFailure? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .emptyToken }
        guard let databaseID = Connection.databaseID(from: databaseInput) else { return .badDatabaseID }

        let candidate = Connection(token: token, databaseID: databaseID)
        let client = client(for: candidate)
        do {
            let database = try await client.database(id: databaseID)
            guard let source = database.data_sources?.first else { return .notFound }
            let schema = try await client.dataSource(id: source.id)
            if let failure = ConnectCheck.failure(in: schema.properties.mapValues(\.type)) { return failure }

            // 다른 DB로 바꾸면 받아 둔 것은 쓸모가 없다. 토큰만 바꾸면 그대로 둔다.
            guard candidate.save() else {
                return .other("토큰을 이 기기에 저장하지 못했어요. 잠금을 푼 상태에서 다시 시도하세요.")
            }
            if let connection, connection.databaseID != databaseID { clearLocalData() }
            // 옛 토큰으로 돌던 동기화와 미리 받기가 새 연결의 결과에 섞이지 않게 버린다
            cards.cancelSync()
            bodies.stopPrefetch()
            connection = candidate
            cards.updateMeta {
                $0.dataSourceID = source.id
                $0.databaseTitle = database.title?.plainText ?? source.name ?? ""
            }
            Task { await refresh() }
            return nil
        } catch let error as NotionError {
            return ConnectFailure(error)
        } catch {
            return .other("")
        }
    }

    /// 키체인과 기기에 받아 둔 내용을 지우고 연결 화면으로 돌아간다
    func disconnect() {
        clearLocalData()
        Connection.clear()
        connection = nil
        path = []
    }

    private func clearLocalData() {
        // 예전 빌드가 공용 세션으로 받은 응답이 캐시에 남아 있을 수 있다
        URLCache.shared.removeAllCachedResponses()
        bodies.reset()
        cards.reset()
        saved.reset()
        readingOrder = []
        newSince = nil
    }

    // MARK: - 새로 온 요약

    /// 닫은 지 오래됐으면 새 방문으로 보고 "새로 온 요약"의 기준을 옮긴다
    private func beginVisit() {
        guard !isMock else { return }
        cards.updateMeta { VisitTracker.activate(&$0, now: .now) }
        newSince = cards.meta.lastVisitAt
        #if DEBUG
        if let days = DebugLaunch.string("newSinceDays").flatMap(Double.init) {
            newSince = Date.now.addingTimeInterval(-days * 86400)
        }
        #endif
    }

    func isNew(_ section: DaySection) -> Bool {
        guard let newSince else { return false }
        return section.cards.contains { $0.createdAt > newSince }
    }

    var newCount: Int {
        guard let newSince else { return 0 }
        return cards.cards.reduce(0) { $0 + ($1.createdAt > newSince ? 1 : 0) }
    }

    // MARK: - 읽기

    /// 상세를 연다. `order`는 지금 목록에 보이는 카드 순서.
    func open(_ card: Card, order: [String]) {
        readingOrder = order
        path.append(.detail(cardID: card.id))
    }

    /// 상세에서 핵심이 아직 없으면 그 카드를 먼저 받는다
    func loadBody(for card: Card) async {
        guard let connection, !isMock else { return }
        await bodies.load(card, using: client(for: connection))
    }

    /// "요약 복사"와 공유에 쓰는 글: 제목, 한줄요약, 핵심, 링크
    func shareText(for card: Card) -> String {
        var lines = [card.title]
        if !card.summary.isEmpty { lines += ["", card.summary] }
        let points = bodies.body(for: card)?.points ?? []
        if !points.isEmpty { lines += [""] + points.map { "• " + $0 } }
        if let link = card.link { lines += ["", link.absoluteString] }
        return lines.joined(separator: "\n")
    }

    #if DEBUG
    private func applyDebugScreen() {
        switch DebugLaunch.initialScreen {
        case "detail":
            let order = cards.sections.flatMap(\.cards)
            let index = min(max(Int(DebugLaunch.string("openCard") ?? "") ?? 0, 0), max(order.count - 1, 0))
            if order.indices.contains(index) { open(order[index], order: order.map(\.id)) }
        case "settings":
            path = [.settings]
        default:
            break
        }
    }
    #endif
}
