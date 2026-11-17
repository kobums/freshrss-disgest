import Foundation
import Observation

/// 나중에 원문을 읽으려고 표시해 둔 글. 이 기기에만 저장한다.
@MainActor
@Observable
final class SavedStore {
    /// 카드 ID → 저장한 시각
    private(set) var saved: [String: Date] = [:]

    private let persists: Bool
    static let fileName = "saved.json"

    init(persists: Bool = true) {
        self.persists = persists
    }

    func loadFromDisk() {
        guard persists, let stored = DiskStore.load([String: Date].self, from: Self.fileName) else { return }
        saved = stored
    }

    var count: Int { saved.count }

    func isSaved(_ id: String) -> Bool {
        saved[id] != nil
    }

    func toggle(_ id: String) {
        if saved[id] == nil {
            saved[id] = .now
        } else {
            saved[id] = nil
        }
        if persists { DiskStore.save(saved, to: Self.fileName) }
    }

    func replace(with ids: [String]) {
        saved = Dictionary(ids.map { ($0, Date.now) }, uniquingKeysWith: { first, _ in first })
    }

    func reset() {
        saved = [:]
        if persists { DiskStore.remove(Self.fileName) }
    }
}
