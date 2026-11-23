// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The Flash code on its band: never smaller than before, always on white with at least four
/// light modules on every side.
final class LinkFlashLayoutTests: XCTestCase {
    /// iPhone screens in points and their scale, small to large.
    private let screens: [(width: Int, height: Int, scale: Int)] = [
        (320, 568, 2), (375, 667, 2), (375, 812, 3), (390, 844, 3), (393, 852, 3),
        (402, 874, 3), (414, 896, 2), (414, 896, 3), (428, 926, 3), (430, 932, 3), (440, 956, 3),
    ]

    func testTheCodeIsNeverSmallerThanBeforeTheArtAndKeepsItsQuietZone() {
        for screen in screens {
            // Frames are 917 bytes (version 21, 103 modules with Core Image's border) or, for
            // larger codes, 317 (version 11, 63). Others are checked in case a size changes.
            for modules in [63, 79, 91, 103, 111] {
                let width = screen.width * screen.scale, height = screen.height * screen.scale
                // Header and footer text, as the Flash screen keeps clear.
                let top = 110 * screen.scale, bottom = 120 * screen.scale
                let layout = LinkFlashLayout(width: width, height: height, top: top, bottom: bottom,
                                             modules: modules, minimumArt: 12 * screen.scale)
                // Before the art: the code area was the height between the header and the controls.
                let before = LinkFlashLayout.previousModule(width: width, scale: screen.scale,
                                                            codeAreaHeight: height - top - bottom, modules: modules)
                let name = "\(screen.width)x\(screen.height)@\(screen.scale)x, \(modules) modules"
                XCTAssertGreaterThanOrEqual(layout.module, before, name)
                XCTAssertGreaterThanOrEqual(layout.quietZone.horizontal, LinkFlashLayout.quietModules, name)
                XCTAssertGreaterThanOrEqual(layout.quietZone.vertical, LinkFlashLayout.quietModules, name)
                XCTAssertGreaterThanOrEqual(layout.codeX, 0, name)
                XCTAssertLessThanOrEqual(layout.codeX + layout.codeSide, width, name)
                XCTAssertGreaterThanOrEqual(layout.bandY, top, name)
                XCTAssertLessThanOrEqual(layout.bandY + layout.bandHeight, height - bottom, name)
                XCTAssertEqual(layout.codeSide, modules * layout.module, "every module whole pixels: \(name)")
                XCTAssertEqual(layout.codeY - layout.bandY, layout.bandY + layout.bandHeight - (layout.codeY + layout.codeSide),
                               "centered in the band: \(name)")
                // In color the art comes up to the portal's edge, so the quiet zone is all inside it.
                XCTAssertEqual(layout.portalQuiet, LinkFlashLayout.quietModules, "four light modules inside the portal: \(name)")
                XCTAssertEqual(layout.portalSide, (modules + 6) * layout.module, name)
                XCTAssertGreaterThanOrEqual(layout.portalX, 0, name)
                XCTAssertLessThanOrEqual(layout.portalX + layout.portalSide, width, name)
                XCTAssertEqual(layout.portalX, width - layout.portalX - layout.portalSide, accuracy: 1, "centered: \(name)")
                XCTAssertEqual(layout.portalMargin(width: width), layout.portalX, name)
            }
        }
    }

    func testTheUsualFrameOnAnIPhone17Pro() {
        // 402 by 874 points at 3x, the version 11 frame (61 modules and Core Image's border).
        let layout = LinkFlashLayout(width: 1206, height: 2622, top: 330, bottom: 360, modules: 63, minimumArt: 36)
        XCTAssertEqual(layout.module, 17, "17 pixels a module, as before the art")
        XCTAssertEqual(layout.bandHeight, 69 * 17)
        XCTAssertEqual(layout.quietZone.vertical, 4)
        XCTAssertEqual(layout.quietZone.horizontal, 4, "and 16 pixels more")
    }

    func testTheFastFrameOnAnIPhone17Pro() {
        let layout = LinkFlashLayout(width: 1206, height: 2622, top: 330, bottom: 360, modules: 103, minimumArt: 36)
        XCTAssertEqual(layout.module, 11, "11 pixels a module, the code 1133 pixels wide")
        XCTAssertGreaterThanOrEqual(layout.quietZone.horizontal, 4)
        XCTAssertEqual(layout.quietZone.vertical, 4)
    }

    func testAShortScreenShrinksTheCodeToFitTheBandBetweenTheText() {
        let layout = LinkFlashLayout(width: 1206, height: 1400, top: 300, bottom: 300, modules: 63)
        XCTAssertLessThanOrEqual(layout.bandHeight, 800)
        XCTAssertEqual(layout.module, 800 / 69)
        XCTAssertGreaterThanOrEqual(layout.quietZone.vertical, 4)
    }
}
