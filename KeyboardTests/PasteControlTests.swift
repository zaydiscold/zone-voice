// by zayd/cold @ zayd.wtf

import SwiftUI
import XCTest
import UniformTypeIdentifiers
@testable import ZoneCore

/// The system paste button's hand-off: text arrives after the tap, and only lands in the field
/// the tap was made in.
@MainActor final class PasteControlTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    private func make(_ p: Proxy) -> (KeyboardModel, PasteTarget) {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: false))
        return (m, PasteTarget(session: { m.currentSession }) { m.insertPasted($0) })
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    func testProviderTextIsInserted() async throws {
        let p = Proxy(), (_, target) = make(p)
        XCTAssertTrue(target.canPaste([NSItemProvider(object: "hello" as NSString)]))
        target.paste(itemProviders: [NSItemProvider(object: "hello" as NSString)])
        try await settle()
        XCTAssertEqual(p.text, "hello")
    }
    func testRichPastePrefersTextToItsPreviewWithHistoryOff() async throws {
        var inserted = ""
        let saving = PasteSaving(tap: { nil }, image: { _, _, _ in XCTFail("Preview replaced text") }, keep: { _, _, _ in })
        let target = PasteTarget(session: { "field" }, saving: saving) { inserted = $0 }
        let provider = NSItemProvider(object: "https://example.com" as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { done in
            done(Data(), nil)
            return nil
        }
        target.paste(itemProviders: [provider])
        try await settle()
        XCTAssertEqual(inserted, "https://example.com")
        for (type, content, expected) in [("public.rtf", #"{\rtf1\ansi hello}"#, "hello"),
                                          ("public.url", "https://example.org", "https://example.org")] {
            let text = NSItemProvider()
            if type == "public.url" {
                text.registerObject(URL(string: content)! as NSURL, visibility: .all)
            } else {
                text.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
                    done(Data(content.utf8), nil)
                    return nil
                }
            }
            target.paste(itemProviders: [NSItemProvider(object: UIImage()), text])
            try await settle()
            XCTAssertEqual(inserted.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func testUnavailableRichItemFallsBackToSeparatePlainSelection() async throws {
        let proxy = Proxy(), (_, target) = make(proxy)
        let rich = NSItemProvider()
        rich.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let words = "All of the selected text\nincluding the second line."
        target.paste(itemProviders: [rich, NSItemProvider(object: words as NSString)])
        try await settle()
        XCTAssertEqual(proxy.text, words)
    }

    func testEmptyStringFallsBackToURLOnTheSameProvider() async throws {
        let provider = NSItemProvider(object: "" as NSString)
        let address = try XCTUnwrap(URL(string: "https://example.org/clipboard"))
        provider.registerObject(address as NSURL, visibility: .all)
        XCTAssertTrue(provider.canLoadObject(ofClass: String.self))
        XCTAssertTrue(provider.canLoadObject(ofClass: URL.self))
        let delivered = await withCheckedContinuation { continuation in
            ClipboardPasteText.load(from: [provider]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(delivered, address.absoluteString)
    }

    func testFailedRichSelectionWithSourceURLStillPrefersLargePlainSelection() async throws {
        let link = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.org/source")) as NSURL)
        link.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { callback in
            callback(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let words = String(repeating: "𝄞 Full paragraphs, including line breaks.\n", count: 2048)
        let inserted = expectation(description: "the complete selection")
        let target = PasteTarget(session: { "original" }) { text in
            XCTAssertEqual(text.utf8.count, words.utf8.count)
            XCTAssertTrue(text == words)
            inserted.fulfill()
        }
        target.paste(itemProviders: [link, NSItemProvider(object: words as NSString)])
        await fulfillment(of: [inserted], timeout: 5)
        withExtendedLifetime(target) {}
    }

    func testFailedTextFallsBackToTheImageFromTheSamePaste() async throws {
        let provider = NSItemProvider(object: "" as NSString)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { callback in
            callback(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            callback(picture, nil)
            return nil
        }
        let saved = expectation(description: "one saved image")
        let token = ClipboardPasteToken(changeCount: 11, observedChangeCount: 11)
        let saving = PasteSaving(tap: { token }, image: { value, _, received in
            XCTAssertNotNil(value)
            XCTAssertEqual(received, token)
            saved.fulfill()
        }, keep: { _, _, _ in XCTFail("Empty text cannot replace the image") })
        let target = PasteTarget(session: { "field" }, saving: saving) { _ in XCTFail("Unexpected insertion") }
        let unavailablePreview = NSItemProvider()
        unavailablePreview.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            callback(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        target.paste(itemProviders: [unavailablePreview, provider])
        await fulfillment(of: [saved], timeout: 5)
        withExtendedLifetime(target) {}
    }

    func testFormattedSelectionWinsOverAnAccompanyingLink() async throws {
        let p = Proxy(), (_, target) = make(p)
        let selection = NSItemProvider()
        let body = #"{\rtf1 Text before the link.\par Text after the link.}"#
        selection.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { callback in
            callback(Data(body.utf8), nil)
            return nil
        }
        let link = NSItemProvider(object: URL(string: "https://example.com")! as NSURL)
        XCTAssertTrue(target.canPaste([selection]))
        target.paste(itemProviders: [link, selection])
        try await settle()
        XCTAssertTrue(p.text.contains("Text before the link."))
        XCTAssertTrue(p.text.contains("Text after the link."))
    }

    func testFormattedSelectionAndURLOnTheSameProvider() async throws {
        let p = Proxy(), (_, target) = make(p)
        let provider = NSItemProvider(object: URL(string: "https://example.org")! as NSURL)
        let body = #"{\rtf1 The entire selected passage.}"#
        provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { callback in
            callback(Data(body.utf8), nil)
            return nil
        }
        target.paste(itemProviders: [provider])
        try await settle()
        XCTAssertEqual(p.text.trimmingCharacters(in: .whitespacesAndNewlines), "The entire selected passage.")
    }

    func testLateTextIsDroppedAfterTheFieldChanges() async throws {
        let p = Proxy(), (_, target) = make(p)
        target.paste(itemProviders: [NSItemProvider(object: "hello" as NSString)])
        p.session = "b"
        try await settle()
        XCTAssertEqual(p.text, "")
    }
    func testEmptyAndNonTextProvidersInsertNothing() async throws {
        let p = Proxy(), (_, target) = make(p)
        target.paste(itemProviders: [NSItemProvider(object: "" as NSString)])
        target.paste(itemProviders: [NSItemProvider(object: UIImage())])
        XCTAssertFalse(target.canPaste([NSItemProvider(object: UIImage())]))
        try await settle()
        XCTAssertEqual(p.text, "")
    }
    func testPasteEndsTheWordInProgressWithoutCorrectingIt() async throws {
        let p = Proxy(), (m, target) = make(p)
        for character in "teh" { m.handleTap(.character(String(character))) }
        target.paste(itemProviders: [NSItemProvider(object: " x" as NSString)])
        try await settle()
        XCTAssertEqual(p.text, "teh x")
        m.handleTap(.space)
        XCTAssertEqual(p.text, "teh x ")
    }
}

@MainActor final class PasteKeyAppearanceTests: XCTestCase {
    private final class Touch: UITouch {
        let point: CGPoint
        init(_ point: CGPoint) { self.point = point; super.init() }
        override func location(in view: UIView?) -> CGPoint { point }
        override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    }

    private func makeGrid(width: CGFloat = 393) -> (SwipeIntegrationTests.Proxy, KeyboardModel, KeyGridView) {
        let proxy = SwipeIntegrationTests.Proxy()
        proxy.hasOpenAccess = true
        proxy.explicitDarkAppearance = false
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.refreshFullAccess(reloadVocabulary: false)
        model.apply(KeyboardPreferences(autocorrectEnabled: false, showsPasteKey: true))
        let grid = KeyGridView(model: model, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: width, height: 216)
        grid.sync()
        return (proxy, model, grid)
    }

    private func pasteControl(in grid: KeyGridView) -> UIPasteControl? {
        grid.subviews.compactMap { $0 as? UIPasteControl }.first { !$0.isHidden }
    }

    func testAppearanceChangeKeepsTheNativePasteControlInItsSlot() throws {
        let (proxy, model, grid) = makeGrid()
        defer { withExtendedLifetime(proxy) {} }
        grid.sync()
        let lightPaste = try XCTUnwrap(pasteControl(in: grid))
        let frame = lightPaste.frame
        capture(grid, name: "portrait-light")
        proxy.explicitDarkAppearance = true
        model.refreshTraits()
        grid.sync()
        capture(grid, name: "portrait-dark")
        // An invisible key must never fall through to the grid's clipboard handler.
        let point = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertFalse(grid.hitTest(point, with: nil) === grid)
        let darkPaste = try XCTUnwrap(pasteControl(in: grid), "Appearance can change without changing the grid geometry")
        XCTAssertEqual(darkPaste.frame, frame)
        XCTAssertTrue((grid.accessibilityElements ?? []).contains { ($0 as? UIView) === darkPaste })
        XCTAssertTrue(grid.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === darkPaste)
    }

    func testCancelledBottomRowTouchRestoresTheKeyFace() throws {
        let (proxy, model, grid) = makeGrid()
        defer { withExtendedLifetime(proxy) {} }
        proxy.explicitDarkAppearance = true
        model.refreshTraits()
        grid.sync()
        // Start from a fresh layout so the native Paste control is present on the old code too.
        grid.frame.size.width += 1
        grid.sync()
        let frame = try XCTUnwrap(pasteControl(in: grid)).frame
        let keyLayers = try XCTUnwrap(grid.layer.sublayers?.flatMap { $0.sublayers ?? [] })
        let returnFace = try XCTUnwrap(keyLayers.first { !$0.isHidden && $0.frame.midY == frame.midY && $0.frame.minX >= frame.maxX })
        let paste = try XCTUnwrap(pasteControl(in: grid))
        XCTAssertFalse(paste.isHighlighted)
        capture(grid, name: "bottom-row-dark-at-rest")
        let base = returnFace.backgroundColor
        let touch = Touch(CGPoint(x: returnFace.frame.midX, y: returnFace.frame.midY))
        grid.touchesBegan([touch], with: nil)
        XCTAssertNotEqual(returnFace.backgroundColor, base)
        capture(grid, name: "bottom-row-dark-pressed")
        grid.touchesCancelled([touch], with: nil)
        capture(grid, name: "bottom-row-dark-cancelled")
        XCTAssertEqual(returnFace.backgroundColor, base)
        XCTAssertEqual(proxy.text, "")
    }

    func testPasteReleaseFollowsGridOwnershipAtEveryEdge() throws {
        for width: CGFloat in [375, 393, 440] {
            let (proxy, _, grid) = makeGrid(width: width)
            defer { withExtendedLifetime(proxy) {} }
            let paste = try XCTUnwrap(pasteControl(in: grid))
            let cap = paste.bounds
            let inside = [CGPoint(x: cap.midX, y: cap.midY), CGPoint(x: 1, y: cap.midY),
                          CGPoint(x: cap.maxX - 1, y: cap.midY), CGPoint(x: cap.midX, y: 1),
                          CGPoint(x: cap.midX, y: cap.maxY - 1)]
            let outside = [CGPoint(x: -cap.width, y: cap.midY), CGPoint(x: cap.maxX + cap.width, y: cap.midY),
                           CGPoint(x: cap.midX, y: -cap.height), CGPoint(x: cap.midX, y: cap.maxY + cap.height)]
            for (points, expected) in [(inside, true), (outside, false)] {
                for point in points {
                    XCTAssertEqual(paste.point(inside: point, with: nil), expected, "Width \(width), point \(point)")
                    XCTAssertEqual(grid.hitTest(paste.convert(point, to: grid), with: nil) === paste, expected)
                }
            }
        }
    }

    func testSpaceCornerSurvivesNarrowAndSplitLayouts() throws {
        let (proxy, model, grid) = makeGrid()
        defer { withExtendedLifetime(proxy) {} }
        let defaults = UserDefaults(suiteName: ZoneContract.appGroup)
        let original = defaults?.object(forKey: AccentChoice.defaultsKey)
        let cachedKey = "zone.keyboard.lastAccent"
        let cached = UserDefaults.standard.object(forKey: cachedKey)
        defer {
            defaults?.set(original, forKey: AccentChoice.defaultsKey)
            UserDefaults.standard.set(cached, forKey: cachedKey)
            KeyboardTheme.refreshAccent()
        }
        for accent in AccentChoice.allCases {
            AccentChoice.current = accent
            KeyboardTheme.refreshAccent()
            XCTAssertEqual(KeyboardTheme.accentChoice, accent)
            try checkSpaceCorners(proxy, model, grid, accent)
        }
    }

    private func checkSpaceCorners(_ proxy: SwipeIntegrationTests.Proxy, _ model: KeyboardModel,
                                   _ grid: KeyGridView, _ accent: AccentChoice) throws {
        for dark in [false, true] {
            proxy.explicitDarkAppearance = dark
            model.refreshTraits()
            for split in [false, true] {
                grid.duo = split ? .innerLandscape : .ordinary
                grid.splitKeys = split
                grid.windowInset = split ? 75 : 0
                grid.previewBoardWidth = split ? 801 : 393
                grid.frame.size = CGSize(width: split ? 801 : 275, height: split ? 203.1 : 216)
                grid.sync()
                let spaces = grid.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
                    .filter { $0.accessibilityLabel == "Space" } ?? []
                XCTAssertEqual(spaces.count, split ? 2 : 1)
                let caps = grid.layer.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
                for space in spaces {
                    let cap = try XCTUnwrap(caps.first { !$0.isHidden && $0.frame == space.accessibilityFrameInContainerSpace })
                    let mark = try XCTUnwrap(cap.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
                    XCTAssertEqual(mark.frame.width * 3, 16, accuracy: 0.01)
                    XCTAssertEqual(mark.frame.height * 3, 29, accuracy: 0.01)
                    XCTAssertEqual((cap.bounds.maxX - mark.frame.maxX) * 3, 16, accuracy: 0.75)
                    XCTAssertEqual((cap.bounds.maxY - mark.frame.maxY) * 3, 18, accuracy: 0.75)
                }
                capture(grid, name: "space-" + accent.rawValue + (split ? "-split" : "-one-hand") + (dark ? "-dark" : "-light"))
            }
        }
    }

    func testPasteKeepsItsSlotWhenAccessChanges() throws {
        let (proxy, model, grid) = makeGrid()
        defer { withExtendedLifetime(proxy) {} }
        for dark in [false, true] {
            proxy.explicitDarkAppearance = dark
            model.refreshTraits()
            grid.sync()
            let native = try XCTUnwrap(pasteControl(in: grid))
            let frame = native.frame
            let tag = dark ? "dark" : "light"
            capture(grid, name: "paste-access-" + tag)
            native.isHighlighted = true
            XCTAssertEqual(native.backgroundColor, UIColor(KeyboardTheme(isDark: dark).pressedKey))
            capture(grid, name: "paste-access-pressed-" + tag)
            native.isHighlighted = false
            proxy.hasOpenAccess = false
            model.refreshFullAccess(reloadVocabulary: false)
            grid.sync()
            XCTAssertNil(pasteControl(in: grid))
            let key = try XCTUnwrap(grid.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
                .first { $0.accessibilityLabel == "Paste" })
            XCTAssertEqual(frame, key.accessibilityFrameInContainerSpace)
            capture(grid, name: "paste-needs-access-" + tag)
            let touch = Touch(CGPoint(x: frame.midX, y: frame.midY))
            grid.touchesBegan([touch], with: nil)
            capture(grid, name: "paste-needs-access-pressed-" + tag)
            grid.touchesEnded([touch], with: nil)
            XCTAssertNotNil(model.pasteAccessHint)
            XCTAssertEqual(proxy.text, "")
            proxy.hasOpenAccess = true
            model.refreshFullAccess(reloadVocabulary: false)
            grid.sync()
            XCTAssertNil(model.pasteAccessHint)
        }
    }

    func testPasteHintYieldsToDictationAndExpiresWithoutAView() async throws {
        let (proxy, model, _) = makeGrid()
        proxy.hasOpenAccess = false
        model.refreshFullAccess(reloadVocabulary: false)
        model.explainPasteAccess()
        XCTAssertNotNil(model.pasteAccessHint)
        model.setDictationOwnsStrip(true)
        XCTAssertNil(model.pasteAccessHint)
        model.explainPasteAccess()
        XCTAssertNil(model.pasteAccessHint)
        model.setDictationOwnsStrip(false)
        XCTAssertNil(model.pasteAccessHint)
        model.explainPasteAccess()
        try await Task.sleep(for: .seconds(3.1))
        XCTAssertNil(model.pasteAccessHint)
    }

    func testCancelledPasteTouchClearsNativeHighlight() throws {
        let (proxy, _, grid) = makeGrid()
        let paste = try XCTUnwrap(pasteControl(in: grid))
        paste.isHighlighted = true
        paste.touchesCancelled([Touch(CGPoint(x: paste.bounds.midX, y: paste.bounds.midY))], with: nil)
        XCTAssertFalse(paste.isHighlighted)
        XCTAssertEqual(proxy.text, "")
    }

    func testPasteSlotMatchesNeighboringCapsAcrossKeyboardLooks() throws {
        let (proxy, model, grid) = makeGrid()
        defer { withExtendedLifetime(proxy) {} }
        let host = UIView(frame: grid.frame)
        host.addSubview(grid)
        let shared = UserDefaults(suiteName: ZoneContract.appGroup)
        let savedAccent = shared?.object(forKey: AccentChoice.defaultsKey)
        let cachedAccentKey = "zone.keyboard.lastAccent"
        let cachedAccent = UserDefaults.standard.object(forKey: cachedAccentKey)
        defer {
            shared?.set(savedAccent, forKey: AccentChoice.defaultsKey)
            UserDefaults.standard.set(cachedAccent, forKey: cachedAccentKey)
            KeyboardTheme.refreshAccent()
        }
        let width = host.bounds.width
        let narrowed = try XCTUnwrap(OneHandedLayout.column(width: width, fraction: 0.70, hand: .right))
        for accent in AccentChoice.allCases {
            AccentChoice.current = accent
            KeyboardTheme.refreshAccent()
            XCTAssertEqual(KeyboardTheme.accentChoice, accent)
            for spaceBar in SpaceBarLabel.allCases {
                for dark in [false, true] {
                    for layout in [(x: CGFloat.zero, width: width), narrowed, (x: 0, width: narrowed.width), (x: 0, width: 852)] {
                        proxy.explicitDarkAppearance = dark
                        model.refreshTraits()
                        model.apply(KeyboardPreferences(autocorrectEnabled: false, showsPasteKey: true, spaceBar: spaceBar,
                                                        oneHandedEnabled: layout.width == narrowed.width))
                        host.frame.size.width = max(layout.width, width)
                        grid.frame = CGRect(x: layout.x, y: 0, width: layout.width, height: 216)
                        grid.sync()
                        try assertPasteConfiguration(in: grid, dark: dark)
                    }
                }
            }
        }
    }

    func testGlobeAndEmojiCanSwapWithoutChangingTheBottomRowWidths() throws {
        let (proxy, model, grid) = makeGrid()
        proxy.needsGlobeKey = true
        model.refreshTraits()
        grid.sync()
        let globe = try XCTUnwrap(grid.subviews.first { $0.accessibilityLabel == "Next keyboard" })
        let frame = globe.frame
        XCTAssertFalse(globe.isHidden)

        proxy.needsGlobeKey = false
        model.refreshTraits()
        model.apply(KeyboardPreferences(autocorrectEnabled: false, showsPasteKey: true, showsEmojiKey: true))
        grid.sync()
        let emoji = try XCTUnwrap(grid.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
            .first { $0.accessibilityLabel == "Emoji" })
        XCTAssertTrue(globe.isHidden)
        XCTAssertEqual(emoji.accessibilityFrameInContainerSpace, frame)
        XCTAssertTrue(grid.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === grid)
    }

    private func assertPasteConfiguration(in grid: KeyGridView, dark: Bool) throws {
        let paste = try XCTUnwrap(pasteControl(in: grid))
        let elements = try XCTUnwrap(grid.accessibilityElements)
        let index = try XCTUnwrap(elements.firstIndex { ($0 as? UIView) === paste })
        let space = try XCTUnwrap(elements[index - 1] as? UIAccessibilityElement)
        let enter = try XCTUnwrap(elements[index + 1] as? UIAccessibilityElement)
        XCTAssertEqual(space.accessibilityLabel, "Space")
        XCTAssertEqual(enter.accessibilityLabel, "return")
        XCTAssertGreaterThan(paste.frame.minX, space.accessibilityFrameInContainerSpace.maxX)
        XCTAssertLessThan(paste.frame.maxX, enter.accessibilityFrameInContainerSpace.minX)
        XCTAssertTrue(grid.bounds.contains(paste.frame))
        XCTAssertEqual(paste.frame.height, enter.accessibilityFrameInContainerSpace.height)
        XCTAssertGreaterThan(paste.frame.width, 2 * KeyboardTheme.cornerRadius)
        XCTAssertEqual(paste.alpha, 1)
        XCTAssertFalse(paste.isHighlighted)
        XCTAssertEqual(paste.overrideUserInterfaceStyle, dark ? .dark : .light)
        let config = paste.configuration
        XCTAssertEqual(config.displayMode, .iconOnly)
        XCTAssertEqual(config.cornerStyle, .fixed)
        XCTAssertEqual(config.cornerRadius, KeyboardTheme.cornerRadius)
        let theme = KeyboardTheme(isDark: dark)
        XCTAssertEqual(config.baseForegroundColor, UIColor(theme.text))
        XCTAssertEqual(config.baseBackgroundColor, UIColor(theme.key))
        XCTAssertEqual(paste.backgroundColor, UIColor(theme.key))
        let caps = grid.layer.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
        let returnCap = try XCTUnwrap(caps.first { $0.frame == enter.accessibilityFrameInContainerSpace })
        XCTAssertEqual(paste.backgroundColor?.cgColor, returnCap.backgroundColor)
    }

    private func capture(_ grid: KeyGridView, name: String) {
        grid.layoutIfNeeded()
        grid.subviews.forEach { $0.layoutIfNeeded() }
        let bounds = CGRect(x: 0, y: grid.bounds.maxY - 55, width: grid.bounds.width, height: 55)
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let keyboard = renderer.image { grid.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: keyboard)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
