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
}
