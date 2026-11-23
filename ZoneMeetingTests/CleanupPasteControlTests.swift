// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import XCTest
@testable import Zone

/// A live UIPasteControl makes UIKit ask the pasteboard server, synchronously on the main
/// thread, after every pasteboard change; on the phone that hung Zone for up to 2 s per copy.
/// Home keeps the Cleanup page mounted while hidden, so the control must exist only while
/// that page is the one showing.
@MainActor
final class CleanupPasteControlTests: XCTestCase {
    @Observable final class Page { var active: Bool; init(_ active: Bool) { self.active = active } }

    struct Host: View {
        let page: Page
        var body: some View { CleanupView(isActive: page.active) }
    }

    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func show(_ page: Page) -> UIView {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: Host(page: page))
        window.makeKeyAndVisible()
        // The page is built either way: its draft editor is there even while hidden.
        XCTAssertTrue(wait { self.count(UITextView.self, in: self.window) > 0 }, "The Cleanup page never rendered")
        return window
    }

    /// Runs the main loop until `condition` holds, for SwiftUI to apply a state change.
    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            window.layoutIfNeeded()
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func count<T>(_ type: T.Type, in view: UIView) -> Int {
        (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(type, in: $1) }
    }

    private func pasteControls(in view: UIView) -> Int { count(UIPasteControl.self, in: view) }

    func testActivePageHasThePasteButton() {
        let root = show(Page(true))
        XCTAssertTrue(wait { self.pasteControls(in: root) == 1 }, "The visible Cleanup page keeps its prompt-free Paste")
    }

    func testHiddenPageHasNoPasteControl() {
        let root = show(Page(false))
        // Give a wrongly built control every chance to appear before checking it did not.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        root.layoutIfNeeded()
        XCTAssertEqual(pasteControls(in: root), 0)
    }

    func testSwitchingAwayRemovesTheControlAndKeepsItComingBack() {
        let page = Page(true)
        let root = show(page)
        XCTAssertTrue(wait { self.pasteControls(in: root) == 1 })
        page.active = false
        XCTAssertTrue(wait { self.pasteControls(in: root) == 0 }, "Leaving Cleanup must tear the control down")
        page.active = true
        XCTAssertTrue(wait { self.pasteControls(in: root) == 1 }, "Coming back to Cleanup brings Paste back")
    }
}
