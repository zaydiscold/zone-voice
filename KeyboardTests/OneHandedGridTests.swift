// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// The one-handed keyboard through the production grid: the keys narrowed into a column inside a
/// full-width keyboard, the edge margin toward the side panel, the hold-123 picker, and the side
/// panel's buttons. Synthetic touches at typing speed, as `CursorGridTests` does.
@MainActor final class OneHandedGridTests: XCTestCase {
    private final class Touch: UITouch {
        var point: CGPoint
        let owner: UIView
        var reportedTimestamp: TimeInterval?
        init(_ point: CGPoint, in owner: UIView) { self.point = point; self.owner = owner; super.init() }
        override var view: UIView? { owner }
        override var timestamp: TimeInterval { reportedTimestamp ?? ProcessInfo.processInfo.systemUptime }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private struct Setup {
        let proxy: SwipeIntegrationTests.Proxy
        let model: KeyboardModel
        let grid: KeyGridView
        let keyboard: UIView
    }

    /// A 402 pt keyboard (iPhone 17 Pro) with the grid in the right-hand column, as
    /// `KeyboardViewController.layoutColumn` places it at the default 80 percent.
    private func setup(hand: OneHandedSide? = .right, enabled: Bool = true, swipe: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Setup {
        let suite = "OneHandedGridTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let p = SwipeIntegrationTests.Proxy()
        let m = KeyboardModel(proxy: p)
        m.handMemory = LocalKeyboardHand(defaults: defaults)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: false, showsEmojiKey: false, swipeTypingEnabled: swipe,
                                    swipeLearningEnabled: false, oneHandedEnabled: enabled, oneHandedSide: hand ?? .right))
        let keyboard = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 290))
        let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
        keyboard.addSubview(grid)
        if enabled, let hand, let column = OneHandedLayout.column(width: 402, fraction: 0.8, hand: KeyboardHand(hand)) {
            grid.frame = CGRect(x: column.x, y: 40, width: column.width, height: 250)
            grid.edgeSlop = hand == .right ? (10, 0) : (0, 10)
        } else {
            grid.frame = CGRect(x: 0, y: 40, width: 402, height: 250)
        }
        grid.sync()
        addTeardownBlock { m.keyboardWillDisappear() }
        return Setup(proxy: p, model: m, grid: grid, keyboard: keyboard)
    }

    private func element(_ name: String, in grid: KeyGridView) throws -> UIAccessibilityElement {
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        return try XCTUnwrap(elements.first { $0.accessibilityLabel == name }, "no key \(name)")
    }

    private func touch(_ name: String, in grid: KeyGridView) throws -> Touch {
        let frame = try element(name, in: grid).accessibilityFrameInContainerSpace
        return Touch(CGPoint(x: frame.midX, y: frame.midY), in: grid)
    }

    private func tap(_ touch: Touch, on grid: KeyGridView) {
        grid.touchesBegan([touch], with: nil)
        grid.touchesEnded([touch], with: nil)
    }

    private func hold() async throws { try await Task.sleep(for: .milliseconds(Int(KeyGridView.handHoldDuration * 1000) + 120)) }

    // MARK: Layout

    func testTheColumnKeepsTheFullKeyboardsRowHeight() throws {
        // 322 pt alone would read as a narrow host (38 pt keys); the keyboard is 402 pt wide.
        let s = try setup()
        XCTAssertEqual(s.grid.bounds.width, 322)
        XCTAssertEqual(try element("q", in: s.grid).accessibilityFrameInContainerSpace.height, 43)
        XCTAssertEqual(try element("Space", in: s.grid).accessibilityFrameInContainerSpace.height, 43)
        let full = try setup(hand: nil, enabled: false)
        let q = try element("q", in: full.grid).accessibilityFrameInContainerSpace
        let p = try element("p", in: full.grid).accessibilityFrameInContainerSpace
        XCTAssertEqual(q.height, 43)
        // The full keyboard is untouched: ten keys across 402 pt.
        XCTAssertEqual(p.maxX + 6.5, 402, accuracy: 0.01)
        XCTAssertEqual(q.minX, 6.5, accuracy: 0.01)
    }

    func testLetterKeysAreAppleWidthInTheColumn() throws {
        // Apple's one-handed keys measured 24.7 pt caps at a 32 pt pitch on this phone.
        let s = try setup()
        let q = try element("q", in: s.grid).accessibilityFrameInContainerSpace
        let w = try element("w", in: s.grid).accessibilityFrameInContainerSpace
        XCTAssertEqual(w.minX - q.minX, 31.5, accuracy: 0.6)
        XCTAssertGreaterThan(q.width, 24.7)
    }

    // MARK: Typing in the column

    func testEveryLetterTypesAtSpeedOnBothSides() throws {
        for side in OneHandedSide.allCases {
            let s = try setup(hand: side)
            for letter in "qwertyuiopasdfghjklzxcvbnm" {
                tap(try touch(String(letter), in: s.grid), on: s.grid)
            }
            XCTAssertEqual(s.proxy.text, "qwertyuiopasdfghjklzxcvbnm", "\(side)")
        }
    }

    func testRolloverInTheColumnKeepsPressOrder() throws {
        let s = try setup()
        var held: Touch?
        for letter in "thequickbrownfox" {
            let next = try touch(String(letter), in: s.grid)
            s.grid.touchesBegan([next], with: nil)
            if let held { s.grid.touchesEnded([held], with: nil) }
            held = next
        }
        if let held { s.grid.touchesEnded([held], with: nil) }
        XCTAssertEqual(s.proxy.text, "thequickbrownfox")
    }

    func testAnOvershootIntoThePanelTypesTheEdgeKey() throws {
        let s = try setup(hand: .right)
        let q = try touch("q", in: s.grid)
        // 6 pt left of the column, over the panel.
        q.point.x = -6
        XCTAssertTrue(s.grid.point(inside: q.point, with: nil))
        XCTAssertTrue(s.grid.hitTest(q.point, with: nil) === s.grid)
        tap(q, on: s.grid)
        XCTAssertEqual(s.proxy.text, "q")
        // Past the margin the panel has it.
        XCTAssertFalse(s.grid.point(inside: CGPoint(x: -11, y: q.point.y), with: nil))
        // No margin on the screen edge side, where nothing else could take the touch anyway.
        XCTAssertFalse(s.grid.point(inside: CGPoint(x: s.grid.bounds.maxX + 1, y: q.point.y), with: nil))

        let left = try setup(hand: .left)
        let p = try touch("p", in: left.grid)
        p.point.x = left.grid.bounds.maxX + 6
        tap(p, on: left.grid)
        XCTAssertEqual(left.proxy.text, "p")
    }

    func testSwipeDecodesTheSameWordInTheColumn() async throws {
        var words: [String] = []
        for side in [OneHandedSide?.none, .right, .left] {
            let s = try setup(hand: side, enabled: side != nil, swipe: true)
            for _ in 0..<250 where !s.model.canSwipe { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(s.model.canSwipe)
            let path = try "hello".map { try touch(String($0), in: s.grid).point }
            let finger = Touch(path[0], in: s.grid)
            var t: TimeInterval = 500
            finger.reportedTimestamp = t
            s.grid.touchesBegan([finger], with: nil)
            for (a, b) in zip(path, path.dropFirst()) {
                for step in 1...6 {
                    let f = CGFloat(step) / 6
                    finger.point = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                    t += 0.016
                    finger.reportedTimestamp = t
                    s.grid.touchesMoved([finger], with: nil)
                }
            }
            finger.reportedTimestamp = t + 0.016
            s.grid.touchesEnded([finger], with: nil)
            for _ in 0..<150 where s.proxy.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            words.append(s.proxy.text.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(words, ["hello", "hello", "hello"])
    }

    // MARK: The hold-123 picker

    func testHolding123OpensThePickerAndSlidingChoosesTheOtherSide() async throws {
        let s = try setup(hand: .right)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        try await hold()
        let open = try XCTUnwrap(s.grid.handPickerState, "the picker opens on a held 123")
        XCTAssertEqual(open.selection, .right, "it opens on the hand in use")
        XCTAssertGreaterThanOrEqual(open.frame.minX, 4, "kept inside the column")
        XCTAssertLessThanOrEqual(open.frame.maxX, s.grid.bounds.maxX - 4)
        XCTAssertGreaterThan(open.frame.minY, -s.grid.frame.minY, "inside the keyboard's own view")
        // Slide over the middle, then the left item; the finger drifts up as thumbs do.
        key.point = CGPoint(x: open.frame.midX, y: key.point.y - 30)
        s.grid.touchesMoved([key], with: nil)
        XCTAssertEqual(s.grid.handPickerState?.selection, .full)
        key.point.x = open.frame.minX + 10
        s.grid.touchesMoved([key], with: nil)
        XCTAssertEqual(s.grid.handPickerState?.selection, .left)
        s.grid.touchesEnded([key], with: nil)
        XCTAssertNil(s.grid.handPickerState)
        XCTAssertEqual(s.model.hand, .left)
        XCTAssertEqual(s.model.layer, .letters, "a hold that chose a layout does not switch to numbers")
        XCTAssertEqual(s.proxy.text, "")
        // Remembered for the next keyboard.
        XCTAssertEqual(s.model.handMemory.resolve(s.model.preferences), .left)
    }

    func testSlidingPastTheEndsStillPicksTheEndItems() async throws {
        let s = try setup(hand: .right)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        try await hold()
        let open = try XCTUnwrap(s.grid.handPickerState)
        key.point.x = open.frame.minX - 80
        s.grid.touchesMoved([key], with: nil)
        XCTAssertEqual(s.grid.handPickerState?.selection, .left)
        key.point.x = open.frame.maxX + 80
        s.grid.touchesMoved([key], with: nil)
        XCTAssertEqual(s.grid.handPickerState?.selection, .right)
        key.point.x = open.frame.midX
        s.grid.touchesMoved([key], with: nil)
        s.grid.touchesEnded([key], with: nil)
        XCTAssertEqual(s.model.hand, .full)
    }

    func testLiftingWithoutSlidingChangesNothing() async throws {
        let s = try setup(hand: .right)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        try await hold()
        XCTAssertNotNil(s.grid.handPickerState)
        s.grid.touchesEnded([key], with: nil)
        XCTAssertEqual(s.model.hand, .right)
        XCTAssertEqual(s.model.layer, .letters)
    }

    func testJitterOnLiftAndDriftBeforeTheHoldKeepTheHand() async throws {
        for (drift, jitter) in [(CGFloat(0), CGFloat(6)), (12, 0), (12, -7), (-14, 9)] {
            let s = try setup(hand: .right)
            let key = try touch("Numbers", in: s.grid)
            s.grid.touchesBegan([key], with: nil)
            // A thumb resting on 123 rolls a little before the picker opens.
            key.point.x += drift
            s.grid.touchesMoved([key], with: nil)
            try await hold()
            XCTAssertNotNil(s.grid.handPickerState, "drift \(drift)")
            key.point.x += jitter
            s.grid.touchesMoved([key], with: nil)
            s.grid.touchesEnded([key], with: nil)
            XCTAssertEqual(s.model.hand, .right, "drift \(drift), jitter \(jitter)")
            XCTAssertEqual(s.model.layer, .letters)
        }
    }

    func testAQuickTapOn123StillSwitchesLayers() throws {
        let s = try setup(hand: .right)
        tap(try touch("Numbers", in: s.grid), on: s.grid)
        XCTAssertNil(s.grid.handPickerState)
        XCTAssertEqual(s.model.layer, .numbers)
        XCTAssertEqual(s.model.hand, .right)
        // And ABC back, many times in a row.
        for _ in 0..<5 {
            s.grid.sync()
            tap(try touch("Letters", in: s.grid), on: s.grid)
            s.grid.sync()
            tap(try touch("Numbers", in: s.grid), on: s.grid)
        }
        XCTAssertEqual(s.model.layer, .numbers)
    }

    func testHoldingABCOnTheNumbersLayerOpensItToo() async throws {
        let s = try setup(hand: .left)
        tap(try touch("Numbers", in: s.grid), on: s.grid)
        s.grid.sync()
        let abc = try touch("Letters", in: s.grid)
        s.grid.touchesBegan([abc], with: nil)
        try await hold()
        XCTAssertEqual(s.grid.handPickerState?.selection, .left)
        s.grid.touchesEnded([abc], with: nil)
        XCTAssertEqual(s.model.layer, .numbers)
    }

    func testASecondFingerClosesThePickerWithoutChoosing() async throws {
        let s = try setup(hand: .right)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        try await hold()
        let open = try XCTUnwrap(s.grid.handPickerState)
        key.point.x = open.frame.minX + 10
        s.grid.touchesMoved([key], with: nil)
        let x = try touch("x", in: s.grid)
        tap(x, on: s.grid)
        XCTAssertNil(s.grid.handPickerState)
        XCTAssertEqual(s.model.hand, .right)
        XCTAssertEqual(s.proxy.text, "x", "the second finger types as usual")
        s.grid.touchesEnded([key], with: nil)
        XCTAssertEqual(s.model.hand, .right)
        XCTAssertEqual(s.model.layer, .letters)
    }

    func testTheFingerSlidingOff123BeforeTheHoldOpensNothing() async throws {
        let s = try setup(hand: .right)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        key.point.y -= 60
        s.grid.touchesMoved([key], with: nil)
        try await hold()
        XCTAssertNil(s.grid.handPickerState)
        s.grid.touchesEnded([key], with: nil)
        XCTAssertEqual(s.model.hand, .right)
    }

    func testOffInSettingsHolding123IsTheOldKey() async throws {
        let s = try setup(hand: nil, enabled: false)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        try await hold()
        XCTAssertNil(s.grid.handPickerState)
        s.grid.touchesEnded([key], with: nil)
        XCTAssertEqual(s.model.layer, .numbers)
        XCTAssertEqual(s.model.hand, .full)
        // No gesture can turn it on while Settings has it off.
        s.model.chooseHand(.left)
        XCTAssertEqual(s.model.hand, .full)
    }

    func testTheKeyboardBeingClosedMidHoldClosesThePicker() async throws {
        let s = try setup(hand: .right)
        let key = try touch("Numbers", in: s.grid)
        s.grid.touchesBegan([key], with: nil)
        try await hold()
        XCTAssertNotNil(s.grid.handPickerState)
        s.grid.touchesCancelled([key], with: nil)
        XCTAssertNil(s.grid.handPickerState)
        XCTAssertEqual(s.model.hand, .right)
    }

    // MARK: VoiceOver

    func testVoiceOverCanMoveTheKeysFrom123() throws {
        let s = try setup(hand: .right)
        let numbers = try element("Numbers", in: s.grid)
        let names = numbers.accessibilityCustomActions?.map(\.name) ?? []
        XCTAssertEqual(names, [KeyboardHand.left.label, KeyboardHand.full.label])
        let action = try XCTUnwrap(numbers.accessibilityCustomActions?.first { $0.name == KeyboardHand.full.label })
        _ = action.actionHandler?(action)
        XCTAssertEqual(s.model.hand, .full)
        let off = try setup(hand: nil, enabled: false)
        XCTAssertNil(try element("Numbers", in: off.grid).accessibilityCustomActions)
    }

    // MARK: Side panel

    func testThePanelsButtonsSwitchSidesAndGoFullWidth() throws {
        let panel = OneHandedPanel(frame: CGRect(x: 0, y: 0, width: 80, height: 290))
        panel.layoutIfNeeded()
        var chosen: [KeyboardHand] = []
        panel.onChoose = { chosen.append($0) }
        // Keys on the right: the panel is on the left.
        panel.configure(side: .left, isDark: false)
        let buttons = panel.subviews.compactMap { $0 as? UIButton }
        let flip = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "oneHanded.flip" })
        let expand = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "oneHanded.expand" })
        XCTAssertEqual(flip.accessibilityLabel, "Move keys to the left")
        flip.sendActions(for: .touchUpInside)
        expand.sendActions(for: .touchUpInside)
        panel.configure(side: .right, isDark: true)
        flip.sendActions(for: .touchUpInside)
        XCTAssertEqual(chosen, [.left, .full, .right])
        // Each target is half the panel: far larger than 44 pt.
        XCTAssertEqual(flip.frame.height, 145)
        XCTAssertEqual(expand.frame.minY, 145)
    }
}
