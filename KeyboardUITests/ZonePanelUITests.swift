// by zayd/cold @ zayd.wtf

import XCTest

/// Uses the installed extension in a UITextView. The simulator's keyboard list must include Zone
/// (`defaults write -g AppleKeyboards -array wtf.zayd.zone.keyboard "en_US@sw=QWERTY;hw=Automatic"`);
/// every launch then picks Zone inside the host itself, because iOS remembers the last keyboard per app
/// and XCTest relaunches the host for each test.
final class ZonePanelUITests: XCTestCase {
    private let host = XCUIApplication()
    private let zone = XCUIApplication(bundleIdentifier: "wtf.zayd.zone")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZONE_PANEL_E2E"] == "1",
                          "Requires Zone installed and selected as the simulator keyboard")
    }

    /// The device driver stages one synthetic retry WAV immediately before this check.
    /// Its recording ID and the engine that actually recognized it are verified in the journal.
    func testRealKeyboardInsertsTheRecoveredSpeechFixture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZONE_SPEECH_REPLAY"] == "1")
        if ProcessInfo.processInfo.environment["ZONE_PRELAUNCHED_HOST"] == "1" {
            XCTAssertTrue(host.wait(for: .runningForeground, timeout: 40))
        } else {
            host.launchArguments = ["--apple-oracle"]
            host.launch()
        }
        selectZoneKeyboard()
        let insert = host.buttons["Insert dictation"]
        let field = host.textViews["oracle"]
        let hasWords = NSPredicate(format: "value CONTAINS[c] %@ AND value CONTAINS[c] %@", "Kevin", "Thursday")
        let spoken = NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Kevin", "Thursday")
        let pendingText = host.staticTexts.matching(spoken).firstMatch
        if insert.waitForExistence(timeout: 28), pendingText.exists {
            tapKey(insert)
        } else if !hasWords.evaluate(with: field) {
            let recent = host.buttons["keyboard.recent"]
            XCTAssertTrue(recent.waitForExistence(timeout: 8))
            tapKey(recent)
            let tab = host.buttons["Dictations"]
            if tab.exists { tapKey(tab) }
            let sample = host.buttons.matching(spoken).firstMatch
            XCTAssertTrue(sample.waitForExistence(timeout: 12))
            tapKey(sample)
        }
        let result = XCTNSPredicateExpectation(predicate: hasWords, object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 6), .completed)
    }

    // Device-only verification of the installed app, opened by CoreDevice at zone://settings.
    func testInstalledKeyboardRecognitionSavesItsLocalSelection() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZONE_VERIFY_SETTINGS"] == "1")
        XCTAssertTrue(zone.wait(for: .runningForeground, timeout: 45))
        let keyboard = zone.descendants(matching: .any)["settings.keyboard"].firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        keyboard.tap()
        let recognition = zone.buttons["Keyboard recognition"]
        for _ in 0..<8 where !recognition.isHittable { zone.swipeUp() }
        XCTAssertTrue(recognition.isHittable)
        recognition.tap()
        XCTAssertTrue(zone.staticTexts["Model downloaded"].waitForExistence(timeout: 6))
        let save = zone.buttons["Save recognition settings"]
        for _ in 0..<4 where !save.isHittable { zone.swipeUp() }
        XCTAssertTrue(save.isEnabled && save.isHittable)
        save.tap()
        XCTAssertTrue(zone.staticTexts["Saved."].waitForExistence(timeout: 6))
    }

    private func launch(_ fixture: String) {
        host.launchArguments = ["--apple-oracle", "--zone-panel-fixture", fixture]
        host.launch()
        selectZoneKeyboard()
    }

    /// Presses of Next keyboard before giving up: Zone, Apple's English, emoji and one spare.
    private static let keyboardSwitchLimit = 6

    /// Zone's keys are showing: the Z, or the fold control a recording fixture shows instead.
    private func zoneKeyboardAppears(within timeout: TimeInterval) -> Bool {
        let markers = ["keyboard.home", "Hide keys", "Show keys"].map { host.buttons[$0] }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if markers.contains(where: \.exists) { return true }
            _ = markers[0].waitForExistence(timeout: 0.25)
        } while Date() < deadline
        return false
    }

    /// The keyboard on screen, for the failure message.
    private func keyboardDescription() -> String {
        if host.keys["q"].exists || host.keys["Q"].exists { return "Apple's letter keyboard" }
        if host.keyboards.firstMatch.exists { return "another keyboard (\(host.keyboards.firstMatch.label))" }
        return "no keyboard"
    }

    /// iOS keeps the keyboard each app used last, so choosing Zone in Messages or in an earlier
    /// run does not carry into a freshly launched host. Press Next keyboard until Zone's keys appear.
    private func selectZoneKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        if zoneKeyboardAppears(within: 4) {
            print("ZonePanelUITests: Zone keyboard already selected")
            return
        }
        let field = host.textViews["oracle"]
        if !host.keyboards.firstMatch.exists, field.exists { field.tap() }
        var seen: [String] = []
        for press in 1...Self.keyboardSwitchLimit {
            let next = host.buttons["Next keyboard"]
            guard next.waitForExistence(timeout: 4) else {
                capture("Keyboard selection")
                XCTFail("""
                    Zone's keyboard is not showing in KeyboardTestHost and there is no Next keyboard key \
                    (showing \(keyboardDescription()) after \(press - 1) presses). Install the Zone.app under \
                    test and add wtf.zayd.zone.keyboard to the simulator's AppleKeyboards list.
                    """, file: file, line: line)
                return
            }
            seen.append(keyboardDescription())
            print("ZonePanelUITests: pressing Next keyboard over \(seen.last ?? "")")
            tapKey(next)
            if zoneKeyboardAppears(within: 4) {
                print("ZonePanelUITests: Zone keyboard selected after \(press) Next keyboard press(es)")
                return
            }
        }
        capture("Keyboard selection")
        XCTFail("""
            Zone's keyboard did not appear in KeyboardTestHost after \(Self.keyboardSwitchLimit) presses \
            of Next keyboard (saw: \(seen.joined(separator: ", "))). Check that wtf.zayd.zone.keyboard is \
            in the simulator's AppleKeyboards list and that the installed Zone.app embeds ZoneKeyboard.appex.
            """, file: file, line: line)
    }

    // On iOS 26 the remote keyboard sometimes reports extension-local frames to XCTest.
    // Its host container still has a screen frame and an equal-sized child at (0, 0).
    private func screenFrame(_ element: XCUIElement) -> CGRect {
        let frame = element.frame
        let hostFrame = host.frame
        let halfway = hostFrame.midY
        guard frame.midY < halfway else { return frame }
        func origin(in node: any XCUIElementSnapshot) -> CGPoint? {
            for child in node.children {
                if node.frame.minY > halfway, child.frame.origin == .zero,
                   child.frame.size == node.frame.size, child.frame.width == hostFrame.width {
                    return node.frame.origin
                }
                if let found = origin(in: child) { return found }
            }
            return nil
        }
        guard let snapshot = try? host.snapshot(), let offset = origin(in: snapshot) else {
            XCTFail("Missing screen-space container for keyboard control: \(element.label)")
            return frame
        }
        return frame.offsetBy(dx: offset.x, dy: offset.y)
    }

    private func tapKey(_ key: XCUIElement) {
        let frame = screenFrame(key)
        host.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    private func openPanel() {
        let brand = host.buttons["keyboard.home"]
        XCTAssertTrue(brand.waitForExistence(timeout: 15))
        tapKey(brand)
        XCTAssertTrue(host.buttons["Home"].waitForExistence(timeout: 5))
    }

    private func reveal(_ button: XCUIElement, towardStart: Bool = false) {
        let panel = host.scrollViews["keyboard.zonePanel"]
        for attempt in 0..<12 {
            let visible = screenFrame(panel).intersection(host.frame)
            var scrollBack = towardStart
            if button.exists {
                let target = screenFrame(button)
                if visible.insetBy(dx: 0, dy: 2).contains(CGPoint(x: target.midX, y: target.midY)) { return }
                scrollBack = target.midY < visible.minY + 2
            }
            // The extension's own scroll view can also report keyboard-local coordinates.
            let origin = host.coordinate(withNormalizedOffset: .zero)
            // Start over a tile. The middle of a two-column layout is the gap between
            // tiles, and iOS also reserves the bottom edge of the keyboard for gestures.
            // Vary the starting row to avoid repeatedly hitting a separator after scrolling.
            let x = visible.minX + visible.width * 0.37
            let startFraction = [0.60, 0.72, 0.84][attempt % 3]
            let start = origin.withOffset(CGVector(dx: x, dy: visible.minY + visible.height * startFraction))
            let end = origin.withOffset(CGVector(dx: x, dy: visible.minY + visible.height * 0.11))
            (scrollBack ? end : start).press(forDuration: 0.1, thenDragTo: scrollBack ? start : end,
                                             withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("Missing panel button: \(button)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Accessibility can find a perfectly tappable menu button even when the glyph inside is blank.
    func testMenuMarkRendersInsideTheTypingKeyboard() throws {
        launch("idle type")
        let key = host.buttons["keyboard.home"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        let frame = screenFrame(key)
        let image = XCUIScreen.main.screenshot().image
        let scale = CGFloat(try XCTUnwrap(image.cgImage).width) / image.size.width
        let center = CGRect(x: frame.midX - 9, y: frame.midY - 11, width: 18, height: 22)
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: center.applying(
            CGAffineTransform(scaleX: scale, y: scale)).integral))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let bitmap = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            bitmap.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        capture("Zone typing keyboard")
        let coloredPixels = stride(from: 0, to: pixels.count, by: 4).filter { index in
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            return max(r, g, b) - min(r, g, b) > 30
        }
        XCTAssertGreaterThan(coloredPixels.count, Int(8 * scale * scale), "The Z must draw colored ink inside the neutral menu key")
        openPanel()
    }

    /// The accessory's bottom marks the host's keyboard glass. The Z and Q belong to the
    /// real extension. A displaced composer can change the first without moving either key.
    func testKeyboardGeometryAfterOpeningZoneAndReturningToTheSameField() throws {
        host.launchArguments = ["--apple-oracle", "--keyboard-accessory", "--zone-panel-fixture", "idle type"]
        host.launch()
        selectZoneKeyboard()

        func measure(_ name: String) throws -> (glass: CGFloat, strip: CGFloat, row: CGFloat) {
            let accessory = host.staticTexts["oracle.accessory"]
            let mark = host.buttons["keyboard.home"]
            let q = host.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", "q")).firstMatch
            XCTAssertTrue(mark.waitForExistence(timeout: 8))
            XCTAssertTrue(accessory.waitForExistence(timeout: 8))
            XCTAssertTrue(q.waitForExistence(timeout: 8))
            let glassTop = screenFrame(accessory).maxY
            let stripTop = screenFrame(mark).minY
            let firstRowTop = screenFrame(q).minY
            XCTAssertGreaterThan(glassTop, host.frame.midY)
            XCTAssertGreaterThan(firstRowTop, stripTop)
            let metrics = XCTAttachment(string: """
                Host accessory bottom / glass top: \(glassTop) pt
                Extension Z hit target top: \(stripTop) pt
                Extension Q cap top: \(firstRowTop) pt
                Glass to Z: \(stripTop - glassTop) pt
                Z to Q: \(firstRowTop - stripTop) pt
                """)
            metrics.name = name + " geometry"
            metrics.lifetime = .keepAlways
            add(metrics)
            capture(name)
            return (glassTop, stripTop, firstRowTop)
        }

        let before = try measure("Before Zone opens")
        openPanel()
        tapKey(host.buttons["Home"])
        XCTAssertTrue(zone.wait(for: .runningForeground, timeout: 15))
        host.activate()
        host.textViews["oracle"].tap()
        selectZoneKeyboard()
        let after = try measure("After returning to the same field")
        // iOS owns the accessory. Keep the measured delta alongside the two images:
        // a 17 pt move also occurs with a minimal non-Zone keyboard on this simulator.
        let hostDelta = XCTAttachment(string: "Host accessory bottom moved by \(after.glass - before.glass) pt")
        hostDelta.name = "Host accessory movement"
        hostDelta.lifetime = .keepAlways
        add(hostDelta)
        XCTAssertEqual(after.row - after.strip, before.row - before.strip, accuracy: 1,
                       "The keyboard's own spacing changed between the strip and first row.")
        XCTAssertEqual(after.strip, before.strip, accuracy: 1, "The typing strip moved after the app round trip.")
        XCTAssertEqual(after.row, before.row, accuracy: 1, "The first key row moved after the app round trip.")
    }

    func testOpenCloseStylesAndHandoffs() {
        zone.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                                "-zoneWhatsNewAfter", "1.0.6"]
        zone.launch()
        launch("idle dictate")
        capture("Keyboard with the Zone menu key")
        openPanel()
        capture("Zone menu")
        XCTAssertTrue(host.buttons["Notes"].exists)
        let brand = host.buttons["keyboard.home"]
        XCTAssertTrue(brand.isSelected)
        tapKey(brand)
        XCTAssertFalse(host.buttons["Home"].exists)
        openPanel()
        let formal = host.buttons["Formal. style"]
        reveal(formal)
        tapKey(formal)
        openPanel()
        reveal(formal)
        XCTAssertTrue(formal.isSelected)
        let settings = host.buttons["Settings"]
        reveal(settings, towardStart: true)
        capture("Zone menu settings")
        tapKey(settings)
        XCTAssertTrue(zone.navigationBars["Settings"].waitForExistence(timeout: 15))

        for destination in ["Notes", "Home"] {
            host.activate()
            host.textViews["oracle"].tap()
            selectZoneKeyboard() // coming back from Zone can bring the list's first keyboard back
            openPanel()
            tapKey(host.buttons[destination])
            if destination == "Notes" {
                XCTAssertTrue(zone.navigationBars["Notes"].waitForExistence(timeout: 15))
            } else {
                XCTAssertTrue(zone.buttons["History"].waitForExistence(timeout: 15))
                XCTAssertFalse(zone.navigationBars["Notes"].exists)
            }
        }
    }

    private func revealControlsIfTabbed() {
        let tab = host.buttons["keyboard.controlsTab"]
        if tab.exists && !tab.isSelected {
            reveal(tab, towardStart: true)
            tapKey(tab)
        }
    }

    func testQuietGraphicAndSpaceHoldSurviveReopeningTheMenu() throws {
        launch("idle type")
        openPanel()
        revealControlsIfTabbed()
        func waitForValue(_ button: XCUIElement, _ value: String) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed, button.identifier)
        }
        for (id, first, second) in [("quickQuiet", "Off", "5 s"), ("quickGraphic", "Transcription Hero", "Bars")] {
            let tile = host.buttons["keyboard." + id]
            reveal(tile)
            let original = try XCTUnwrap(tile.value as? String)
            for choice in [original == first ? second : first, original] {
                tapKey(tile)
                let option = host.buttons[choice]
                reveal(option)
                tapKey(option)
                waitForValue(tile, choice)
                tapKey(host.buttons["keyboard.home"])
                openPanel()
                revealControlsIfTabbed()
                reveal(tile)
                XCTAssertEqual(tile.value as? String, choice)
            }
        }
        let hold = host.buttons["keyboard.quickHold"]
        reveal(hold)
        let original = try XCTUnwrap(hold.value as? String)
        tapKey(hold)
        waitForValue(hold, original == "Move cursor" ? "Talk (Beta)" : "Move cursor")
        tapKey(hold)
        waitForValue(hold, original)
    }

    func testCustomQuietChoiceSurvivesOffAndOn() {
        zone.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                                "-zoneWhatsNewAfter", "1.0.6", "-zone.settings.finishWhenQuiet", "YES",
                                "-zone.settings.finishWhenQuietWait", "8"]
        zone.launch()
        launch("idle type")
        openPanel()
        revealControlsIfTabbed()
        let quiet = host.buttons["Finish when quiet"]
        reveal(quiet)
        XCTAssertEqual(quiet.value as? String, "8 s")
        tapKey(quiet)
        let custom = host.buttons["8 s"]
        reveal(custom)
        XCTAssertTrue(custom.isSelected)
        capture("Quiet with a custom wait")
        let off = host.buttons["Off"]
        reveal(off)
        tapKey(off)
        reveal(quiet)
        XCTAssertEqual(quiet.value as? String, "Off")
        tapKey(quiet)
        reveal(custom)
        tapKey(custom)
        reveal(quiet)
        XCTAssertEqual(quiet.value as? String, "8 s")
    }

    func testKeyboardSoundChoiceAppearsInAppSettings() {
        zone.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                                "-zoneWhatsNewAfter", "1.0.6"]
        zone.launch()
        launch("idle type")
        openPanel()
        revealControlsIfTabbed()
        let sounds = host.buttons["keyboard.quickSounds"]
        reveal(sounds)
        let original = sounds.value as? String
        XCTAssertTrue(["On", "Off"].contains(original ?? ""))
        tapKey(sounds)
        let expected = original == "On" ? "Off" : "On"
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: sounds)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 6), .completed)
        let settings = host.buttons["Settings"]
        reveal(settings, towardStart: true)
        tapKey(settings)
        XCTAssertTrue(zone.navigationBars["Settings"].waitForExistence(timeout: 15))
        zone.buttons["settings.keyboard"].tap()
        let feedback = zone.buttons["settings.soundsAndHaptics"]
        for _ in 0..<8 where !feedback.exists || !feedback.isHittable { zone.swipeUp() }
        feedback.tap()
        let toggle = zone.switches["Start and stop sounds"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, expected == "On" ? "1" : "0")
        toggle.tap() // Restore the original sound preference through the app.
    }

    func testFoldWhileRecording() {
        launch("listening type")
        let fold = host.buttons["Hide keys"]
        XCTAssertTrue(fold.waitForExistence(timeout: 15))
        XCTAssertTrue(host.buttons["Pause recording"].waitForExistence(timeout: 10))
        capture("Recording above the keys")
        tapKey(fold)
        XCTAssertTrue(host.buttons["Show keys"].waitForExistence(timeout: 5))
        XCTAssertTrue(host.buttons["Pause recording"].exists)
        XCTAssertTrue(host.buttons["Stop"].exists) // the capture key while recording (56cad089 renamed it from Done)
        let show = screenFrame(host.buttons["Show keys"])
        let cancel = screenFrame(host.buttons["Cancel dictation"])
        XCTAssertEqual(show.midY, cancel.midY, accuracy: 2)
        XCTAssertEqual(show.maxX, cancel.minX, accuracy: 8)
        capture("Folded recording")
        tapKey(host.buttons["Show keys"])
        XCTAssertTrue(fold.waitForExistence(timeout: 5))
        tapKey(host.buttons["Cancel dictation"])
        XCTAssertTrue(host.buttons["Tap again to discard the recording"].exists)
    }
}
