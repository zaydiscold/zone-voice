// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class HistoryRangeDeleteTests: XCTestCase {
    func testDeletesOnlyRecordsInsideTheRange() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptHistory(directory: dir)
        store.setRetention(.untilDeleted)
        let old = Date(timeIntervalSinceNow: -40 * 86_400), recent = Date(timeIntervalSinceNow: -2 * 86_400)
        let a = UUID(), b = UUID()
        store.begin(id: a, engine: "t", source: .app, now: old)
        _ = store.finish(id: a, text: "old one", audioSeconds: 1, status: .finished, now: old)
        store.begin(id: b, engine: "t", source: .app, now: recent)
        _ = store.finish(id: b, text: "recent one", audioSeconds: 1, status: .finished, now: recent)
        store.delete(createdIn: Date.distantPast...Date(timeIntervalSinceNow: -30 * 86_400))
        XCTAssertEqual(store.recent(limit: 10).map(\.text), ["recent one"])
    }
}
