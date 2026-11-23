// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// The Bars voice graphic as it is drawn: the swell shape of the shared bar meter.
@MainActor
final class VoiceGraphicBarsTests: XCTestCase {
    private func meter(width: CGFloat = 136, height: CGFloat = 40, levels: [Float],
                       shape: SignalLevelMeter.Shape = .swell) -> [CAShapeLayer] {
        let view = SignalLevelMeter.LevelBarsView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.update(levels: levels, count: 32, pitch: nil, shape: shape, color: .systemPurple, animated: false)
        view.layoutIfNeeded()
        return (view.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    }

    private func box(_ bar: CAShapeLayer) -> CGRect { bar.path?.boundingBox ?? .null }

    func testTheWidthDecidesTheBarCountAndTheRowIsCentered() {
        let bars = meter(levels: [Float](repeating: 0.5, count: 36))
        XCTAssertEqual(bars.count, VoiceBars.count(fitting: 136))
        XCTAssertEqual(bars.count % 2, 1)
        let left = box(bars.first!).minX
        let right = 136 - box(bars.last!).maxX
        XCTAssertEqual(left, right, accuracy: 0.01)
        XCTAssertEqual(box(bars[bars.count / 2]).midX, 68, accuracy: 0.01)
        XCTAssertEqual(box(bars[1]).minX - box(bars[0]).minX, VoiceBars.pitch, accuracy: 0.01)
    }

    func testBarsAreSolidTwoPointsWideAndTallestInTheMiddle() {
        let bars = meter(levels: [Float](repeating: 0.5, count: 36))
        XCTAssertTrue(bars.allSatisfy { $0.opacity == 1 })
        XCTAssertTrue(bars.allSatisfy { abs(box($0).width - 2) < 0.01 })
        let heights = bars.map { box($0).height }
        XCTAssertEqual(heights.max(), heights[bars.count / 2])
        XCTAssertEqual(heights[bars.count / 2], 40 * pow(0.5, 0.62), accuracy: 0.05)
        XCTAssertLessThan(heights.first!, heights[bars.count / 2] * 0.4)
        XCTAssertTrue(bars.allSatisfy { abs(box($0).midY - 20) < 0.01 }, "every bar straddles the center line")
    }

    func testSilenceAndNoSamplesLeaveARowOfStubs() {
        for levels in [[Float](repeating: 0, count: 36), []] {
            let bars = meter(levels: levels)
            XCTAssertEqual(bars.count, 37)
            XCTAssertTrue(bars.allSatisfy { abs(box($0).height - 3.5) < 0.01 })
        }
    }

    func testAShoutNeverLeavesTheView() {
        let bars = meter(levels: [.infinity, 4, 1, 1, .nan, 1, 1])
        XCTAssertTrue(bars.allSatisfy { box($0).height <= 40.001 && box($0).minY >= -0.001 })
    }

    func testAWideRowAndAThinOneBothDraw() {
        XCTAssertEqual(meter(width: 420, levels: [0.3, 0.6]).count, VoiceBars.count(fitting: 420))
        XCTAssertEqual(meter(width: 3, levels: [0.3, 0.6]).count, 0)
        XCTAssertEqual(meter(width: 0, levels: [0.3, 0.6]).count, 0)
    }

    /// The meter the note card and the dictation screen use is drawn as before.
    func testTheTrailShapeIsUnchanged() {
        let levels = (0..<32).map { Float($0) / 31 }
        let bars = meter(width: 160, levels: levels, shape: .trail)
        XCTAssertEqual(bars.count, 32)
        XCTAssertEqual(bars.first!.opacity, 0.35, accuracy: 0.001)
        XCTAssertEqual(bars.last!.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(box(bars.last!).height, 40, accuracy: 0.01)
        XCTAssertEqual(box(bars.first!).height, 3, accuracy: 0.01)
        XCTAssertEqual(box(bars[0]).width, 160.0 / 32 * 0.55, accuracy: 0.01)
    }

    func testSwitchingShapeRedrawsTheSameView() {
        let view = SignalLevelMeter.LevelBarsView(frame: CGRect(x: 0, y: 0, width: 136, height: 40))
        let levels = [Float](repeating: 0.5, count: 36)
        view.update(levels: levels, count: 32, pitch: nil, shape: .trail, color: .systemPurple, animated: false)
        view.layoutIfNeeded()
        XCTAssertEqual(view.layer.sublayers?.count, 32)
        view.update(levels: levels, count: 32, pitch: nil, shape: .swell, color: .systemPurple, animated: false)
        XCTAssertEqual(view.layer.sublayers?.count, 37)
        XCTAssertTrue((view.layer.sublayers ?? []).allSatisfy { $0.opacity == 1 })
    }
}
