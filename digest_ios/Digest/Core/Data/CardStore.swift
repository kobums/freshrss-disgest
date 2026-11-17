import Foundation
import Observation

/// 동기화에 딸린 값. UserDefaults에 둔다.
struct SyncMeta: Codable, Equatable {
    var databaseTitle = ""
    /// 연결할 때 한 번 찾아 둔 데이터 소스 ID
    var dataSourceID: String?
    var lastSyncAt: Date?
    /// 지운 카드를 반영하려고 전체를 대조한 마지막 시각
    var lastFullSyncAt: Date?
    /// 이 시각 뒤에 만들어진 날짜 묶음을 "새로 온 날"로 본다
    var lastVisitAt: Date?
    var backgroundedAt: Date?

    init() {}

    // 항목이 늘거나 바뀌어도 나머지가 초기화되지 않게 하나씩 읽는다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        databaseTitle = try c.decodeIfPresent(String.self, forKey: .databaseTitle) ?? ""
        dataSourceID = try c.decodeIfPresent(String.self, forKey: .dataSourceID)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastFullSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastFullSyncAt)
        lastVisitAt = try c.decodeIfPresent(Date.self, forKey: .lastVisitAt)
        backgroundedAt = try c.decodeIfPresent(Date.self, forKey: .backgroundedAt)
    }

    static let defaultsKey = "syncMeta"

    static func load() -> SyncMeta {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let meta = try? JSONDecoder().decode(SyncMeta.self, from: data) else { return SyncMeta() }
        return meta
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case failed(NotionError)
}

/// 카드 목록을 기기에 저장해 두고 Notion과 맞춘다
@MainActor
@Observable
final class CardStore {
    private(set) var cards: [Card] = []
    /// 화면에 그리는 순서: 날짜 최신순, 같은 날 안에서는 발행일 최신순
    private(set) var sections: [DaySection] = []
    /// 필터 메뉴에 늘어놓는 태그와 출처. 받은 카드에서 뽑는다.
    private(set) var tagCounts: [FacetCount] = []
    private(set) var sourceCounts: [FacetCount] = []
    private(set) var state: SyncState = .idle
    private(set) var meta: SyncMeta

    /// 표본 데이터로 실행할 때는 기기 저장 내용을 건드리지 않는다
    private let persists: Bool
    private var syncTask: Task<Void, Never>?
    /// 동기화를 버릴 때마다 올린다. 버려진 작업이 뒤늦게 끝나도 상태를 건드리지 못하게 한다.
    private var generation = 0
    private var byID: [String: Card] = [:]

    static let fileName = "cards.json"
    /// 지운 카드를 반영하는 전체 대조 주기
    static let fullSyncInterval: TimeInterval = 7 * 24 * 3600
    /// 수정 시각이 분 단위로 기록되므로 여유를 둔다
    static let incrementalMargin: TimeInterval = 5 * 60

    init(persists: Bool = true) {
        self.persists = persists
        meta = persists ? SyncMeta.load() : SyncMeta()
    }

    var isEmpty: Bool { cards.isEmpty }

    func card(id: String) -> Card? {
        byID[id]
    }

    func loadFromDisk() {
        guard persists, let saved = DiskStore.load([Card].self, from: Self.fileName) else { return }
        apply(saved)
    }

    /// 표본 데이터나 테스트용으로 목록을 통째로 바꾼다
    func replace(with cards: [Card]) {
        apply(cards)
    }

    func updateMeta(_ change: (inout SyncMeta) -> Void) {
        change(&meta)
        if persists { meta.save() }
    }

