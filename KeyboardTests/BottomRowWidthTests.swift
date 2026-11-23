// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// 123 alone left of space is as wide as Return, as iOS draws it without its emoji key. A tester
/// said the 123 key was the wrong size (November 12): it was 43 pt beside a 93 pt Return.
@MainActor final class BottomRowWidthTests: XCTestCase {
    private func grid(_ preferences: KeyboardPreferences, layer: KeyboardLayer = .letters) -> KeyGridView {
        let proxy = SwipeIntegrationTests.Proxy()
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits(); model.apply(preferences)
        if layer != .letters { model.handleTap(.switchLayer(.numbers, label: "123")) }
        let grid = KeyGridView(model: model, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250)
        grid.sync()
        return grid
    }

    private func frame(_ name: String, in grid: KeyGridView) throws -> CGRect {
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        return try XCTUnwrap(elements.first { $0.accessibilityLabel == name }, name).accessibilityFrameInContainerSpace
    }

    func testALoneSwitchKeyIsAsWideAsReturn() throws {
        let letters = grid(KeyboardPreferences(showsPasteKey: false, showsEmojiKey: false))
        let numbers = try frame("Numbers", in: letters), enter = try frame("return", in: letters)
        XCTAssertEqual(numbers.width, enter.width, accuracy: 0.5)
        XCTAssertEqual(numbers.width, 93, accuracy: 1.5)
        // Space sits between them, centered on the keyboard.
        let space = try frame("Space", in: letters)
        XCTAssertEqual(space.midX, 201, accuracy: 0.5)
        XCTAssertGreaterThan(space.width, 4 * 33.5)

        let abc = grid(KeyboardPreferences(showsPasteKey: false, showsEmojiKey: false), layer: .numbers)
        XCTAssertEqual(try frame("Letters", in: abc).width, try frame("return", in: abc).width, accuracy: 0.5)
    }

    func testSwitchKeyKeepsItsSizeBesideEmojiOrFieldKeys() throws {
        let emoji = grid(KeyboardPreferences(showsPasteKey: false, showsEmojiKey: true))
        XCTAssertEqual(try frame("Numbers", in: emoji).width, 43.3, accuracy: 1)
        XCTAssertEqual(try frame("return", in: emoji).width, 93, accuracy: 1.5)

        let fieldKeys = KeyGridLayout.gridRows(
            [KeyboardLayout.rows(for: .letters, shifted: false, needsGlobe: false, fieldKeys: [".", "/"])[3]], layer: .letters)[0]
        XCTAssertEqual(fieldKeys.widths.first, .units(1.29))
        let globe = KeyGridLayout.gridRows(
            [KeyboardLayout.rows(for: .letters, shifted: false, needsGlobe: true)[3]], layer: .letters)[0]
        XCTAssertEqual(globe.widths.first, .units(1.29))
    }

    func testPasteBesideReturnLeavesTheSwitchKeyWide() throws {
        let paste = grid(KeyboardPreferences(showsPasteKey: true, showsEmojiKey: false))
        let numbers = try frame("Numbers", in: paste), space = try frame("Space", in: paste)
        XCTAssertEqual(numbers.width, 93, accuracy: 1.5)
        XCTAssertGreaterThan(space.width, 3.5 * 33.5)
    }

    /// The wider key is one target: every point on it, edge to edge, switches the layer.
    func testTheWholeWideKeyIsTheSwitch() throws {
        let letters = grid(KeyboardPreferences(showsPasteKey: false, showsEmojiKey: false))
        let numbers = try frame("Numbers", in: letters), space = try frame("Space", in: letters)
        XCTAssertLessThan(numbers.maxX, space.minX)
        XCTAssertEqual(space.minX - numbers.maxX, 6, accuracy: 0.5)
    }
}
