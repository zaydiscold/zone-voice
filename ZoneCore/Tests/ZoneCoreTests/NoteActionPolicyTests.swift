// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class NoteActionPolicyTests: XCTestCase {
    func testRepeatedPressStopsOnlyTheNoteRecording() {
        XCTAssertEqual(NoteActionPolicy.action(for: .idle), .start)
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingNote), .stop)
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingElsewhere), .ignore)
    }

    func testDictationAndNoteShortcutsOnlyStopTheirOwnMode() {
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingDictation, noteMode: false), .stop)
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingNote, noteMode: false), .ignore)
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingDictation, noteMode: true), .ignore)
        XCTAssertEqual(NoteActionPolicy.action(for: .starting, noteMode: false), .stopWhenStarted)
        XCTAssertEqual(NoteActionPolicy.action(for: .transcribing, noteMode: false), .ignore)
    }
    func testPressesDuringPreparationAndFinalizationDoNotReplaceSpeech() {
        XCTAssertEqual(NoteActionPolicy.action(for: .transcribing), .ignore)
    }

    func testADoublePressWhileStartingStopsOnceRecording() {
        XCTAssertEqual(NoteActionPolicy.action(for: .starting, noteMode: true), .stopWhenStarted)
        XCTAssertEqual(NoteActionPolicy.action(for: .starting, noteMode: false), .stopWhenStarted)
        XCTAssertNotEqual(NoteActionPolicy.action(for: .starting), .start, "never a second recording")
    }
    func testExplicitOnAndOffAreIdempotent() {
        XCTAssertEqual(NoteActionPolicy.action(for: .idle, desiredState: true), .start)
        XCTAssertEqual(NoteActionPolicy.action(for: .idle, desiredState: false), .ignore)
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingNote, desiredState: true), .ignore)
        XCTAssertEqual(NoteActionPolicy.action(for: .recordingNote, desiredState: false), .stop)
        XCTAssertEqual(NoteActionPolicy.action(for: .starting, desiredState: true), .ignore)
        XCTAssertEqual(NoteActionPolicy.action(for: .starting, desiredState: false), .stopWhenStarted)
    }

    func testExplicitControlPreservesOtherOwnersAndRecognition() {
        for desired in [true, false] {
            XCTAssertEqual(NoteActionPolicy.action(for: .recordingElsewhere, desiredState: desired), .ignore)
            XCTAssertEqual(NoteActionPolicy.action(for: .recordingDictation, noteMode: true, desiredState: desired), .ignore)
            XCTAssertEqual(NoteActionPolicy.action(for: .recordingNote, noteMode: false, desiredState: desired), .ignore)
            XCTAssertEqual(NoteActionPolicy.action(for: .transcribing, desiredState: desired), .ignore)
        }
    }

    /// Zayd's phone, 2026-11-20: a note ended outside its control, and the Action Button, still showing
    /// On, sent Off two seconds later. That press did nothing.
    func testAnOffPressAfterARecordingEndedByItselfStarts() {
        XCTAssertTrue(NoteActionPolicy.offPressStarts(state: .idle, noteMode: true, endedByItself: (true, 2)))
        // Still recognizing the note that ended: the press waits for it, then starts.
        XCTAssertTrue(NoteActionPolicy.offPressStarts(state: .transcribing, noteMode: true, endedByItself: (true, 0.5)))
        XCTAssertTrue(NoteActionPolicy.offPressStarts(state: .idle, noteMode: false, endedByItself: (false, 60)))
    }

    func testAnOffPressWithNothingEndedByItselfStaysANoOp() {
        XCTAssertFalse(NoteActionPolicy.offPressStarts(state: .idle, noteMode: true, endedByItself: nil))
        // The other control's recording ended: this control was never showing On.
        XCTAssertFalse(NoteActionPolicy.offPressStarts(state: .idle, noteMode: true, endedByItself: (false, 2)))
        // Long ago: iOS has redrawn the control since, so Off means off.
        XCTAssertFalse(NoteActionPolicy.offPressStarts(state: .idle, noteMode: true,
                                                       endedByItself: (true, NoteActionPolicy.staleControlWindow + 1)))
        XCTAssertFalse(NoteActionPolicy.offPressStarts(state: .idle, noteMode: true, endedByItself: (true, -5)))
    }

    func testAnOffPressWhileRecordingOrStartingIsNeverTurnedIntoAStart() {
        for state in [NoteActionPolicy.State.starting, .recordingNote, .recordingDictation, .recordingElsewhere] {
            XCTAssertFalse(NoteActionPolicy.offPressStarts(state: state, noteMode: true, endedByItself: (true, 2)), "\(state)")
        }
    }
}