    /// 바뀐 카드만 받는다. 처음이거나 전체 대조 주기가 지났으면 전부 받는다.
    /// 이미 받는 중이면 그 작업이 끝나기를 기다린다.
    func sync(using client: NotionClient, databaseID: String, forceFull: Bool = false) async {
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await performSync(using: client, databaseID: databaseID, forceFull: forceFull) }
        syncTask = task
        await task.value
        // 기다리는 사이에 버려지고 새 동기화가 시작됐으면 그 작업을 지우지 않는다
        if syncTask == task { syncTask = nil }
    }

    /// 돌고 있는 동기화를 버린다. 토큰이나 DB를 바꿀 때, 옛 연결로 받던 결과가 섞이지 않게 한다.
    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        generation += 1
        state = .idle
    }

    /// 이 동기화가 아직 유효한지 본다. 버려졌으면 던진다.
    private func checkCurrent(_ generation: Int) throws {
        try Task.checkCancellation()
        if generation != self.generation { throw CancellationError() }
    }

    private func performSync(using client: NotionClient, databaseID: String, forceFull: Bool) async {
        let generation = generation
        state = .syncing
        let started = Date.now
        do {
            if meta.dataSourceID == nil {
                let database = try await client.database(id: databaseID)
                try checkCurrent(generation)
                guard let source = database.data_sources?.first else { throw NotionError.notFound }
                updateMeta {
                    $0.dataSourceID = source.id
                    $0.databaseTitle = database.title?.plainText ?? source.name ?? ""
                }
            }
            guard let dataSourceID = meta.dataSourceID else { throw NotionError.notFound }

            let fullIsDue = meta.lastFullSyncAt.map { started.timeIntervalSince($0) > Self.fullSyncInterval } ?? true
            let full = forceFull || cards.isEmpty || meta.lastSyncAt == nil || fullIsDue
            let editedAfter = full ? nil : meta.lastSyncAt?.addingTimeInterval(-Self.incrementalMargin)

            var pages: [NotionPage] = []
            var cursor: String?
            repeat {
                let page = try await client.query(dataSourceID: dataSourceID, editedAfter: editedAfter, cursor: cursor)
                // 받는 사이에 연결을 끊었으면 옛 카드를 다시 채우지 않는다
                try checkCurrent(generation)
                pages += page.results
                cursor = page.has_more ? page.next_cursor : nil
            } while cursor != nil

            let trashed = Set(pages.filter { $0.in_trash == true }.map(\.id))
            let fetched = pages.filter { $0.in_trash != true }.compactMap(Card.init(page:))
            apply(full ? fetched : Self.merge(cards, with: fetched, removing: trashed))
            if persists { DiskStore.save(cards, to: Self.fileName) }

            updateMeta {
                $0.lastSyncAt = started
                if full { $0.lastFullSyncAt = started }
            }
            state = .idle
        } catch is CancellationError {
            if generation == self.generation { state = .idle }
        } catch let error as NotionError {
            guard generation == self.generation else { return }
            // DB가 바뀌었을 수 있으니 데이터 소스 ID는 다음에 다시 찾는다
            if error == .notFound { updateMeta { $0.dataSourceID = nil } }
            state = .failed(error)
        } catch {
            guard generation == self.generation else { return }
            state = .failed(.invalidResponse)
        }
    }

    /// 저장된 카드에 새로 받은 카드를 덮어쓰고, 휴지통에 간 카드를 뺀다
    static func merge(_ existing: [Card], with fetched: [Card], removing trashed: Set<String> = []) -> [Card] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for card in fetched { byID[card.id] = card }
        for id in trashed { byID[id] = nil }
        return Array(byID.values)
    }

    func reset() {
        cancelSync()
        cards = []
        sections = []
        tagCounts = []
        sourceCounts = []
        byID = [:]
        state = .idle
        meta = SyncMeta()
        if persists {
            DiskStore.remove(Self.fileName)
            UserDefaults.standard.removeObject(forKey: SyncMeta.defaultsKey)
        }
    }

    private func apply(_ newCards: [Card]) {
        cards = newCards.sorted { $0.createdAt > $1.createdAt }
        sections = DayGrouping.sections(from: cards)
        tagCounts = Facets.tags(in: cards)
        sourceCounts = Facets.sources(in: cards)
        byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
