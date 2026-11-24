// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DuoKeyboardTests: XCTestCase {
    func testFoldOverridesFlatPreferenceOnlyWhenItIntersectsThisHost() {
        func placement(_ width: CGFloat, center: CGFloat, fold: CGRect?, split: Bool = false) -> DuoKeyPlacement {
            .init(pose: .innerLandscape, width: width, center: center, side: 11, safeLeft: 0,
                  safeRight: 0, division: fold, prefersSplit: split)
        }
        let active = CGRect(x: 380.5, y: 0, width: 40, height: 245)
        XCTAssertFalse(placement(801, center: 400.5, fold: nil).split)
        XCTAssertTrue(placement(801, center: 400.5, fold: nil, split: true).split)
        XCTAssertTrue(placement(801, center: 400.5, fold: active).forced)
        let half = placement(360, center: 400.5, fold: active, split: true)
        XCTAssertFalse(half.offersSplit)
        XCTAssertEqual(half.leading, 0)
        XCTAssertEqual(half.trailing, 0)
        let partial = placement(550, center: 150, fold: CGRect(x: 130, y: 0, width: 40, height: 245))
        XCTAssertFalse(partial.offersSplit)
        XCTAssertEqual(partial.leading, 170)
        XCTAssertEqual(partial.trailing, 0)
    }

    func testNativeRowPitchAndOutsideEdgesInEachOrientation() {
        let cases: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, DuoKeyboard)] = [
            (466, 678, 452, 56, 45, 8, .coverPortrait),
            (678, 466, 528, 35.5, 27.5, 79, .coverLandscape),
            (669, 951, 655, 59.7, 46, 19, .innerPortrait),
            (951, 669, 801, 51.7, 39, 85.3, .innerLandscape)
        ]
        for (w, h, input, pitch, cap, edge, expected) in cases {
            let screen = CGSize(width: w, height: h)
            let pose = DuoKeyboard(isDuo: true, screen: screen)
            XCTAssertEqual(pose, expected)
            XCTAssertEqual(DuoKeyboard(isDuo: false, screen: screen), .ordinary)
            let inset = (w - input) / 2
            let m = pose.metrics(width: input, windowInset: inset)
            XCTAssertEqual(m.rowPitch, pitch)
            XCTAssertEqual(m.keyHeight, cap)
            XCTAssertEqual(m.sideInset + inset, edge, accuracy: 0.5)
            XCTAssertEqual(pose.allowsOneHand, expected == .coverPortrait)
        }
    }
}
