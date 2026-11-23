// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The system paste button's hand-off: text arrives after the tap, and only lands in the field
/// the tap was made in.
@MainActor final class PasteControlTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    private func make(_ p: Proxy) -> (KeyboardModel, PasteTarget) {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: false))
        return (m, PasteTarget(session: { m.currentSession }) { m.insertPasted($0) })
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    func testProviderTextIsInserted() async throws {
        let p = Proxy(), (_, target) = make(p)
        XCTAssertTrue(target.canPaste([NSItemProvider(object: "hello" as NSString)]))
        target.paste(itemProviders: [NSItemProvider(object: "hello" as NSString)])
        try await settle()
        XCTAssertEqual(p.text, "hello")
    }
    func testLateTextIsDroppedAfterTheFieldChanges() async throws {
        let p = Proxy(), (_, target) = make(p)
        target.paste(itemProviders: [NSItemProvider(object: "hello" as NSString)])
        p.session = "b"
        try await settle()
        XCTAssertEqual(p.text, "")
    }
    func testEmptyAndNonTextProvidersInsertNothing() async throws {
        let p = Proxy(), (_, target) = make(p)
        target.paste(itemProviders: [NSItemProvider(object: "" as NSString)])
        target.paste(itemProviders: [NSItemProvider(object: UIImage())])
        XCTAssertFalse(target.canPaste([NSItemProvider(object: UIImage())]))
        try await settle()
        XCTAssertEqual(p.text, "")
    }
    func testPasteEndsTheWordInProgressWithoutCorrectingIt() async throws {
        let p = Proxy(), (m, target) = make(p)
        for character in "teh" { m.handleTap(.character(String(character))) }
        target.paste(itemProviders: [NSItemProvider(object: " x" as NSString)])
        try await settle()
        XCTAssertEqual(p.text, "teh x")
        m.handleTap(.space)
        XCTAssertEqual(p.text, "teh x ")
    }
}
