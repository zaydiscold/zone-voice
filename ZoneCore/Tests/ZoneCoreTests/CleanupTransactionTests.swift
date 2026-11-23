// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CleanupTransactionTests: XCTestCase {
    func testModelFailureKeepsDurableOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = CleanupArchive(directory: root)
        do {
            _ = try await CleanupTransaction.run(original: "um keep this", archive: archive) { _ in
                throw CocoaError(.fileReadUnknown)
            }
            XCTFail("Model failure must propagate")
        } catch {}
        XCTAssertEqual(try archive.entries().first?.original, "um keep this")
        XCTAssertNil(try archive.entries().first?.cleaned)
    }

    func testUnsafeResultCannotBecomeSavedCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = CleanupArchive(directory: root)
        do {
            _ = try await CleanupTransaction.run(original: "do not send 500 dollars", archive: archive) { _ in "Send 500 dollars." }
            XCTFail("Changed words must be rejected")
        } catch {}
        XCTAssertNil(try archive.entries().first?.cleaned)
    }

    func testSaveFailurePreventsModelExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked".utf8).write(to: root)
        do {
            _ = try await CleanupTransaction.run(original: "keep this", archive: CleanupArchive(directory: root)) { _ in
                XCTFail("Model must not run before the original is saved")
                return "Keep this."
            }
            XCTFail("Save failure must propagate")
        } catch {}
    }

    func testCancelledGenerationCannotPublishCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = CleanupArchive(directory: root)
        let started = expectation(description: "Original saved; generation started")
        let task = Task {
            try await CleanupTransaction.run(original: "um keep this", archive: archive) { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "Keep this."
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not publish") } catch {}
        XCTAssertEqual(try archive.entries().first?.original, "um keep this")
        XCTAssertNil(try archive.entries().first?.cleaned)
    }
}
