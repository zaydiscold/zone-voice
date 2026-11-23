// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SelectedWordCorrectionTests: XCTestCase {
    func testOnlyDeliberateSelectedReplacementLearnsCanonicalSpelling() {
        var tracker = SelectedWordCorrection()
        tracker.insert("Dahlsson", session: "field")
        XCTAssertNil(tracker.finish(before: "Dahlsson", after: "", session: "field"))
        tracker.select("Dahlson", before: "Hi ", after: " today", session: "field")
        for letter in "Dahlsson" { tracker.insert(String(letter), session: "field") }
        XCTAssertEqual(tracker.finish(before: "Hi Dahlsson", after: " today", session: "field"), "Dahlsson")
        XCTAssertFalse(tracker.isTracking)
    }
    func testUIKitWholeDraftSelectionCanHaveNilEdgeContexts() {
        var tracker = SelectedWordCorrection()
        tracker.select("Dahlson", before: nil, after: nil, session: "field", emptyContextMayBeNil: true)
        XCTAssertTrue(tracker.isTracking)
        for character in "Dahlsson" { tracker.insert(String(character), session: "field") }
        XCTAssertEqual(tracker.finish(before: "Dahlsson", after: nil, session: "field"), "Dahlsson")
    }

    func testNilSelectionEdgesStillRequireFreshExactReplacementAndField() {
        for (before, after, session) in [(nil, nil, "field"), ("Other Dahlsson", nil, "field"),
                                          ("Dahlsson", "unexpected", "field"), ("Dahlsson", nil, "other")] as [(String?, String?, String)] {
            var tracker = SelectedWordCorrection()
            tracker.select("Dahlson", before: nil, after: nil, session: "field", emptyContextMayBeNil: true)
            tracker.insert("Dahlsson", session: "field")
            XCTAssertNil(tracker.finish(before: before, after: after, session: session))
        }
        var tracker = SelectedWordCorrection()
        tracker.select("Mat", before: nil, after: "son", session: "field", emptyContextMayBeNil: true)
        XCTAssertFalse(tracker.isTracking)
    }

    func testCursorFieldOrSurroundingEditCannotTeachUnrelatedWord() {
        for (before, after, session) in [("Other Dahlsson", " today", "field"), ("Hi Dahlsson", " tomorrow", "field"), ("Hi Dahlsson", " today", "other")] {
            var t = SelectedWordCorrection()
            t.select("Dahlson", before: "Hi ", after: " today", session: "field")
            t.insert("Dahlsson", session: "field")
            XCTAssertNil(t.finish(before: before, after: after, session: session))
        }
    }
    func testUnknownContextPartialSelectionAndUnchangedWordDoNotLearn() {
        var t = SelectedWordCorrection()
        t.select("att", before: "M", after: "son", session: "field")
        XCTAssertFalse(t.isTracking)
        t.select("Dahlsson", before: nil, after: "", session: "field")
        XCTAssertFalse(t.isTracking)
        t.select("Dahlsson", before: "", after: "", session: "field")
        t.insert("Dahlsson", session: "field")
        XCTAssertNil(t.finish(before: "Dahlsson", after: "", session: "field"))
    }
    func testReplacementCanBeEditedButDeletingPastSelectionCancels() {
        var t = SelectedWordCorrection()
        t.select("Zaid", before: "", after: "", session: "field")
        t.delete(session: "field") // explicitly remove the selection
        t.insert("Zayx", session: "field")
        t.delete(session: "field")
        t.insert("d", session: "field")
        XCTAssertEqual(t.finish(before: "Zayd", after: "", session: "field"), "Zayd")
        t.select("Zaid", before: "", after: "", session: "field")
        t.delete(session: "field")
        t.delete(session: "field")
        XCTAssertFalse(t.isTracking)
    }
    func testCancelledSelectionCannotTeachLaterTyping() {
        var t = SelectedWordCorrection()
        t.select("Zaid", before: "", after: "", session: "field")
        t.reconcile(before: "", after: "Zaid", session: "field")
        t.insert("Zayd", session: "field")
        XCTAssertNil(t.finish(before: "Zayd", after: "", session: "field"))
    }
    func testReconcileAbandonsExternalCursorOrTextChange() {
        var t = SelectedWordCorrection()
        t.select("Zaid", before: "Hi ", after: "!", session: "field")
        t.insert("Zayd", session: "field")
        t.reconcile(before: "Hi Zayd", after: "!", session: "field")
        XCTAssertTrue(t.isTracking)
        t.reconcile(before: "Hi Za", after: "yd!", session: "field")
        XCTAssertFalse(t.isTracking)
    }
}
