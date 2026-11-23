// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore

@MainActor
final class SystemLexiconBridgeTests: XCTestCase {
    func testKeyboardSharesCaseOnlyTermsWhenFullAccessArrivesAndReplacesRemovedContacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SystemLexiconStore(fileURL: root.appendingPathComponent("system.json"))
        let reader = SystemLexiconStore(fileURL: writer.fileURL)
        let proxy = SwipeIntegrationTests.Proxy()
        let model = KeyboardModel(proxy: proxy, systemLexiconStore: writer)
        model.applySystemLexicon([(input: "nita", text: "Nita"), (input: "omw", text: "On my way!")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path), "No shared write without Full Access")
        proxy.hasOpenAccess = true
        model.refreshFullAccess()
        for _ in 0..<100 {
            if try reader.snapshot().names == ["Nita"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try reader.snapshot().names, ["Nita"])
        XCTAssertEqual(TextStyle.casual.insertion(of: "I met Nida", contextBefore: nil,
            fieldCapitalizesSentences: true, systemWords: try reader.snapshot().speechWords), "I met Nita")
        model.applySystemLexicon([])
        for _ in 0..<100 {
            if try reader.snapshot() == .empty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try reader.snapshot(), .empty)
        model.keyboardWillDisappear()
    }
}
