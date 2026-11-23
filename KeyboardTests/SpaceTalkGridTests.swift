// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// Hold space to talk (Beta), through the real `KeyGridView` and `KeyboardModel` with synthetic
/// touches. The mic is the counting test double in `SwipeGridTests.swift`: these tests prove what
/// the space bar asks of it and that the press itself never types, moves the cursor or lets
/// another finger in. `SpaceHoldTests` (ZoneCore) covers the decisions behind the mic's answers.
@MainActor final class SpaceTalkGridTests: XCTestCase {
    private final class Touch: UITouch {
        var point: CGPoint
        let owner: UIView
        var reportedTimestamp: TimeInterval?
        init(_ point: CGPoint, in owner: UIView) { self.point = point; self.owner = owner; super.init() }
        override var view: UIView? { owner }
        override var timestamp: TimeInterval { reportedTimestamp ?? ProcessInfo.processInfo.systemUptime }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private struct Rig {
        let proxy: SwipeIntegrationTests.Proxy
        let model: KeyboardModel
        let mic: MicController
        let grid: KeyGridView
    }

    private func rig(_ hold: SpaceHold = .talk, talkAvailable: Bool = true) -> Rig {
        let p = SwipeIntegrationTests.Proxy(); p.text = "abcdef"
        let m = KeyboardModel(proxy: p)
        m.refreshTraits(); m.apply(KeyboardPreferences(autocorrectEnabled: false, showsEmojiKey: false, spaceHold: hold))
        let mic = MicController()
        mic.talkAvailable = talkAvailable
        let grid = KeyGridView(model: m, mic: mic, controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250)
        grid.sync()
        return Rig(proxy: p, model: m, mic: mic, grid: grid)
    }

    private func element(_ name: String, in grid: KeyGridView) throws -> UIAccessibilityElement {
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        return try XCTUnwrap(elements.first { $0.accessibilityLabel == name })
    }

    private func touch(_ name: String, in grid: KeyGridView) throws -> Touch {
        let frame = try element(name, in: grid).accessibilityFrameInContainerSpace
        return Touch(CGPoint(x: frame.midX, y: frame.midY), in: grid)
    }

    /// Past `SpaceTalk.holdDuration` (0.35 s) with room for a loaded simulator.
    private func hold() async throws { try await Task.sleep(for: .milliseconds(450)) }
    /// One turn for the grid's observation hop.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    // MARK: The hold

