// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class OneHandedTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "OneHandedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Geometry

    func testDefaultMatchesApplesMeasuredWidthOnA402PointPhone() throws {
        // Apple's one-handed keyboard measured 320 pt on the 402 pt iPhone 17 Pro simulator.
        let right = try XCTUnwrap(OneHandedLayout.column(width: 402, fraction: OneHandedLayout.defaultWidth, hand: .right))
        XCTAssertEqual(right.width, 322)
        XCTAssertEqual(right.x, 80)
        let left = try XCTUnwrap(OneHandedLayout.column(width: 402, fraction: OneHandedLayout.defaultWidth, hand: .left))
        XCTAssertEqual(left.x, 0)
        XCTAssertEqual(left.width, 322)
    }

    func testTheColumnTouchesItsThumbsEdgeOnEveryCurrentIPhone() throws {
        for width: CGFloat in [375, 390, 393, 402, 420, 430, 440] {
            for fraction in [0.70, 0.80, 0.90] {
                let right = try XCTUnwrap(OneHandedLayout.column(width: width, fraction: fraction, hand: .right))
                XCTAssertEqual(right.x + right.width, width, "right column ends at the right edge at \(width)")
                XCTAssertGreaterThanOrEqual(width - right.width, OneHandedLayout.minimumPanel)
                XCTAssertEqual(right.width, right.width.rounded(), "whole points at \(width)")
                let left = try XCTUnwrap(OneHandedLayout.column(width: width, fraction: fraction, hand: .left))
                XCTAssertEqual(left.x, 0)
                XCTAssertEqual(left.width, right.width)
            }
        }
    }

    func testFullWidthIsNoColumn() {
        XCTAssertNil(OneHandedLayout.column(width: 402, fraction: 0.8, hand: .full))
    }

    func testTooNarrowAndLandscapeOrIPadKeepTheFullKeyboard() {
        // An SE with Display Zoom is 320 pt; landscape iPhones and iPads are far wider.
        XCTAssertNil(OneHandedLayout.column(width: 320, fraction: 0.8, hand: .right))
        XCTAssertNil(OneHandedLayout.column(width: 667, fraction: 0.8, hand: .right))
        XCTAssertNil(OneHandedLayout.column(width: 834, fraction: 0.8, hand: .left))
        XCTAssertTrue(OneHandedLayout.isAvailable(width: 375))
        XCTAssertTrue(OneHandedLayout.isAvailable(width: 440))
    }

    func testWidthIsClampedToTheSettingsRange() throws {
        XCTAssertEqual(OneHandedLayout.clamped(0.2), 0.70)
        XCTAssertEqual(OneHandedLayout.clamped(1.4), 0.90)
        XCTAssertEqual(OneHandedLayout.clamped(.nan), OneHandedLayout.defaultWidth)
        XCTAssertEqual(OneHandedLayout.clamped(.infinity), OneHandedLayout.defaultWidth)
        let wide = try XCTUnwrap(OneHandedLayout.column(width: 402, fraction: 5, hand: .right))
        XCTAssertEqual(wide.width, (402 * 0.9).rounded())
    }

    // MARK: Preferences

    func testOffByDefaultAndOldRecordsReadAsOff() throws {
        let fresh = KeyboardPreferences()
        XCTAssertFalse(fresh.oneHandedEnabled)
        XCTAssertEqual(fresh.oneHandedSide, .right)
        XCTAssertEqual(fresh.oneHandedWidth, OneHandedLayout.defaultWidth)
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"showsPasteKey":true}"#.utf8))
        XCTAssertFalse(old.oneHandedEnabled)
        XCTAssertEqual(old.oneHandedSide, .right)
        XCTAssertTrue(old.showsPasteKey)
    }

    func testRoundTripsAndOneBadValueFallsBackAlone() throws {
        let on = KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .left, oneHandedWidth: 0.74)
        let back = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(back, on)
        let odd = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(
            #"{"oneHandedEnabled":true,"oneHandedSide":"middle","oneHandedWidth":3,"autocorrectEnabled":false}"#.utf8))
        XCTAssertTrue(odd.oneHandedEnabled)
        XCTAssertEqual(odd.oneHandedSide, .right)
        XCTAssertEqual(odd.oneHandedWidth, 0.90)
        XCTAssertFalse(odd.autocorrectEnabled)
    }

    // MARK: What the keyboard remembers

    func testOffInSettingsIsAlwaysFullWidth() {
        let local = LocalKeyboardHand(defaults: defaults())
        XCTAssertEqual(local.resolve(KeyboardPreferences()), .full)
        local.choose(.left)
        XCTAssertEqual(local.resolve(KeyboardPreferences()), .full)
    }

    func testTurningItOnStartsOnTheChosenThumb() {
        let local = LocalKeyboardHand(defaults: defaults())
        XCTAssertEqual(local.resolve(KeyboardPreferences()), .full)
        XCTAssertEqual(local.resolve(KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .left)), .left)
    }

    func testAChoiceOnTheKeyboardSurvivesEveryReappearance() {
        let store = defaults()
        let on = KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .right)
        XCTAssertEqual(LocalKeyboardHand(defaults: store).resolve(on), .right)
        LocalKeyboardHand(defaults: store).choose(.full)
        // A new process reads the same container.
        XCTAssertEqual(LocalKeyboardHand(defaults: store).resolve(on), .full)
        LocalKeyboardHand(defaults: store).choose(.left)
        XCTAssertEqual(LocalKeyboardHand(defaults: store).resolve(on), .left)
        // A width change in Settings is not a new start.
        var wider = on
        wider.oneHandedWidth = 0.88
        XCTAssertEqual(LocalKeyboardHand(defaults: store).resolve(wider), .left)
    }

    func testChangingTheThumbInSettingsIsAdoptedOnce() {
        let local = LocalKeyboardHand(defaults: defaults())
        _ = local.resolve(KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .right))
        local.choose(.full)
        XCTAssertEqual(local.resolve(KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .left)), .left)
        local.choose(.right)
        XCTAssertEqual(local.resolve(KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .left)), .right)
    }

    func testOffThenOnAgainStartsOver() {
        let local = LocalKeyboardHand(defaults: defaults())
        let on = KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .right)
        _ = local.resolve(on)
        local.choose(.full)
        XCTAssertEqual(local.resolve(KeyboardPreferences()), .full)
        XCTAssertEqual(local.resolve(on), .right)
    }

    func testAnUnreadableStoredHandFallsBackToSettings() {
        let store = defaults()
        let local = LocalKeyboardHand(defaults: store)
        _ = local.resolve(KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .left))
        store.set("diagonal", forKey: LocalKeyboardHand.handKey)
        XCTAssertEqual(local.resolve(KeyboardPreferences(oneHandedEnabled: true, oneHandedSide: .left)), .left)
    }
}
