// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

final class HistoryNotificationTests: XCTestCase {
    func testChangeObserverCanReadBackupBeforeWriterReturns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = TranscriptHistory(directory: root)
        let id = UUID()
        history.begin(id: id, engine: "test", source: .note)
        let observed = expectation(description: "observer reads committed history without deadlock")
        let writerFinished = expectation(description: "writer returns")
        let observer = NotificationCenter.default.addObserver(forName: .init("ZoneLibraryDidChange"),
                                                              object: nil, queue: nil) { _ in
            do {
                let records = try TranscriptHistory.recordsInBackup(history.backupData())
                XCTAssertEqual(records.first?.id, id)
                XCTAssertEqual(records.first?.text, "Saved before notification")
            } catch { XCTFail("Snapshot failed: \(error)") }
            observed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        DispatchQueue.global().async {
            XCTAssertTrue(history.finish(id: id, text: "Saved before notification", audioSeconds: 1, status: .note))
            writerFinished.fulfill()
        }
        wait(for: [observed, writerFinished], timeout: 3)
    }

    func testMainQueueBackupAndBackgroundWriteCompleteTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = TranscriptHistory(directory: root)
        let observed = expectation(description: "main queue observer")
        let finished = expectation(description: "background writer")
        let observer = NotificationCenter.default.addObserver(forName: .init("ZoneLibraryDidChange"),
                                                              object: nil, queue: .main) { _ in
            do { _ = try history.backupData() } catch { XCTFail("Snapshot failed: \(error)") }
            observed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        DispatchQueue.global().async { history.purgeExpired(); finished.fulfill() }
        wait(for: [observed, finished], timeout: 3)
    }
}
