// by zayd/cold @ zayd.wtf

import XCTest

/// Settings destinations remain reachable in the order shown on the phone.
final class SettingsOrderUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version]
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func openSettings(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + arguments
        app.launch()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings")
        return app
    }

    /// Kept in the result bundle, so a run shows the screen it checked.
    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func above(_ upper: XCUIElement, _ lower: XCUIElement, _ message: String) {
        XCTAssertTrue(upper.exists && lower.exists, message)
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, message)
    }

    func testFasterDictationHelp() { checkSpeechHelp() }

    func testSearchByNameAndSubjectAndClear() {
        let app = openSettings()
        let field = app.textFields["settings.search"]
        for (term, result) in [("cursor", "settings.keyboard"), ("1st, 2nd, 3rd", "settings.numbers"),
                               ("clock", "settings.island"), ("WHAT'S NEW", "settings.help")] {
            field.tap()
            field.typeText(term)
            XCTAssertTrue(app.buttons[result].waitForExistence(timeout: 5), term)
            if term == "clock" { XCTAssertFalse(app.buttons["settings.meetingAppearance"].exists) }
            app.buttons["Clear search"].tap()
        }
        field.typeText("not-a-real-setting")
        XCTAssertTrue(app.staticTexts["No matching settings"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.buttons["settings.keyboard"].exists)
        let numbers = app.buttons["settings.numbers"]
        // Clear keeps typing focus. Reveal the restored row below the keyboard and open it.
        reveal(numbers, in: app)
        numbers.tap()
        XCTAssertTrue(app.navigationBars["Numbers"].waitForExistence(timeout: 5))
    }

    func testFasterDictationHelpAtLargestTextSize() {
        checkSpeechHelp(size: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func checkSpeechHelp(size: String? = nil) {
        let app = XCUIApplication()
        app.launchArguments = settled
        if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        app.launch()
        app.buttons["home.settings"].tap()
        let options = app.buttons["settings.dictationOptions"]
        for _ in 0..<8 where !options.isHittable { app.swipeUp() }
        options.tap()
        let info = app.buttons["About Speed up speech in Zone"]
        for _ in 0..<16 where !info.isHittable { app.swipeUp() }
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(info.frame.height + 1e-9, 44, "Allow for fractional screen coordinate rounding")
        keepScreenshot(size == nil ? "speech-speed-row" : "speech-speed-row-largest")
        info.tap()
        let details = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "No boost while locked")).firstMatch
        for _ in 0..<8 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.waitForExistence(timeout: 8))
        keepScreenshot(size == nil ? "speech-speed-help" : "speech-speed-help-largest")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.switches["Speed up speech in Zone"].exists)
    }

    func testHomeOffAndHistoryDetail() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zone.settings.autoArm", "<false/>", "-zoneFakeSpeech", "Hello",
                                         "-zoneHomeMode", "transcribe", "-zoneLinkSeed", "12",
                                         "-zone.settings.clipboardHistory", "NO"]
        app.launch()
        let off = app.buttons["Turn off"]
        if off.waitForExistence(timeout: 2) { off.tap() }
        let standby = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Standby off")).firstMatch
        XCTAssertTrue(standby.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Turn on for an instant start and live words."].waitForExistence(timeout: 15))
        keepScreenshot("home-standby-off")
        app.buttons["History"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("dentist")
        let row = app.buttons.matching(identifier: "library.row")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "call the dentist")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "call the dentist")).firstMatch.exists)
        let copy = app.buttons["record.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        keepScreenshot("dictation-detail")
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
        app.buttons["record.delete"].tap()
        XCTAssertTrue(app.buttons["Delete dictation"].exists)
    }

    func testPersonalizeControlsAndMeetingAppearance() {
        let app = openSettings(["-zone.settings.meterStyle", "bars", "-zone.settings.micLightStyle", "glow"])
        let voice = app.buttons["settings.voiceGraphic"]
        // A full flick can skip the entire picker on the SE. Stop the drag before lifting.
        func reveal(_ row: XCUIElement) {
            let viewport = app.frame.insetBy(dx: 0, dy: 75)
            for _ in 0..<24 {
                let frame = row.exists ? row.frame : .null
                if !frame.isNull, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)), row.isHittable { return }
                let distance: CGFloat = !frame.isNull && frame.midY < viewport.minY ? 190 : -190
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.56))
                start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                            withVelocity: .slow, thenHoldForDuration: 0.25)
            }
            XCTFail("Could not bring the setting into view: \(row)")
        }
        reveal(voice)
        voice.tap()
        let scope = app.buttons["Hex"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let preview = app.descendants(matching: .any)["settings.voicePreview"]
        XCTAssertEqual(preview.value as? String, "Hex")
        let micLight = app.buttons["settings.micLight"]
        reveal(micLight)
        micLight.tap()
        app.buttons["Clear edge"].tap()
        XCTAssertEqual(micLight.value as? String, "Clear edge")
        micLight.tap()
        app.buttons["Glow"].tap()
        // The credit is the Personalize footer, below the inline accent rows; Form builds it on screen only.
        let credit = app.buttons["About Hex"]
        reveal(credit)
        XCTAssertTrue(credit.exists)
        credit.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Oscilloscope by Christopher Langton'")).firstMatch.exists)
        app.buttons["Done"].tap()
        let meeting = app.buttons["settings.meetingAppearance"]
        reveal(meeting)
        meeting.tap()
        XCTAssertTrue(app.navigationBars["Meeting appearance"].waitForExistence(timeout: 8))
        app.buttons["nav.back"].tap()
        XCTAssertTrue(app.buttons["settings.island"].exists)
        keepScreenshot("settings-personalize")
    }

    @MainActor
    func testKeyboardRecordingCanBeTurnedOffAcrossLaunches() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("The recording option requires iOS 26") }

        func micSwitch() -> XCUIElement {
            let app = openSettings()
            app.buttons["settings.keyboard"].tap()
            let toggle = app.switches["keyboard.dictatesInKeyboard"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            return toggle
        }

        func set(_ toggle: XCUIElement, to value: String) {
            if toggle.value as? String != value {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, value)
        }

        let toggle = micSwitch()
        let original = try XCTUnwrap(toggle.value as? String)
        defer { set(micSwitch(), to: original) }
        set(toggle, to: "1")
        set(toggle, to: "0")
        let reopened = micSwitch()
        XCTAssertEqual(reopened.value as? String, "0")
        keepScreenshot("keyboard-recording-off")
    }

    func testFullAccessPrecedesKeyboardMicAndNamesLiveInMyWords() {
        let app = openSettings(["-zone.settings.dictatesInKeyboard", "<true/>",
                                "-zone.settings.neverAppleSpeech", "<false/>"])
        app.buttons["settings.keyboard"].tap()
        if #available(iOS 26, *) {
            let mic = app.switches["keyboard.dictatesInKeyboard"]
            XCTAssertTrue(mic.waitForExistence(timeout: 5))
            above(app.staticTexts["Full Access"], mic, "Permission comes before the keyboard mic")
            let model = app.switches["keyboard.neverAppleSpeech"]
            let download = app.buttons["Download Apple’s fallback speech model"]
            above(mic, model, "Model policy follows keyboard recording")
            above(model, download, "The fallback download is beside its policy")
            let thumb = model.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
            thumb.tap()
            XCTAssertFalse(download.exists)
            thumb.tap()
            XCTAssertTrue(download.exists)
        }
        keepScreenshot("keyboard-settings")
        app.navigationBars.buttons.firstMatch.tap()
        let words = app.buttons["My words"]
        reveal(words, in: app)
        words.tap()
        let names = app.switches["Learn names"]
        XCTAssertTrue(names.waitForExistence(timeout: 5))
        above(app.switches["Learn from corrections"], names, "Learning switches first")
        let field = app.descendants(matching: .any)["words.field"].firstMatch
        above(names, field, "Learning before adding words")
        let handles = app.buttons["Saved @handles"]
        reveal(handles, in: app)
        above(field, handles, "Words before handles")
        let transfer = app.buttons["Import or export words"]
        reveal(transfer, in: app)
        above(handles, transfer, "Transfer follows handles")
        XCTAssertEqual(app.cells.allElementsBoundByIndex.last?.buttons.firstMatch.label, "Import or export words")
    }

    func testMeetingPreviewDevelopmentControl() {
        let app = XCUIApplication()
        app.launchArguments = settled
        app.launch()
        let meeting = app.buttons["Meeting"]
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        meeting.tap()
        app.buttons["Meeting appearance"].tap()
        XCTAssertTrue(app.navigationBars["Meeting appearance"].waitForExistence(timeout: 5))
        let rollover = app.buttons["Hour rollover"]
        #if DEBUG
        for _ in 0..<6 where !rollover.isHittable { app.swipeUp() }
        XCTAssertTrue(rollover.isHittable)
        #else
        XCTAssertFalse(rollover.exists)
        #endif
    }

    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !row.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.isHittable, row.debugDescription)
    }

    func testSearchFindsKeyboardControls() {
        let app = openSettings()
        let search = app.textFields["settings.search"]
        if !search.isHittable { app.swipeDown() }
        search.tap()
        search.typeText("cursor")
        let result = app.buttons["settings.keyboard"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        reveal(app.buttons["keyboard.spaceHold"], in: app)
    }

    func testSpaceBarChoicesAndTaggingAreOnTheFirstScreen() {
        let app = openSettings()
        app.buttons["settings.keyboard"].tap()
        let picker = app.buttons["keyboard.spaceHold"]
        reveal(picker, in: app)
        let originalTalk = picker.label.contains("Talk (Beta)") || picker.value as? String == "Talk (Beta)"
        let other = originalTalk ? "Move cursor" : "Talk (Beta)"
        picker.tap()
        app.buttons[other].tap()
        XCTAssertTrue(picker.label.contains(other) || picker.value as? String == other)
        picker.tap()
        app.buttons[originalTalk ? "Talk (Beta)" : "Move cursor"].tap()

        app.buttons["nav.back"].tap()
        let tagging = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "tag names")).firstMatch
        XCTAssertTrue(tagging.isHittable)
        app.buttons["About Name tagging"].tap()
        let meaning = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", "tagging on", "words stay plain", "always writes @kevin")).firstMatch
        XCTAssertTrue(meaning.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let original = tagging.value as? String
        let thumb = tagging.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        thumb.tap()
        XCTAssertNotEqual(tagging.value as? String, original)
        thumb.tap()
        XCTAssertEqual(tagging.value as? String, original)
    }

    func testTalkHintExplainsWhenStandbyIsNeeded() {
        for local in [false, true] {
            let app = openSettings(["-zone.settings.spaceHold", "talk",
                                    "-zone.settings.dictatesInKeyboard", local ? "<true/>" : "<false/>"])
            app.buttons["settings.keyboard"].tap()
            let info = app.buttons["About Hold to talk"]
            reveal(info, in: app)
            info.tap()
            let hint = "Hold to talk, let go to insert. Slide sideways to move the cursor."
            let canRecord: Bool
            if #available(iOS 26, *) { canRecord = local } else { canRecord = false }
            XCTAssertTrue(app.staticTexts[canRecord ? hint : hint + " Works while Standby is on."].exists)
        }
    }

    func testRecorderPreviewNamesItsShippingColor() {
        let app = openSettings(["-zone.settings.islandLook", "recorder", "-zone.settings.islandPalette", "accent",
                                "-zone.settings.islandWhileReady", "<true/>"])
        let island = app.buttons["settings.island"]
        reveal(island, in: app)
        island.tap()
        let preview = app.descendants(matching: .any)["Dynamic Island preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Recorder, Recorder red")
    }

    func testEverydaySettingsPrecedeComputers() {
        let app = openSettings()
        keepScreenshot("settings-top")
        let microphone = app.buttons["Microphone and timing"]
        let options = app.buttons["settings.dictationOptions"]
        XCTAssertEqual(microphone.label, "Microphone and timing")
        XCTAssertEqual(options.label, "Dictation options")
        for row in [microphone, options] { XCTAssertTrue((row.value as? String ?? "").isEmpty) }
        above(app.buttons["settings.keyboard"], microphone, "Keyboard comes before dictation")
        for row in [app.buttons["My words"], app.buttons["settings.voiceGraphic"], app.buttons["settings.computers"]] {
            reveal(row, in: app)
        }
        app.buttons["settings.computers"].tap()
        XCTAssertTrue(app.navigationBars["Computers"].waitForExistence(timeout: 10))
    }

    func testDataAndHelpPrecedeAboutWithCreditsLast() {
        let app = openSettings()
        let data = app.buttons["settings.yourData"]
        reveal(app.buttons["settings.about"], in: app)
        above(app.buttons["Share Zone with a friend"], data, "Share before data")
        above(data, app.buttons["settings.help"], "Data before help")
        above(app.buttons["settings.help"], app.buttons["settings.about"], "About last")
        data.tap()
        above(app.buttons["Dictation history"], app.buttons["settings.clipboard"], "Dictations before copies")
        above(app.buttons["settings.clipboard"], app.buttons["Backup and export"], "Copies before backup")
        above(app.buttons["Backup and export"], app.buttons["Delete data"], "Backup before deletion")
        let dataHelp = app.buttons["About Your data"]
        for _ in 0..<4 where !dataHelp.isHittable { app.swipeDown() }
        XCTAssertTrue(dataHelp.isHittable)
        dataHelp.tap()
        XCTAssertTrue(app.staticTexts["Stored on this iPhone. Back up to Files, or pair a computer in Settings > Computers."].exists
                      || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Dictations, notes and meeting transcripts go to'")).firstMatch.exists,
                      "the Your data explanation")
        app.buttons["Done"].tap()
        app.buttons["nav.back"].tap()
        app.buttons["settings.help"].tap()
        for label in ["Take the tour", "Send feedback", "What’s New", "Recording log", "Diagnostics"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), label)
        }
        app.buttons["nav.back"].tap()
        app.buttons["settings.about"].tap()
        above(app.buttons["settings.version"], app.buttons["Privacy"], "Version first")
        keepScreenshot("settings-about")
        above(app.buttons["settings.version"], app.buttons["Acknowledgments"], "Credits end About")
        app.buttons["Acknowledgments"].tap()
        XCTAssertTrue(app.staticTexts["Swipe typing powered by FUTO Swipe."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Words, emoji and other credits"].exists)
    }

    func testSettingsPagesInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = openSettings(["-zone.settings.appearance", appearance])
            keepScreenshot("pass-\(appearance)-settings-top")
            for (identifier, name, title) in [("settings.keyboard", "keyboard", "Zone keyboard"),
                                               ("settings.textStyle", "text-style", "Text style"),
                                               ("My words", "my-words", "My words"),
                                               ("Microphone and timing", "microphone", "Microphone and timing"),
                                               ("settings.island", "island", "Dynamic Island"),
                                               ("settings.help", "help", "Help"),
                                               ("settings.about", "about", "About")] {
                let row = app.buttons[identifier]
                reveal(row, in: app)
                if identifier == "settings.island" { keepScreenshot("pass-\(appearance)-personalize") }
                if identifier == "settings.about" {
                    app.swipeUp()
                    XCTAssertLessThanOrEqual(row.frame.maxY, app.frame.maxY)
                    keepScreenshot("pass-\(appearance)-settings-bottom")
                }
                row.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
                keepScreenshot("pass-\(appearance)-\(name)")
                if name == "microphone" {
                    let info = app.buttons["About Finish when quiet"]
                    reveal(info, in: app)
                    info.tap()
                    XCTAssertTrue(app.staticTexts["5 seconds works for most people."].waitForExistence(timeout: 5))
                    app.buttons["Done"].tap()
                }
                app.buttons["nav.back"].tap()
            }
        }
    }
}
