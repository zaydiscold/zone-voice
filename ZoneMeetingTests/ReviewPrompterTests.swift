// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class ReviewPrompterTests: XCTestCase {
    private var suite: String!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    override func setUp() {
        suite = "zone.tests.review-prompter.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func prompter(version: String = "1.0.3") -> ReviewPrompter {
        ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: version)
    }

    func testBackgroundSuccessesCountButNeverAsk() {
        let reviews = prompter()
        reviews.noteLaunch(now: start)
        for _ in 0..<5 { reviews.recordSuccess(onScreen: false, now: start.addingTimeInterval(3 * day)) }
        XCTAssertEqual(reviews.state.successes, 5)
        XCTAssertEqual(reviews.askRequests, 0, "A keyboard dictation finishes with Zone in the background")
    }

    func testThirdSuccessOnScreenAfterTwoDaysAsksOnce() {
        let reviews = prompter()
        reviews.noteLaunch(now: start)
        reviews.recordSuccess(onScreen: true, now: start.addingTimeInterval(3 * day))
        reviews.recordSuccess(onScreen: true, now: start.addingTimeInterval(3 * day))
        XCTAssertEqual(reviews.askRequests, 0, "Two successes are not enough")
        reviews.recordSuccess(onScreen: true, now: start.addingTimeInterval(3 * day))
        XCTAssertEqual(reviews.askRequests, 1)
        XCTAssertTrue(reviews.claimAsk(isRecording: false, showsError: false, now: start.addingTimeInterval(3 * day)))
        // Asked in this version: later successes neither request nor claim again.
        reviews.recordSuccess(onScreen: true, now: start.addingTimeInterval(4 * day))
        XCTAssertEqual(reviews.askRequests, 1)
        XCTAssertFalse(reviews.claimAsk(isRecording: false, showsError: false, now: start.addingTimeInterval(4 * day)))
        // A relaunch keeps the record.
        XCTAssertEqual(prompter().state.lastAskedVersion, "1.0.3")
    }

    func testFirstDaysNeverAsk() {
        let reviews = prompter()
        reviews.noteLaunch(now: start)
        for _ in 0..<10 { reviews.recordSuccess(onScreen: true, now: start.addingTimeInterval(day)) }
        XCTAssertEqual(reviews.askRequests, 0)
        XCTAssertFalse(reviews.claimAsk(isRecording: false, showsError: false, now: start.addingTimeInterval(day)))
    }

    func testClaimRefusesWhileRecordingOrShowingAnErrorAndKeepsTheVersionOpen() {
        let reviews = prompter()
        reviews.noteLaunch(now: start)
        let later = start.addingTimeInterval(3 * day)
        for _ in 0..<3 { reviews.recordSuccess(onScreen: true, now: later) }
        XCTAssertFalse(reviews.claimAsk(isRecording: true, showsError: false, now: later))
        XCTAssertFalse(reviews.claimAsk(isRecording: false, showsError: true, now: later))
        XCTAssertNil(reviews.state.lastAskedVersion, "A refused ask must not use up the version")
        XCTAssertTrue(reviews.claimAsk(isRecording: false, showsError: false, now: later))
    }

    func testNewVersionMayAskAgain() {
        let first = prompter(version: "1.0.3")
        first.noteLaunch(now: start)
        let later = start.addingTimeInterval(3 * day)
        for _ in 0..<3 { first.recordSuccess(onScreen: true, now: later) }
        XCTAssertTrue(first.claimAsk(isRecording: false, showsError: false, now: later))
        let updated = prompter(version: "1.0.4")
        updated.recordSuccess(onScreen: true, now: later.addingTimeInterval(day))
        XCTAssertEqual(updated.askRequests, 1)
        XCTAssertTrue(updated.claimAsk(isRecording: false, showsError: false, now: later.addingTimeInterval(day)))
    }
}

extension ReviewPrompter {
    /// For tests that build a coordinator: recordings they finish count in a scratch suite, never
    /// in the App Group the simulator's Zone reads.
    static var forTests: ReviewPrompter {
        ReviewPrompter(store: ReviewPromptStore(suiteName: "zone.tests.review-prompter.scratch"), appVersion: "test")
    }
}
