// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// The host makes a new keyboard controller for nearly every appearance in one long-lived
/// process. Anything that keeps an old model alive keeps its whole keyboard alive with it: on
/// the iOS 26.2 simulator a retained model and view tree grew the footprint about 1 MB per
/// appearance (November 15), the climb the phone's jetsam reports showed. The model and the key
/// grid, used and then let go, must be freed.
@MainActor final class KeyboardLifetimeTests: XCTestCase {
    func testModelAndGridAreFreedAfterTypingAndSwipeSetup() throws {
        weak var model: KeyboardModel?
        weak var grid: KeyGridView?
        weak var proxy: SwipeIntegrationTests.Proxy?
        autoreleasepool {
            let p = SwipeIntegrationTests.Proxy()
            let m = KeyboardModel(proxy: p)
            m.refreshTraits()
            m.apply(KeyboardPreferences(showSuggestions: true, showsEmojiKey: true, swipeTypingEnabled: true))
            let g = KeyGridView(model: m, mic: MicController(), controller: nil)
            g.frame = CGRect(x: 0, y: 0, width: 402, height: 250)
            g.sync()
            for key in ["h", "i"] { m.keyDown(.character(key)) }
            m.keyDown(.space)
            m.keyboardWillDisappear()
            model = m; grid = g; proxy = p
        }
        // Let queued main-thread work that captured them weakly or briefly run out.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(grid, "the key grid outlived its controller")
        XCTAssertNil(model, "the keyboard model outlived its controller and kept its keyboard alive")
        XCTAssertNil(proxy)
    }
}
