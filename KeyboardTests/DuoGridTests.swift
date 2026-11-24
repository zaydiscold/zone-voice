// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

@MainActor final class DuoGridTests: XCTestCase {
    private final class Touch: UITouch {
        var point: CGPoint
        init(_ point: CGPoint) { self.point = point; super.init() }
        override func location(in view: UIView?) -> CGPoint { point }
        var time: TimeInterval?
        override var timestamp: TimeInterval { time ?? ProcessInfo.processInfo.systemUptime }
    }

    func testFastRolloverAcrossThumbsAndSilentMiddle() throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.apply(KeyboardPreferences(autocorrectEnabled: false, showsEmojiKey: false))
        defer { model.keyboardWillDisappear() }
        let grid = KeyGridView(model: model, mic: MicController(), controller: nil)
        grid.duo = .innerLandscape
        grid.windowInset = 75
        grid.splitKeys = true
        grid.frame = CGRect(x: 0, y: 0, width: 801, height: 203.1)
        grid.sync()
        func frames(_ name: String) throws -> [CGRect] {
            let keys = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
            return keys.filter { $0.accessibilityLabel == name }.map(\.accessibilityFrameInContainerSpace)
        }
        var previous: Touch?
        for _ in 0..<8 {
            for letter in ["q", "p", "g", "v"] {
                let keys = try frames(letter)
                XCTAssertEqual(keys.count, ["g", "v"].contains(letter) ? 2 : 1)
                for cap in keys {
                    let next = Touch(CGPoint(x: cap.midX, y: cap.midY))
                    grid.touchesBegan([next], with: nil)
                    if let previous { grid.touchesEnded([previous], with: nil) }
                    previous = next
                }
            }
        }
        if let previous { grid.touchesEnded([previous], with: nil) }
        let typed = String(repeating: "qpggvv", count: 8)
        XCTAssertEqual(proxy.text, typed)
        let q = try XCTUnwrap(frames("q").first)
        XCTAssertEqual(q.width, 46.3, accuracy: 0.01)
        for x in [q.midX, 400.5] {
            let drag = Touch(CGPoint(x: x, y: q.midY))
            grid.touchesBegan([drag], with: nil)
            drag.point.x = 400.5
            grid.touchesMoved([drag], with: nil)
            drag.point.x = 760
            grid.touchesEnded([drag], with: nil)
        }
        XCTAssertEqual(proxy.text, typed)
        XCTAssertEqual(try frames("Space").count, 2)
        for cap in try frames("Space") {
            let touch = Touch(CGPoint(x: cap.midX, y: cap.midY))
            grid.touchesBegan([touch], with: nil)
            grid.touchesEnded([touch], with: nil)
        }
        XCTAssertTrue(proxy.text.hasPrefix(typed))
        XCTAssertGreaterThan(proxy.text.count, typed.count)
    }

    func testSwipeWordsWithinEitherHalf() async throws {
        for (word, right) in [("water", false), ("upon", true)] {
            let proxy = SwipeIntegrationTests.Proxy()
            let model = KeyboardModel(proxy: proxy)
            defer { model.keyboardWillDisappear() }
            model.refreshTraits()
            model.apply(KeyboardPreferences(autocorrectEnabled: false, swipeTypingEnabled: true,
                                            swipeLearningEnabled: false))
            let grid = KeyGridView(model: model, mic: MicController(), controller: nil)
            grid.duo = .innerLandscape
            grid.windowInset = 75
            grid.splitKeys = true
            grid.frame = CGRect(x: 0, y: 0, width: 801, height: 203.1)
            grid.sync()
            let caps = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
            let path = try word.map { letter -> CGPoint in
                let cap = try XCTUnwrap(caps.first { $0.accessibilityLabel == String(letter) &&
                    ($0.accessibilityFrameInContainerSpace.midX > 400.5) == right }).accessibilityFrameInContainerSpace
                return .init(x: cap.midX, y: cap.midY)
            }
            let touch = Touch(path[0])
            var time: TimeInterval = 100
            touch.time = time
            grid.touchesBegan([touch], with: nil)
            for (start, end) in zip(path, path.dropFirst()) {
                for step in 1...8 {
                    let f = CGFloat(step) / 8
                    touch.point = .init(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
                    time += 0.016
                    touch.time = time
                    grid.touchesMoved([touch], with: nil)
                }
            }
            grid.touchesEnded([touch], with: nil)
            for _ in 0..<200 where proxy.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(proxy.text, word)
        }
    }

    func testBothSpaceBarsHoldToTalkAndSlideToMoveTheCursor() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        proxy.text = "abcdef"
        let model = KeyboardModel(proxy: proxy)
        defer { model.keyboardWillDisappear() }
        model.refreshTraits()
        model.apply(KeyboardPreferences(autocorrectEnabled: false, spaceHold: .talk))
        let mic = MicController()
        mic.talkAvailable = true
        let grid = KeyGridView(model: model, mic: mic, controller: nil)
        grid.duo = .innerLandscape
        grid.windowInset = 75
        grid.splitKeys = true
        grid.frame = CGRect(x: 0, y: 0, width: 801, height: 203.1)
        grid.sync()
        let caps = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        let spaces = caps.filter { $0.accessibilityLabel == "Space" }
        XCTAssertEqual(spaces.count, 2)
        // UIKit can recycle a UITouch object's address. Keep every synthetic event
        // on the same increasing clock, including the next hold after a fast slide.
        let clock = ProcessInfo.processInfo.systemUptime
        for (i, space) in spaces.enumerated() {
            let began = clock + Double(i) * 2
            let cap = space.accessibilityFrameInContainerSpace
            let start = CGPoint(x: cap.midX, y: cap.midY)
            let hold = Touch(start)
            hold.time = began
            grid.touchesBegan([hold], with: nil)
            let gap = Touch(CGPoint(x: 400.5, y: cap.midY))
            gap.time = began + 0.1
            grid.touchesBegan([gap], with: nil)
            grid.touchesEnded([gap], with: nil)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(mic.holdsBegan, i + 1)
            hold.time = began + 0.45
            grid.touchesEnded([hold], with: nil)
            XCTAssertEqual(mic.holdsEnded, i + 1)
            let slide = Touch(start)
            let time = began + 0.5
            slide.time = time
            grid.touchesBegan([slide], with: nil)
            for step in 1...2 {
                slide.time = time + Double(step) * 0.1
                slide.point.x -= 16
                grid.touchesMoved([slide], with: nil)
            }
            grid.touchesEnded([slide], with: nil)
            XCTAssertEqual(proxy.tail.count, (i + 1) * 2)
        }
        XCTAssertEqual(proxy.text + proxy.tail, "abcdef")
    }

    func testEveryLayerAndFieldHasDisjointCapsAndReachableTargets() throws {
        let size = CGSize(width: 801, height: 203.1)
        let metrics = DuoKeyboard.innerLandscape.metrics(width: size.width, windowInset: 75)
        for layer in [KeyboardLayer.letters, .numbers, .symbols] {
            for field in [[], ["."], ["@", "."]] as [[String]] {
                for paste in [false, true] {
                    let rows = KeyboardLayout.rows(for: layer, shifted: false, needsGlobe: true,
                                                   pasteKey: paste, emojiKey: true, fieldKeys: field)
                    let split = KeyGridLayout.split(rows)
                    var gridRows = KeyGridLayout.gridRows(split.rows, layer: layer)
                    gridRows[1].duplicatesCenter = !rows[1].count.isMultiple(of: 2)
                    let geometry = KeyGridGeometry(size: size, rows: gridRows, metrics: metrics, splitAt: split.cuts)
                    for (r, caps) in geometry.caps.enumerated() {
                        XCTAssertNil(geometry.key(at: CGPoint(x: 400.5, y: caps[0].midY)))
                        var previous: CGRect?
                        for (i, cap) in caps.enumerated() {
                            let p = KeyGridGeometry.Position(row: r, index: i)
                            let region = try XCTUnwrap(geometry.touchRegion(p))
                            XCTAssertTrue(region.contains(cap), "\(p) \(region) \(cap)")
                            XCTAssertGreaterThanOrEqual(region.width, 46.3)
                            XCTAssertFalse(region.intersects(CGRect(x: 380, y: 0, width: 40, height: size.height)))
                            if let previous { XCTAssertLessThanOrEqual(previous.maxX, region.minX + 0.0001) }
                            XCTAssertEqual(geometry.key(at: CGPoint(x: cap.midX, y: cap.midY)), p)
                            previous = region
                        }
                    }
                }
            }
        }
    }
}
