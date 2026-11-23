// by zayd/cold @ zayd.wtf

#if canImport(CoreImage) && canImport(Vision)
import CryptoKit
import Vision
import XCTest
@testable import ZoneCore

/// The pictures of a Flash: each frame as a QR code, read back by Apple's own barcode reader,
/// and the set of PNG files the computer side decodes in its cross-test.
final class LinkFlashQRTests: XCTestCase {
    /// The bytes of the QR code in a picture, as a camera-side reader sees them.
    private func read(_ image: CGImage) throws -> Data? {
        try readSegments(image)?.bytes
    }

    private func readSegments(_ image: CGImage) throws -> (bytes: Data, modes: [Int])? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let raw = request.results?.first?.payloadData else { return nil }
        return Self.message(codewords: [UInt8](raw))
    }

    /// Reads a QR code's data codewords (what Vision hands back) the way the QR standard lays
    /// them out: segments of a 4-bit mode, a character count, then the characters.
    ///
    /// Core Image writes a frame as one byte-mode segment, except that a long enough run of
    /// digits or capital letters inside it becomes a numeric or alphanumeric segment. Every
    /// standard reader joins the segments back into the same bytes, as this does. `modes` is
    /// the mode of each segment in order (4 is byte mode).
    static func message(codewords: [UInt8]) -> (bytes: Data, modes: [Int])? {
        // Level L data codewords: at most 232 for versions 1 to 9, 1370 for versions 10 to 26.
        let tier = codewords.count <= 232 ? 0 : codewords.count <= 1370 ? 1 : 2
        var position = 0
        func bits(_ count: Int) -> Int? {
            guard position + count <= codewords.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int(codewords[position / 8] >> UInt8(7 - position % 8) & 1)
                position += 1
            }
            return value
        }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)
        var out = Data()
        var modes: [Int] = []
        while let mode = bits(4), mode != 0 {
            modes.append(mode)
            switch mode {
            case 0b0001:
                guard var left = bits([10, 12, 14][tier]) else { return nil }
                while left > 0 {
                    let digits = min(3, left)
                    guard let value = bits([0, 4, 7, 10][digits]) else { return nil }
                    out.append(contentsOf: String(format: "%0\(digits)d", value).utf8)
                    left -= digits
                }
            case 0b0010:
                guard var left = bits([9, 11, 13][tier]) else { return nil }
                while left > 0 {
                    if left >= 2 {
                        guard let value = bits(11), value < 45 * 45 else { return nil }
                        out.append(contentsOf: [alphabet[value / 45], alphabet[value % 45]])
                        left -= 2
                    } else {
                        guard let value = bits(6), value < 45 else { return nil }
                        out.append(alphabet[value])
                        left -= 1
                    }
                }
            case 0b0100:
                guard let count = bits([8, 16, 16][tier]) else { return nil }
                for _ in 0..<count {
                    guard let byte = bits(8) else { return nil }
                    out.append(UInt8(byte))
                }
            default:
                // Kanji, ECI and the rest would change what a reader reports. A frame never uses them.
                return nil
            }
        }
        return (out, modes)
    }

    /// Apple's reader (Vision) gives up on a code whose bytes end in a long run of zeros: the
    /// last plain frame of a flash, its chunk padded out with up to 899 zero bytes. zone's own
    /// reader reads those frames (checked with `zone dev flash-decode` on the PNG this file
    /// writes, frame 4 of 80 dictations), so it is this harness's limit, not the code's. The
    /// frame is still written for the computer side's cross-test; only Vision skips it.
    static func visionSkips(_ frame: Data) -> Bool {
        frame.reversed().prefix { $0 == 0 }.count >= 200
    }

    func testTheUsualFrameIsAVersionTwentyOneCode() throws {
        let encoder = try LinkFlashEncoder(payload: Data((0..<4000).map { UInt8(($0 * 7 + 3) & 0xff) }), session: 0x8102_0304)
        let frame = encoder.frame(5)
        XCTAssertEqual(frame.count, 917)
        let small = try XCTUnwrap(LinkFlashQR.modules(frame))
        // Version 21 is 101 modules a side, and Core Image's one-module border.
        XCTAssertEqual(small.width, 103)
        let large = try XCTUnwrap(LinkFlashQR.image(frame, scale: 5))
        XCTAssertEqual(try read(large), frame, "Apple's reader reads the dense code back exactly")
    }

    func testALargerFrameIsAVersionElevenCode() throws {
        let encoder = try LinkFlashEncoder(payload: Data((0..<1280).map { UInt8(($0 * 7 + 3) & 0xff) }), session: 0x0102_0304,
                                           chunkBytes: 300)
        let frame = encoder.frame(7)
        XCTAssertEqual(frame.count, 317)
        let small = try XCTUnwrap(LinkFlashQR.modules(frame))
        // Version 11 is 61 modules a side; Core Image adds one module of border on each side.
        XCTAssertEqual(small.width, 63)
        XCTAssertEqual(small.height, 63)

        let large = try XCTUnwrap(LinkFlashQR.image(frame, scale: 8))
        XCTAssertEqual(large.width, (61 + 8) * 8, "four modules of quiet border on each side")
        XCTAssertEqual(large.width, large.height)
        // Nearest neighbour: only pure black and pure white, never a blend.
        let data = try XCTUnwrap(large.dataProvider?.data as Data?)
        var shades = Set<UInt8>()
        for row in 0..<large.height {
            for column in 0..<large.width { shades.insert(data[row * large.bytesPerRow + column]) }
        }
        XCTAssertEqual(shades, [0, 255])
    }

    func testEveryByteValueSurvivesTheCode() throws {
        // Bodies are ciphertext: every byte value appears, including zero and the high half.
        var body = Data((0..<300).map { UInt8($0 & 0xff) })
        body[0] = 0
        let encoder = try LinkFlashEncoder(payload: body, session: 0xFFFF_FFFF)
        for index in [UInt32(0), 1, 2, 77] {
            let frame = encoder.frame(index)
            let image = try XCTUnwrap(LinkFlashQR.image(frame, scale: 6))
            XCTAssertEqual(try read(image), frame, "frame \(index)")
        }
    }

    func testARunOfLettersOrDigitsStillReadsAsTheSameBytes() throws {
        // Not what a sealed payload looks like, but possible: Core Image writes these runs as
        // alphanumeric and numeric segments. A reader must give back the same bytes.
        var body = Data((0..<300).map { _ in UInt8.random(in: 128...255) })
        body.replaceSubrange(40..<70, with: Data("ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*".utf8))
        body.replaceSubrange(200..<230, with: Data("012345678901234567890123456789".utf8))
        let frame = try LinkFlashEncoder(payload: body, session: 0x5A4F_4E45).frame(0)
        XCTAssertEqual(String(decoding: frame.prefix(7), as: UTF8.self), "ZF1ZONE")
        let found = try XCTUnwrap(try readSegments(try XCTUnwrap(LinkFlashQR.image(frame, scale: 6))))
        XCTAssertEqual(found.bytes, frame)
        XCTAssertTrue(found.modes.contains(0b0001) && found.modes.contains(0b0010), "modes \(found.modes)")
    }

    func testAFrameOfSealedBytesIsOneByteSegment() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let plan = try LinkFlash.plan(items: FlashFixtures.library(dictations: 80), phone: FlashFixtures.phone, key: key)
        XCTAssertGreaterThanOrEqual(plan.encoder.session, 0x8000_0000)
        for index in 0..<60 {
            let frame = plan.encoder.frame(UInt32(index))
            if Self.visionSkips(frame) { continue }
            let found = try XCTUnwrap(try readSegments(try XCTUnwrap(LinkFlashQR.image(frame, scale: 5))))
            XCTAssertEqual(found.bytes, frame)
            XCTAssertEqual(found.modes, [0b0100], "frame \(index)")
        }
    }

    func testAFlashReadFromItsPicturesOpensToTheSameItems() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashFixtures.library(dictations: 60)
        let plan = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key)
        var decoder = FlashTestDecoder()
        var index = plan.encoder.chunkCount
        while !decoder.isComplete, index < plan.encoder.cycleLength {
            let image = try XCTUnwrap(LinkFlashQR.image(plan.encoder.frame(UInt32(index)), scale: 5))
            if let bytes = try read(image) { decoder.add(bytes) }
            index += 1
        }
        let json = try LinkFlashPayload.open(try XCTUnwrap(decoder.payload()), key: key)
        XCTAssertEqual(json, try LinkFlashPayload.json(phone: FlashFixtures.phone, items: items))
    }

    /// How long one frame takes to make: the XOR of its chunks, then the QR code. The sender
    /// shows twenty a second, so each has 50 ms; this prints what a frame really costs.
    func testFrameGenerationTime() throws {
        for (label, size) in [("12 kB (a day or two)", 12_000), ("400 kB (a large library)", 400_000)] {
            let payload = Data((0..<size).map { UInt8(($0 * 31 + 5) & 0xff) })
            let encoder = try LinkFlashEncoder(payload: payload, session: 0xA1B2_C3D4)
            var bytesTime = 0.0, codeTime = 0.0, worst = 0.0
            let count = 240
            for step in 0..<count {
                let index = UInt32(encoder.chunkCount + step)
                let start = CFAbsoluteTimeGetCurrent()
                let frame = encoder.frame(index)
                let middle = CFAbsoluteTimeGetCurrent()
                XCTAssertNotNil(LinkFlashQR.modules(frame))
                let end = CFAbsoluteTimeGetCurrent()
                bytesTime += middle - start
                codeTime += end - middle
                worst = max(worst, end - start)
            }
            let each = (bytesTime + codeTime) / Double(count) * 1000
            print(String(format: "FLASH-TIMING %@: k=%d, frame bytes %.3f ms, QR code %.3f ms, total %.3f ms, worst %.3f ms",
                         label, encoder.chunkCount, bytesTime / Double(count) * 1000, codeTime / Double(count) * 1000, each, worst * 1000))
            XCTAssertLessThan(each, 20, "a frame must take far less than the 50 ms it is shown for")
        }
    }

    /// Writes a Flash as PNG files, for the computer side's `zone dev flash-decode`.
    ///
    ///     ZONE_FLASH_OUT=/tmp/zone-flash-frames-ios \
    ///     ZONE_FLASH_SECRET=abab...ab (64 hex, a pairing secret) \
    ///     swift test --package-path ZoneCore --filter LinkFlashQRTests/testWriteFramesForTheComputerSide
    ///
    /// Instead of ZONE_FLASH_SECRET: ZONE_FLASH_LINK (a whole `zone://pair?...` link) or
    /// ZONE_FLASH_KEY (the 32-byte Flash key as 64 hex). Optional: ZONE_FLASH_ITEMS (dictations
    /// in the synthetic library, default 400), ZONE_FLASH_FRAMES (how many frames, default
    /// 2k + 30: every plain frame, then k + 30 coded ones), ZONE_FLASH_SCALE (pixels per module,
    /// default 8), ZONE_FLASH_SESSION (the session as 8 hex characters, default da4f4e45).
    /// Without ZONE_FLASH_OUT it writes a small set to a temporary folder.
    func testWriteFramesForTheComputerSide() throws {
        let environment = ProcessInfo.processInfo.environment
        let key: Data
        var keySource = "secret \(FlashFixtures.secretHex)"
        if let link = environment["ZONE_FLASH_LINK"] {
            key = try LinkPairingLink.parse(link).flashKey
            keySource = "pairing link"
        } else if let hex = environment["ZONE_FLASH_KEY"] {
            XCTAssertEqual(hex.count, 64)
            key = FlashFixtures.bytes(hex: hex)
            keySource = "key"
        } else {
            let secret = environment["ZONE_FLASH_SECRET"] ?? FlashFixtures.secretHex
            XCTAssertTrue(LinkPairingLink.isSecret(secret), "ZONE_FLASH_SECRET must be 64 lowercase hex characters")
            key = LinkPairingLink(endpointID: FlashFixtures.endpoint, secret: secret, name: "test").flashKey
            keySource = "secret \(secret)"
        }
        let exporting = environment["ZONE_FLASH_OUT"] != nil
        let directory = environment["ZONE_FLASH_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("zone-flash-\(UUID().uuidString)", isDirectory: true)
        let dictations = environment["ZONE_FLASH_ITEMS"].flatMap { Int($0) } ?? (exporting ? 400 : 30)
        let scale = environment["ZONE_FLASH_SCALE"].flatMap { Int($0) } ?? 8

        let items = FlashFixtures.library(dictations: dictations)
        // A fixed session and nonce, so the same command writes the same files.
        let session = environment["ZONE_FLASH_SESSION"].flatMap { UInt32($0, radix: 16) } ?? 0xDA4F_4E45
        let plan = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, session: session, nonce: Data(0..<12))
        let json = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: items)
        let count = environment["ZONE_FLASH_FRAMES"].flatMap { Int($0) } ?? (2 * plan.encoder.chunkCount + 30)

        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var all = Data()
        var mixed = 0
        for index in 0..<count {
            let frame = plan.encoder.frame(UInt32(index))
            all.append(frame)
            let png = try XCTUnwrap(LinkFlashQR.png(frame, scale: scale))
            try png.write(to: directory.appendingPathComponent(String(format: "frame-%05d.png", index)))
            if Self.visionSkips(frame) { continue }
            let found = try XCTUnwrap(try readSegments(try XCTUnwrap(LinkFlashQR.image(frame, scale: scale))), "frame \(index)")
            XCTAssertEqual(found.bytes, frame, "frame \(index)")
            if found.modes != [0b0100] { mixed += 1 }
        }
        try json.write(to: directory.appendingPathComponent("expected.json"))
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let manifest: [String: Any] = [
            "made_by": "ZoneCore LinkFlashQRTests.testWriteFramesForTheComputerSide",
            "key_from": keySource,
            "flash_key": FlashFixtures.hex(key),
            "session": plan.encoder.session,
            "total_len": plan.encoder.totalLength,
            "k": plan.encoder.chunkCount,
            "c": plan.encoder.chunkBytes,
            "frames": count,
            "first_frame": 0,
            "items": items.count,
            "phone_id": FlashFixtures.phone.id,
            "json_bytes": json.count,
            "json_sha256": sha(json),
            "frames_sha256": sha(all),
            "pixels_per_module": scale,
            "frames_not_one_byte_segment": mixed,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
        print("FLASH-EXPORT \(count) frames, k=\(plan.encoder.chunkCount), \(items.count) items, \(json.count) bytes of JSON, \(mixed) frames not one byte segment, in \(directory.path)")

        // Read the files back the hard way: coded frames only, from the pictures on disk.
        var decoder = FlashTestDecoder()
        for index in plan.encoder.chunkCount..<count where !decoder.isComplete {
            let url = directory.appendingPathComponent(String(format: "frame-%05d.png", index))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            if let bytes = try read(image) { decoder.add(bytes) }
        }
        XCTAssertEqual(try LinkFlashPayload.open(try XCTUnwrap(decoder.payload()), key: key), json)
        if !exporting { try? FileManager.default.removeItem(at: directory) }
    }
}
#endif