    func testHoldAsksOnceAndLettingGoStopsWithoutTypingASpace() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        XCTAssertEqual(r.mic.holdsBegan, 1)
        r.mic.spaceTalkPhase = .listening
        try await settle()
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.mic.holdsEnded, 1)
        XCTAssertEqual(r.proxy.text, "abcdef")
        XCTAssertEqual(r.proxy.tail, "")
    }

    func testTheSpaceBarFollowsTheDictation() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        XCTAssertNil(try element("Space", in: r.grid).accessibilityValue)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        XCTAssertEqual(try element("Space", in: r.grid).accessibilityValue, "Starting")
        r.mic.spaceTalkPhase = .listening
        try await settle()
        XCTAssertEqual(try element("Space", in: r.grid).accessibilityValue, "Listening")
        r.grid.touchesEnded([space], with: nil)
        XCTAssertNil(try element("Space", in: r.grid).accessibilityValue)
    }

    func testTheHintSaysHoldToTalkOnlyWithTalkChosen() throws {
        let talk = rig(.talk), cursor = rig(.moveCursor)
        defer { talk.model.keyboardWillDisappear(); cursor.model.keyboardWillDisappear() }
        XCTAssertEqual(try element("Space", in: talk.grid).accessibilityHint,
                       "Touch and hold to talk, and let go to insert. Slide sideways to move the cursor.")
        XCTAssertEqual(try element("Space", in: cursor.grid).accessibilityHint,
                       "Touch and hold, then slide to move the cursor. Slide up or down to change lines.")
    }

    // MARK: What stays as it was

    func testATapStillTypesASpace() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        r.grid.touchesEnded([space], with: nil)
        try await hold() // a timer left armed would ask now
        XCTAssertEqual(r.proxy.text, "abcdef ")
        XCTAssertEqual(r.mic.holdsBegan, 0)
        XCTAssertEqual(r.mic.holdsEnded, 0)
    }

    func testRapidSpacesNeverTalk() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        for _ in 0..<12 {
            r.grid.touchesBegan([space], with: nil)
            r.grid.touchesEnded([space], with: nil)
        }
        try await hold()
        // Every tap typed (a double space may become ". "), and none of them asked to talk.
        XCTAssertTrue(r.proxy.text.hasPrefix("abcdef"), r.proxy.text)
        XCTAssertTrue(r.proxy.text.hasSuffix(" "), r.proxy.text)
        XCTAssertGreaterThan(r.proxy.text.count, 6)
        XCTAssertEqual(r.mic.holdsBegan, 0)
        XCTAssertEqual(r.mic.holdsEnded, 0)
    }

    func testASlideBeforeTheHoldMovesTheCursorAndNeverTalks() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        let start = ProcessInfo.processInfo.systemUptime
        space.reportedTimestamp = start
        r.grid.touchesBegan([space], with: nil)
        space.reportedTimestamp = start + 0.1
        space.point.x -= 16; r.grid.touchesMoved([space], with: nil) // activates, does not move
        space.reportedTimestamp = start + 0.2
        space.point.x -= 16; r.grid.touchesMoved([space], with: nil)
        try await hold() // the cancelled hold timer must not ask either
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.proxy.text, "abcd"); XCTAssertEqual(r.proxy.tail, "ef")
        XCTAssertEqual(r.mic.holdsBegan, 0)
    }

    func testMoveCursorNeverAsksToTalk() async throws {
        let r = rig(.moveCursor)
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        space.point.x -= 16; r.grid.touchesMoved([space], with: nil)
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.mic.holdsBegan, 0)
        XCTAssertEqual(r.proxy.text, "abcd"); XCTAssertEqual(r.proxy.tail, "ef")
    }

    func testNothingToTalkWithFallsBackToTheCursor() async throws {
        // No Full Access, or a dictation already under way: the hold is the cursor's.
        let r = rig(talkAvailable: false)
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        XCTAssertEqual(r.mic.holdsBegan, 1)
        space.point.x -= 16; r.grid.touchesMoved([space], with: nil)
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.mic.holdsEnded, 0)
        XCTAssertEqual(r.proxy.text, "abcd"); XCTAssertEqual(r.proxy.tail, "ef")
    }

    func testAVerticalExitBeforeTheHoldNeverTalksOrTypes() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        space.point.y -= 180; r.grid.touchesMoved([space], with: nil)
        try await hold()
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.mic.holdsBegan, 0)
        XCTAssertEqual(r.proxy.text, "abcdef"); XCTAssertEqual(r.proxy.tail, "")
    }

    // MARK: While talking

    func testOtherFingersTypeNothingWhileTalkingAndWorkAfter() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid), x = try touch("x", in: r.grid), delete = try touch("Delete", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        r.mic.spaceTalkPhase = .listening
        // Rollover, a tap and a held delete from the other thumb.
        r.grid.touchesBegan([x], with: nil); r.grid.touchesEnded([x], with: nil)
        r.grid.touchesBegan([delete], with: nil); try await settle(); r.grid.touchesEnded([delete], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdef")
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.mic.holdsEnded, 1)
        r.grid.touchesBegan([x], with: nil); r.grid.touchesEnded([x], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdefx")
    }

    func testAWanderingFingerNeitherMovesTheCursorNorTypes() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        r.mic.spaceTalkPhase = .listening
        for step in 0..<10 {
            space.point.x += step.isMultiple(of: 2) ? -24 : 18
            space.point.y -= 12
            r.grid.touchesMoved([space], with: nil)
        }
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdef"); XCTAssertEqual(r.proxy.tail, "")
        XCTAssertEqual(r.mic.holdsEnded, 1)
    }

    func testADictationEndedFromTheStripHandsTheKeysBackWhileSpaceIsHeld() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid), x = try touch("x", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        r.mic.spaceTalkPhase = .listening
        try await settle()
        // Stop in the strip: the recording ends while the thumb stays on space.
        r.mic.spaceTalkPhase = .none
        try await settle()
        XCTAssertNil(try element("Space", in: r.grid).accessibilityValue)
        // The other thumb types again; the held space lands first and types nothing.
        r.grid.touchesBegan([x], with: nil); r.grid.touchesEnded([x], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdefx")
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdefx")
        XCTAssertEqual(r.mic.holdsEnded, 1)
    }

    func testAHoldTheStripOnlyExplainsTypesNothingAndLeavesTheKeys() async throws {
        // Zone not ready: the mic says so in the strip and owns the hold without a dictation.
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        r.mic.talkAvailable = true
        let space = try touch("Space", in: r.grid), x = try touch("x", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        r.mic.explainsInsteadOfTalking = true
        try await hold()
        XCTAssertEqual(r.mic.holdsBegan, 1)
        XCTAssertNil(try element("Space", in: r.grid).accessibilityValue)
        space.point.x -= 40; r.grid.touchesMoved([space], with: nil) // no cursor either
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdef"); XCTAssertEqual(r.proxy.tail, "")
        r.grid.touchesBegan([x], with: nil); r.grid.touchesEnded([x], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdefx")
    }

    func testACancelledTouchEndsTheHoldOnce() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        r.grid.touchesCancelled([space], with: nil)
        r.grid.touchesEnded([space], with: nil) // a late duplicate release
        XCTAssertEqual(r.mic.holdsEnded, 1)
        XCTAssertEqual(r.proxy.text, "abcdef")
    }

    func testAResizeWhileTalkingEndsTheHoldOnce() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        r.grid.touchesBegan([space], with: nil)
        try await hold()
        r.grid.frame.size.width = 600; r.grid.sync()
        r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.mic.holdsEnded, 1)
        XCTAssertEqual(r.proxy.text, "abcdef")
    }

    func testHoldsInARowEachAskAndEndOnce() async throws {
        let r = rig()
        defer { r.model.keyboardWillDisappear() }
        let space = try touch("Space", in: r.grid)
        for round in 1...4 {
            r.grid.touchesBegan([space], with: nil)
            try await hold()
            r.mic.spaceTalkPhase = .listening
            r.grid.touchesEnded([space], with: nil)
            XCTAssertEqual(r.mic.holdsBegan, round)
            XCTAssertEqual(r.mic.holdsEnded, round)
        }
        // Then an ordinary tap types its space again.
        r.grid.touchesBegan([space], with: nil); r.grid.touchesEnded([space], with: nil)
        XCTAssertEqual(r.proxy.text, "abcdef ")
    }
}
