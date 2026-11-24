// by zayd/cold @ zayd.wtf

import XCTest
import ImageIO
@testable import ZoneCore

/// The list of kept copies: order, no doubles, the age, count and size limits, kept copies,
/// search, and a file that survives another process and a build that cannot read all of it.
final class ClipboardHistoryTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testLargeImageIsReducedOnceAndThePreviewFitsIn128Pixels() throws {
        let history = ClipboardHistory(directory: directory)
        let url = directory.appendingPathComponent("wide.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 4096, height: 512, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let source = try XCTUnwrap(bitmap.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let reduced = try XCTUnwrap(ClipboardImage(url: url))
        guard case let .saved(entry) = history.addImage(reduced, route: .pasteKey, now: now) else { return XCTFail() }
        guard case let .alreadySaved(again) = history.addImage(reduced, route: .saved, now: now) else {
            return XCTFail("A second save should reuse the image")
        }
        XCTAssertEqual(again.id, entry.id)
        for (thumbnail, width) in [(false, 1536), (true, 128)] {
            let file = history.imageURL(entry.id, thumbnail: thumbnail)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, width)
        }
    }

    func testImagesHaveSeparateThumbnailsAndLeaveWithTheirEntry() throws {
        let history = ClipboardHistory(directory: directory)
        let url = directory.appendingPathComponent("sample.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1kAAAAASUVORK5CYII="))
        try png.write(to: url)
        let image = try XCTUnwrap(ClipboardImage(url: url))
        try Data(repeating: 0, count: png.count).write(to: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(image.data, png)
        for action in 0..<3 {
            guard case let .saved(entry) = history.addImage(image, route: .saved, now: now) else { return XCTFail() }
            let thumb = history.imageURL(entry.id, thumbnail: true)
            XCTAssertNotNil(CGImageSourceCreateWithURL(thumb as CFURL, nil))
            XCTAssertEqual(entry.imageBytes, png.count + image.thumbnail.count)
            switch action {
            case 0: history.delete(id: entry.id)
            case 1: history.deleteAll()
            default: history.purgeExpired(now: now.addingTimeInterval(31 * 86400))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: thumb.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: history.imageURL(entry.id).path))
        }
        var large = ClipboardEntry(text: "Image", savedAt: now, route: .saved)
        large.imageBytes = ClipboardHistory.imageBudget
        var next = ClipboardEntry(text: "Image", savedAt: now.addingTimeInterval(1), route: .saved)
        next.imageBytes = 100
        XCTAssertEqual(ClipboardHistory.pruned([next, large], retention: .default, now: now), [next])
    }

    func testLongMultilineCopySurvivesReopeningWithExactBytes() throws {
        let text = String(repeating: "A long paragraph with café and 中文.\n", count: 8_000)
        let history = store()
        guard case .saved = history.add(text, route: .pasteKey, now: at(0)) else {
            return XCTFail("A long text selection should be saved whole")
        }
        XCTAssertEqual(store().recent(limit: 1, now: at(1)).first?.text, text)
    }

    func testCommonSecretsAndOrdinaryCopies() {
        let secrets = ["P@ssw0rd.2024", "Summer@2024.", "hunter2hunter2", "lower!case!pass",
                       "correct horse battery staple", "violet candle walnut harbor", "123 456", "G-123456"]
        let ordinary = ["Alex25@example.com", "a.b+test2@example.co.uk", "hello@example.org",
                        "Please bring the package tomorrow.", "meet me after work", "call when you arrive",
                        "+1 415 555 0123", "(212) 555-0199", "415-555-0177", "https://example.com/A12",
                        "http://example.com/path", "example.org/path2", "tomorrow at 9", "the bus was late",
                        "Wonderful!", "please bring extra paper", "report@example.com", "Congratulations!"]
        for text in secrets { XCTAssertNotNil(ClipboardPolicy.skipAfterReading(text, skipsSecrets: true), text) }
        for text in ordinary { XCTAssertNil(ClipboardPolicy.skipAfterReading(text, skipsSecrets: true), text) }
    }

    private func store() -> ClipboardHistory { ClipboardHistory(directory: directory) }
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    func testNewestFirstAndReadByAnotherInstance() {
        let history = store()
        XCTAssertTrue(history.entries(now: now).isEmpty)
        history.add("first", route: .keyboard, now: at(0))
        history.add("second", route: .app, now: at(10))
        XCTAssertEqual(history.entries(now: at(20)).map(\.text), ["second", "first"])
        // The keyboard and the app each have their own instance over the same file.
        let other = store()
        XCTAssertEqual(other.entries(now: at(20)).map(\.text), ["second", "first"])
        XCTAssertEqual(other.entries(now: at(20)).map(\.route), [.app, .keyboard])
    }

    func testTheSameTextTwiceIsOneEntryMovedToTheTop() {
        let history = store()
        guard case .saved(let original) = history.add("the address", route: .keyboard, now: at(0)) else { return XCTFail() }
        history.add("a link", route: .keyboard, now: at(10))
        guard case .alreadySaved(let again) = history.add(" the address\n", route: .app, now: at(20)) else { return XCTFail() }
        XCTAssertEqual(again.id, original.id)
        let entries = history.entries(now: at(30))
        XCTAssertEqual(entries.map(\.text), ["the address", "a link"], "the first wording stands; spaces around a copy do not make it new")
        XCTAssertEqual(entries[0].savedAt, at(20))
    }

    func testSeeingTheNewestCopyAgainChangesNothing() {
        let history = store()
        history.add("only", route: .keyboard, now: at(0))
        guard case .alreadySaved(let again) = history.add("only", route: .app, now: at(500)) else { return XCTFail() }
        XCTAssertEqual(again.savedAt, at(0), "the app seeing what the keyboard kept is not a new copy")
        XCTAssertEqual(again.route, .keyboard)
    }

    func testNewCopySurvivesPinnedListAndBackwardClock() {
        let history = store()
        for index in 0..<ClipboardPolicy.maxEntries {
            guard case let .saved(entry) = history.add("copy \(index)", route: .keyboard, now: at(1)) else { return XCTFail() }
            history.setPinned(id: entry.id, true, now: at(1))
        }
        guard case .saved = history.add("new", route: .keyboard, now: at(-1)) else { return XCTFail() }
        XCTAssertEqual(store().entries(now: now).first?.text, "new")
    }

    func testDifferentCaseIsADifferentCopy() {
        let history = store()
        history.add("Hello", route: .keyboard, now: at(0))
        history.add("hello", route: .keyboard, now: at(1))
        XCTAssertEqual(history.entries(now: at(2)).count, 2)
    }

    func testCopiesAgeOutByTheChosenTime() {
        let history = store()
        history.add("old", route: .keyboard, now: at(0))
        history.add("new", route: .keyboard, now: at(29 * 86_400))
        XCTAssertEqual(history.entries(now: at(30 * 86_400 + 1)).map(\.text), ["new"], "30 days by default")
        history.setRetention(.day, now: at(30 * 86_400 + 1))
        XCTAssertEqual(history.retention, .day)
        XCTAssertTrue(history.entries(now: at(30 * 86_400 + 2)).isEmpty, "a shorter time prunes at once")
    }

    func testAKeptCopyOutlivesTheAgeAndCountLimits() {
        let history = store()
        guard case .saved(let keep) = history.add("wifi: kettle-and-toast", route: .keyboard, now: at(0)) else { return XCTFail() }
        history.setPinned(id: keep.id, true, now: at(1))
        for index in 0..<(ClipboardPolicy.maxEntries + 5) {
            history.add("copy \(index)", route: .keyboard, now: at(TimeInterval(10 + index)))
        }
        let later = at(40 * 86_400)
        XCTAssertEqual(history.entries(now: later).map(\.text), ["wifi: kettle-and-toast"])
        history.setPinned(id: keep.id, false, now: later)
        XCTAssertTrue(history.entries(now: later).isEmpty, "let go, it ages like the rest")
    }

    func testAtMostTwoHundredUnkeptCopies() {
        let history = store()
        for index in 0..<(ClipboardPolicy.maxEntries + 20) {
            history.add("copy \(index)", route: .keyboard, now: at(TimeInterval(index)))
        }
        let entries = history.entries(now: at(1_000))
        XCTAssertEqual(entries.count, ClipboardPolicy.maxEntries)
        XCTAssertEqual(entries.first?.text, "copy \(ClipboardPolicy.maxEntries + 19)")
        XCTAssertEqual(entries.last?.text, "copy 20", "the oldest went first")
    }

    func testTheWholeListStaysUnderItsSizeLimit() {
        let history = store()
        let big = String(repeating: "word ", count: 12_000) // 60,000 bytes
        for index in 0..<30 { history.add("\(index) \(big)", route: .keyboard, now: at(TimeInterval(index))) }
        let entries = history.entries(now: at(100))
        XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.text.utf8.count }, ClipboardPolicy.maxTotalBytes)
        XCTAssertTrue(entries.first?.text.hasPrefix("29 ") == true)
        XCTAssertLessThan(entries.count, 30)
    }

    func testSecretsAreNotKeptAndAreCountedWithoutTheirText() throws {
        let history = store()
        XCTAssertEqual(history.add("481516", route: .keyboard, skipsSecrets: true, now: now), .skipped(.code))
        XCTAssertEqual(history.add("Summer2024!", route: .keyboard, skipsSecrets: true, now: now), .skipped(.password))
        XCTAssertEqual(history.add("   ", route: .keyboard, now: now), .skipped(.empty))
        XCTAssertTrue(history.entries(now: now).isEmpty)
        XCTAssertEqual(history.skips, [.code: 1, .password: 1], "nothing to count for a copy that was only spaces")
        let file = try String(contentsOf: directory.appendingPathComponent("clipboard.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("481516"))
        XCTAssertFalse(file.contains("Summer2024"))
        // With the switch off the person has said to keep them.
        guard case .saved = history.add("481516", route: .keyboard, now: now) else { return XCTFail() }
    }

    func testDeleteRefusalIsReturnedAndOriginalBytesSurvive() throws {
        let history = store()
        let file = directory.appendingPathComponent("clipboard.json")
        let bytes = Data("unreadable".utf8)
        try bytes.write(to: file)
        XCTAssertFalse(history.delete(id: UUID()))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testSearchIgnoresCaseAndAccents() {
        let history = store()
        history.add("Café on Valencia, 9am", route: .keyboard, now: at(0))
        history.add("https://example.com/menu", route: .keyboard, now: at(1))
        XCTAssertEqual(history.search("cafe", now: at(2)).map(\.text), ["Café on Valencia, 9am"])
        XCTAssertEqual(history.search("EXAMPLE", now: at(2)).count, 1)
        XCTAssertEqual(history.search("  ", now: at(2)).count, 2)
        XCTAssertTrue(history.search("nothing like it", now: at(2)).isEmpty)
    }

    func testDeleteOneAndDeleteAll() {
        let history = store()
        guard case .saved(let first) = history.add("first", route: .keyboard, now: at(0)) else { return XCTFail() }
        guard case .saved(let second) = history.add("second", route: .keyboard, now: at(1)) else { return XCTFail() }
        history.setPinned(id: second.id, true, now: at(2))
        history.add("481516", route: .keyboard, skipsSecrets: true, now: at(3))
        history.delete(id: first.id)
        XCTAssertEqual(history.entries(now: at(4)).map(\.text), ["second"])
        XCTAssertTrue(history.deleteAll())
        XCTAssertTrue(history.entries(now: at(5)).isEmpty, "kept copies go with Delete all")
        XCTAssertTrue(history.skips.isEmpty)
    }

    func testAnEntryThisBuildCannotReadIsDroppedAlone() throws {
        let history = store()
        history.add("kept", route: .keyboard, now: now)
        let url = directory.appendingPathComponent("clipboard.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        entries.append(["id": "not-a-uuid", "text": 7])
        entries.append(["id": UUID().uuidString, "text": "from a later build", "savedAt": now.timeIntervalSince1970 * 1000,
                        "route": "airdrop", "pinned": true, "colour": "blue"])
        json["entries"] = entries
        json["retention"] = "forever"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let read = store()
        XCTAssertEqual(Set(read.entries(now: now).map(\.text)), ["kept", "from a later build"])
        XCTAssertEqual(read.retention, .default, "a time this build does not know reads as the default")
        XCTAssertEqual(read.entries(now: now).first { $0.pinned }?.route.rawValue, "airdrop", "an unknown route is carried, not lost")
    }

    func testAFileThatIsNotAListIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("clipboard.json")
        try Data("not json".utf8).write(to: url)
        let history = store()
        XCTAssertEqual(history.add("new", route: .keyboard, now: now), .failed)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    func testTheFolderIsKeptOutOfBackups() throws {
        let history = store()
        history.add("x y z", route: .keyboard, now: now)
        let values = try history.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

}
