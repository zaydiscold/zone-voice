// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SetupSessionTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let size: Int64 = 253_000_000

    func testKeyboardMustHaveAppearedDuringThisCheck() {
        let record = KeyboardPresence(lastSeen: start, hasFullAccess: true)
        XCTAssertNil(record.seenDuringSetup(since: start.addingTimeInterval(1)))
        XCTAssertNil(record.seenDuringSetup(since: start, now: start.addingTimeInterval(-1)))
        XCTAssertEqual(record.seenDuringSetup(since: start, now: start), record)
    }

    func testOnlyANewRecordingFromTheIntentCounts() {
        let id = UUID()
        XCTAssertNil(SetupFacts.setupRecordingID(id, isNote: true, fromIntent: false))
        XCTAssertNil(SetupFacts.setupRecordingID(id, isNote: false, fromIntent: true))
        XCTAssertEqual(SetupFacts.setupRecordingID(id, isNote: true, fromIntent: true), id)
    }

    private func fresh() -> SetupFacts {
        SetupFacts(model: .missing, modelBytes: size, microphone: .undetermined, keyboardAdded: false, fullAccess: nil)
    }

    private func ids(_ session: SetupSession) -> [String] { session.lines.map(\.id) }

    func testAFreshPhoneAsksOneThingAtATimeAndPrintsOnlyWhatHappened() {
        var session = SetupSession()
        var facts = fresh()
        XCTAssertEqual(session.remaining, 5)
        session.observe(facts, at: start)
        XCTAssertEqual(session.prompt, .downloadModel)
        XCTAssertTrue(session.lines.isEmpty, "nothing is done yet, so nothing is printed")
        XCTAssertEqual(session.remaining, 5)

        session.answer(.download, at: start)
        facts.model = .downloading(fraction: 0)
        session.observe(facts, at: start.addingTimeInterval(1))
        // The download runs while the rest is asked.
        XCTAssertEqual(session.prompt, .microphone)
        XCTAssertEqual(session.live?.id, "live.download")

        facts.microphone = .granted
        session.observe(facts, at: start.addingTimeInterval(4))
        XCTAssertEqual(session.prompt, .addKeyboard)

        facts.keyboardAdded = true
        session.observe(facts, at: start.addingTimeInterval(20))
        XCTAssertEqual(session.prompt, .switchToKeyboard)

        facts.fullAccess = true
        session.observe(facts, at: start.addingTimeInterval(26))
        XCTAssertEqual(session.prompt, .waitForModel, "the model is still on its way")

        facts.model = .loading
        session.observe(facts, at: start.addingTimeInterval(30))
        XCTAssertEqual(session.live?.id, "live.loading")
        facts.model = .ready
        session.observe(facts, at: start.addingTimeInterval(31))
        XCTAssertEqual(session.prompt, .dictate)
        XCTAssertNil(session.live)

        facts.recording = .listening("")
        session.observe(facts, at: start.addingTimeInterval(33))
        XCTAssertEqual(session.live?.detail, "Say a sentence, then tap Stop (■)")
        facts.recording = .listening("Running ten")
        session.observe(facts, at: start.addingTimeInterval(34))
        XCTAssertEqual(session.live?.detail, "Running ten")
        facts.recording = .recognizing
        session.observe(facts, at: start.addingTimeInterval(36))
        XCTAssertEqual(session.live?.text, "Writing it down")
        facts.recording = .idle
        facts.firstDictation = "Running ten minutes late"
        session.observe(facts, at: start.addingTimeInterval(37))
        XCTAssertEqual(session.prompt, .actionButton)

        XCTAssertEqual(session.remaining, 1)
        session.answer(.skipActionButton, at: start.addingTimeInterval(39))
        XCTAssertEqual(session.prompt, .finish)
        XCTAssertEqual(session.remaining, 0)
        session.finish(at: start.addingTimeInterval(40))

        XCTAssertEqual(ids(session), [
            "microphone.done", "keyboard.added", "keyboard.fullAccess", "model.done",
            "said", "dictation.done", "button.skipped", "finished",
        ])
        XCTAssertEqual(session.lines.first { $0.id == "model.done" }?.text, "Speech model downloaded")
        XCTAssertEqual(session.lines.first { $0.id == "model.done" }?.detail, "253 MB in 30 s")
        XCTAssertEqual(session.lines.first { $0.id == "dictation.done" }?.detail, "4 words")
        XCTAssertEqual(session.lines.last?.detail, "Set up in 40 s")
        XCTAssertTrue(session.isFinished)
    }

    func testComingBackWithStepsDoneSaysSoOnceAndAsksForWhatIsLeft() {
        var session = SetupSession()
        let facts = SetupFacts(model: .ready, modelBytes: size, microphone: .granted, keyboardAdded: true, fullAccess: true)
        session.observe(facts, at: start)
        session.observe(facts, at: start.addingTimeInterval(2))
        session.observe(facts, at: start.addingTimeInterval(4))
        XCTAssertEqual(ids(session), ["model.done", "microphone.done", "keyboard.added", "keyboard.fullAccess"])
        XCTAssertEqual(session.lines.first?.text, "Speech model is on this iPhone")
        XCTAssertEqual(session.prompt, .dictate)
    }

    func testAModelThatIsLoadingAtLaunchIsNotCalledADownload() {
        var session = SetupSession()
        var facts = SetupFacts(model: .loading, modelBytes: size, microphone: .granted, keyboardAdded: false, fullAccess: nil)
        session.observe(facts, at: start)
        XCTAssertEqual(session.live?.text, "Getting the speech model ready")
        facts.model = .ready
        session.observe(facts, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.lines.first { $0.id == "model.done" }?.text, "Speech model is on this iPhone")
    }

    func testABuiltInModelNeedsNoDownloadLine() {
        var session = SetupSession()
        let facts = SetupFacts(model: .ready, modelBytes: 0, microphone: .granted, keyboardAdded: false, fullAccess: nil)
        session.observe(facts, at: start)
        XCTAssertEqual(session.lines.first?.text, "Speech uses Apple's built-in model")
    }

    func testAFailedDownloadSaysWhyAndAsksToRetryThenCountsTheRetry() {
        var session = SetupSession()
        var facts = fresh()
        session.observe(facts, at: start)
        session.answer(.download, at: start)
        facts.model = .downloading(fraction: 0.2)
        session.observe(facts, at: start.addingTimeInterval(1))
        facts.model = .failed("The network connection was lost.")
        session.observe(facts, at: start.addingTimeInterval(5))
        session.observe(facts, at: start.addingTimeInterval(6))
        XCTAssertEqual(session.prompt, .retryDownload("The network connection was lost."))
        XCTAssertEqual(session.lines.filter { $0.kind == .problem }.count, 1)
        XCTAssertEqual(session.lines.last?.detail, "The network connection was lost.")

        session.answer(.download, at: start.addingTimeInterval(10))
        facts.model = .downloading(fraction: 0)
        session.observe(facts, at: start.addingTimeInterval(10))
        facts.model = .ready
        session.observe(facts, at: start.addingTimeInterval(40))
        XCTAssertEqual(session.lines.last?.detail, "253 MB in 30 s", "timed from the retry, not the first try")
    }

    func testMicrophoneOffAndFullAccessOffAreProblemsWithAWayOut() {
        var session = SetupSession()
        var facts = SetupFacts(model: .ready, modelBytes: size, microphone: .denied, keyboardAdded: false, fullAccess: nil)
        session.observe(facts, at: start)
        session.observe(facts, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.prompt, .microphoneDenied)
        XCTAssertEqual(session.lines.filter { $0.kind == .problem }.map(\.text), ["The microphone is off"])

        facts.microphone = .granted
        facts.fullAccess = false
        session.observe(facts, at: start.addingTimeInterval(8))
        session.observe(facts, at: start.addingTimeInterval(9))
        XCTAssertEqual(session.prompt, .fullAccessOff)
        XCTAssertEqual(session.lines.filter { $0.kind == .problem }.map(\.text), ["The microphone is off", "Full Access is off"])
        XCTAssertTrue(session.lines.contains { $0.id == "keyboard.added" }, "a keyboard that ran was added")

        facts.fullAccess = true
        session.observe(facts, at: start.addingTimeInterval(20))
        XCTAssertEqual(session.lines.last?.text, "Full Access on")
        XCTAssertEqual(session.prompt, .dictate)
    }

    func testSkippingTheDictationAndAButtonPressAreBothRecorded() {
        var session = SetupSession()
        var facts = SetupFacts(model: .ready, modelBytes: size, microphone: .granted, keyboardAdded: true, fullAccess: true)
        session.observe(facts, at: start)
        session.answer(.skipDictation, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.prompt, .actionButton)
        facts.buttonPressed = true
        session.observe(facts, at: start.addingTimeInterval(9))
        XCTAssertEqual(session.prompt, .finish)
        XCTAssertEqual(Array(ids(session).suffix(2)), ["dictation.skipped", "button.done"])
    }

    func testTheDownloadLineShowsSizeSpeedAndTimeLeftFromRecentReports() {
        var session = SetupSession()
        var facts = fresh()
        session.observe(facts, at: start)
        session.answer(.download, at: start)
        facts.model = .downloading(fraction: 0)
        session.observe(facts, at: start)
        XCTAssertEqual(session.live?.detail, "0% · 0 of 253 MB", "no speed until a second of reports")
        // 10 MB a second for four seconds.
        for second in 1...4 {
            facts.model = .downloading(fraction: Double(second) * 10_000_000 / Double(size))
            session.observe(facts, at: start.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(session.live?.detail, "15% · 40 of 253 MB · 10 MB/s · about 21 s left")
        facts.model = .downloading(fraction: 102_840_000 / Double(size))
        session.observe(facts, at: start.addingTimeInterval(4.5))
        XCTAssertTrue(session.live?.detail?.hasPrefix("40% · 102 of 253 MB") == true, "whole megabytes")
        facts.model = .downloading(fraction: 40_000_000 / Double(size))
        session.observe(facts, at: start.addingTimeInterval(4.6))
        XCTAssertEqual(session.live?.fraction ?? 0, 40_000_000 / Double(size), accuracy: 0.0001)

        // A stall reads as a stall within the window, not as the old average.
        for second in 5...10 { session.observe(facts, at: start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(session.live?.detail, "15% · 40 of 253 MB · waiting for the network")
    }

    func testTimesReadPlainly() {
        XCTAssertEqual(SetupSession.durationLabel(0.2), "1 s")
        XCTAssertEqual(SetupSession.durationLabel(59.4), "59 s")
        XCTAssertEqual(SetupSession.durationLabel(60), "1 min")
        XCTAssertEqual(SetupSession.durationLabel(95), "1 min 35 s")
    }

    func testNoLineUsesADashOrJargon() {
        var session = SetupSession()
        var facts = fresh()
        session.observe(facts, at: start)
        session.answer(.download, at: start)
        facts.model = .failed("x")
        facts.microphone = .denied
        session.observe(facts, at: start.addingTimeInterval(1))
        facts.model = .ready
        facts.microphone = .granted
        facts.fullAccess = false
        session.observe(facts, at: start.addingTimeInterval(2))
        facts.fullAccess = true
        facts.firstDictation = "hi"
        session.answer(.skipActionButton, at: start.addingTimeInterval(3))
        session.observe(facts, at: start.addingTimeInterval(3))
        session.answer(.skipDictation, at: start.addingTimeInterval(3))
        session.finish(at: start.addingTimeInterval(4))
        for line in session.lines {
            let text = line.text + " " + (line.detail ?? "")
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
            for word in ["$", "sudo", "install", "command", "error:", "[Y/n]"] {
                XCTAssertFalse(text.contains(word), "\(word) in \(text)")
            }
        }
    }
}
