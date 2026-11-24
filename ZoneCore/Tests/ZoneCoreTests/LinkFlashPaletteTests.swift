// by zayd/cold @ zayd.wtf

#if canImport(CoreImage) && canImport(Vision)
import Vision
import XCTest
@testable import ZoneCore

/// The palettes a color Flash is drawn in: two levels a channel, far enough apart to read, and
/// a picture in any of them still gives back each channel's frame.
final class LinkFlashPaletteTests: XCTestCase {
    private let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)

    private func read(_ image: CGImage) throws -> Data? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let raw = request.results?.first?.payloadData else { return nil }
        return LinkFlashQRTests.message(codewords: [UInt8](raw))?.bytes
    }

    private func plan() throws -> LinkFlashPlan {
        try LinkFlash.plan(items: FlashFixtures.library(dictations: 120), phone: FlashFixtures.phone, key: key,
                           session: 0xDA4F_4E45, codesPerPicture: LinkFlashMode.color.codesPerPicture, nonce: Data(0..<12))
    }

    // MARK: The contract with the computer's reader

    func testEveryScenePaletteKeepsTheSpanInEveryChannel() {
        XCTAssertEqual(LinkFlashPalette.span, 150, "the computer side reads 120 and up and recommends 150: agree a change with it")
        XCTAssertGreaterThanOrEqual(LinkFlashPalette.span, 120, "the least the computer's reader is built for")
        for scene in LinkFlashScene.allCases {
            let palette = scene.palette
            XCTAssertGreaterThanOrEqual(palette.narrowestSpan, LinkFlashPalette.span, scene.name)
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(Int(palette.light[channel]) - Int(palette.dark[channel]), LinkFlashPalette.span,
                                            "\(scene.name), channel \(channel)")
            }
            // Green carries the most: its span is never smaller than red's or blue's.
            let spans = (0..<3).map { Int(palette.light[$0]) - Int(palette.dark[$0]) }
            XCTAssertGreaterThanOrEqual(spans[1], spans[0], "green against red: \(scene.name)")
            XCTAssertGreaterThanOrEqual(spans[1], spans[2], "green against blue: \(scene.name)")
            XCTAssertEqual(Set(palette.colors).count, 8, "eight different colors: \(scene.name)")
            XCTAssertEqual(palette.colors.first, palette.dark, "all dark")
            XCTAssertEqual(palette.colors.last, palette.light, "all light")
        }
        XCTAssertEqual(LinkFlashPalette.pure.dark, [0, 0, 0])
        XCTAssertEqual(LinkFlashPalette.pure.light, [255, 255, 255])
        XCTAssertEqual(Set(LinkFlashScene.allCases.map(\.palette.light)).count, 3, "each scene its own palette")
    }

    func testThePalettesAreTheDesignedOnesAtTheAgreedSpan() {
        // Written out, so a change of the span or of a level shows up here and is meant.
        XCTAssertEqual(LinkFlashScene.dusk.palette.dark, [60, 0, 90])
        XCTAssertEqual(LinkFlashScene.dusk.palette.light, [255, 200, 255])
        XCTAssertEqual(LinkFlashScene.aurora.palette.dark, [0, 30, 70])
        XCTAssertEqual(LinkFlashScene.aurora.palette.light, [150, 255, 255])
        XCTAssertEqual(LinkFlashScene.ember.palette.dark, [80, 20, 0])
        XCTAssertEqual(LinkFlashScene.ember.palette.light, [255, 240, 165])
    }

    func testAPaletteAskedForTooNarrowIsWidenedToTheSpan() {
        // The dark level gives way first.
        let narrow = LinkFlashPalette(dark: (120, 100, 200), light: (255, 180, 255))
        XCTAssertEqual(narrow.light, [255, 180, 255])
        XCTAssertEqual(narrow.dark, [105, 30, 105])
        // Only when the dark is already 0 does the light rise.
        let low = LinkFlashPalette(dark: (0, 0, 0), light: (100, 120, 255))
        XCTAssertEqual(low.dark, [0, 0, 0])
        XCTAssertEqual(low.light, [150, 150, 255])
        // Another span is one argument, which is how the cross-test pictures try narrower ones.
        let tight = LinkFlashPalette(dark: (120, 100, 200), light: (255, 180, 255), span: 60)
        XCTAssertEqual(tight.dark, [120, 100, 195])
        // Levels outside 0 to 255 are clamped, and a dark above its light comes down under it.
        let odd = LinkFlashPalette(dark: (-20, 300, 40), light: (400, 500, 20), span: 10)
        XCTAssertEqual(odd.light, [255, 255, 20])
        XCTAssertEqual(odd.dark, [0, 245, 10])
    }

    // MARK: Pictures in a palette

    func testAPictureInAPaletteUsesOnlyItsTwoLevelsWithLightQuietZoneAndDarkFinders() throws {
        let plan = try plan()
        let frames = plan.frames(inPicture: 3).map { plan.encoder.frame($0) }
        for scene in LinkFlashScene.allCases {
            let palette = scene.palette
            let small = try XCTUnwrap(LinkFlashColor.picture(frames, palette: palette))
            let rgba = try XCTUnwrap(LinkFlashColor.pixels(small))
            let side = small.width
            func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * side + x) * 4..<(y * side + x) * 4 + 3]) }
            var colors = Set<[UInt8]>()
            for y in 0..<side { for x in 0..<side { colors.insert(pixel(x, y)) } }
            XCTAssertEqual(colors, Set(palette.colors), "exactly the palette's eight colors: \(scene.name)")
            for i in 0..<side {
                XCTAssertEqual(pixel(i, 0), palette.light, "the border is the all-light color")
                XCTAssertEqual(pixel(side - 1, i), palette.light)
            }
            for (fx, fy) in [(1, 1), (side - 8, 1), (1, side - 8)] {
                XCTAssertEqual(pixel(fx, fy), palette.dark, "the finder's ring is the all-dark color")
                XCTAssertEqual(pixel(fx + 1, fy + 1), palette.light)
                XCTAssertEqual(pixel(fx + 3, fy + 3), palette.dark)
            }
            // Enlarged for a screen or a file, the quiet zone around it is the same light color.
            let shown = try XCTUnwrap(LinkFlashColor.image(small, scale: 4))
            let large = try XCTUnwrap(LinkFlashColor.pixels(shown))
            XCTAssertEqual(Array(large[0..<3]), palette.light, scene.name)
            let last = (shown.width * shown.height - 1) * 4
            XCTAssertEqual(Array(large[last..<last + 3]), palette.light, scene.name)
        }
    }

    func testRecoloringAPurePictureIsTheSameAsDrawingItInThePalette() throws {
        // The Flash screen keeps pure pictures and recolors their bytes for the scene on show.
        let plan = try plan()
        let frames = plan.frames(inPicture: 5).map { plan.encoder.frame($0) }
        let pure = try XCTUnwrap(LinkFlashColor.pixels(try XCTUnwrap(LinkFlashColor.picture(frames))))
        for scene in LinkFlashScene.allCases {
            var recolored = pure
            scene.palette.recolor(&recolored)
            let drawn = try XCTUnwrap(LinkFlashColor.pixels(try XCTUnwrap(LinkFlashColor.picture(frames, palette: scene.palette))))
            XCTAssertEqual(recolored, drawn, scene.name)
        }
        var untouched = pure
        LinkFlashPalette.pure.recolor(&untouched)
        XCTAssertEqual(untouched, pure)
    }

    func testEachChannelOfAPalettePictureReadAloneIsItsFrame() throws {
        // No unmixing, no stretching: the raw channel, with its dark at 60 or 80 instead of 0.
        let plan = try plan()
        var checked = 0
        for scene in LinkFlashScene.allCases {
            for picture in 0..<4 {
                let frames = plan.frames(inPicture: picture).map { plan.encoder.frame($0) }
                let small = try XCTUnwrap(LinkFlashColor.picture(frames, palette: scene.palette))
                let shown = try XCTUnwrap(LinkFlashColor.image(small, scale: 6))
                for (channel, frame) in frames.enumerated() where !LinkFlashQRTests.visionSkips(frame) {
                    let gray = try XCTUnwrap(LinkFlashColor.channel(shown, channel))
                    XCTAssertEqual(try read(gray), frame, "\(scene.name), picture \(picture), channel \(channel)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 30, "nearly every channel of twelve pictures read back")
    }

    // MARK: Scenes

    func testTheSessionChoosesTheSceneAndActsMoveThroughAllThree() {
        XCTAssertEqual(LinkFlashScene(session: 0x8000_0000), LinkFlashScene.allCases[Int(0x8000_0000 % 3)])
        var seen = Set<LinkFlashScene>()
        for session in UInt32(0x8000_0000)..<UInt32(0x8000_0040) { seen.insert(LinkFlashScene(session: session)) }
        XCTAssertEqual(seen.count, 3, "different flashes open in different scenes")
        for scene in LinkFlashScene.allCases {
            XCTAssertEqual(scene.act(0), scene)
            XCTAssertEqual(Set((0..<3).map { scene.act($0) }).count, 3, "three acts, three scenes")
            XCTAssertEqual(scene.act(3), scene, "and round again")
            XCTAssertEqual(LinkFlashScene(named: scene.name), scene)
            XCTAssertEqual(LinkFlashScene(named: " \(scene.name.uppercased()) "), scene)
            XCTAssertEqual(LinkFlashScene(named: "\(scene.rawValue)"), scene)
        }
        XCTAssertNil(LinkFlashScene(named: "noir"))
        XCTAssertNil(LinkFlashScene(named: "7"))
    }
}
#endif
