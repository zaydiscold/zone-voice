// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SpacebarCursorTests: XCTestCase {
    func testHoldDoesNotMoveAndSmallJitterDoesNotAccumulate() {
        var g = SpacebarCursorGesture(x: 100, y: 100)
        XCTAssertEqual(g.move(x: 104, y: 102), 0)
        XCTAssertTrue(g.activate())
        XCTAssertEqual(g.move(x: 111, y: 103), 0)
        XCTAssertEqual(g.move(x: 112, y: 103), 1)
        XCTAssertFalse(g.activate())
    }
    func testPreHoldVerticalTravelPermanentlyDisarmsEvenIfFingerReturns() {
        var g = SpacebarCursorGesture(x: 100, y: 100)
        XCTAssertEqual(g.move(x: 102, y: 88), 0)
        XCTAssertEqual(g.move(x: 100, y: 100), 0)
        XCTAssertFalse(g.activate())
        XCTAssertEqual(g.move(x: 140, y: 100), 0)
        XCTAssertFalse(g.isActive)
    }
    func testHorizontalSlideActivatesWithoutHoldAndStartsFromThere() {
        var g = SpacebarCursorGesture(x: 100, y: 100)
        XCTAssertEqual(g.move(x: 90, y: 102), 0)
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(g.move(x: 84, y: 103), 0) // 16 points: activates, travel is not charged
        XCTAssertTrue(g.isActive)
        XCTAssertEqual(g.move(x: 76, y: 103), -1)
        XCTAssertFalse(g.activate())
    }
    func testDiagonalSlideNeitherActivatesNorDisarms() {
        var g = SpacebarCursorGesture(x: 100, y: 100)
        XCTAssertEqual(g.move(x: 112, y: 106), 0)
        XCTAssertFalse(g.isActive)
        XCTAssertTrue(g.activate())
    }
    func testFastDragsCoverMoreCharactersThanSlowOnes() {
        func steps(pointsPerFrame: Double) -> Int {
            var g = SpacebarCursorGesture(x: 0, y: 0)
            XCTAssertTrue(g.activate())
            var total = 0, x = 0.0, t = 0.0
            _ = g.move(x: 0, y: 0, time: 0)
            while x < 240 { x += pointsPerFrame; t += 1.0 / 120; total += g.move(x: x, y: 0, time: t) }
            return total
        }
        XCTAssertEqual(steps(pointsPerFrame: 0.5), 30) // 60 points per second: 8 points each
        XCTAssertGreaterThan(steps(pointsPerFrame: 12), 45) // 1440 points per second
    }
    func testDirectionReversalAndLargeJumpsAreBounded() {
        var g = SpacebarCursorGesture(x: 0, y: 0)
        XCTAssertTrue(g.activate())
        XCTAssertEqual(g.move(x: 23, y: 0), 2)
        XCTAssertEqual(g.move(x: 15, y: 0), -1)
        // A wild jump moves at most one event's worth and does not keep moving afterwards.
        XCTAssertEqual(g.move(x: -10000, y: 0), -SpacebarCursorGesture.maximumStepsPerEvent)
        XCTAssertEqual(g.move(x: -10000, y: 0), 0)
        XCTAssertEqual(g.move(x: -9992, y: 0), 1)
        XCTAssertEqual(g.move(x: .nan, y: 0), 0)
    }
    func testUnicodeOffsetsPreserveGraphemeClustersInBothDirections() {
        for glyph in ["👍", "👩🏽‍🎓", "🇺🇸", "e\u{301}", "👨‍👩‍👧‍👦", "\r\n", "क्‍ष"] {
            XCTAssertEqual(CursorTextOffset.utf16(steps: -1, before: "a" + glyph, after: nil), -glyph.utf16.count)
            XCTAssertEqual(CursorTextOffset.utf16(steps: 1, before: nil, after: glyph + "z"), glyph.utf16.count)
            XCTAssertEqual(CursorTextOffset.utf16(steps: -2, before: "a" + glyph, after: nil), -1 - glyph.utf16.count)
        }
    }
    func testEdgesUnknownContextAndExtremeStepCounts() {
        XCTAssertEqual(CursorTextOffset.utf16(steps: -4, before: "ab", after: "xyz"), -2)
        XCTAssertEqual(CursorTextOffset.utf16(steps: 4, before: "ab", after: "xyz"), 3)
        XCTAssertEqual(CursorTextOffset.utf16(steps: -1, before: nil, after: "x"), 0)
        XCTAssertEqual(CursorTextOffset.utf16(steps: 1, before: "x", after: ""), 0)
        XCTAssertEqual(CursorTextOffset.utf16(steps: Int.min, before: "abc", after: nil), -3)
        XCTAssertEqual(CursorTextOffset.utf16(steps: Int.max, before: nil, after: "abc"), 3)
    }

    // MARK: Smoothness

    func testOneJerkySampleDoesNotFlingTheCaret() {
        var g = SpacebarCursorGesture(x: 0, y: 0)
        XCTAssertTrue(g.activate())
        var x = 0.0, t = 0.0
        _ = g.move(x: 0, y: 0, time: 0)
        for _ in 0..<10 { x += 1; t += 1.0 / 120; _ = g.move(x: x, y: 0, time: t) } // slow
        // One 40-point jump in a single frame, then slow again.
        x += 40; t += 1.0 / 120
        let jump = g.move(x: x, y: 0, time: t)
        XCTAssertEqual(jump, 5, "a lone spike moves at the precise rate (40 / 8)")
    }

    func testPerEventStepsNeverExceedTheCap() {
        var g = SpacebarCursorGesture(x: 0, y: 0)
        XCTAssertTrue(g.activate())
        var x = 0.0, t = 0.0
        _ = g.move(x: 0, y: 0, time: 0)
        for _ in 0..<60 {
            x -= 30; t += 1.0 / 120
            XCTAssertLessThanOrEqual(abs(g.move(x: x, y: 0, time: t)), SpacebarCursorGesture.maximumStepsPerEvent)
        }
    }

    // MARK: Real touches are noisy

    /// A thumb's samples wobble: iOS reports a fraction of a point backward every few samples
    /// even while the finger travels one way. These offsets repeat every seven samples.
    private static let wobble = [0.0, 0.6, -0.4, 0.3, -0.7, 0.5, -0.2]

    func testSlowNoisyDragLosesNoTravel() {
        var g = SpacebarCursorGesture(x: 300, y: 300)
        XCTAssertTrue(g.activate())
        var steps = 0, t = 0.0
        _ = g.move(x: 300, y: 300, time: 0)
        // 60 points a second at 120 Hz for four seconds: 240 points, 30 characters.
        for i in 0..<480 {
            t += 1.0 / 120
            steps += g.move(x: 300 - 0.5 * Double(i + 1) + Self.wobble[i % 7], y: 300, time: t)
        }
        XCTAssertEqual(Double(steps), -30, accuracy: 1)
    }

    func testSlowNoisySlideUpStillChangesLines() {
        var g = SpacebarCursorGesture(x: 300, y: 300)
        XCTAssertTrue(g.activate())
        var lines = 0
        // 68 points up, half a point a sample, wobbling: the first line (24) and two more (20 each).
        for i in 0..<136 {
            lines += g.motion(x: 300, y: 300 - 0.5 * Double(i + 1) + Self.wobble[i % 7]).lines
        }
        XCTAssertEqual(lines, -3)
    }

    func testWobbleWhileHoldingStillMovesNothing() {
        var g = SpacebarCursorGesture(x: 300, y: 300)
        XCTAssertTrue(g.activate())
        var motion = CursorMotion()
        for i in 0..<600 {
            let m = g.motion(x: 300 + 3 * Self.wobble[i % 7], y: 300 + 3 * Self.wobble[(i + 3) % 7], time: Double(i) / 120)
            motion.steps += m.steps; motion.lines += m.lines
        }
        XCTAssertEqual(motion, CursorMotion())
    }

    func testSameSpeedCoversTheSameTextAt60And120Hertz() {
        func steps(hertz: Double) -> Int {
            var g = SpacebarCursorGesture(x: 0, y: 0)
            XCTAssertTrue(g.activate())
            var total = 0
            _ = g.move(x: 0, y: 0, time: 0)
            // Half a second at 600 points a second.
            for i in 1...Int(hertz / 2) { total += g.move(x: 600 * Double(i) / hertz, y: 0, time: Double(i) / hertz) }
            return total
        }
        XCTAssertEqual(Double(steps(hertz: 60)), Double(steps(hertz: 120)), accuracy: 2)
    }

    func testAPauseForgetsTheSpeedOfTheFlickBeforeIt() {
        var g = SpacebarCursorGesture(x: 0, y: 0)
        XCTAssertTrue(g.activate())
        var x = 0.0, t = 0.0
        _ = g.move(x: 0, y: 0, time: 0)
        for _ in 0..<30 { x += 10; t += 1.0 / 120; _ = g.move(x: x, y: 0, time: t) } // 1200 points a second
        // The finger rests (no events arrive while it is still), then nudges 16 points.
        t += 0.5
        var nudge = 0
        for _ in 0..<4 { x += 4; t += 1.0 / 120; nudge += g.move(x: x, y: 0, time: t) }
        XCTAssertEqual(nudge, 2, "a nudge after a rest moves at the precise rate")
    }

    func testSlowNoisyReversalStepsBackWithinACharacterOfTheTurn() {
        var g = SpacebarCursorGesture(x: 0, y: 300)
        XCTAssertTrue(g.activate())
        var t = 0.0, x = 0.0
        _ = g.move(x: 0, y: 300, time: 0)
        // 28 points right (three characters, half a character banked), then back at the same crawl.
        for i in 0..<56 { x += 0.5; t += 1.0 / 120; _ = g.move(x: x + Self.wobble[i % 7], y: 300, time: t) }
        var back = 0, travelled = 0.0
        while back == 0, travelled < 40 {
            x -= 0.5; travelled += 0.5; t += 1.0 / 120
            back = g.move(x: x + Self.wobble[Int(travelled * 2) % 7], y: 300, time: t)
        }
        XCTAssertEqual(back, -1)
        XCTAssertLessThanOrEqual(travelled, 10, "the banked half character is not repaid first")
    }

    func testAStalledFrameKeepsItsTravel() {
        var g = SpacebarCursorGesture(x: 0, y: 0)
        XCTAssertTrue(g.activate())
        var x = 0.0, t = 0.0, total = 0
        _ = g.move(x: 0, y: 0, time: 0)
        for _ in 0..<30 { x += 5; t += 1.0 / 60; total += g.move(x: x, y: 0, time: t) } // 300 points a second
        let before = total
        // The keyboard misses five frames, then gets their travel in one event.
        x += 25; t += 5.0 / 60; total += g.move(x: x, y: 0, time: t)
        XCTAssertEqual(total - before, 3, "25 points at this speed is three characters, not a fling")
    }

    // MARK: Up and down

    func testFirstLineNeedsDeliberateTravelThenLinesFollowTheFinger() {
        var g = SpacebarCursorGesture(x: 100, y: 200)
        XCTAssertTrue(g.activate())
        XCTAssertEqual(g.motion(x: 100, y: 180), CursorMotion()) // 20 points: not yet
        XCTAssertEqual(g.motion(x: 100, y: 176).lines, -1)       // 24 points: one line up
        XCTAssertEqual(g.motion(x: 100, y: 162).lines, 0)
        XCTAssertEqual(g.motion(x: 100, y: 156).lines, -1)       // 20 points a line after that
        XCTAssertEqual(g.motion(x: 100, y: 136).lines, -1)
        // Coming back down returns line by line, without starting over.
        XCTAssertEqual(g.motion(x: 100, y: 150).lines, 0)
        XCTAssertEqual(g.motion(x: 100, y: 156).lines, 1)
        XCTAssertEqual(g.motion(x: 100, y: 176).lines, 1)
        XCTAssertEqual(g.motion(x: 100, y: 240).lines, 3)
    }

    func testDiagonalMovesAlongAndAcrossLinesTogether() {
        var g = SpacebarCursorGesture(x: 200, y: 300)
        XCTAssertTrue(g.activate())
        var motion = CursorMotion()
        // 64 points left and 64 up, as one stroke.
        for i in 1...32 {
            let m = g.motion(x: 200 - Double(i) * 2, y: 300 - Double(i) * 2)
            motion.steps += m.steps; motion.lines += m.lines
        }
        XCTAssertEqual(motion, CursorMotion(steps: -8, lines: -3))
    }

    func testClimbingWithTheLaneOpenKeepsTheColumn() {
        var g = SpacebarCursorGesture(x: 200, y: 300)
        XCTAssertTrue(g.activate())
        var motion = CursorMotion()
        // 70 points up while the thumb drifts 14 points sideways: lines, and no characters.
        for i in 1...70 {
            let m = g.motion(x: 200 - Double(i) * 0.2, y: 300 - Double(i))
            motion.steps += m.steps; motion.lines += m.lines
        }
        XCTAssertEqual(motion, CursorMotion(steps: 0, lines: -3))
        // Before the lane opens the same drift is ordinary sideways travel.
        var h = SpacebarCursorGesture(x: 200, y: 300)
        XCTAssertTrue(h.activate())
        var steps = 0
        for i in 1...20 { steps += h.motion(x: 200 - Double(i) * 0.8, y: 300 - Double(i)).steps }
        XCTAssertEqual(steps, -2)
    }

    func testAWildVerticalJumpIsBoundedAndDoesNotKeepMoving() {
        var g = SpacebarCursorGesture(x: 200, y: 300)
        XCTAssertTrue(g.activate())
        XCTAssertEqual(g.motion(x: 200, y: -5000).lines, -SpacebarCursorGesture.maximumLinesPerEvent)
        XCTAssertEqual(g.motion(x: 200, y: -5000).lines, 0)
        XCTAssertEqual(g.motion(x: 200, y: -4980).lines, 1)
    }

    func testThumbArcDuringHorizontalScrubNeverChangesLines() {
        for slope in [0.2, 0.3, 0.45] {
            var g = SpacebarCursorGesture(x: 200, y: 300)
            XCTAssertTrue(g.activate())
            var lines = 0, steps = 0
            // 200 points left while drifting up, as a thumb pivots, there and back.
            for i in 1...100 {
                let m = g.motion(x: 200 - Double(i) * 2, y: 300 - Double(i) * 2 * slope)
                lines += m.lines; steps += m.steps
            }
            for i in (0..<100).reversed() {
                let m = g.motion(x: 200 - Double(i) * 2, y: 300 - Double(i) * 2 * slope)
                lines += m.lines; steps += m.steps
            }
            XCTAssertEqual(lines, 0, "slope \(slope)")
            XCTAssertEqual(steps, 0, "slope \(slope): back where it started")
        }
    }

    func testScrubbingSidewaysAfterALineMoveLeavesTheLane() {
        var g = SpacebarCursorGesture(x: 200, y: 300)
        XCTAssertTrue(g.activate())
        XCTAssertEqual(g.motion(x: 200, y: 274).lines, -1)
        // 80 points sideways drifting 12 up: the arc, not a second line.
        var lines = 0
        for i in 1...40 { lines += g.motion(x: 200 - Double(i) * 2, y: 274 - Double(i) * 0.3).lines }
        XCTAssertEqual(lines, 0)
        // Out of the lane, the next line again needs the deliberate first travel.
        XCTAssertEqual(g.motion(x: 120, y: 244).lines, 0)
        XCTAssertEqual(g.motion(x: 120, y: 236).lines, -1)
    }

    // MARK: Line-break detent

    func testLineBreakTakesTwoExtraStepsAndTicksOnce() {
        var d = CursorLineDetent()
        // Moving back from "ab\n|cd": the break holds for two steps, then is crossed.
        XCTAssertEqual(d.walk(-1, through: "ab\n").characters, 0)
        XCTAssertEqual(d.walk(-1, through: "ab\n").characters, 0)
        let cross = d.walk(-1, through: "ab\n")
        XCTAssertEqual(cross.characters, -1); XCTAssertEqual(cross.breaks, 1)
        XCTAssertEqual(d.walk(-2, through: "ab").characters, -2)
    }

    func testFastFlickThroughBlankLinesStopsAtEachBreak() {
        var d = CursorLineDetent()
        // Twelve steps forward from "|x\n\n\nshort": crosses x, then pays for each break.
        let walk = d.walk(12, through: "x\n\n\nshort")
        XCTAssertEqual(walk.characters, 6) // x (1 step), three breaks (3 steps each), then "sh"
        XCTAssertEqual(walk.breaks, 3)
    }

    func testDetentResetsOnReversalAndUnknownContextMovesPlainly() {
        var d = CursorLineDetent()
        XCTAssertEqual(d.walk(1, through: "\nz").characters, 0)
        XCTAssertEqual(d.walk(-1, through: "a").characters, -1)    // reversal: no stored credit
        XCTAssertEqual(d.walk(1, through: "\nz").characters, 0)
        XCTAssertEqual(d.walk(5, through: nil).characters, 5)
        XCTAssertEqual(d.walk(1, through: "\r\nz").characters, 0) // CRLF is one break
    }

    // MARK: Lines

    func testUpAndDownKeepTheColumnAcrossShortAndBlankLines() {
        // "first line|" "" "ab" "third line": caret after "first li" (column 8).
        let text = "first line\n\nab\nthird line"
        let caret = 8
        func go(_ lines: Int, from offset: Int, goal: Int? = nil) -> (Int, Int) {
            let chars = Array(text)
            let r = CursorLines.travel(lines: lines, goalColumn: goal, before: String(chars[..<offset]),
                                       after: String(chars[offset...]), wrapWidth: 40)
            return (offset + r.characters, r.goalColumn)
        }
        let (blank, goal) = go(1, from: caret)
        XCTAssertEqual(blank, 11) // the empty line
        XCTAssertEqual(goal, 8)
        let (short, _) = go(1, from: blank, goal: goal)
        XCTAssertEqual(short, 14) // end of "ab"
        let (third, _) = go(1, from: short, goal: goal)
        XCTAssertEqual(third, 23) // "third li|ne": column 8 again
        XCTAssertEqual(go(3, from: caret).0, 23) // three at once
        XCTAssertEqual(go(-3, from: 23, goal: 8).0, 8) // and back
    }

    func testDocumentEdgesGoToStartAndEnd() {
        XCTAssertEqual(CursorLines.travel(lines: -1, goalColumn: nil, before: "abc", after: "def", wrapWidth: 40).characters, -3)
        XCTAssertEqual(CursorLines.travel(lines: 1, goalColumn: nil, before: "abc", after: "def", wrapWidth: 40).characters, 3)
        XCTAssertEqual(CursorLines.travel(lines: -1, goalColumn: nil, before: nil, after: nil, wrapWidth: 40).characters, 0)
    }

    func testWrappedParagraphMovesByEstimatedLineWidth() {
        let paragraph = String(repeating: "abcdefghij", count: 10) // 100 characters, width 40
        let at = 55 // second visual line, column 15
        let chars = Array(paragraph)
        let up = CursorLines.travel(lines: -1, goalColumn: nil, before: String(chars[..<at]),
                                    after: String(chars[at...]), wrapWidth: 40)
        XCTAssertEqual(at + up.characters, 15)
        let down = CursorLines.travel(lines: 1, goalColumn: nil, before: String(chars[..<at]),
                                      after: String(chars[at...]), wrapWidth: 40)
        XCTAssertEqual(at + down.characters, 95)
    }

    func testEmojiCountAsOneColumn() {
        let r = CursorLines.travel(lines: -1, goalColumn: nil, before: "a👩🏽‍🎓b\nxy👍", after: "", wrapWidth: 40)
        XCTAssertEqual(r.goalColumn, 3)
        XCTAssertEqual(r.characters, -4) // to the end of "a👩🏽‍🎓b": 3 back + break
    }

    // MARK: Paragraph-limited context (real UIKit)

    func testHiddenPreviousParagraphHopsThenPlacesColumn() {
        // Real UIKit shows "five six|" only. Up hops across the break...
        XCTAssertEqual(CursorLines.step(-1, goalColumn: 8, before: "five six", after: nil, wrapWidth: 40), .hop(-9))
        // ...then sees "three four|" (+ "\n" after) and moves back to column 8.
        XCTAssertEqual(CursorLines.columnFix(-1, goalColumn: 8, before: "three four", after: "\nfive six", wrapWidth: 40), -2)
        // UITextView cuts the after-text at the break too: the fix needs only the before-text.
        XCTAssertEqual(CursorLines.columnFix(-1, goalColumn: 8, before: "three four", after: "", wrapWidth: 40), -2)
    }

    func testHiddenNextParagraphHopsThenPlacesColumn() {
        XCTAssertEqual(CursorLines.step(1, goalColumn: 3, before: "one", after: " two", wrapWidth: 40), .hop(5))
        XCTAssertEqual(CursorLines.columnFix(1, goalColumn: 3, before: "one two\n", after: "ab", wrapWidth: 40), 2)
        XCTAssertEqual(CursorLines.columnFix(1, goalColumn: 3, before: "one two\n", after: "abcdef", wrapWidth: 40), 3)
    }

    func testHopIntoWrappedPreviousParagraphLandsOnItsLastLine() {
        // A 90-character previous paragraph at width 40: its last line starts at 80.
        let previous = String(repeating: "x", count: 90)
        XCTAssertEqual(CursorLines.columnFix(-1, goalColumn: 5, before: previous, after: "\nnow", wrapWidth: 40), -5)
    }

    func testEstimatedWrapWidth() {
        XCTAssertEqual(CursorLines.estimatedWrapWidth(points: 402), 47)
        XCTAssertEqual(CursorLines.estimatedWrapWidth(points: 0), 40)
        XCTAssertEqual(CursorLines.estimatedWrapWidth(points: 100), 20)
    }
}
