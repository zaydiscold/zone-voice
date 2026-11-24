// by zayd/cold @ zayd.wtf

import XCTest
@testable import Zone

/// The island updates once a second while recording. The widget file, and the widget and control
/// reloads that follow each write, are for changes and a slow refresh, not for every update.
final class WidgetPublishTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func recording(at offset: TimeInterval, note: Bool = false, freshUntil: Date? = nil) -> CarWidgetState {
        CarWidgetState(phase: .recording, noteMode: note, startedAt: start, updatedAt: start.addingTimeInterval(offset), freshUntil: freshUntil)
    }

    private func idle(at offset: TimeInterval) -> CarWidgetState {
        CarWidgetState(phase: .idle, noteMode: false, startedAt: nil, updatedAt: start.addingTimeInterval(offset))
    }

    func testTheFirstStateOfAProcessIsAlwaysWritten() {
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: nil, next: idle(at: 0)))
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: nil, next: recording(at: 0)))
    }

    func testAnHourOfRecordingWritesOncePerRefreshNotOncePerSecond() {
        var last = recording(at: 0)
        var writes = 1
        for second in 1...3600 {
            let next = recording(at: TimeInterval(second))
            if RecordingLiveActivity.widgetNeedsPublish(last: last, next: next) {
                writes += 1
                XCTAssertLessThan(next.updatedAt.timeIntervalSince(last.updatedAt), CarWidgetState.staleAfter,
                                  "The widget calls a recording dead after staleAfter with no refresh")
                last = next
            }
        }
        XCTAssertEqual(writes, 361)
    }

    func testStandbyHeartbeatsNeverRewriteAnIdleWidget() {
        let last = idle(at: 0)
        for beat in stride(from: 10.0, through: 36_000, by: 10) {
            XCTAssertFalse(RecordingLiveActivity.widgetNeedsPublish(last: last, next: idle(at: beat)))
        }
    }

    func testEveryChangeThePersonCanSeeIsWrittenAtOnce() {
        let last = recording(at: 0)
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: last, next: idle(at: 1)), "stopped")
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: idle(at: 0), next: recording(at: 1)), "started")
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: last, next: recording(at: 1, note: true)), "became a note")
        var processing = recording(at: 1)
        processing.phase = .processing
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: last, next: processing), "recognizing")
        let held = recording(at: 1, freshUntil: start.addingTimeInterval(600))
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: last, next: held), "held by an interruption")
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: held, next: recording(at: 2)), "hold released")
        var restarted = recording(at: 1)
        restarted.startedAt = start.addingTimeInterval(1)
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: last, next: restarted), "a new recording")
        var keyboard = recording(at: 1)
        keyboard.controlOwned = false
        XCTAssertTrue(RecordingLiveActivity.widgetNeedsPublish(last: last, next: keyboard), "became busy, not owned")
    }

    // MARK: What each control shows

    private func shows(_ state: CarWidgetState, note: Bool, at offset: TimeInterval = 1) -> CarWidgetState.ControlShows {
        state.controlShows(noteMode: note, now: start.addingTimeInterval(offset))
    }

    func testAControlStopsOnlyItsOwnRecording() {
        let note = recording(at: 0, note: true)
        XCTAssertEqual(shows(note, note: true), .recording)
        XCTAssertEqual(shows(note, note: false), .busy(note: true, saving: false), "Dictate and copy during a note")
        let dictation = recording(at: 0)
        XCTAssertEqual(shows(dictation, note: false), .recording)
        XCTAssertEqual(shows(dictation, note: true), .busy(note: false, saving: false), "Voice note during Dictate and copy")
    }

    /// November 23 handoff: a keyboard or in-app recording left both controls at Off, so a press
    /// promised a start and got a refusal.
    func testARecordingNoControlStartedIsBusyOnBoth() {
        var keyboard = recording(at: 0)
        keyboard.controlOwned = false
        XCTAssertEqual(shows(keyboard, note: false), .busy(note: false, saving: false))
        XCTAssertEqual(shows(keyboard, note: true), .busy(note: false, saving: false))
        keyboard.phase = .processing
        XCTAssertEqual(shows(keyboard, note: false), .busy(note: false, saving: true))
    }

    func testBusyIsNeverDrawnAsAStop() {
        for shows: CarWidgetState.ControlShows in [.busy(note: true, saving: false), .busy(note: false, saving: false),
                                                    .busy(note: false, saving: true), .saving, .off] {
            XCTAssertNotEqual(shows.glyph(off: "mic.fill"), "stop.fill", "\(shows)")
            XCTAssertNotEqual(shows.title(off: "Off"), "Recording", "\(shows)")
        }
        XCTAssertEqual(CarWidgetState.ControlShows.recording.glyph(off: "mic.fill"), "stop.fill")
        XCTAssertEqual(CarWidgetState.ControlShows.busy(note: false, saving: false).title(off: "Off"), "Dictating")
        XCTAssertEqual(CarWidgetState.ControlShows.busy(note: true, saving: false).title(off: "Off"), "Recording note")
    }

    func testOwnProcessingIsSavingAndADeadZoneIsOff() {
        var processing = recording(at: 0, note: true)
        processing.phase = .processing
        XCTAssertEqual(shows(processing, note: true), .saving)
        XCTAssertEqual(shows(recording(at: 0, note: true), note: true, at: CarWidgetState.staleAfter), .off,
                       "no refresh for staleAfter: Zone stopped")
        XCTAssertEqual(shows(idle(at: 0), note: true), .off)
        let held = recording(at: 0, note: true, freshUntil: start.addingTimeInterval(600))
        XCTAssertEqual(shows(held, note: true, at: 300), .recording, "an interruption's hold outlives the limit")
    }

    /// The file a build before this one wrote has no `controlOwned`, and only ever held a control's
    /// own recording. It must still read as that, so an update mid-recording keeps its Stop.
    func testAFileFromTheLastBuildStillReadsAsOwned() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = #"{"phase":"recording","noteMode":true,"startedAt":"2027-01-15T08:00:00Z","updatedAt":"2027-01-15T08:00:00Z"}"#
        let old = try decoder.decode(CarWidgetState.self, from: Data(json.utf8))
        XCTAssertNil(old.controlOwned)
        XCTAssertEqual(old.controlShows(noteMode: true, now: old.updatedAt.addingTimeInterval(5)), .recording)
    }

    // MARK: One liveness limit

    func testTheIslandAndTheControlsGiveUpOnADeadZoneTogether() {
        XCTAssertEqual(RecordingLiveActivity.staleAfter, CarWidgetState.staleAfter)
        XCTAssertGreaterThanOrEqual(CarWidgetState.staleAfter, 3 * RecordingLiveActivity.widgetRefresh,
                                    "two missed refreshes must not call a live Zone dead")
        XCTAssertEqual(RecordingLiveActivity.refreshInterval, RecordingLiveActivity.widgetRefresh)
    }
}
