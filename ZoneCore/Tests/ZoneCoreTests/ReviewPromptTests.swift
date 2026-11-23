// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class ReviewPromptPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func eligible(successes: Int = 3, asked: String? = nil) -> ReviewPromptState {
        ReviewPromptState(firstSeenAt: start, successes: successes, lastAskedVersion: asked)
    }

    private func ask(_ state: ReviewPromptState, after age: TimeInterval = 2 * 86_400, version: String = "1.0.3",
                     isRecording: Bool = false, showsError: Bool = false) -> Bool {
        ReviewPromptPolicy.shouldAsk(state, now: start.addingTimeInterval(age), appVersion: version,
                                     isRecording: isRecording, showsError: showsError)
    }

    func testAsksAtThreeSuccessesAndTwoDays() {
        XCTAssertTrue(ask(eligible()))
        XCTAssertTrue(ask(eligible(successes: 40), after: 90 * day))
    }

    func testNeedsThreeSuccesses() {
        XCTAssertFalse(ask(eligible(successes: 0)))
        XCTAssertFalse(ask(eligible(successes: 2)))
        XCTAssertFalse(ask(eligible(successes: -1)))
    }

    func testNeedsTwoDaysSinceFirstLaunch() {
        XCTAssertFalse(ask(eligible(), after: 0))
        XCTAssertFalse(ask(eligible(), after: 2 * day - 1))
        XCTAssertTrue(ask(eligible(), after: 2 * day))
        // No first launch on record: never old enough.
        XCTAssertFalse(ask(ReviewPromptState(firstSeenAt: nil, successes: 10)))
        // A clock set backwards is too soon, not old enough.
        XCTAssertFalse(ask(eligible(), after: -30 * day))
    }

    func testAsksOncePerVersion() {
        XCTAssertFalse(ask(eligible(asked: "1.0.3"), version: "1.0.3"))
        XCTAssertFalse(ask(eligible(asked: "1.0.3"), version: " 1.0.3 "))
        XCTAssertTrue(ask(eligible(asked: "1.0.2"), version: "1.0.3"))
        // An unknown version never asks, so a missing Info.plist value cannot ask every time.
        XCTAssertFalse(ask(eligible(), version: ""))
        XCTAssertFalse(ask(eligible(), version: "  "))
    }

    func testNeverWhileRecordingOrShowingAnError() {
        XCTAssertFalse(ask(eligible(), isRecording: true))
        XCTAssertFalse(ask(eligible(), showsError: true))
        XCTAssertFalse(ask(eligible(), isRecording: true, showsError: true))
    }
}

final class ReviewPromptStoreTests: XCTestCase {
    private var suite: String!
    private var store: ReviewPromptStore!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "zone.tests.review-prompt.\(UUID().uuidString)"
        store = ReviewPromptStore(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testEmptyStoreReadsAsFreshState() {
        XCTAssertEqual(store.state, ReviewPromptState())
    }

    func testLaunchStartsTheClockOnce() {
        store.noteLaunch(now: start)
        store.noteLaunch(now: start.addingTimeInterval(5 * 86_400))
        XCTAssertEqual(store.state.firstSeenAt, start)
    }

    func testSuccessesCountAndPersistAcrossInstances() {
        store.noteLaunch(now: start)
        store.recordSuccess(now: start.addingTimeInterval(60))
        store.recordSuccess(now: start.addingTimeInterval(120))
        let last = store.recordSuccess(now: start.addingTimeInterval(180))
        XCTAssertEqual(last.successes, 3)
        let reopened = ReviewPromptStore(suiteName: suite)
        XCTAssertEqual(reopened.state, ReviewPromptState(firstSeenAt: start, successes: 3))
    }

    func testFirstSuccessStartsTheClockWhenLaunchDidNot() {
        store.recordSuccess(now: start)
        XCTAssertEqual(store.state.firstSeenAt, start)
    }

    func testMarkAskedRecordsTheVersionAndBlocksItUntilTheNext() {
        store.noteLaunch(now: start)
        for _ in 0..<3 { store.recordSuccess(now: start) }
        let later = start.addingTimeInterval(3 * 86_400)
        XCTAssertTrue(ReviewPromptPolicy.shouldAsk(store.state, now: later, appVersion: "1.0.3", isRecording: false, showsError: false))
        store.markAsked(version: "1.0.3")
        XCTAssertEqual(store.state.lastAskedVersion, "1.0.3")
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(store.state, now: later, appVersion: "1.0.3", isRecording: false, showsError: false))
        XCTAssertTrue(ReviewPromptPolicy.shouldAsk(store.state, now: later, appVersion: "1.0.4", isRecording: false, showsError: false))
        // Asking never resets the count or the clock.
        XCTAssertEqual(store.state.successes, 3)
        XCTAssertEqual(store.state.firstSeenAt, start)
    }

    func testUnreadableRecordReadsAsFresh() {
        UserDefaults(suiteName: suite)?.set(Data("not json".utf8), forKey: ReviewPromptStore.key)
        XCTAssertEqual(store.state, ReviewPromptState())
        store.recordSuccess(now: start)
        XCTAssertEqual(store.state.successes, 1)
    }
}
