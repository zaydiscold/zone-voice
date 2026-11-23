// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

@MainActor final class CursorGridTests: XCTestCase {
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
    private func hold() async throws { try await Task.sleep(for: .milliseconds(450)) }
    func testSecondFingerDuringCursorModeNeverTypesOrRollsOver() async throws {
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid), x = try touch("x", in: grid)
        grid.touchesBegan([space], with: nil)
        try await hold()
        grid.touchesBegan([x], with: nil)
        grid.touchesEnded([x], with: nil)
        space.point.x -= 16
        grid.touchesMoved([space], with: nil)
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcd"); XCTAssertEqual(p.tail, "ef")
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        XCTAssertEqual(p.text + p.tail, "abcdxef")
        m.keyboardWillDisappear()
    }
    func testFinalLiftLocationMovesOnceWithoutMovedEvent() async throws {
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        space.point.x -= 16
        grid.touchesEnded([space], with: nil)
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcd"); XCTAssertEqual(p.tail, "ef")
        m.keyboardWillDisappear()
    }
    func testSecondFingerBeforeHoldCommitsExactlyOneOrdinarySpace() async throws {
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid), x = try touch("x", in: grid)
        grid.touchesBegan([space], with: nil)
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        try await hold()
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcdef x")
        m.keyboardWillDisappear()
    }
    func testCancellationBeforeAndAfterActivationDisarmsTimerAndTap() async throws {
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); grid.touchesCancelled([space], with: nil)
        try await hold()
        XCTAssertEqual(p.text, "abcdef")
        grid.touchesBegan([space], with: nil); try await hold()
        space.point.x -= 8; grid.touchesMoved([space], with: nil)
        grid.touchesCancelled([space], with: nil)
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcde"); XCTAssertEqual(p.tail, "f")
        let x = try touch("x", in: grid)
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        XCTAssertEqual(p.text + p.tail, "abcdexf")
        m.keyboardWillDisappear()
    }
    func testResizeCancelsActiveCursorAndLateReleaseDoesNothing() async throws {
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        grid.frame.size.width = 600; grid.sync()
        space.point.x -= 24
        grid.touchesMoved([space], with: nil); grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcdef"); XCTAssertEqual(p.tail, "")
        m.keyboardWillDisappear()
    }
    func testSlideOnSpaceMovesCursorAtOnceAndNeverTypesASpace() throws {
        // The November 8 recording: a slide before the hold typed a space mid-word ("i f").
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid)
        let start = ProcessInfo.processInfo.systemUptime
        space.reportedTimestamp = start
        grid.touchesBegan([space], with: nil)
        // A slow, deliberate slide: 160 points per second, the precise rate of 8 points each.
        space.reportedTimestamp = start + 0.1
        space.point.x -= 16; grid.touchesMoved([space], with: nil) // activates, does not move
        space.reportedTimestamp = start + 0.2
        space.point.x -= 16; grid.touchesMoved([space], with: nil)
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcd"); XCTAssertEqual(p.tail, "ef")
        m.keyboardWillDisappear()
    }
    func testVerticalExitBeforeHoldTypesNothingAndNeverBecomesCursor() async throws {
        let (p, m, grid) = setupGrid()
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil)
        space.point.y -= 180; grid.touchesMoved([space], with: nil)
        try await hold()
        space.point.x -= 40; grid.touchesMoved([space], with: nil)
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text, "abcdef"); XCTAssertEqual(p.tail, "")
        m.keyboardWillDisappear()
    }
    func testLongScrubBackAndForthNeverStallsOrTypes() async throws {
        let (p, m, grid) = setupGrid()
        p.text = String(repeating: "word ", count: 20); p.lagsContext = true
        let original = p.text, space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        var clock = ProcessInfo.processInfo.systemUptime
        for pass in 0..<6 {
            let direction: CGFloat = pass.isMultiple(of: 2) ? -1 : 1
            for _ in 0..<10 {
                clock += 0.05 // 160 points per second: precise, one character per 8 points
                space.reportedTimestamp = clock
                space.point.x += direction * 8; grid.touchesMoved([space], with: nil)
                try await Task.sleep(for: .milliseconds(2)) // host callbacks land between frames
                m.hostSelectionDidChange()
            }
            XCTAssertEqual(p.text.count, pass.isMultiple(of: 2) ? original.count - 10 : original.count, "pass \(pass)")
        }
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text + p.tail, original)
        m.keyboardWillDisappear()
    }
    func testFlickCoversMoreTextThanTheSameDistanceSlowly() async throws {
        func travel(seconds perFrame: TimeInterval) async throws -> Int {
            let (p, m, grid) = setupGrid()
            p.text = String(repeating: "word ", count: 30)
            let length = p.text.count, space = try touch("Space", in: grid)
            grid.touchesBegan([space], with: nil); try await hold()
            var clock = ProcessInfo.processInfo.systemUptime
            for _ in 0..<12 {
                clock += perFrame; space.reportedTimestamp = clock
                space.point.x -= 10; grid.touchesMoved([space], with: nil)
            }
            grid.touchesEnded([space], with: nil)
            defer { m.keyboardWillDisappear() }
            return length - p.text.count
        }
        let slow = try await travel(seconds: 0.1), fast = try await travel(seconds: 1.0 / 120)
        XCTAssertEqual(slow, 15) // 120 points at 8 points each
        // A 100 ms flick at 1200 points per second: faster than slow, but ramping from sustained
        // speed, not one frame, so it does not teleport (Nov 8: 35+ felt like jumps on device).
        XCTAssertGreaterThanOrEqual(fast, 20)
        XCTAssertLessThanOrEqual(fast, 30)
    }
    func testFastTypingWithSloppySpaceTapsTypesEverySpace() throws {
        let (p, m, grid) = setupGrid()
        p.text = ""
        let x = try touch("x", in: grid), space = try touch("Space", in: grid)
        let home = space.point
        for i in 0..<25 {
            grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
            space.point = home
            grid.touchesBegan([space], with: nil)
            space.point.x += i.isMultiple(of: 2) ? 7 : -7; space.point.y += 4 // thumbs drift
            grid.touchesMoved([space], with: nil); grid.touchesEnded([space], with: nil)
        }
        XCTAssertEqual(p.text, String(repeating: "x ", count: 25))
        m.keyboardWillDisappear()
    }
    func testRolloverFromSpaceIntoLetterTypesBothInOrder() throws {
        let (p, m, grid) = setupGrid()
        p.text = ""
        let x = try touch("x", in: grid), space = try touch("Space", in: grid)
        for _ in 0..<15 {
            grid.touchesBegan([x], with: nil)
            grid.touchesBegan([space], with: nil) // next finger lands before the first lifts
            grid.touchesEnded([x], with: nil)
            grid.touchesEnded([space], with: nil)
        }
        XCTAssertEqual(p.text, String(repeating: "x ", count: 15))
        m.keyboardWillDisappear()
    }
    func testHoldActivatesAfterTrailingSpaceAndOutsideChanges() async throws {
        // Typing "word " then holding space to go back must work; a host echo of that space
        // arriving during the hold used to refuse activation and type a space on release.
        for variant in 0..<3 {
            let (p, m, grid) = setupGrid()
            p.text = ["word ", String(repeating: "word ", count: 20), "abcdef"][variant]
            let original = p.text, space = try touch("Space", in: grid)
            grid.touchesBegan([space], with: nil)
            if variant == 2 { p.text = "abcdefg"; m.hostTextDidChange() } // echo lands mid-hold
            try await hold()
            space.point.x -= 16; grid.touchesMoved([space], with: nil); grid.touchesEnded([space], with: nil)
            let expected = variant == 2 ? "abcdefg" : original
            XCTAssertEqual(p.text + p.tail, expected, "variant \(variant): no space typed")
            XCTAssertEqual(p.tail.count, 2, "variant \(variant): moved two characters")
            m.keyboardWillDisappear()
        }
    }
    // MARK: A real thumb: 120 touches a second, each a fraction of a point off

    /// iOS reports a moving finger a fraction of a point backward every few samples.
    private static let wobble: [CGFloat] = [0, 0.6, -0.4, 0.3, -0.7, 0.5, -0.2]

    /// Moves a held touch along `path` (0 to 1) for `seconds` at 120 Hz, with wobble on both axes.
    private func drag(_ touch: Touch, in grid: KeyGridView, seconds: Double, clock: inout TimeInterval,
                      path: (CGFloat) -> CGPoint) {
        let frames = max(1, Int(seconds * 120))
        for i in 1...frames {
            clock += 1.0 / 120
            touch.reportedTimestamp = clock
            let point = path(CGFloat(i) / CGFloat(frames))
            touch.point = CGPoint(x: point.x + Self.wobble[i % 7], y: point.y + Self.wobble[(i + 3) % 7])
            grid.touchesMoved([touch], with: nil)
        }
    }
    private func line(from start: CGPoint, dx: CGFloat, dy: CGFloat) -> (CGFloat) -> CGPoint {
        { CGPoint(x: start.x + dx * $0, y: start.y + dy * $0) }
    }

    func testSlowWobblyScrubMovesEveryCharacterBothWays() async throws {
        // What "choppy" was: one sample a fraction of a point backward threw away the travel
        // banked toward the next character, so a slow, careful drag kept stalling.
        let (p, m, grid) = setupGrid()
        p.text = String(repeating: "word ", count: 40)
        let length = p.text.count, space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        var clock = ProcessInfo.processInfo.systemUptime
        let home = space.point
        drag(space, in: grid, seconds: 2, clock: &clock, path: line(from: home, dx: -120, dy: 0)) // 60 points a second
        XCTAssertEqual(Double(length - p.text.count), 15, accuracy: 1)
        drag(space, in: grid, seconds: 2, clock: &clock, path: line(from: CGPoint(x: home.x - 120, y: home.y), dx: 120, dy: 0))
        XCTAssertEqual(Double(length - p.text.count), 0, accuracy: 1)
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text + p.tail, String(repeating: "word ", count: 40))
        m.keyboardWillDisappear()
    }

    func testDiagonalDragMovesLinesAndCharactersTogether() async throws {
        let (p, m, grid) = setupGrid()
        p.text = "one two three four\nfive six seven eight\nnine ten"
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        var clock = ProcessInfo.processInfo.systemUptime
        // 50 points left and 50 up in one stroke: six characters back, two lines up.
        drag(space, in: grid, seconds: 0.5, clock: &clock, path: line(from: space.point, dx: -50, dy: -50))
        XCTAssertEqual(p.text, "on")
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text + p.tail, "one two three four\nfive six seven eight\nnine ten")
        m.keyboardWillDisappear()
    }

    func testLinesFollowTheFingerUpAndDownAgainAndAgain() async throws {
        for lagging in [false, true] {
            let (p, m, grid) = setupGrid()
            p.text = "first line here\nsecond line here\nthird line here"; p.lagsContext = lagging
            let space = try touch("Space", in: grid)
            grid.touchesBegan([space], with: nil); try await hold()
            var clock = ProcessInfo.processInfo.systemUptime
            var at = space.point
            // Up two lines (24 points for the first, 20 for the next), then down and up again
            // without lifting: coming back costs 20 points a line, not the first-line travel.
            drag(space, in: grid, seconds: 0.4, clock: &clock, path: line(from: at, dx: 0, dy: -50)); at.y -= 50
            XCTAssertEqual(p.text, "first line here", "lagging \(lagging)")
            for round in 0..<5 {
                drag(space, in: grid, seconds: 0.4, clock: &clock, path: line(from: at, dx: 0, dy: 46)); at.y += 46
                if lagging { try await Task.sleep(for: .milliseconds(2)); m.hostSelectionDidChange() }
                XCTAssertEqual(p.text, "first line here\nsecond line here\nthird line here", "round \(round), lagging \(lagging)")
                drag(space, in: grid, seconds: 0.4, clock: &clock, path: line(from: at, dx: 0, dy: -46)); at.y -= 46
                if lagging { try await Task.sleep(for: .milliseconds(2)); m.hostSelectionDidChange() }
                XCTAssertEqual(p.text, "first line here", "round \(round), lagging \(lagging)")
            }
            grid.touchesEnded([space], with: nil)
            m.keyboardWillDisappear()
        }
    }

    func testFastScrubsAlongAThumbsArcNeverChangeLines() async throws {
        let (p, m, grid) = setupGrid()
        let row = String(repeating: "abcdefghi ", count: 6)
        p.text = row + "\n" + String(row.prefix(30)); p.tail = String(row.dropFirst(30)) + "\n" + row
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        var clock = ProcessInfo.processInfo.systemUptime
        let home = space.point
        // 160 points there and back in a quarter of a second each way, rising 25 points at the
        // far end as the thumb pivots, six times over.
        for _ in 0..<6 {
            drag(space, in: grid, seconds: 0.25, clock: &clock) { CGPoint(x: home.x - 160 * $0, y: home.y - 25 * $0 * $0) }
            drag(space, in: grid, seconds: 0.25, clock: &clock) { CGPoint(x: home.x - 160 * (1 - $0), y: home.y - 25 * (1 - $0) * (1 - $0)) }
        }
        grid.touchesEnded([space], with: nil)
        let before = p.text
        XCTAssertTrue(before.hasPrefix(row + "\n") && !before.dropFirst(row.count + 1).contains("\n"),
                      "still on the middle line")
        XCTAssertEqual(Double(before.count), Double(row.count + 31), accuracy: 3, "and back where it began")
        m.keyboardWillDisappear()
    }

    func testClimbingKeepsTheColumnThroughAShortLine() async throws {
        let (p, m, grid) = setupGrid()
        p.text = "a long first line of text\nshort\nanother long line of text"
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        var clock = ProcessInfo.processInfo.systemUptime
        // Up two lines while the thumb drifts ten points sideways: the caret passes the end of
        // "short" and returns to its column, and the drift moves no characters.
        drag(space, in: grid, seconds: 0.4, clock: &clock, path: line(from: space.point, dx: -10, dy: -50))
        XCTAssertEqual(p.text, "a long first line of text")
        grid.touchesEnded([space], with: nil)
        m.keyboardWillDisappear()
    }

    func testSlidingUpAndDownChangesLinesAndArcDoesNot() async throws {
        let (p, m, grid) = setupGrid()
        p.text = "one two\nthree four\nfive six"
        let space = try touch("Space", in: grid)
        grid.touchesBegan([space], with: nil); try await hold()
        space.point.y -= 32; grid.touchesMoved([space], with: nil)
        XCTAssertEqual(p.text, "one two\nthree fo") // up one line, same column
        space.point.y -= 24; grid.touchesMoved([space], with: nil)
        XCTAssertEqual(p.text, "one two")            // and another
        // Sideways with a thumb's upward drift: no line change, and the break holds two steps.
        var clock = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2 {
            clock += 0.05; space.reportedTimestamp = clock
            space.point.x += 8; space.point.y -= 3; grid.touchesMoved([space], with: nil)
        }
        XCTAssertEqual(p.text, "one two")
        clock += 0.05; space.reportedTimestamp = clock
        space.point.x += 8; space.point.y -= 3; grid.touchesMoved([space], with: nil)
        XCTAssertEqual(p.text, "one two\n")          // the third step pushes through
        grid.touchesEnded([space], with: nil)
        XCTAssertEqual(p.text + p.tail, "one two\nthree four\nfive six")
        m.keyboardWillDisappear()
    }
}
