// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WhatsNewPolicyTests: XCTestCase {
    private func v(_ text: String) -> AppVersion { AppVersion(text)! }

    private func library(_ versions: String...) -> ReleaseNotesLibrary {
        ReleaseNotesLibrary(versions.map { ReleaseNote(version: v($0), day: nil, summary: "s",
                                                    groups: [ReleaseGroup(title: "g", symbol: "mic", items: [ReleaseItem(text: "f")])]) })
    }

    private func launch(_ state: WhatsNewState?, _ installed: String?, setup: Bool = true,
                        notes: ReleaseNotesLibrary? = nil) -> (state: WhatsNewState, owed: AppVersion?) {
        WhatsNewPolicy.launch(state, installed: installed.flatMap(AppVersion.init), setupFinished: setup,
                              library: notes ?? library("1.0", "1.0.3", "1.0.4"))
    }

    // MARK: What is owed

    func testAFreshInstallOwesNothingEvenAfterSetup() {
        let first = launch(nil, "1.0.4", setup: false)
        XCTAssertNil(first.owed)
        XCTAssertTrue(first.state.isSettled(v("1.0.4")))
        // Setup finished, later launches of the same version.
        XCTAssertNil(launch(first.state, "1.0.4").owed)
        XCTAssertNil(launch(launch(first.state, "1.0.4").state, "1.0.4").owed)
    }

    func testAnUpdateFromAVersionThatKeptNoRecordOwesTheNotes() {
        let result = launch(nil, "1.0.4")
        XCTAssertEqual(result.owed, v("1.0.4"))
        XCTAssertFalse(result.state.isSettled(v("1.0.4")), "owed until shown")
    }

    func testOwedUntilShownThenNeverAgain() {
        var state = launch(nil, "1.0.4").state
        // Not shown yet (the keyboard opened Zone, say): still owed at the next launch.
        XCTAssertEqual(launch(state, "1.0.4").owed, v("1.0.4"))
        state.settle(v("1.0.4"))
        XCTAssertNil(launch(state, "1.0.4").owed)
        // A new TestFlight build of the same version is the same marketing version.
        XCTAssertNil(launch(state, "1.0.4").owed)
    }

    func testAnUpdateOwesTheNewVersionOnly() {
        let seen = WhatsNewState(settled: ["1.0"], newest: "1.0")
        let result = launch(seen, "1.0.4")
        XCTAssertEqual(result.owed, v("1.0.4"), "1.0.3 was skipped; only the installed version is shown")
        XCTAssertEqual(result.state.newest, "1.0.4")
    }

    func testAVersionWithoutNotesOwesNothingAndIsNotMarkedShown() {
        let seen = WhatsNewState(settled: ["1.0.4"], newest: "1.0.4")
        let result = launch(seen, "1.0.5")
        XCTAssertNil(result.owed)
        XCTAssertFalse(result.state.isSettled(v("1.0.5")))
        XCTAssertEqual(result.state.newest, "1.0.5")
        // And the same with no record at all.
        XCTAssertNil(launch(nil, "1.0.5").owed)
    }

    func testNotesWrittenAheadAreNeverShownEarly() {
        // 1.0.4's file is already in the bundle, but this copy of Zone is 1.0.3.
        let seen = WhatsNewState(settled: ["1.0"], newest: "1.0")
        XCTAssertEqual(launch(seen, "1.0.3").owed, v("1.0.3"))
        // And a version with no file never borrows the newest file there is.
        XCTAssertNil(launch(seen, "1.0.2").owed)
        XCTAssertNil(launch(seen, "1.0.5").owed)
        XCTAssertNil(launch(seen, "2.0").owed)
    }

    func testAVersionWithoutNotesIsSkippedAndTheNextOneIsOwed() {
        let notes = library("1.0.4", "1.0.6")
        let onFive = launch(WhatsNewState(settled: ["1.0.4"], newest: "1.0.4"), "1.0.5", notes: notes)
        XCTAssertNil(onFive.owed)
        let onSix = launch(onFive.state, "1.0.6", notes: notes)
        XCTAssertEqual(onSix.owed, v("1.0.6"), "1.0.6, never 1.0.4 again and never the missing 1.0.5")
        XCTAssertEqual(onSix.state.newest, "1.0.6")
    }

    func testNotesAddedInALaterBuildOfTheSameVersionAreOwedOnce() {
        // The first 1.0.5 build shipped without a file, so nothing was shown and nothing was settled.
        var state = launch(WhatsNewState(settled: ["1.0.4"], newest: "1.0.4"), "1.0.5").state
        let withNotes = library("1.0.4", "1.0.5")
        XCTAssertEqual(launch(state, "1.0.5", notes: withNotes).owed, v("1.0.5"))
        state.settle(v("1.0.5"))
        XCTAssertNil(launch(state, "1.0.5", notes: withNotes).owed)
    }

    func testGoingBackAndUpdatingAgainDoesNotShowTheSameNotesTwice() {
        let seen = WhatsNewState(settled: ["1.0.4"], newest: "1.0.4")
        let back = launch(seen, "1.0.3")
        XCTAssertNil(back.owed, "an older build never shows its notes as new")
        XCTAssertNil(launch(back.state, "1.0.4").owed, "1.0.4 was already shown")
    }

    func testTheRecordMatchesAVersionHoweverItWasWritten() {
        XCTAssertNil(launch(WhatsNewState(settled: ["1.0"], newest: "1.0"), "1.0.0").owed)
        XCTAssertNil(launch(WhatsNewState(settled: ["1.0.0"], newest: "1.0.0"), "1.0").owed)
        // An unreadable "newest" is treated as no record of one, not as a reason to stay silent.
        XCTAssertEqual(launch(WhatsNewState(settled: [], newest: "garbage"), "1.0.4").owed, v("1.0.4"))
    }

    func testAnOlderVersionInstalledOverANewerOneOwesNothing() {
        let seen = WhatsNewState(settled: ["1.0.4"], newest: "1.0.4")
        let result = launch(seen, "1.0.3")
        XCTAssertNil(result.owed)
        XCTAssertEqual(result.state, seen)
    }

    func testUpdatingBeforeSetupWasEverFinishedOwesNothing() {
        let fresh = launch(nil, "1.0.3", setup: false).state
        let updated = launch(fresh, "1.0.4", setup: false)
        XCTAssertNil(updated.owed)
        XCTAssertNil(launch(updated.state, "1.0.4", setup: true).owed, "nothing was new to someone who had not used Zone")
    }

    func testNoReadableVersionOwesNothing() {
        XCTAssertNil(launch(nil, nil).owed)
        XCTAssertNil(launch(nil, "not a version").owed)
    }

    func testSettlingKeepsTheNewestVersion() {
        var state = WhatsNewState()
        state.settle(v("1.0.4"))
        state.settle(v("1.0.3"))
        state.settle(v("1.0.4"))
        XCTAssertEqual(state.settled, ["1.0.4", "1.0.3"])
        XCTAssertEqual(state.newest, "1.0.4")
    }

    // MARK: When the sheet may open

    /// Someone opened Zone themselves two seconds ago and is looking at an idle Home.
    private var idleHome: WhatsNewMoment {
        var moment = WhatsNewMoment()
        moment.setupFinished = true
        moment.sceneActive = true
        moment.homeInFront = true
        moment.sinceOpened = 2
        return moment
    }

    private func changed(_ change: (inout WhatsNewMoment) -> Void) -> WhatsNewMoment {
        var moment = idleHome
        change(&moment)
        return moment
    }

    func testAnIdleHomeThePersonOpenedMayShowIt() {
        XCTAssertTrue(WhatsNewPolicy.mayPresent(idleHome))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(WhatsNewMoment()), "nothing is assumed")
    }

    func testNeverDuringSetupARecordingOrAnythingElseOnScreen() {
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.setupFinished = false }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.sceneActive = false }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.homeInFront = false }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.somethingPresented = true }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.recording = true }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.showsError = true }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.typing = true }))
    }

    func testNeverOnAVisitTheKeyboardAShortcutOrALinkOpened() {
        // The keyboard's link arrives a moment after Zone comes forward.
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.automationBeforeOpen = -0.2 }))
        // A Shortcut ran, then brought Zone forward.
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.automationBeforeOpen = 0.5 }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.automationBeforeOpen = 15 }))
        // The keyboard asked for a dictation a minute into the visit: still that visit.
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.automationBeforeOpen = -60; $0.sinceOpened = 5 }))
        // Something ran a while ago, and the person opened Zone on their own afterwards.
        XCTAssertTrue(WhatsNewPolicy.mayPresent(changed { $0.automationBeforeOpen = 15.1 }))
        XCTAssertTrue(WhatsNewPolicy.mayPresent(changed { $0.automationBeforeOpen = 3600 }))
    }

    func testOnlyAtTheStartOfAVisitAfterTheScreenSettles() {
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.sinceOpened = 0 }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.sinceOpened = 0.9 }))
        XCTAssertTrue(WhatsNewPolicy.mayPresent(changed { $0.sinceOpened = 1 }))
        XCTAssertTrue(WhatsNewPolicy.mayPresent(changed { $0.sinceOpened = 8 }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.sinceOpened = 8.1 }))
        XCTAssertFalse(WhatsNewPolicy.mayPresent(changed { $0.sinceOpened = 600 }))
    }
}

final class WhatsNewStoreTests: XCTestCase {
    func testTheRecordSurvivesAndClears() throws {
        let suite = "zone.whatsNew.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhatsNewStore(defaults: defaults)
        XCTAssertNil(store.state, "no record before the first launch that keeps one")

        store.settle(try XCTUnwrap(AppVersion("1.0.4")))
        XCTAssertEqual(WhatsNewStore(defaults: defaults).state, WhatsNewState(settled: ["1.0.4"], newest: "1.0.4"))

        store.state = nil
        XCTAssertNil(store.state)
        defaults.set(Data("not json".utf8), forKey: WhatsNewStore.key)
        XCTAssertNil(store.state, "an unreadable record reads as none")
    }
}
