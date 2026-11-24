// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import Observation
import ZoneCore

/// Dictation is outside these tests; the grid, the model and the mic are the production types.
/// The grid only reads the mic's face and history panel and tells it about typed keys.
/// Hold space to talk is stood in for (`SpaceHoldStandIn`): off unless a test turns it on, and
/// counted, with no dictation behind it.
extension MicController {
    convenience init() {
        let proxy = SwipeIntegrationTests.Proxy()
        // A grid fixture has no recording field. Passing one restores the simulator's last folded face.
        self.init(store: InMemorySharedStore(), proxy: nil, feedback: KeyFeedback(proxy: proxy),
                  localHost: LocalDictationHost(store: InMemorySharedStore(), dictation: LocalDictationFlowTests.FakeDictation()))
        holdStandIn = SpaceHoldStandIn()
    }
    var talkAvailable: Bool {
        get { holdStandIn?.talkAvailable ?? false }
        set { holdStandIn?.talkAvailable = newValue }
    }
    /// The strip explains (Zone not ready): the hold is talking's, with no dictation.
    var explainsInsteadOfTalking: Bool {
        get { holdStandIn?.explainsInsteadOfTalking ?? false }
        set { holdStandIn?.explainsInsteadOfTalking = newValue }
    }
    var holdsBegan: Int { holdStandIn?.began ?? 0 }
    var holdsEnded: Int { holdStandIn?.ended ?? 0
    }
}

@MainActor final class SwipeGridTests: XCTestCase {
    private final class Touch: UITouch {
        var point: CGPoint
        let owner: UIView
        var reportedTimestamp: TimeInterval?
        init(_ point: CGPoint, in owner: UIView) { self.point = point; self.owner = owner; super.init() }
        override var view: UIView? { owner }
        override var timestamp: TimeInterval { reportedTimestamp ?? ProcessInfo.processInfo.systemUptime }
        override func location(in view: UIView?) -> CGPoint { point }
    }
    private func setupGrid() -> (SwipeIntegrationTests.Proxy, KeyboardModel, KeyGridView) {
        let p = SwipeIntegrationTests.Proxy(); p.text = "abcdef"
        let m = KeyboardModel(proxy: p)
        m.refreshTraits(); m.apply(KeyboardPreferences(autocorrectEnabled: false, showsEmojiKey: false))
        let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250)
        grid.sync()
        return (p, m, grid)
    }
    private func touch(_ name: String, in grid: KeyGridView) throws -> Touch {
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        let element = try XCTUnwrap(elements.first { $0.accessibilityLabel == name })
        let frame = element.accessibilityFrameInContainerSpace
        return Touch(CGPoint(x: frame.midX, y: frame.midY), in: grid)
    }
    func testDuplicateBeginAndLateDeliveryNeverTypeTwiceAndTouchReuseStillWorks() throws {
        let (p, m, grid) = setupGrid()
        let x = try touch("x", in: grid)
        x.reportedTimestamp = 100
        grid.touchesBegan([x], with: nil); grid.touchesBegan([x], with: nil)
        x.reportedTimestamp = 101
        grid.touchesEnded([x], with: nil)
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        XCTAssertEqual(p.text, "abcdefx")
        x.reportedTimestamp = 102
        grid.touchesBegan([x], with: nil); grid.touchesEnded([x], with: nil)
        XCTAssertEqual(p.text, "abcdefxx")
        m.keyboardWillDisappear()
    }
    func testFastOverlappingRegularTapsRepairSlipsWithSwipeOnAndOff() async throws {
        let corrector: Autocorrector? = await withCheckedContinuation { continuation in
            SpellingStore.load { continuation.resume(returning: $0) }
        }
        XCTAssertNotNil(corrector)
        for enabled in [false, true] {
            for cadence in [0.03, 0.08, 0.15] {
                let p = SwipeIntegrationTests.Proxy()
                let m = KeyboardModel(proxy: p)
                m.refreshTraits()
                m.apply(KeyboardPreferences(autocorrectEnabled: true, showsEmojiKey: false,
                    swipeTypingEnabled: enabled, swipeLearningEnabled: false))
                let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
                grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250); grid.sync()
                var held: Touch?
                var tick = ProcessInfo.processInfo.systemUptime
                for character in "hesxhavingxfun socmuchcfunx fuckxyeahx " {
                    grid.sync()
                    let next = try touch(character == " " ? "Space" : String(character), in: grid)
                    next.reportedTimestamp = tick
                    grid.touchesBegan([next], with: nil)
                    if let held {
                        held.reportedTimestamp = tick + cadence / 3
                        grid.touchesEnded([held], with: nil)
                    }
                    held = next
                    tick += cadence
                    try await Task.sleep(for: .seconds(cadence))
                }
                if let held { held.reportedTimestamp = tick; grid.touchesEnded([held], with: nil) }
                XCTAssertEqual(p.text, "he's having fun so much fun fuck yeah ", "swipe=\(enabled), cadence=\(cadence)")
                m.keyboardWillDisappear()
            }
        }
    }
    func testSecondFingerSubmitsSwipeBeforeSpaceExactlyOnce() async throws {
        let p = SwipeIntegrationTests.Proxy()
        let m = KeyboardModel(proxy: p)
        m.refreshTraits(); m.apply(KeyboardPreferences(autocorrectEnabled: false,
            swipeTypingEnabled: true, swipeLearningEnabled: false))
        let grid = KeyGridView(model: m, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250); grid.sync()
        let finger = try touch("t", in: grid), end = try touch("o", in: grid)
        let space = try touch("Space", in: grid)
        finger.reportedTimestamp = 100
        grid.touchesBegan([finger], with: nil)
        finger.point = end.point; finger.reportedTimestamp = 100.2
        grid.touchesMoved([finger], with: nil)
        space.reportedTimestamp = 100.21
        grid.touchesBegan([space], with: nil)
        space.reportedTimestamp = 100.25
        grid.touchesEnded([space], with: nil)
        finger.reportedTimestamp = 100.3
        grid.touchesEnded([finger], with: nil)
        for _ in 0..<150 {
            if p.text.hasSuffix(" ") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(["to ", "too "].contains(p.text), p.text)
        m.keyboardWillDisappear()
    }
}

