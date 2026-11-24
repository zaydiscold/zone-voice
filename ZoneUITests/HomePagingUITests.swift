// by zayd/cold @ zayd.wtf

import XCTest

final class HomePagingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(mode: String = "transcribe") -> XCUIApplication {
        let app = XCUIApplication()
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        app.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                               "-zoneHomeMode", mode, "-zoneWhatsNewAfter", version]
        app.launch()
        expectPage(mode == "cleanup" ? "transcribe" : mode, in: app)
        return app
    }

    private func expectSelected(_ mode: String, in app: XCUIApplication) {
        let key = app.buttons["home.mode." + mode]
        XCTAssertTrue(key.wait(for: \.isSelected, toEqual: true, timeout: 8), "Expected selected key " + mode)
    }

    private func expectVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(8)
        var previous = CGRect.null
        var stableSince = Date()
        repeat {
            if element.exists, element.isHittable {
                let frame = element.frame
                if app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    if frame == previous {
                        if Date().timeIntervalSince(stableSince) >= 0.35 { return }
                    } else {
                        previous = frame
                        stableSince = Date()
                    }
                } else {
                    previous = .null
                }
            } else {
                previous = .null
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("Expected a visible, settled element: " + element.description)
    }

    private func expectPage(_ mode: String, in app: XCUIApplication) {
        expectSelected(mode, in: app)
        switch mode {
        case "transcribe":
            expectVisible(app.descendants(matching: .any)["home.standbyTitle"].firstMatch, in: app)
        case "meeting":
            expectVisible(app.buttons["How meetings work"], in: app)
        default:
            XCTFail("Unknown page " + mode)
        }
    }

    func testCompactHeaderKeepsBothTapTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                               "-zoneHomeMode", "transcribe", "-zoneWhatsNewAfter", "99.0",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let transcribe = app.buttons["home.mode.transcribe"]
        let meeting = app.buttons["home.mode.meeting"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(meeting.frame.maxX - transcribe.frame.minX, 170)
        for key in [transcribe, meeting] {
            XCTAssertGreaterThanOrEqual(key.frame.height, 44)
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "compact-home-header"
        capture.lifetime = .keepAlways
        add(capture)
        meeting.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        expectPage("meeting", in: app)
    }

    func testFastSwipesMoveOnePageAndStopAtTheEnds() {
        let app = launch()
        app.swipeRight(velocity: .fast)
        expectPage("transcribe", in: app)
        app.swipeLeft(velocity: .fast)
        expectPage("meeting", in: app)
        app.swipeLeft(velocity: .fast)
        expectPage("meeting", in: app)
        XCTAssertFalse(app.buttons["home.mode.cleanup"].exists)
        app.swipeRight(velocity: .fast)
        expectPage("transcribe", in: app)
    }

    func testLeavingMeetingDismissesKeyboardAndKeepsName() {
        let app = launch()
        let mic = app.buttons["Dictate"]
        expectVisible(mic, in: app)
        let restingMicY = mic.frame.midY
        app.buttons["home.mode.meeting"].tap()
        let name = app.textFields["Meeting name, optional"]
        expectVisible(name, in: app)
        let restingNameY = name.frame.midY
        name.tap()
        name.typeText("Weekly sync")
        // Zone's keyboard extension has its own accessibility tree. The pinned field rises
        // above either keyboard, giving a visible precondition even when the app can't query it.
        expectVisible(name, in: app)
        XCTAssertLessThan(name.frame.midY, restingNameY - 100, "The software keyboard must have lifted the field")
        // Start the drag above the keyboard.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.26))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.26)))

        expectSelected("transcribe", in: app)
        expectVisible(mic, in: app)
        XCTAssertEqual(mic.frame.midY, restingMicY, accuracy: 2, "Dismissing the keyboard restores the composer")
        app.swipeLeft()
        expectSelected("meeting", in: app)
        expectVisible(name, in: app)
        XCTAssertEqual(name.value as? String, "Weekly sync")
    }

    func testShortDragAndVerticalSwipeKeepTheSelectedPage() {
        let app = launch(mode: "meeting")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 28, dy: 2)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        expectPage("meeting", in: app)
        app.swipeUp()
        expectSelected("meeting", in: app)
        app.buttons["home.mode.transcribe"].tap()
        expectPage("transcribe", in: app)
        app.buttons["home.mode.meeting"].tap()
        expectSelected("meeting", in: app)
    }

    func testOldCleanupSelectionOpensTranscribeAndKeepsTheTwoPageSwipe() {
        let app = launch(mode: "cleanup")
        XCTAssertFalse(app.buttons["home.mode.cleanup"].exists)
        app.swipeLeft()
        expectPage("meeting", in: app)
        app.terminate()
        if let seed = app.launchArguments.firstIndex(of: "-zoneHomeMode") {
            app.launchArguments.removeSubrange(seed...seed + 1)
        }
        app.launch()
        expectPage("meeting", in: app)
        app.swipeRight()
        expectPage("transcribe", in: app)
    }
}
