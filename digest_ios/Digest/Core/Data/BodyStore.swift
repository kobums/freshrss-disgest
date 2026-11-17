import Foundation
import Observation

/// 카드 본문(핵심)을 기기에 저장해 두고, 없는 것은 뒤에서 미리 받는다.
/// 본문은 카드마다 요청 하나가 들어서 목록과 따로 다룬다.
@MainActor
@Observable
final class BodyStore {
    private(set) var bodies: [String: CardBody] = [:]
    /// 받다가 실패한 카드. 상세에서 "다시 시도"를 보여 준다.
    private(set) var failed: Set<String> = []
    private(set) var isPrefetching = false

    private let persists: Bool
    private var prefetchTask: Task<Void, Never>?
    private var inFlight: [String: Task<Bool, Never>] = [:]
    private var unsavedCount = 0

    static let fileName = "bodies.json"
    /// 미리 받을 때 요청 사이 간격. 초당 2건으로 한도(분당 180)의 3분의 2만 쓴다.
    static let prefetchPause: Duration = .milliseconds(500)

    init(persists: Bool = true) {
        self.persists = persists
    }

    func loadFromDisk() {
        guard persists, let saved = DiskStore.load([String: CardBody].self, from: Self.fileName) else { return }
        bodies = saved
    }

    func replace(with bodies: [String: CardBody]) {
        self.bodies = bodies
    }

    /// 저장된 본문. 카드가 그 뒤에 고쳐졌으면 낡은 것이므로 nil.
    func body(for card: Card) -> CardBody? {
        guard let body = bodies[card.id], body.cardEditedAt >= card.editedAt else { return nil }
        return body
    }

    func hasFailed(_ card: Card) -> Bool {
        failed.contains(card.id)
    }

    /// 본문이 있는 카드 수 (설정 화면 표시용)
    func count(in cards: [Card]) -> Int {
        cards.reduce(0) { $0 + (body(for: $1) == nil ? 0 : 1) }
    }

    /// 한 장을 지금 받는다. 같은 카드를 이미 받는 중이면 그 결과를 기다린다.
    @discardableResult
    func load(_ card: Card, using client: NotionClient) async -> Bool {
        if body(for: card) != nil { return true }
        if let running = inFlight[card.id] { return await running.value }
        let task = Task { await fetch(card, using: client) == nil }
        inFlight[card.id] = task
        let ok = await task.value
        inFlight[card.id] = nil
        return ok
    }

    /// 본문이 없는 카드를 앞에서부터 차례로 받는다. 다시 부르면 새 목록으로 갈아탄다.
    func startPrefetch(_ cards: [Card], using client: NotionClient) {
        prefetchTask?.cancel()
        let pending = cards.filter { body(for: $0) == nil }
        guard !pending.isEmpty else {
            isPrefetching = false
            return
        }
        isPrefetching = true
        prefetchTask = Task {
            for card in pending {
                if Task.isCancelled { return }
                if body(for: card) != nil { continue }
                let error = await fetch(card, using: client)
                if Task.isCancelled { return }
                // 연결 문제면 남은 카드도 실패할 테니 멈춘다. 다음 동기화 때 이어서 받는다.
                if let error, error != .notFound, error != .invalidResponse { break }
                try? await Task.sleep(for: Self.prefetchPause)
            }
            saveNow()
            isPrefetching = false
        }
    }

    func stopPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        isPrefetching = false
    }

    /// 목록에서 사라진 카드의 본문을 지운다
    func prune(keeping ids: Set<String>) {
        let stale = bodies.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { bodies[id] = nil }
        failed.formIntersection(ids)
        unsavedCount += 1
        saveNow()
    }

    func saveNow() {
        guard persists, unsavedCount > 0 else { return }
        DiskStore.save(bodies, to: Self.fileName)
        unsavedCount = 0
    }

    func reset() {
        stopPrefetch()
        bodies = [:]
        failed = []
        unsavedCount = 0
        if persists { DiskStore.remove(Self.fileName) }
    }

    /// 성공하면 nil, 실패하면 그 오류
    private func fetch(_ card: Card, using client: NotionClient) async -> NotionError? {
        do {
            let blocks = try await client.blocks(pageID: card.id)
            bodies[card.id] = CardBody(blocks: blocks, cardEditedAt: card.editedAt)
            failed.remove(card.id)
            unsavedCount += 1
            if unsavedCount >= 25 { saveNow() }
            return nil
        } catch is CancellationError {
            return nil
        } catch let error as NotionError {
            failed.insert(card.id)
            return error
        } catch {
            failed.insert(card.id)
            return .invalidResponse
        }
    }
}
