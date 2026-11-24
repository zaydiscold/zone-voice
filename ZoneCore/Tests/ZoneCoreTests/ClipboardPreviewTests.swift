// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// What a row shows of a kept copy. The copy itself is never changed: these are about a long
/// passage being told from a link in a list of two-line rows.
final class ClipboardPreviewTests: XCTestCase {
    private let address = "https://example.com/articles/2026/11/a-long-address-that-fills-a-row-by-itself-0123456789"

    /// The shape found on the phone: an address, a blank line, then hundreds of words.
    private func passage(words: Int) -> String {
        let body = (1...words).map { "word\($0)" }
        let paragraphs = stride(from: 0, to: body.count, by: 40).map { body[$0..<min($0 + 40, body.count)].joined(separator: " ") }
        return address + "\n\n" + paragraphs.joined(separator: "\n\n") + "\n"
    }

    // MARK: A passage that opens with a link

    func testAPassageThatOpensWithALinkShowsItsWordsNotTheAddress() {
        let preview = ClipboardPreview(passage(words: 503))
        XCTAssertTrue(preview.text.hasPrefix("word1 word2 word3"), preview.text)
        XCTAssertFalse(preview.text.contains("https://"))
        XCTAssertEqual(preview.leadingLinks, 1)
        XCTAssertEqual(preview.links, 0)
        XCTAssertEqual(preview.words, 503)
        XCTAssertTrue(preview.isLong)
        XCTAssertEqual(preview.detail, "Link and 503 words")
    }

    /// The old row: the copy from its first character, cut at two lines of about 40 characters.
    /// For the passage that is the address and nothing else, exactly as for a real link.
    func testTheFirstTwoLinesOfThatPassageWereOnlyTheAddress() {
        let copy = passage(words: 503)
        let oldRow = String(copy.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        XCTAssertEqual(oldRow, String(address.prefix(80)))
        XCTAssertNotEqual(ClipboardPreview(copy).text.prefix(80), ClipboardPreview(address).text.prefix(80))
    }

    func testThreeSelectionsOfOnePageAreToldApartByTheirLength() {
        let rows = [173, 408, 503].map { ClipboardPreview(passage(words: $0)).detail }
        XCTAssertEqual(rows, ["Link and 173 words", "Link and 408 words", "Link and 503 words"])
    }

    func testSeveralOpeningLinksAreCounted() {
        let preview = ClipboardPreview("https://a.example/one\nhttps://b.example/two\n\nThe reason for both.")
        XCTAssertEqual(preview.text, "The reason for both.")
        XCTAssertEqual(preview.detail, "2 links and 4 words")
    }

    func testALinkInsideTheWordsStaysWhereItIs() {
        let preview = ClipboardPreview("Read this first:\nhttps://example.com/a\nthen call me")
        XCTAssertEqual(preview.text, "Read this first: https://example.com/a then call me")
        XCTAssertEqual(preview.leadingLinks, 0)
        XCTAssertNil(preview.detail)
    }

    // MARK: Links

    func testALinkAloneIsStillALink() {
        let preview = ClipboardPreview("  \(address)\n")
        XCTAssertEqual(preview.text, address)
        XCTAssertEqual(preview.links, 1)
        XCTAssertEqual(preview.detail, "Link")
        XCTAssertFalse(preview.isLong)
    }

    func testAListOfLinksSaysHowMany() {
        let preview = ClipboardPreview("https://a.example/one\n\nhttps://b.example/two\nhttps://c.example/three")
        XCTAssertEqual(preview.text, "https://a.example/one https://b.example/two https://c.example/three")
        XCTAssertEqual(preview.detail, "3 links")
    }

    func testOnlyWebAddressesCountAsLinks() {
        // `ClipboardPolicy.link`: http and https with a host. Anything else is words.
        for text in ["mailto:someone@example.com\n\nwords after", "example.com/path\n\nwords after", "ftp://example.com/file\n\nwords after"] {
            let preview = ClipboardPreview(text)
            XCTAssertEqual(preview.leadingLinks, 0, text)
            XCTAssertEqual(preview.links, 0, text)
        }
    }

    // MARK: Plain text

    func testAShortCopyIsShownAsItIsWithNothingOnTheQuietLine() {
        let preview = ClipboardPreview("Dinner at eight on Friday")
        XCTAssertEqual(preview.text, "Dinner at eight on Friday")
        XCTAssertEqual(preview.words, 5)
        XCTAssertFalse(preview.isLong)
        XCTAssertNil(preview.detail)
    }

    func testBlankLinesAndLineBreaksDoNotSpendTheRowsTwoLines() {
        let preview = ClipboardPreview("\n\n  Title\n\n\n\tfirst line  of   it\r\nsecond line\u{2028}third\n")
        XCTAssertEqual(preview.text, "Title first line of it second line third")
        XCTAssertEqual(preview.words, 8)
    }

    func testALongPassageSaysHowLongItIs() {
        let text = (1...45).map { "word\($0)" }.joined(separator: " ")
        let preview = ClipboardPreview(text)
        XCTAssertTrue(preview.isLong)
        XCTAssertEqual(preview.detail, "45 words")
        XCTAssertEqual(ClipboardPreview("one-unbroken-" + String(repeating: "x", count: 200)).detail, "1 word")
    }

    func testTheRowIsGivenAtMostTheLimitAndStillCountsEveryWord() {
        let text = (1...10_000).map { "w\($0)" }.joined(separator: "\n")
        let preview = ClipboardPreview(text, limit: 240)
        XCTAssertEqual(preview.text.count, 240)
        XCTAssertTrue(text.replacingOccurrences(of: "\n", with: " ").hasPrefix(preview.text))
        XCTAssertEqual(preview.words, 10_000)
        XCTAssertEqual(preview.detail, "\(10_000.formatted()) words")
    }

    func testNothingButSpacesShowsNothing() {
        let preview = ClipboardPreview(" \n\t ")
        XCTAssertEqual(preview.text, "")
        XCTAssertEqual(preview.words, 0)
        XCTAssertEqual(preview.links, 0)
    }

    func testAnImageEntryKeepsItsName() {
        // `ClipboardHistory.addImage` stores the text "Image".
        let preview = ClipboardPreview("Image")
        XCTAssertEqual(preview.text, "Image")
        XCTAssertNil(preview.detail)
    }

    // MARK: The stored copy

    /// The preview is for the row only. What was kept, and what a tap inserts, is every character.
    func testTheStoredCopyIsWholeAndUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ClipboardHistory(directory: directory)
        let copy = passage(words: 503)
        XCTAssertGreaterThan(copy.utf8.count, 3_000)
        guard case .saved = history.add(copy, route: .pasteKey) else { return XCTFail("A long passage was not kept") }
        guard case .saved = history.add(address, route: .pasteKey) else { return XCTFail("A link was not kept") }
        let rows = history.recent(limit: 40)
        XCTAssertEqual(rows.map(\.text), [address, copy])
        XCTAssertEqual(rows.map { ClipboardPreview($0.text).detail }, ["Link", "Link and 503 words"])
        XCTAssertNil(rows[1].link, "A passage is not offered Open as if it were its first line")
    }

