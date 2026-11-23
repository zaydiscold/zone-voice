// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import SwiftUI
import ZoneCore

@MainActor
final class SwipeTrailTests: XCTestCase {
    func testTrailUsesChosenColorAndAgesWithoutNewTouches() throws {
        let trail = SwipeTrailLayer()
        trail.append(.zero, color: .magenta, now: 0)
        trail.append(CGPoint(x: 10, y: 5), color: .magenta, now: 0.01)
        let segment = try XCTUnwrap(trail.sublayers?.first as? CAShapeLayer)
        XCTAssertEqual(segment.strokeColor, UIColor.magenta.cgColor)
        XCTAssertEqual(segment.lineWidth, 0, "Model layer draws nothing once its taper completes")
        XCTAssertEqual(segment.lineCap, .round, "Round head, and opaque caps cannot stack into dots")
        let taper = try XCTUnwrap(segment.animation(forKey: "taper") as? CABasicAnimation)
        XCTAssertGreaterThan(taper.duration, 0)
        XCTAssertLessThanOrEqual(taper.duration, SwipeTrailLayer.lifetime)
        XCTAssertEqual(taper.fromValue as? CGFloat, SwipeTrailLayer.headWidth)
        XCTAssertEqual(taper.toValue as? Int, 0)
        XCTAssertLessThan(trail.opacity, 1, "Softness comes from group opacity, not per-segment alpha")
        XCTAssertEqual(trail.opacity, SwipeTrailLayer.groupOpacity)
        XCTAssertNotNil(segment.path)
        trail.clear()
        XCTAssertTrue(trail.sublayers?.isEmpty ?? true)
    }
    /// Zayd, 2026-11-18: a bit more see-through and a shorter tail, closer to the system
    /// keyboard's. The comet was 0.36 s long at 0.85 opacity.
    func testTrailIsShortAndSeeThrough() {
        XCTAssertLessThanOrEqual(SwipeTrailLayer.lifetime, 0.25, "the tail fades in a quarter second")
        XCTAssertGreaterThanOrEqual(SwipeTrailLayer.lifetime, 0.15, "long enough to show the path just drawn")
        XCTAssertLessThanOrEqual(SwipeTrailLayer.groupOpacity, 0.65)
        XCTAssertGreaterThanOrEqual(SwipeTrailLayer.groupOpacity, 0.5, "still reads on both keyboard backdrops")
    }
    func testTrailIsBoundedAndDoesNotJoinSeparateGestures() throws {
        let trail = SwipeTrailLayer()
        for i in 0..<500 { trail.append(CGPoint(x: i, y: i % 20), color: .cyan, now: Double(i) / 10000) }
        XCTAssertLessThanOrEqual(trail.sublayers?.count ?? 0, SwipeTrailLayer.maximumSegments)
        trail.clear()
        trail.append(CGPoint(x: 100, y: 100), color: .orange)
        XCTAssertTrue(trail.sublayers?.isEmpty ?? true)
        trail.append(CGPoint(x: 110, y: 110), color: .orange)
        XCTAssertEqual(trail.sublayers?.count, 1)
    }
}

extension SwipeTrailTests {
    func testPresentationTapersFromThickHeadToNothing() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        let controller = UIViewController()
        controller.view.backgroundColor = .secondarySystemBackground
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let trail = SwipeTrailLayer()
        controller.view.layer.addSublayer(trail)
        trail.append(CGPoint(x: 30, y: 160), color: .systemPink)
        for i in 1...18 {
            trail.append(CGPoint(x: 30 + i * 17, y: 110 + Int(sin(Double(i) * 0.35) * 50)), color: .systemPink)
            try await Task.sleep(for: .milliseconds(8))
        }
        let head = try XCTUnwrap(trail.sublayers?.last as? CAShapeLayer)
        let born = CACurrentMediaTime()
        try await Task.sleep(for: .milliseconds(35))
        let initial = try XCTUnwrap(head.presentation())
        // A loaded Mac can oversleep, so the bound follows the head's real age: it narrows evenly
        // over the lifetime and has lost no more than that share of its width.
        let age = CACurrentMediaTime() - born
        if age < SwipeTrailLayer.lifetime / 2 {
            XCTAssertGreaterThan(initial.lineWidth, SwipeTrailLayer.headWidth / 2, "the head stays thick near the finger")
        }
        let width = initial.lineWidth
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            UIColor.secondarySystemBackground.setFill()
            context.fill(window.bounds)
            // Render the running presentation layers; unhosted XCTest windows cannot
            // reliably use drawHierarchy's screen snapshot service.
            for segment in trail.sublayers ?? [] { segment.presentation()?.render(in: context.cgContext) }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Selected pink accent, comet swipe trail: thick round head to a fine tip"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await Task.sleep(for: .milliseconds(70))
        let later = try XCTUnwrap(head.presentation())
        XCTAssertLessThan(later.lineWidth, width)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(head.presentation()?.lineWidth ?? head.lineWidth, 0)
    }
}

/// The home mark is the bare Z, with no tile, in the accent's ink tone for each appearance.
extension SwipeTrailTests {
    /// Renders the bare Z on both keyboard backdrops; the attachments show it reads on each.
    func testHomeMarkIsTheBareZInTheAccentInk() throws {
        KeyboardTheme.refreshAccent()
        XCTAssertEqual(UIColor(KeyboardTheme(isDark: true).accentInk), KeyboardTheme.accentUIColor)
        XCTAssertEqual(UIColor(KeyboardTheme(isDark: false).accentInk), KeyboardTheme.accentOnLightUIColor)
        let samples = [(false, Color(hex: 0xD3D5DB)), (true, Color(hex: 0x2C2C2E))]
        for (dark, backdrop) in samples {
            let renderer = ImageRenderer(content:
                ZoneHomeMark(theme: KeyboardTheme(isDark: dark))
                    .padding(16)
                    .background(backdrop)
                    .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 3
            let image: UIImage = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Home mark on \(dark ? "dark" : "light") keyboard"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