extension SwipeGridTests {
    func testCircleAndZigzagWhileFingerIsDown() throws {
        let (proxy, model, grid) = setupGrid()
        model.apply(KeyboardPreferences(swipeTypingEnabled: true, swipeLearningEnabled: false))
        defer { model.keyboardWillDisappear(); withExtendedLifetime(proxy) {} }
        let window = UIWindow(frame: grid.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(grid)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        grid.backgroundColor = .systemGray5
        grid.sync()
        let circle = (0...12).map { i in
            let angle = CGFloat(i) * .pi / 6
            return CGPoint(x: 200 + 39 * cos(angle), y: 85 + 39 * sin(angle))
        }
        let zigzag = [CGPoint(x: 122, y: 114), CGPoint(x: 160, y: 55),
                      CGPoint(x: 197, y: 114), CGPoint(x: 235, y: 55), CGPoint(x: 272, y: 114)]
        for (name, points) in [("circle", circle), ("zigzag", zigzag)] {
            let finger = Touch(points[0], in: grid)
            let start = CACurrentMediaTime()
            finger.reportedTimestamp = start
            grid.touchesBegan([finger], with: nil)
            for (i, point) in points.enumerated().dropFirst() {
                finger.point = point
                finger.reportedTimestamp = start + Double(i) * 0.14 / Double(points.count - 1)
                grid.touchesMoved([finger], with: nil)
                CATransaction.flush()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14 / Double(points.count - 1)))
            }
            let trail = try XCTUnwrap(grid.layer.sublayers?.first { $0 is SwipeTrailLayer })
            XCTAssertNotNil((trail.sublayers?.first as? CAShapeLayer)?.path)
            let image = UIGraphicsImageRenderer(bounds: grid.bounds).image { context in
                (grid.layer.presentation() ?? grid.layer).render(in: context.cgContext)
            }
            let shot = XCTAttachment(image: image)
            shot.name = "Held " + name
            shot.lifetime = .keepAlways
            add(shot)
            grid.touchesCancelled([finger], with: nil)
        }
    }
}
