// by zayd/cold @ zayd.wtf

import XCTest

/// Pairing a computer, in the real app: a pairing link asks "Send your Zone library to ...?"
/// and nothing is saved or shown until the person answers Send.
///
/// The link is offered with the debug launch arguments (`Zone/Link/LinkDebug.swift`), which
/// take the same path as a scanned code. The computer does not exist, so nothing is ever
/// delivered; that is the state Flash is for, and `-zoneLinkFlash` opens it once a computer is saved.
final class LinkPairingUITests: XCTestCase {
    /// A well-formed endpoint id and the published test secret. No computer answers to it.
    private let link = "zone://pair?v=1&n=523c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea&s="
        + String(repeating: "ab", count: 32) + "&name=UI%20test%20box"

    /// This build's version, which the app shares with this test bundle. These tests mark its
    /// notes as seen: `VersionHistoryUITests` leave What's New owed in the simulator, and its
    /// sheet, shown first, would keep the Computers screen and Flash from opening.
    private var settledVersion: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.4"
        return ["-zoneWhatsNewAfter", version]
    }

    private func launch(_ extra: [String] = ["-zoneLinkFlash"], forget: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settledVersion + (forget ? ["-zoneLinkForgetAll", "-zoneLinkSeed", "12", "-zoneLinkPair", link] : []) + extra
        app.launch()
        return app
    }

    /// The switch's own knob: a tap in the middle of a SwiftUI toggle row can land on its label.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testSendPairsTheComputerAndFlashCanShowItsCodes() {
        let app = launch()
        let question = app.alerts["Send your Zone library to UI test box?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30), "the pairing question")
        XCTAssertTrue(question.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Only pair a computer you trust'")).firstMatch.exists)
        XCTAssertFalse(app.otherElements["flash.code"].exists, "nothing is paired before the answer")
        question.buttons["Send"].tap()

        // Saved without ever connecting: Send by Flash opens for it, on its guide.
        let start = app.buttons["flash.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), "the Flash guide for the new computer")
        XCTAssertTrue(app.staticTexts["flash.name"].label == "UI test box")
        XCTAssertTrue(app.descendants(matching: .any)["flash.steps"].exists, "the three steps")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'full brightness'")).firstMatch.exists)
        // The computer's app comes first, the command second; and one honest line about the flashing.
        XCTAssertTrue(app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'open Zone and choose Flash'")).firstMatch.exists)
        let sensitivity = app.descendants(matching: .any)["flash.sensitivity"]
        XCTAssertTrue(sensitivity.exists, "the line for people sensitive to flashing lights")
        XCTAssertTrue(sensitivity.isHittable, "on screen beside Start, without scrolling")
        XCTAssertTrue(sensitivity.label.contains("20 times a second"), sensitivity.label)
        XCTAssertTrue(sensitivity.label.contains("in color and in black and white"), "black and white is no way around it")
        XCTAssertTrue(sensitivity.label.contains("photosensitive epilepsy"), sensitivity.label)
        let code = app.descendants(matching: .any)["flash.code"]
        XCTAssertFalse(code.exists, "no codes before Start")
        let blackAndWhite = app.switches["flash.blackAndWhite"]
        XCTAssertTrue(blackAndWhite.exists, "the black and white choice for older cameras")
        XCTAssertEqual(blackAndWhite.value as? String, "0", "color is the default")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        wait(for: [ready], timeout: 20)
        XCTAssertTrue(app.staticTexts["flash.detail"].label.contains("items"), app.staticTexts["flash.detail"].label)
        start.tap()

        XCTAssertTrue(code.waitForExistence(timeout: 10), "Start shows the codes")
        XCTAssertTrue(app.staticTexts["UI test box"].exists)
        let progress = app.staticTexts["flash.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let first = progress.label
        XCTAssertTrue(first.hasPrefix("Pass "), first)
        // The frames move: the line changes within a second.
        let moved = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: progress)
        wait(for: [moved], timeout: 5)
        XCTAssertTrue(app.staticTexts["flash.detail"].label.contains("says Done for this flash, tap Done"))
        // The flash's name, which the computer's page shows for the flash it reads.
        let name = app.staticTexts["flash.id"]
        XCTAssertTrue(name.exists)
        let flash = name.value as? String ?? ""
        XCTAssertNotNil(flash.range(of: #"^[89a-f][0-9a-f]{3} [0-9a-f]{4}$"#, options: .regularExpression), flash)

        // Done plays the short ending, then asks. Leaving the question unanswered (Keep showing,
        // or a tap outside it, which is all iOS 26 offers) goes back to the codes.
        app.buttons["flash.done"].tap()
        let received = app.buttons["No, not yet"]
        XCTAssertTrue(received.waitForExistence(timeout: 5), "Done asks whether the computer received it")
        let paused = progress.label
        let keep = app.buttons["Keep showing"]
        if keep.exists {
            keep.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        }
        XCTAssertTrue(received.waitForNonExistence(timeout: 5))
        let resumed = expectation(for: NSPredicate(format: "label != %@", paused), evaluatedWith: progress)
        wait(for: [resumed], timeout: 6)

        app.buttons["flash.done"].tap()
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        // The question names this flash, not only a count another flash could share.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "says Done for flash \(flash)")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Yes, it has them"].exists)
        received.tap()
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
    }

    /// A dictation in the flash is transcribed again while the codes show (as a retried
    /// dictation or a Watch recording would change it): the codes are made again without
    /// leaving the screen, under a new name, and Done asks about the new flash.
    func testTheCodesAreMadeAgainWhenWhatTheyCarryChangesWhileTheyShow() {
        let app = launch(["-zoneLinkFlash", "-zoneLinkFlashStart", "-zoneLinkFlashChangeAfter", "3"])
        let question = app.alerts["Send your Zone library to UI test box?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30))
        question.buttons["Send"].tap()

        let name = app.staticTexts["flash.id"]
        XCTAssertTrue(name.waitForExistence(timeout: 30), "the codes start by themselves")
        let before = name.value as? String ?? ""
        XCTAssertFalse(before.isEmpty)
        let remade = expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: name)
        wait(for: [remade], timeout: 20)
        let after = name.value as? String ?? ""
        XCTAssertTrue(app.descendants(matching: .any)["flash.code"].exists, "still showing codes, not back on the guide")
        XCTAssertTrue(app.staticTexts["flash.detail"].label.contains("made again"), app.staticTexts["flash.detail"].label)
        let progress = app.staticTexts["flash.progress"]
        let first = progress.label
        let moved = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: progress)
        wait(for: [moved], timeout: 5)
        // Nothing else changed, so the codes stay as they are.
        sleep(3)
        XCTAssertEqual(name.value as? String, after, "made again once, not over and over")

        app.buttons["flash.done"].tap()
        let no = app.buttons["No, not yet"]
        XCTAssertTrue(no.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "says Done for flash \(after)")).firstMatch.exists,
                      "the question is about the codes on screen now")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "was for the earlier flash")).firstMatch.exists)
        no.tap()
        XCTAssertTrue(app.descendants(matching: .any)["flash.code"].waitForNonExistence(timeout: 5))
    }

    /// Done before any camera could have read every piece of the codes on screen: a Done on
    /// the page is an earlier flash's, so the question offers no Yes.
    func testDoneBeforeACameraCouldHaveReadTheCodesCannotSayYes() {
        // One picture a second, small pieces: many seconds before the codes can all be read.
        let app = launch(["-zoneLinkFlash", "-zoneLinkFlashStart", "-zoneLinkFlashRate", "1", "-zoneLinkFlashChunk", "40"])
        let question = app.alerts["Send your Zone library to UI test box?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30))
        question.buttons["Send"].tap()
        let done = app.buttons["flash.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 30))
        done.tap()
        let no = app.buttons["No, not yet"]
        XCTAssertTrue(no.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Yes, it has them"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "is for an earlier flash")).firstMatch.exists)
        no.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }

    /// Flashes small enough that the seeded library goes as several, with Everything chosen.
    private let split = ["-zoneLinkFlash", "-zoneLinkFlashEverything", "-zoneLinkFlashPieces", "3", "-zoneLinkFlashChunk", "300"]

    /// Pairs, sends the first part of the library by Everything, says Yes, and quits Zone: the
    /// next Everything flash goes on after what this one carried.
    private func confirmTheFirstEverythingFlash() {
        let app = launch(split)
        let question = app.alerts["Send your Zone library to UI test box?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30))
        question.buttons["Send"].tap()
        let start = app.buttons["flash.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)], timeout: 20)
        let detail = app.staticTexts["flash.detail"]
        XCTAssertTrue(detail.label.contains("more go in the next flash"), detail.label)
        XCTAssertFalse(detail.label.contains("goes on from"), detail.label)
        start.tap()
        let done = app.buttons["flash.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        sleep(2)
        done.tap()
        let yes = app.buttons["Yes, it has them"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        yes.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    /// The number a choice on the Flash guide shows, as in "Everything (14)".
    private func count(_ segment: XCUIElement) -> Int? {
        guard let range = segment.label.range(of: #"\(([0-9,]+)\)"#, options: .regularExpression) else { return nil }
        return Int(segment.label[range].filter(\.isNumber))
    }

    /// A library larger than one flash, with Everything: the flash the person confirms carries
    /// the first part, and the next Everything flash goes on from there instead of repeating it.
    func testEverythingGoesOnFromTheLastFlash() {
        confirmTheFirstEverythingFlash()
        let again = launch(split, forget: false)
        let next = again.buttons["flash.start"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)], timeout: 20)
        let goesOn = again.staticTexts["flash.detail"]
        XCTAssertTrue(goesOn.label.contains("goes on from your last Everything flash"), goesOn.label)
        // It can also start from the first item again.
        again.swipeUp()
        let restart = again.buttons["flash.restartEverything"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        restart.tap()
        let fromTheStart = expectation(for: NSPredicate(format: "NOT (label CONTAINS 'goes on from')"), evaluatedWith: goesOn)
        wait(for: [fromTheStart], timeout: 10)
        XCTAssertFalse(restart.exists)
    }

    /// Items that join the library during an Everything round with times before where it goes
    /// on from still go in the round. `-zoneLinkRestoreNotes 3` adds three notes no earlier run
    /// added, dated before the whole library, through the import a backup restore uses, which
    /// keeps their own times. (Not a larger `-zoneLinkSeed`: its ids are fixed, so on a
    /// simulator an earlier run seeded it adds nothing.) Everything then counts every item Not
    /// sent yet does, and once the rest is confirmed nothing is left to send.
    func testEverythingCarriesWhatJoinsTheLibraryWithAnOlderTime() {
        confirmTheFirstEverythingFlash()
        // One flash for the rest, and the older notes added before the guide opens.
        let app = launch(["-zoneLinkRestoreNotes", "3", "-zoneLinkFlash", "-zoneLinkFlashEverything"], forget: false)
        let start = app.buttons["flash.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)], timeout: 20)
        let detail = app.staticTexts["flash.detail"]
        XCTAssertTrue(detail.label.contains("goes on from your last Everything flash"), detail.label)
        XCTAssertFalse(detail.label.contains("more go in the next flash"), detail.label)
        let what = app.segmentedControls["flash.what"]
        let notSent = count(what.buttons.element(boundBy: 0)), everything = count(what.buttons.element(boundBy: 1))
        XCTAssertNotNil(notSent)
        XCTAssertGreaterThan(notSent ?? 0, 3, "the restored notes and what the first flash left")
        XCTAssertEqual(everything, notSent, "Everything goes on with every item the computer does not have yet, older ones included")
        start.tap()
        let done = app.buttons["flash.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        sleep(2)
        done.tap()
        let yes = app.buttons["Yes, it has them"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        yes.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        app.terminate()

        // The round is over and nothing was left out of it.
        let after = launch(["-zoneLinkFlash"], forget: false)
        let problem = after.staticTexts["flash.problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 30), "Not sent yet has nothing to send")
        XCTAssertTrue(problem.label.contains("has been sent everything in your library"), problem.label)
        XCTAssertEqual(count(after.segmentedControls["flash.what"].buttons.element(boundBy: 0)), 0)
        XCTAssertFalse(after.buttons["flash.restartEverything"].exists)
    }

    /// Send everything again on the Computers screen also starts Everything from the first item,
    /// as a computer with a new library would need.
    func testSendEverythingAgainStartsEverythingFromTheFirstItem() {
        confirmTheFirstEverythingFlash()
        let app = launch(["-zoneLinkComputers", "-zoneLinkFlashEverything"], forget: false)
        let flash = app.buttons["computers.flash"]
        XCTAssertTrue(flash.waitForExistence(timeout: 90), "the Computers screen")
        func openFlash() -> XCUIElement {
            flash.tap()
            let start = app.buttons["flash.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)], timeout: 20)
            return app.staticTexts["flash.detail"]
        }
        let before = openFlash()
        XCTAssertTrue(before.label.contains("goes on from your last Everything flash"), before.label)
        app.buttons["flash.cancel"].tap()

        let sendAgain = app.buttons["computers.sendAgain"]
        XCTAssertTrue(sendAgain.waitForExistence(timeout: 30))
        // Off while Zone tries to reach the computer, which does not exist.
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: sendAgain)], timeout: 90)
        sendAgain.tap()
        let after = openFlash()
        XCTAssertFalse(after.label.contains("goes on from"), after.label)
        XCTAssertFalse(app.buttons["flash.restartEverything"].exists)
    }

    /// Black and white codes are the plain screen: no art, and Done asks straight away.
    func testBlackAndWhiteCodesStayPlain() {
        let app = launch()
        let question = app.alerts["Send your Zone library to UI test box?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30))
        question.buttons["Send"].tap()
        let start = app.buttons["flash.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        // The switch is at the end of the guide, under the fold on most phones.
        app.swipeUp()
        let blackAndWhite = app.switches["flash.blackAndWhite"]
        flip(blackAndWhite)
        XCTAssertEqual(blackAndWhite.value as? String, "1")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        wait(for: [ready], timeout: 20)
        XCTAssertTrue(app.staticTexts["flash.detail"].label.contains("One code a picture"), app.staticTexts["flash.detail"].label)
        start.tap()

        let progress = app.staticTexts["flash.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let first = progress.label
        let moved = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: progress)
        wait(for: [moved], timeout: 5)
        XCTAssertFalse(app.staticTexts["flash.detail"].label.contains("three codes"))
        app.buttons["flash.done"].tap()
        XCTAssertTrue(app.buttons["No, not yet"].waitForExistence(timeout: 3))
        app.buttons["No, not yet"].tap()

        // The choice is remembered, so put it back for the tests that expect color.
        app.terminate()
        let again = launch(forget: false)
        let toggle = again.switches["flash.blackAndWhite"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        XCTAssertEqual(toggle.value as? String, "1", "kept for next time")
        again.swipeUp()
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testCancelPairsNothing() {
        let app = launch()
        let question = app.alerts["Send your Zone library to UI test box?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30), "the pairing question")
        question.buttons["Cancel"].tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))
        // -zoneLinkFlash opens Flash as soon as any computer is saved. None is.
        XCTAssertFalse(app.buttons["flash.start"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.descendants(matching: .any)["flash.code"].exists)
    }

    /// The per-computer switch: off shows Paused, turns off Sync now and Send everything again,
    /// keeps Send by Flash, and is still off after Zone is quit and opened again.
    func testSendingCanBeTurnedOffAndBackOn() {
        var app = launch(["-zoneLinkAutoConfirm", "-zoneLinkComputers"])
        let sending = app.switches["computers.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 90), "the Computers screen with the new computer")
        XCTAssertEqual(sending.value as? String, "1", "on after pairing")
        XCTAssertFalse(app.staticTexts["computers.paused"].exists)

        flip(sending)
        XCTAssertTrue(app.staticTexts["computers.paused"].waitForExistence(timeout: 5), "the Paused tag")
        XCTAssertEqual(sending.value as? String, "0")
        XCTAssertTrue(app.staticTexts["computers.pausedNote"].label.contains("Send by Flash still works"))
        XCTAssertFalse(app.buttons["computers.syncNow"].isEnabled, "Sync now is off while paused")
        XCTAssertFalse(app.buttons["computers.sendAgain"].isEnabled)
        XCTAssertTrue(app.buttons["computers.flash"].isEnabled, "Flash is something the person starts")

        // Saved with the computer.
        app.terminate()
        app = launch(["-zoneLinkComputers"], forget: false)
        let again = app.switches["computers.sending"]
        XCTAssertTrue(again.waitForExistence(timeout: 30))
        XCTAssertEqual(again.value as? String, "0", "still off after Zone opens again")
        XCTAssertTrue(app.staticTexts["computers.paused"].exists)

        flip(again)
        XCTAssertTrue(app.staticTexts["computers.paused"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(again.value as? String, "1")
        XCTAssertFalse(app.staticTexts["computers.pausedNote"].exists)
    }

    /// "Keep what I delete here": off by default, says what it does either way, and is still
    /// on after Zone is quit and opened again. The screen also points to Zone for the computer.
    func testAComputerCanKeepWhatIsDeletedHere() {
        var app = launch(["-zoneLinkAutoConfirm", "-zoneLinkComputers"])
        let keep = app.switches["computers.keepDeleted"]
        XCTAssertTrue(keep.waitForExistence(timeout: 90), "the Computers screen with the new computer")
        XCTAssertEqual(keep.label, "Keep what I delete here")
        XCTAssertEqual(keep.value as? String, "0", "off after pairing: deletes are sent")
        let note = app.staticTexts["computers.keepNote"]
        XCTAssertTrue(note.label.contains("also deletes the copy on UI test box"), note.label)

        flip(keep)
        XCTAssertEqual(keep.value as? String, "1")
        let on = expectation(for: NSPredicate(format: "label CONTAINS 'UI test box keeps its copy'"), evaluatedWith: note)
        wait(for: [on], timeout: 5)
        XCTAssertTrue(note.label.contains("Turning it off later does not reach back"), note.label)
        XCTAssertEqual(app.switches["computers.sending"].value as? String, "1", "sending is a separate switch")

        // Saved with the computer.
        app.terminate()
        app = launch(["-zoneLinkComputers"], forget: false)
        let again = app.switches["computers.keepDeleted"]
        XCTAssertTrue(again.waitForExistence(timeout: 30))
        XCTAssertEqual(again.value as? String, "1", "still on after Zone opens again")
        flip(again)
        XCTAssertEqual(again.value as? String, "0")
        XCTAssertTrue(app.staticTexts["computers.keepNote"].label.contains("also deletes the copy"))

        // Further down: where to get Zone for the computer, and what to do there.
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["computers.getZone"].waitForExistence(timeout: 5), "Get Zone for your computer")
        XCTAssertTrue(app.descendants(matching: .any)["computers.shareZone"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'open Zone and choose Pair a phone'")).firstMatch.exists)
    }

    /// Send text to your computer: typed text is queued for the paired computer at once. This
    /// computer does not exist, so the clip waits, the sheet says for whom, and the list keeps
    /// it across a relaunch until it is removed.
    func testSendTextQueuesAClipAndSaysWhichComputerItWaitsFor() {
        var app = launch(["-zoneLinkAutoConfirm", "-zoneLinkComputers"])
        let row = app.buttons["computers.sendText"]
        XCTAssertTrue(row.waitForExistence(timeout: 90), "the Send text row, once a computer is paired")
        XCTAssertTrue(row.label.contains("Send text to your computer"), row.label)
        row.tap()
        let done = app.buttons["clips.done"]
        if !done.waitForExistence(timeout: 5) {
            // The first tap can land while the screen is still sliding up.
            row.tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Send text opens")

        let field = app.descendants(matching: .any)["clips.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the text field\n" + app.debugDescription)
        let send = app.buttons["clips.send"]
        XCTAssertFalse(send.isEnabled, "nothing to send yet")
        XCTAssertTrue(app.descendants(matching: .any)["clips.paste"].exists, "the system paste button")
        XCTAssertTrue(app.staticTexts["clips.destination"].label.contains("Goes to UI test box"),
                      app.staticTexts["clips.destination"].label)
        field.tap()
        field.typeText("Build 42 is ready")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let clip = app.descendants(matching: .any).matching(identifier: "clips.row").firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 5), "the clip is listed at once")
        XCTAssertTrue(clip.label.contains("Build 42 is ready"), clip.label)
        // Nobody answers at that address: after the connection gives up, it waits.
        let waiting = expectation(for: NSPredicate(format: "label CONTAINS 'Waiting for UI test box'"), evaluatedWith: clip)
        wait(for: [waiting], timeout: 120)
        let message = app.staticTexts["clips.message"]
        let told = expectation(for: NSPredicate(format: "label CONTAINS 'could not reach UI test box'"), evaluatedWith: message)
        wait(for: [told], timeout: 60)
        XCTAssertTrue(message.label.contains("goes with the next sync"), message.label)
        XCTAssertFalse(app.buttons["clips.clear"].exists, "nothing was sent, so there is nothing to clear")

        // Still queued after Zone is quit and opened again, and the row says so.
        app.terminate()
        app = launch(["-zoneLinkComputers"], forget: false)
        let again = app.buttons["computers.sendText"]
        XCTAssertTrue(again.waitForExistence(timeout: 30))
        XCTAssertTrue(again.label.contains("1 text is waiting for a computer"), again.label)
        again.tap()
        let kept = app.descendants(matching: .any).matching(identifier: "clips.row").firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 10))
        XCTAssertTrue(kept.label.contains("Build 42 is ready"), kept.label)

        // Removing it takes it off the phone; nothing is left to send.
        kept.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(kept.waitForNonExistence(timeout: 5))
        app.buttons["clips.done"].tap()
        let cleared = expectation(for: NSPredicate(format: "NOT (label CONTAINS 'waiting')"), evaluatedWith: again)
        wait(for: [cleared], timeout: 5)
    }
}