    /// A list pulled from a phone, to see what its rows show without printing a word of it:
    /// `ZONE_CLIPBOARD_DIR=/path/to/Clipboard swift test --filter ClipboardPreviewTests/testAPulledListTellsPassagesFromLinks`.
    /// The directory holds `clipboard.json` and is read from a copy.
    func testAPulledListTellsPassagesFromLinks() throws {
        guard let path = ProcessInfo.processInfo.environment["ZONE_CLIPBOARD_DIR"] else {
            throw XCTSkip("set ZONE_CLIPBOARD_DIR to a pulled Clipboard directory")
        }
        let copyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-pulled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copyDirectory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copyDirectory)
        // Old enough entries would be hidden by retention; a pulled list is read as of its last write.
        let history = ClipboardHistory(directory: copyDirectory)
        let rows = history.recent(limit: 40, now: history.lastWrite ?? Date())
        var oldLinkRows = 0, linkRows = 0, hidden = 0
        for row in rows where row.imageType == nil {
            let preview = ClipboardPreview(row.text)
            let oldRow = row.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
            let oldLooksLikeLink = ClipboardPolicy.link(in: String(oldRow.prefix { !$0.isNewline })) != nil
            if oldLooksLikeLink { oldLinkRows += 1 }
            if preview.links > 0 { linkRows += 1 }
            if oldLooksLikeLink && preview.links == 0 { hidden += 1 }
            print("row: \(row.text.count) characters, old row showed only an address: \(oldLooksLikeLink), now: \(preview.detail ?? "short text, shown whole")")
            XCTAssertEqual(preview.links == 1, row.link != nil, "Open is offered for one link and nothing else")
            if preview.links == 0 { XCTAssertFalse(preview.text.isEmpty) }
        }
        print("rows: \(rows.count), read as links before: \(oldLinkRows), links now: \(linkRows), passages that were hidden behind an address: \(hidden)")
    }
}
