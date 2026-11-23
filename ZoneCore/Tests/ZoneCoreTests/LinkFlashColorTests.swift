// by zayd/cold @ zayd.wtf

#if canImport(CoreImage) && canImport(Vision)
import CryptoKit
import Vision
import XCTest
@testable import ZoneCore

/// Color Flash: three frames in one picture, one in each of red, green and blue. Every channel,
/// read alone by Apple's barcode reader, must give back exactly its frame.
final class LinkFlashColorTests: XCTestCase {
    private let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)

    /// The bytes of the QR code in a gray picture, joined from its segments as any reader does.
    private func read(_ image: CGImage) throws -> Data? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let raw = request.results?.first?.payloadData else { return nil }
        return LinkFlashQRTests.message(codewords: [UInt8](raw))?.bytes
    }

    private func plan(dictations: Int = 120) throws -> LinkFlashPlan {
        try LinkFlash.plan(items: FlashFixtures.library(dictations: dictations), phone: FlashFixtures.phone, key: key,
                           codesPerPicture: LinkFlashMode.color.codesPerPicture)
    }

    func testEachChannelReadAloneIsItsFrame() throws {
        let plan = try plan()
        XCTAssertGreaterThanOrEqual(plan.encoder.chunkCount, 5, "plain frames and coded ones both appear in eight pictures")
        var checked = 0
        for picture in 0..<8 {
            let frames = plan.frames(inPicture: picture).map { plan.encoder.frame($0) }
            XCTAssertEqual(frames.count, 3)
            let small = try XCTUnwrap(LinkFlashColor.picture(frames))
            XCTAssertEqual(small.width, 103, "version 21 and Core Image's border, as in black and white")
            let shown = try XCTUnwrap(LinkFlashColor.image(small, scale: 6))
            for (channel, frame) in frames.enumerated() {
                let gray = try XCTUnwrap(LinkFlashColor.channel(shown, channel))
                if LinkFlashQRTests.visionSkips(frame) { continue }
                XCTAssertEqual(try read(gray), frame, "picture \(picture), channel \(channel)")
                checked += 1
            }
        }
        // Skipped: only frames whose bytes end in the last chunk's zero padding (Vision's limit,
        // see LinkFlashQRTests.visionSkips); zone reads those.
        XCTAssertGreaterThanOrEqual(checked, 20, "nearly every channel of eight pictures read back")
    }

    func testTheMosaicIsEightPureColorsWithBlackFindersOnWhite() throws {
        let plan = try plan()
        let frames = plan.frames(inPicture: 3).map { plan.encoder.frame($0) }
        let small = try XCTUnwrap(LinkFlashColor.picture(frames))
        let rgba = try XCTUnwrap(LinkFlashColor.rgba(small))
        let side = small.width
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * side + x) * 4..<(y * side + x) * 4 + 3]) }
        var colors = Set<[UInt8]>()
        for y in 0..<side { for x in 0..<side { colors.insert(pixel(x, y)) } }
        XCTAssertTrue(colors.allSatisfy { $0.allSatisfy { $0 == 0 || $0 == 255 } }, "only full on or off in each channel")
        XCTAssertEqual(colors.count, 8, "black, white and the six primaries and secondaries all appear")
        // Core Image's border is light in every code: white.
        for i in 0..<side {
            XCTAssertEqual(pixel(i, 0), [255, 255, 255])
            XCTAssertEqual(pixel(0, i), [255, 255, 255])
        }
        // The three finder patterns line up, so they are black and white like any QR code.
        for (fx, fy) in [(1, 1), (side - 8, 1), (1, side - 8)] {
            XCTAssertEqual(pixel(fx, fy), [0, 0, 0], "outer ring")
            XCTAssertEqual(pixel(fx + 1, fy + 1), [255, 255, 255], "light ring")
            XCTAssertEqual(pixel(fx + 3, fy + 3), [0, 0, 0], "center")
        }
    }

    func testTaggedForTheDisplayTheBytesStayPure() throws {
        // On the phone the picture is tagged Display P3, so 255 in one channel lights only that
        // subpixel. Reading it back in its own space must give the same pure bytes.
        let plan = try plan()
        let frames = plan.frames(inPicture: 0).map { plan.encoder.frame($0) }
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let small = try XCTUnwrap(LinkFlashColor.picture(frames, colorSpace: p3))
        XCTAssertEqual(small.colorSpace?.name, CGColorSpace.displayP3)
        let srgb = try XCTUnwrap(LinkFlashColor.picture(frames))
        XCTAssertEqual(LinkFlashColor.rgba(small), LinkFlashColor.rgba(srgb), "the same bytes, only the tag differs")
        let rgba = try XCTUnwrap(LinkFlashColor.rgba(small))
        XCTAssertTrue(rgba.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 || $0.element == 255 })
    }

    func testAPictureCarriesThreeFramesAndTheCycleCoversEveryFrame() throws {
        let plan = try plan()
        XCTAssertEqual(plan.codesPerPicture, 3)
        XCTAssertEqual(plan.frames(inPicture: 0), [0, 1, 2])
        XCTAssertEqual(plan.frames(inPicture: 5), [15, 16, 17])
        let cycle = plan.encoder.cycleLength
        XCTAssertEqual(plan.pictureCycle, (cycle + 2) / 3)
        let shown = Set((0..<plan.pictureCycle).flatMap { plan.frames(inPicture: $0) })
        XCTAssertEqual(shown, Set((0..<cycle).map(UInt32.init)), "every frame of the cycle appears in some picture")

        let blackAndWhite = try LinkFlash.plan(items: FlashFixtures.library(dictations: 120), phone: FlashFixtures.phone, key: key)
        XCTAssertEqual(blackAndWhite.codesPerPicture, 1)
        XCTAssertEqual(blackAndWhite.frames(inPicture: 7), [7])
        XCTAssertEqual(plan.seconds * 3, blackAndWhite.seconds, accuracy: 1e-9, "three codes a picture, three times as fast")
    }

    func testCodesOfDifferentSizesAreCenteredSoEachChannelStaysWhole() throws {
        let big = try XCTUnwrap(LinkFlashQR.modules(Data(repeating: 0x9C, count: 917)))
        let small = try XCTUnwrap(LinkFlashQR.modules(Data(repeating: 0x9C, count: 317)))
        let picture = try XCTUnwrap(LinkFlashColor.compose([big, small, big]))
        XCTAssertEqual(picture.width, big.width)
        let shown = try XCTUnwrap(LinkFlashColor.image(picture, scale: 6))
        XCTAssertEqual(try read(try XCTUnwrap(LinkFlashColor.channel(shown, 1))), Data(repeating: 0x9C, count: 317))
        XCTAssertEqual(try read(try XCTUnwrap(LinkFlashColor.channel(shown, 0))), Data(repeating: 0x9C, count: 917))
        XCTAssertNil(LinkFlashColor.compose([]))
        XCTAssertNil(LinkFlashColor.compose([big, big, big, big]))
    }

    /// Writes a color flash as PNG pictures for the computer side: `ZONE_FLASH_COLOR_OUT=/tmp/x
    /// swift test --package-path ZoneCore --filter LinkFlashColorTests/testWriteColorPicturesForTheComputerSide`.
    /// Synthetic items sealed with the published test secret (`ab` 32 times), and `expected.json`.
    /// `ZONE_FLASH_PALETTE=dusk` (or `aurora`, `ember`) draws them in that scene's palette
    /// instead of pure 0 and 255; `ZONE_FLASH_SPAN=120` narrows or widens every channel to that
    /// span first; `ZONE_FLASH_SCALE` is pixels per module (default 6).
    func testWriteColorPicturesForTheComputerSide() throws {
        let environment = ProcessInfo.processInfo.environment
        let exporting = environment["ZONE_FLASH_COLOR_OUT"] != nil
        let directory = environment["ZONE_FLASH_COLOR_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("zone-flash-color-\(UUID().uuidString)", isDirectory: true)
        let secretKey = LinkPairingLink(endpointID: FlashFixtures.endpoint, secret: FlashFixtures.secretHex, name: "test").flashKey
        let items = FlashFixtures.library(dictations: environment["ZONE_FLASH_ITEMS"].flatMap { Int($0) } ?? (exporting ? 400 : 40))
        let plan = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: secretKey, session: 0xC0_10_4E_45,
                                      codesPerPicture: 3, nonce: Data(0..<12))
        let scene = environment["ZONE_FLASH_PALETTE"].flatMap { LinkFlashScene(named: $0) }
        var palette = scene?.palette ?? .pure
        if let span = environment["ZONE_FLASH_SPAN"].flatMap({ Int($0) }), let scene {
            // The scene's levels as it asks for them, held to another span: for finding how
            // narrow the computer side can still read.
            let wanted = scene.palette
            palette = LinkFlashPalette(dark: (Int(wanted.light[0]) - span, Int(wanted.light[1]) - span, Int(wanted.light[2]) - span),
                                       light: (Int(wanted.light[0]), Int(wanted.light[1]), Int(wanted.light[2])), span: span)
        }
        let scale = environment["ZONE_FLASH_SCALE"].flatMap { Int($0) } ?? 6
        let pictures = (plan.encoder.chunkCount + 2) / 3 * 2 + 10
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<pictures {
            let frames = plan.frames(inPicture: index).map { plan.encoder.frame($0) }
            let png = try XCTUnwrap(LinkFlashColor.png(frames, palette: palette, scale: scale))
            try png.write(to: directory.appendingPathComponent(String(format: "picture-%05d.png", index)))
        }
        try LinkFlashPayload.json(phone: FlashFixtures.phone, items: items)
            .write(to: directory.appendingPathComponent("expected.json"))
        let manifest: [String: Any] = [
            "made_by": "ZoneCore LinkFlashColorTests.testWriteColorPicturesForTheComputerSide",
            "secret": FlashFixtures.secretHex, "k": plan.encoder.chunkCount, "c": plan.encoder.chunkBytes,
            "pictures": pictures, "codes_per_picture": 3, "channels": "red, green, blue: frames 3p, 3p+1, 3p+2",
            "items": items.count, "palette": scene?.name ?? "pure",
            "dark": palette.dark.map(Int.init), "light": palette.light.map(Int.init), "pixels_per_module": scale,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
        if !exporting { try? FileManager.default.removeItem(at: directory) }
    }
}
#endif
