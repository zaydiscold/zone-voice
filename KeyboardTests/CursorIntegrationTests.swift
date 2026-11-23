// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

@MainActor
final class CursorIntegrationTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    func model(_ p: Proxy) -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: false))
        return m
    }
    func testHoldAndReleaseNeverInsertAndRestoreCasingAtNewPosition() throws {
        let p = Proxy(); p.text = "hello"; p.capitalizes = true
        let m = model(p)
        let t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-5, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, ""); XCTAssertEqual(p.tail, "hello")
        XCTAssertEqual(m.shift, .on)
        m.handleTap(.character("x"))
        XCTAssertEqual(p.text + p.tail, "Xhello")
        m.keyboardWillDisappear()
    }
    func testUnicodeMovementAndBoundariesNeverChangeText() throws {
        let original = "a👩🏽‍🎓e\u{301}🇺🇸z"
        let p = Proxy(); p.text = original
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        for expected in [4, 3, 2, 1, 0, 0] {
            m.moveCursor(-1, token: t)
            XCTAssertEqual(p.text.count, expected)
            XCTAssertEqual(p.text + p.tail, original)
        }
        m.moveCursor(3, token: t)
        XCTAssertEqual(p.text, "a👩🏽‍🎓e\u{301}")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
    func testChangedFieldOrDisappearanceCannotReceiveOldDrag() throws {
        let p = Proxy(); p.text = "first"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.session = "new"; p.text = "new field"
        m.moveCursor(-2, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "new field")
        let t2 = try XCTUnwrap(m.beginCursorControl())
        m.keyboardWillDisappear()
        m.moveCursor(-2, token: t2); m.endCursorControl(t2)
        XCTAssertEqual(p.text, "new field")
    }
    func testUnknownContextStillMovesByCharacters() throws {
        // A host that hides its context must not freeze the trackpad.
        let p = Proxy(); p.text = "abc"; p.unknown = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-2, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "a"); XCTAssertEqual(p.tail, "bc")
        m.keyboardWillDisappear()
    }
    func testExternalTextChangeInSameDocumentKeepsDragMovingFromLiveCaret() throws {
        let p = Proxy(); p.text = "original"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.text = "replacement"
        m.hostTextDidChange()
        m.moveCursor(-2, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "replaceme"); XCTAssertEqual(p.tail, "nt")
        m.keyboardWillDisappear()
    }
    func testDeferredHostAdjustmentsAllLand() throws {
        let p = Proxy(); p.text = "abcdef"; p.defersCursorAdjustments = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-1, token: t); m.moveCursor(-2, token: t)
        XCTAssertEqual(p.cursorAdjustments, [-1, -2])
        p.settleCursorAdjustments(); m.hostSelectionDidChange()
        m.endCursorControl(t)
        XCTAssertEqual(p.text, "abc"); XCTAssertEqual(p.tail, "def")
        m.keyboardWillDisappear()
    }
    func testExternalSelectionChangeIsFollowedNotFought() throws {
        let p = Proxy(); p.text = "abcdef"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.adjustTextPosition(byCharacterOffset: -3)
        m.hostSelectionDidChange()
        m.moveCursor(-2, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "a"); XCTAssertEqual(p.tail, "bcdef")
        m.keyboardWillDisappear()
    }
    func testLaggingWebHostNeverFreezesAFastDrag() async throws {
        // The bug in the November 8 recording: a web view answers context reads late, the old
        // ownership check saw a mismatch, dropped the drag and left the keys blank and dead.
        let p = Proxy(); p.text = String(repeating: "word ", count: 12); p.lagsContext = true
        let length = p.text.count
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        for _ in 0..<20 { m.moveCursor(-1, token: t) }
        XCTAssertEqual(p.text.count, length - 20)
        for _ in 0..<10 {
            m.moveCursor(-1, token: t)
            try await Task.sleep(for: .milliseconds(1))
            m.hostSelectionDidChange(); m.hostTextDidChange()
        }
        XCTAssertEqual(p.text.count, length - 30)
        for _ in 0..<5 { m.moveCursor(2, token: t) }
        XCTAssertEqual(p.text.count, length - 20)
        m.endCursorControl(t)
        XCTAssertEqual(p.text + p.tail, String(repeating: "word ", count: 12))
        m.keyboardWillDisappear()
    }
    func testOwnSelectionEchoesKeepCursorGestureAlive() throws {
        let p = Proxy(); p.text = "abcdef"; p.boundaryContextIsNil = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        for expected in ["abcde", "abcd", "abc"] {
            m.moveCursor(-1, token: t)
            m.hostSelectionDidChange(); m.hostTextDidChange()
            XCTAssertEqual(p.text, expected)
        }
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
    func testSynchronousAdjustmentCallbacksKeepGestureAlive() throws {
        let p = Proxy(); p.text = "abcdef"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.onCursorAdjustment = { [weak m] in
            m?.hostSelectionDidChange(); m?.hostTextDidChange()
        }
        m.moveCursor(-2, token: t); m.moveCursor(-1, token: t)
        XCTAssertEqual(p.text, "abc"); XCTAssertEqual(p.tail, "def")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
    func testHostSelectionDuringDragIsCollapsedByMovement() throws {
        let p = Proxy(); p.text = "abc"; p.tail = "def"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.selection = "selected"
        m.hostSelectionDidChange()
        m.moveCursor(1, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "abcd"); XCTAssertNil(p.selection)
        m.keyboardWillDisappear()
    }
    func testReturningToOriginalDocumentDoesNotReviveOldDrag() throws {
        let p = Proxy(); p.text = "abcdef"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.session = "other"
        m.moveCursor(-1, token: t)
        p.session = "a"
        m.moveCursor(-1, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "abcdef"); XCTAssertEqual(p.tail, "")
        m.keyboardWillDisappear()
    }
    func testLimitedContextWindowCanShiftDuringRepeatedMovement() throws {
        let p = Proxy(); p.text = "abcdefghij"; p.contextLimit = 4
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        for expected in ["abcdefghi", "abcdefgh", "abcdefg"] {
            m.moveCursor(-1, token: t); m.hostSelectionDidChange()
            XCTAssertEqual(p.text, expected)
        }
        m.moveCursor(2, token: t)
        XCTAssertEqual(p.text, "abcdefghi"); XCTAssertEqual(p.tail, "j")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
    func testExistingSelectionCollapsesAndMoves() throws {
        let p = Proxy(); p.text = "abc"; p.tail = "def"; p.selection = "selected"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-1, token: t); m.moveCursor(2, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "abcd"); XCTAssertEqual(p.tail, "ef")
        XCTAssertNil(p.selection)
        m.keyboardWillDisappear()
    }
    func testTransientPostAdjustmentContextIsNotAdopted() async throws {
        let p = Proxy(); p.text = "a👩🏽‍🎓e\u{301}🇺🇸z"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        p.onCursorAdjustment = {
            let before = p.text, after = p.tail
            p.text = ""; p.tail = before + after
            DispatchQueue.main.async { p.text = before; p.tail = after }
        }
        for _ in 0..<3 {
            m.moveCursor(-1, token: t)
            try await Task.sleep(for: .milliseconds(20))
            m.hostSelectionDidChange()
        }
        XCTAssertEqual(p.text, "a👩🏽‍🎓"); XCTAssertEqual(p.tail, "e\u{301}🇺🇸z")
        p.onCursorAdjustment = nil
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
    func testPendingSwipeThenCursorThenTypingKeepsOrderWithoutPhantomSpace() async throws {
        let helper = SwipeIntegrationTests()
        let p = Proxy(), m = helper.prepared(p)
        m.handleSwipe(helper.path("hello"), layout: helper.layout)
        let t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-2, token: t); m.endCursorControl(t)
        m.handleTap(.character("x"))
        try await helper.waitFor { p.text.contains("x") }
        XCTAssertEqual(p.text, "helx"); XCTAssertEqual(p.tail, "lo")
        XCTAssertFalse(m.hasSwipeAlternatives)
        m.keyboardWillDisappear()
    }
    func testCursorInvalidatesOldSwipeTokenAndWholeWordDelete() async throws {
        let helper = SwipeIntegrationTests()
        let p = Proxy(), m = helper.prepared(p)
        try await helper.swipe(m, p)
        let old = m.swipeInputToken
        let t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-1, token: t)
        m.hostSelectionDidChange()
        m.endCursorControl(t)
        m.handleSwipe(helper.path("world"), layout: helper.layout, token: old)
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text + p.tail, "helo")
        XCTAssertFalse(m.hasSwipeAlternatives)
        m.keyboardWillDisappear()
    }
    func testCursorClearsDoubleSpaceAndAutocorrectOwnership() async throws {
        let p = Proxy(), m = model(p)
        m.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true))
        // Wait for asynchronous dictionary loading by observing a real correction candidate.
        for c in "helo" { m.handleTap(.character(String(c))) }
        for _ in 0..<200 {
            if !m.suggestions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(m.suggestions.isEmpty)
        let t = try XCTUnwrap(m.beginCursorControl())
        m.endCursorControl(t)
        XCTAssertTrue(m.suggestions.isEmpty)
        m.handleTap(.space)
        XCTAssertEqual(p.text, "helo ") // cursor ownership ended, no correction of old word
        let t2 = try XCTUnwrap(m.beginCursorControl())
        m.endCursorControl(t2)
        m.handleTap(.space)
        XCTAssertEqual(p.text, "helo  ") // no period across a cursor gesture
        m.keyboardWillDisappear()
    }
    func testOrdinaryDoubleSpaceStillWorks() async throws {
        let p = Proxy(), m = model(p)
        m.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true))
        for c in "hello" { m.handleTap(.character(String(c))) }
        for _ in 0..<200 {
            if !m.suggestions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(m.suggestions.isEmpty)
        m.handleTap(.space); m.handleTap(.space)
        XCTAssertEqual(p.text, "hello. ")
        m.keyboardWillDisappear()
    }
    func testUIKitTextPositionsWithComposedCharacters() throws {
        let view = UITextView()
        view.text = "a👩🏽‍🎓e\u{301}z"
        var pos = view.endOfDocument
        var before = view.text!
        for _ in 0..<4 {
            let offset = CursorTextOffset.utf16(steps: -1, before: before, after: nil)
            pos = try XCTUnwrap(view.position(from: pos, offset: offset))
            before.removeLast()
            XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: pos), before.utf16.count)
        }
    }
    // MARK: A host that reports late

    func testHostStillCatchingUpDoesNotRewindTheDrag() throws {
        // A web view reports a move late. A callback that still shows the text from before the
        // move used to replace the drag's own context, so the next step walked "two" a second
        // time: three characters too far, and straight through the line break.
        let p = Proxy(); p.text = "one\ntwo"; p.lagsContext = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-3, token: t)
        XCTAssertEqual(p.text, "one\n")
        m.hostSelectionDidChange(); m.hostTextDidChange() // the host has not caught up yet
        m.moveCursor(-2, token: t)
        XCTAssertEqual(p.text, "one\n", "held at the line break")
        m.hostSelectionDidChange()
        m.moveCursor(-1, token: t)
        XCTAssertEqual(p.text, "one", "pushed through, once")
        m.endCursorControl(t)
        XCTAssertEqual(p.text + p.tail, "one\ntwo")
        m.keyboardWillDisappear()
    }

    func testLinesKeepTheirColumnWhileTheHostCatchesUp() throws {
        let p = Proxy(); p.text = "alpha beta\ngamma delta\nepsilon"; p.lagsContext = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "alpha beta\ngamma d")
        m.hostSelectionDidChange() // still showing the caret after "epsilon"
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "alpha b")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }

    func testEveryLateReportOfAFastDragIsRecognized() throws {
        // A fast drag with the host always two moves behind: every callback shows where the
        // caret was two moves ago. The old code re-read that each time and, at the line break,
        // walked the last two letters again, carrying the caret over the break and past it.
        let p = Proxy(); p.text = "abcdefghijkl\nmnopqrstuvwx"; p.defersCursorAdjustments = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        for i in 0..<12 {
            m.moveCursor(-1, token: t)
            if i >= 2 { p.settleNextCursorAdjustment(); m.hostSelectionDidChange() }
        }
        m.moveCursor(-1, token: t); m.moveCursor(-1, token: t) // at the break: it resists
        XCTAssertEqual(p.cursorAdjustments.count, 12)
        p.settleCursorAdjustments(); m.hostSelectionDidChange()
        XCTAssertEqual(p.text, "abcdefghijkl\n")
        m.moveCursor(-1, token: t); p.settleCursorAdjustments()
        XCTAssertEqual(p.text, "abcdefghijkl", "the third push carries through")
        m.endCursorControl(t)
        XCTAssertEqual(p.text + p.tail, "abcdefghijkl\nmnopqrstuvwx")
        m.keyboardWillDisappear()
    }

    func testFieldClearedMidDragIsNoticedAndTheDragCarriesOn() throws {
        let p = Proxy(); p.text = "hello world"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-3, token: t)
        p.text = ""; p.tail = ""; m.hostTextDidChange() // Send cleared the field
        m.moveCursor(-2, token: t)
        XCTAssertEqual(p.text + p.tail, "")
        p.text = "ok then"; m.hostTextDidChange()
        m.moveCursor(-4, token: t); m.endCursorControl(t)
        XCTAssertEqual(p.text, "ok "); XCTAssertEqual(p.tail, "then")
        m.keyboardWillDisappear()
    }

    func testLineMoveAfterASidewaysDragUsesTheHostsFullerWindow() throws {
        // A host that shows only the last twelve characters before the caret. The drag's own
        // context shrinks as it walks back; a line move must not mistake its edge for the
        // start of the paragraph.
        let p = Proxy(); p.text = "aaaa bbbb cccc dddd eeee ffff gggg hhhh"; p.contextLimit = 12
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-5, token: t)
        XCTAssertEqual(p.text.count, 34)
        m.moveCursorLines(-1, wrapWidth: 10, token: t)
        XCTAssertEqual(p.text.count, 24, "one wrapped line of ten characters up")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }

    // MARK: Lines and line breaks

    func testUpAndDownLanesKeepTheColumnAcrossBlankAndShortLines() throws {
        let p = Proxy(); p.text = "first li"; p.tail = "ne\n\nab\nthird line"
        let full = p.text + p.tail
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        for expected in [11, 14, 23] {
            m.moveCursorLines(1, wrapWidth: 40, token: t)
            XCTAssertEqual(p.text.count, expected)
        }
        m.moveCursorLines(-3, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "first li")
        m.moveCursor(1, token: t) // a sideways move forgets the column
        m.moveCursorLines(1, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text.count, 11)
        m.endCursorControl(t)
        XCTAssertEqual(p.text + p.tail, full)
        m.keyboardWillDisappear()
    }

    func testLinesThroughALaggingWebHost() async throws {
        let p = Proxy(); p.text = "alpha beta\ngamma delta\nepsilon"; p.lagsContext = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        m.moveCursorLines(-1, wrapWidth: 40, token: t) // before the host has caught up
        XCTAssertEqual(p.text, "alpha b")
        try await Task.sleep(for: .milliseconds(5)); m.hostSelectionDidChange()
        m.moveCursorLines(2, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "alpha beta\ngamma delta\nepsilon")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }

    func testDragStopsAtEachLineBreakUntilPushedThrough() throws {
        let p = Proxy(); p.text = "top\n\n\nend"
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursor(-3, token: t)
        XCTAssertEqual(p.text, "top\n\n\n")      // "end" crossed
        m.moveCursor(-2, token: t)
        XCTAssertEqual(p.text, "top\n\n\n")      // held at the break
        m.moveCursor(-1, token: t)
        XCTAssertEqual(p.text, "top\n\n")         // pushed through
        m.moveCursor(1, token: t)                   // reversal: no carried resistance
        m.moveCursor(1, token: t); m.moveCursor(1, token: t)
        XCTAssertEqual(p.text, "top\n\n\n")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }

    func testDiscreteStepsCrossLineBreaksImmediately() throws {
        let p = Proxy(); p.text = "ab\n"
        let m = model(p)
        for expected in ["ab", "a"] {
            let t = try XCTUnwrap(m.beginCursorControl())
            m.moveCursor(-1, resisting: false, token: t); m.endCursorControl(t)
            XCTAssertEqual(p.text, expected)
        }
        m.keyboardWillDisappear()
    }
    func testLinesWhenTheHostShowsOnlyTheCurrentParagraph() throws {
        let p = Proxy(); p.text = "one two\nthree four\nfive six"; p.paragraphContext = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "one two\nthree fo")
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "one two")
        m.moveCursorLines(2, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "one two\nthree four\nfive six")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }

    func testParagraphHopThroughALaggingHostFinishesOnItsCallback() async throws {
        let p = Proxy(); p.text = "one two\nthree four\nfive six"
        p.paragraphContext = true; p.lagsContext = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        XCTAssertEqual(p.text, "one two\nthree four") // hopped; the host still shows the old paragraph
        try await Task.sleep(for: .milliseconds(5))
        m.hostSelectionDidChange()                     // the host catches up: place the column
        try await Task.sleep(for: .milliseconds(5))    // on the next turn, outside the callback
        XCTAssertEqual(p.text, "one two\nthree fo")
        m.endCursorControl(t)
        XCTAssertEqual(p.text + p.tail, "one two\nthree four\nfive six")
        m.keyboardWillDisappear()
    }
    func testParagraphHopWithASilentHostFinishesByPolling() async throws {
        // UITextView: applies the move a moment later and never calls back about it.
        let p = Proxy(); p.text = "one two\nthree four\nfive six"
        p.paragraphContext = true; p.lagsContext = true
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        try await Task.sleep(for: .milliseconds(60))   // no callback at all
        XCTAssertEqual(p.text, "one two\nthree fo")
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
    func testTransientMidHopContextIsNotMistakenForArrival() async throws {
        // Real UITextView, right after hopping up from "five six|": before nil, after "five six".
        let p = Proxy(); p.text = "one two\nthree four\nfive six"; p.paragraphContext = true
        var transient = true
        p.onCursorAdjustment = {
            guard transient else { return }
            let before = p.text, after = p.tail
            p.text = "one two\nthree four\n"; p.tail = "five six"
            DispatchQueue.main.async { p.text = before; p.tail = after; transient = false }
        }
        let m = model(p), t = try XCTUnwrap(m.beginCursorControl())
        m.moveCursorLines(-1, wrapWidth: 40, token: t)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(p.text, "one two\nthree fo")
        p.onCursorAdjustment = nil
        m.endCursorControl(t); m.keyboardWillDisappear()
    }
}
