// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import Observation
import ZoneCore

/// Dictation is outside these tests; the grid and model are the production types.
@MainActor @Observable final class MicController {
    var mode = KeyboardMode.type
    var showsHistory = false
    func userTypedKey() {}
    /// Hold space to talk: off unless a test turns it on, and counted.
    var talkAvailable = false
    var spaceTalkPhase = SpaceTalk.Phase.none
    private(set) var holdsBegan = 0
    private(set) var holdsEnded = 0
    /// The strip explains (Zone not ready): the hold is talking's, with no dictation.
    var explainsInsteadOfTalking = false
    func spaceHoldBegan() -> Bool {
        holdsBegan += 1
        if talkAvailable, !explainsInsteadOfTalking { spaceTalkPhase = .starting }
        return talkAvailable
    }
    func spaceHoldEnded() {
        holdsEnded += 1
        spaceTalkPhase = .none
    }
}

@MainActor final class SwipeGridTests: XCTestCase {
    private final class Touch: UITouch {
        var point: CGPoint
        let owner: UIView
        var reportedTimestamp: TimeInterval?
        init(_ point: CGPoint, in owner: UIView) { self.point = point; self.owner = owner; super.init() }
        override var view: UIView? { owner }
        override var timestamp: TimeInterval { reportedTimestamp ?? ProcessInfo.processInfo.systemUptime }
        override func location(in view: UIView?) -> CGPoint { point }
    }
    private func setupGrid() -> (SwipeIntegrationTests.Proxy, KeyboardModel, KeyGridView) {
        let p = SwipeIntegrationTests.Proxy(); p.text = "abcdef"
        let m = KeyboardModel(proxy: p)
        m.refreshTraits(); m.apply(KeyboardPreferences(autocorrectEnabled: false, showsEmojiKey: false))
        let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250)
        grid.sync()
        return (p, m, grid)
    }
    private func touch(_ name: String, in grid: KeyGridView) throws -> Touch {
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        let element = try XCTUnwrap(elements.first { $0.accessibilityLabel == name })
        let frame = element.accessibilityFrameInContainerSpace
        return Touch(CGPoint(x: frame.midX, y: frame.midY), in: grid)
    }
    func testDuplicateBeginAndLateDeliveryNeverTypeTwiceAndTouchReuseStillWorks() throws {
        let (p, m, grid) = setupGrid()
        let x = try touch("x", in: grid)
        x.reportedTimestamp = 100
        grid.touchesBegan([x], with: nil); grid.touchesBegan([x], with: nil)
        x.reportedTimestamp = 101
        grid.touchesEnded([x], with: nil)
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        XCTAssertEqual(p.text, "abcdefx")
        x.reportedTimestamp = 102
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        XCTAssertEqual(p.text, "abcdefxx")
        m.keyboardWillDisappear()
    }
    func testFastOverlappingRegularTapsRepairSlipsWithSwipeOnAndOff() async throws {
        let corrector: Autocorrector? = await withCheckedContinuation { continuation in
            SpellingStore.load { continuation.resume(returning: $0) }
        }
        XCTAssertNotNil(corrector)
        for enabled in [false, true] {
            for cadence in [0.03, 0.08, 0.15] {
                let p = SwipeIntegrationTests.Proxy()
                let m = KeyboardModel(proxy: p)
                m.refreshTraits()
                m.apply(KeyboardPreferences(autocorrectEnabled: true, showsEmojiKey: false,
                    swipeTypingEnabled: enabled, swipeLearningEnabled: false))
                let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
                grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250); grid.sync()
                var held: Touch?
                var tick = ProcessInfo.processInfo.systemUptime
                for character in "hesxhavingxfun socmuchcfunx fuckxyeahx " {
                    grid.sync()
                    let next = try touch(character == " " ? "Space" : String(character), in: grid)
                    next.reportedTimestamp = tick
                    grid.touchesBegan([next], with: nil)
                    if let held {
                        held.reportedTimestamp = tick + cadence / 3
                        grid.touchesEnded([held], with: nil)
                    }
                    held = next
                    tick += cadence
                    try await Task.sleep(for: .seconds(cadence))
                }
                if let held { held.reportedTimestamp = tick; grid.touchesEnded([held], with: nil) }
                XCTAssertEqual(p.text, "he's having fun so much fun fuck yeah ", "swipe=\(enabled), cadence=\(cadence)")
                m.keyboardWillDisappear()
            }
        }
    }
    func testSecondFingerSubmitsSwipeBeforeSpaceExactlyOnce() async throws {
        let p = SwipeIntegrationTests.Proxy()
        let m = KeyboardModel(proxy: p)
        m.refreshTraits(); m.apply(KeyboardPreferences(autocorrectEnabled: false,
            swipeTypingEnabled: true, swipeLearningEnabled: false))
        let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250); grid.sync()
        let finger = try touch("t", in: grid), end = try touch("o", in: grid)
        let space = try touch("Space", in: grid)
        finger.reportedTimestamp = 100
        grid.touchesBegan([finger], with: nil)
        finger.point = end.point; finger.reportedTimestamp = 100.2
        grid.touchesMoved([finger], with: nil)
        space.reportedTimestamp = 100.21
        grid.touchesBegan([space], with: nil)
        space.reportedTimestamp = 100.25
        grid.touchesEnded([space], with: nil)
        finger.reportedTimestamp = 100.3
        grid.touchesEnded([finger], with: nil)
        for _ in 0..<150 {
            if p.text.hasSuffix(" ") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(["to ", "too "].contains(p.text), p.text)
        m.keyboardWillDisappear()
    }
}
