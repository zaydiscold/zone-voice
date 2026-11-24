// by zayd/cold @ zayd.wtf

import SwiftUI
import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class KeyboardLookPreviewTests: XCTestCase {
    private var window: UIWindow!
    private var settings: AppSettings!
    private let suite = UUID().uuidString

    override func setUpWithError() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, store: InMemorySharedStore(), vocabulary: nil, systemLexicon: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 390)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: KeyboardLookPreview().environment(settings).padding())
        window.makeKeyAndVisible()
        settle()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func image() throws -> Data {
        let pixels = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(pixels.pngData())
    }

    func testPersonalizeContainsTheKeyGrid() throws {
        window.rootViewController = UIHostingController(rootView: Form { PersonalizeSection() }.environment(settings))
        settle()
        XCTAssertNotNil(find(KeyGridView.self, in: window))
    }

    func testUpdatingLayoutMovesAndResizesTheSameKeys() throws {
        settings.oneHandedEnabled = false
        settings.showsPasteKey = false
        settle()
        let grid = try XCTUnwrap(find(KeyGridView.self, in: window))
        let full = grid.convert(grid.bounds, to: window)
        XCTAssertGreaterThan(full.width, 200)
        XCTAssertNil(find(UIPasteControl.self, in: grid))
        settings.oneHandedSide = .left
        settings.oneHandedWidth = OneHandedLayout.widthRange.lowerBound
        settings.oneHandedEnabled = true
        settings.showsPasteKey = true
        settle()
        let left = grid.convert(grid.bounds, to: window)
        XCTAssertLessThan(left.width, full.width)
        XCTAssertNotNil(find(UIPasteControl.self, in: grid))
        settings.oneHandedSide = .right
        settings.oneHandedWidth = OneHandedLayout.widthRange.upperBound
        settle()
        let right = grid.convert(grid.bounds, to: window)
        XCTAssertGreaterThan(right.minX, left.minX)
        XCTAssertGreaterThan(right.width, left.width)
        let before = try image()
        settings.showsEmojiKey.toggle()
        settle()
        XCTAssertNotEqual(before, try image())
    }

    func testSplitPreferenceDrawsBothSpaceBarsOnTheUnfoldedDuo() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AppGroup.identifier))
        let key = DuoKeyboard.splitPreferenceKey
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        func openPreview() throws -> KeyGridView {
            window.rootViewController = UIHostingController(rootView:
                KeyboardLookPreview(displaySize: CGSize(width: 920, height: 700), isDuo: true).environment(settings))
            settle()
            return try XCTUnwrap(find(KeyGridView.self, in: window))
        }
        func spaces(in grid: KeyGridView) -> Int {
            (grid.accessibilityElements as? [NSObject] ?? []).filter { $0.accessibilityLabel == "Space" }.count
        }
        defaults.set(false, forKey: key)
        let full = try openPreview()
        XCTAssertFalse(full.splitKeys)
        XCTAssertEqual(spaces(in: full), 1)
        // The split gesture is in the extension. Visiting the app reads that saved preference.
        defaults.set(true, forKey: key)
        let split = try openPreview()
        XCTAssertTrue(split.splitKeys)
        XCTAssertEqual(spaces(in: split), 2)
    }

    func testColorAndMarkChangesRedrawAndReducedMotionStaysStill() throws {
        let store = AccentStore.shared
        let previousStyle = store.windowStyle
        let previousChoice = store.choice
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AppGroup.identifier))
        let savedAccent = defaults.object(forKey: AccentChoice.defaultsKey)
        let previousAccent = settings.accent
        defer {
            settings.accent = previousAccent
            defaults.set(savedAccent, forKey: AccentChoice.defaultsKey)
            store.choice = previousChoice
            store.windowStyle = previousStyle
        }
        store.windowStyle = .light
        settings.accent = .ember
        settings.hideHomeButton = false
        settle()
        XCTAssertNotNil(UIImage(named: "ZoneHomeMark"))
        let ember = try image()
        settings.accent = .violet
        settle()
        let violet = try image()
        XCTAssertNotEqual(ember, violet)
        settings.hideHomeButton = true
        settle()
        XCTAssertNotEqual(violet, try image())
        XCTAssertEqual(window.traitCollection.userInterfaceStyle, .light)
        let light = try image()
        store.windowStyle = .dark
        settle()
        XCTAssertEqual(window.traitCollection.userInterfaceStyle, .dark)
        let dark = try image()
        XCTAssertNotEqual(light, dark)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        print("Keyboard look preview system Reduce Motion: \(UIAccessibility.isReduceMotionEnabled)")
        XCTAssertEqual(dark, try image())
    }
}
