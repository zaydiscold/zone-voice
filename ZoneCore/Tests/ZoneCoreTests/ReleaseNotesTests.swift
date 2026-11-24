// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore
#if canImport(AppKit)
import AppKit
#endif

final class AppVersionTests: XCTestCase {
    func testComparesNumberByNumber() throws {
        let v = { (text: String) in try XCTUnwrap(AppVersion(text)) }
        XCTAssertLessThan(try v("1.0.9"), try v("1.0.10"))
        XCTAssertLessThan(try v("1.0"), try v("1.0.1"))
        XCTAssertLessThan(try v("1.0.4"), try v("1.1"))
        XCTAssertLessThan(try v("1.9"), try v("2.0"))
        XCTAssertEqual(try v("1.0"), try v("1.0.0"))
        XCTAssertEqual(try v(" 1.0.4\n").description, "1.0.4")
        XCTAssertEqual(Set([try v("1.0"), try v("1.0.0")]).count, 1)
    }

    func testRefusesWhatIsNotAVersion() {
        for text in ["", "1.", ".1", "1..2", "v1.0", "1.0-beta", "1.0 (5)", "one", "1.2.3.4.5", "1234567.0"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testReleaseDay() throws {
        let day = try XCTUnwrap(ReleaseDay("2026-11-14"))
        XCTAssertEqual([day.year, day.month, day.day], [2026, 11, 14])
        XCTAssertLessThan(try XCTUnwrap(ReleaseDay("2026-11-08")), day)
        for text in ["2026-13-01", "2026-02-30", "26-11-14", "2026/11/14", "2026-11", "November 14", "2026-1-4"] {
            XCTAssertNil(ReleaseDay(text), text)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(utc.component(.day, from: try XCTUnwrap(day.date(in: utc))), 14)
    }
}

final class ReleaseNotesParserTests: XCTestCase {
    private let sample = """
    # 1.2.3
    date: 2026-11-15
    name: Sample
    summary: Two groups and a few changes.

    ## Keyboard
    symbol: keyboard

    * Next word: Finish a word and the row
      offers the next one.
    - Hold space to talk (Beta): Hold, speak, let go.
    - A plain fix with no name.

    ## Dictation
    symbol: waveform
    - Settings > Keyboard: this colon follows a path, so the line is all sentence.
    * Learns your fixes: Retype a word once.
    """

    private func failure(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ReleaseNotesParser.Failure? {
        do {
            _ = try ReleaseNotesParser.parse(text)
            XCTFail("parsed, expected a failure", file: file, line: line)
            return nil
        } catch let failure as ReleaseNotesParser.Failure {
            return failure
        } catch {
            XCTFail("\(error)", file: file, line: line)
            return nil
        }
    }

    func testReadsAWholeVersion() throws {
        let note = try ReleaseNotesParser.parse(sample)
        XCTAssertEqual(note.version, AppVersion("1.2.3"))
        XCTAssertEqual(note.day, ReleaseDay("2026-11-15"))
        XCTAssertEqual(note.name, "Sample")
        XCTAssertEqual(note.summary, "Two groups and a few changes.")
        XCTAssertEqual(note.groups, [
            ReleaseGroup(title: "Keyboard", symbol: "keyboard", items: [
                ReleaseItem(title: "Next word", text: "Finish a word and the row offers the next one.", isHighlight: true),
                ReleaseItem(title: "Hold space to talk", tag: "Beta", text: "Hold, speak, let go."),
                ReleaseItem(text: "A plain fix with no name."),
            ]),
            ReleaseGroup(title: "Dictation", symbol: "waveform", items: [
                ReleaseItem(text: "Settings > Keyboard: this colon follows a path, so the line is all sentence."),
                ReleaseItem(title: "Learns your fixes", text: "Retype a word once.", isHighlight: true),
            ]),
        ])
        XCTAssertEqual(note.count, 5)
        XCTAssertEqual(note.highlights.map(\.item.title), ["Next word", "Learns your fixes"])
        XCTAssertEqual(note.highlights.map(\.group.title), ["Keyboard", "Dictation"])
    }

    func testANameIsShortAndHasNoSentenceInIt() {
        func item(_ text: String) -> ReleaseItem { ReleaseNotesParser.item(text, starred: false) }
        XCTAssertEqual(item("Colors: Pick one."), ReleaseItem(title: "Colors", text: "Pick one."))
        XCTAssertEqual(item("My words, one key per word: Tap to fix."), ReleaseItem(title: "My words, one key per word", text: "Tap to fix."))
        // A sentence, a quotation or a path before the colon is not a name.
        XCTAssertNil(item("It works. Then: it stops.").title)
        XCTAssertNil(item("Saying \"at sign\": writes @.").title)
        XCTAssertNil(item("Settings > Dynamic Island > Times: Live counts by itself.").title)
        XCTAssertNil(item(String(repeating: "long ", count: 9) + "name: text").title)
        XCTAssertNil(item("No colon here.").title)
        XCTAssertNil(item("Ends with a colon:").title)
        // A time is not a name and a sentence: the colon has no space after it.
        XCTAssertNil(item("Times like 7:30 are digits.").title)
        // The label is one word in brackets at the end of the name.
        XCTAssertEqual(item("Computers (Beta): Pair one.").tag, "Beta")
        XCTAssertEqual(item("Zone (on iOS 26): Lasts longer.").title, "Zone (on iOS 26)")
        XCTAssertNil(item("Zone (on iOS 26): Lasts longer.").tag)
    }

    func testDateAndNameAreOptionalAndWindowsLineEndingsRead() throws {
        let note = try ReleaseNotesParser.parse("# 2.0\r\nsummary: No date yet.\r\n\r\n## Fixes\r\nsymbol: wrench\r\n- Only a fix.\r\n")
        XCTAssertNil(note.day)
        XCTAssertNil(note.name)
        XCTAssertEqual(note.groups.map(\.title), ["Fixes"])
        XCTAssertEqual(note.groups[0].items, [ReleaseItem(text: "Only a fix.")])
        XCTAssertEqual(note.highlights, [])
    }

    func testCommentsAreForEditorsOnly() throws {
        let note = try ReleaseNotesParser.parse("""
        # 1.0
        summary: Comments vanish. <!-- even here -->
        <!-- TODO(integrator): add the line
             when the branch merges. ## Not a heading
        -->

        ## A group
        symbol: mic
        - Text before <!-- inline --> and after.
        <!-- a whole line -->
        - More text.
        """)
        XCTAssertEqual(note.summary, "Comments vanish.")
        XCTAssertEqual(note.groups[0].items.map(\.text), ["Text before and after.", "More text."])
        XCTAssertEqual(failure("# 1.0\nsummary: s\n<!-- never closed\n## A\nsymbol: mic\n- Text.")?.message, "a comment is never closed")
    }

    func testMistakesAreErrorsWithTheirLine() {
        XCTAssertEqual(failure("")?.message, "the file must start with \"# \" and the version")
        XCTAssertEqual(failure("Hello\n# 1.0")?.line, 1)
        XCTAssertEqual(failure("# one point oh\nsummary: s")?.message, "\"one point oh\" is not a version like 1.0.4")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n# 1.1")?.message, "one version per file")
        XCTAssertEqual(failure("# 1.0\n\n## A\nsymbol: mic\n- Text.")?.message, "the version needs a summary: line before its first group")
        XCTAssertEqual(failure("# 1.0\nsummary: s")?.message, "the version has no notes")
        XCTAssertEqual(failure("# 1.0\ndate: tomorrow\nsummary: s")?.message, "\"tomorrow\" is not a date like 2026-11-15")
        XCTAssertEqual(failure("# 1.0\nsummary: s\nauthor: someone")?.message, "\"author:\" is not known here (date, name, summary)")
        XCTAssertEqual(failure("# 1.0\nsummary: s\nsummary: t")?.message, "summary: appears twice")
        XCTAssertEqual(failure("# 1.0\nname: a\nname: b\nsummary: s")?.message, "name: appears twice")
        XCTAssertEqual(failure("# 1.0\nsummary: s\nLoose text.")?.message, "text must sit under a \"## \" group")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n- A change with no group.")?.message, "a change must sit under a \"## \" group")

        let noSymbol = failure("# 1.0\nsummary: s\n\n## A group\n- Text.")
        XCTAssertEqual(noSymbol?.message, "\"A group\" needs a symbol: line (an SF Symbol name)")
        XCTAssertEqual(noSymbol?.line, 4)
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A group\nsymbol: mic\n\n## Another\nsymbol: mic\n- Text.")?.message,
                       "\"A group\" has no changes under it")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\nicon: mic\n- Text.")?.message,
                       "\"icon:\" is not known here (symbol)")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\n- Text.\n\n## a\nsymbol: mic\n- Text.")?.message, "\"a\" appears twice")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\n- Text.\n### Deeper")?.message, "use \"## \" for a group")
        // The old card format, a paragraph under a heading, is refused rather than half read.
        let paragraph = failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\n\nA paragraph, as a card had.")
        XCTAssertEqual(paragraph?.message, "a change starts with \"- \", or \"* \" for a highlight")
        XCTAssertEqual(paragraph?.line, 7)
        let star = failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\n- Fine.\n* A highlight with no name.")
        XCTAssertEqual(star?.message, "a starred change needs a name and a colon before its sentence")
        XCTAssertEqual(star?.line, 7)
    }
}

final class ReleaseNotesLibraryTests: XCTestCase {
    private func note(_ version: String) throws -> ReleaseNote {
        ReleaseNote(version: try XCTUnwrap(AppVersion(version)), day: nil, summary: "s",
                    groups: [ReleaseGroup(title: "g", symbol: "mic", items: [ReleaseItem(text: "f")])])
    }

    func testNewestFirstAndOnlyUpToTheInstalledVersion() throws {
        let library = ReleaseNotesLibrary([try note("1.0.1"), try note("1.0.10"), try note("1.0"), try note("1.0.9")])
        XCTAssertEqual(library.notes.map(\.id), ["1.0.10", "1.0.9", "1.0.1", "1.0"])
        XCTAssertEqual(library.history(installed: AppVersion("1.0.9")).map(\.id), ["1.0.9", "1.0.1", "1.0"])
        // A version with no notes of its own still lists everything before it.
        XCTAssertEqual(library.history(installed: AppVersion("1.0.5")).map(\.id), ["1.0.1", "1.0"])
        XCTAssertEqual(library.history(installed: nil).count, 4)
        XCTAssertEqual(library.note(for: AppVersion("1.0.0"))?.id, "1.0")
        XCTAssertNil(library.note(for: AppVersion("1.0.5")))
        XCTAssertNil(library.note(for: nil))
        // An installed version newer than every file lists them all and has no notes of its own.
        XCTAssertEqual(library.history(installed: AppVersion("2.0")).map(\.id), ["1.0.10", "1.0.9", "1.0.1", "1.0"])
        XCTAssertNil(library.note(for: AppVersion("2.0")))
        // One older than every file lists nothing, so no later version's notes can show.
        XCTAssertEqual(library.history(installed: AppVersion("0.9")), [])
        // Two files for one version (1.0 and 1.0.0) are one entry, not a repeat in the list.
        XCTAssertEqual(ReleaseNotesLibrary([try note("1.0"), try note("1.0.0"), try note("1.1")]).notes.count, 2)
    }

    func testLoadingAFolderKeepsGoodFilesAndNamesBadOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zone-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = "summary: s\n\n## Fixes\nsymbol: wrench\n- f\n"
        try "# 1.0\n\(good)".write(to: folder.appendingPathComponent("1.0.md"), atomically: true, encoding: .utf8)
        try "# 1.1\n\(good)".write(to: folder.appendingPathComponent("1.1.md"), atomically: true, encoding: .utf8)
        try "# 1.3\n\(good)".write(to: folder.appendingPathComponent("1.2.md"), atomically: true, encoding: .utf8)
        try "not notes".write(to: folder.appendingPathComponent("2.0.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let (library, problems) = ReleaseNotesLibrary.load(folder: folder)
        XCTAssertEqual(library.notes.map(\.id), ["1.1", "1.0"])
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems.contains("1.2.md: holds the notes for 1.3"), "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("2.0.md: line 1") }, "\(problems)")
        let missing = folder.appendingPathComponent("missing")
        XCTAssertFalse(ReleaseNotesLibrary.load(folder: missing).problems.isEmpty)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("1.0.md"), to: missing.appendingPathComponent("1.0.md"))
        XCTAssertEqual(ReleaseNotesLibrary.load(folder: missing).library.notes.map(\.id), ["1.0"])
    }
}

/// The notes that ship: `Zone/ReleaseNotes/*.md`, read from the checkout exactly as the app
/// bundles them.
final class ShippedReleaseNotesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let loaded = ReleaseNotesLibrary.load(folder: root.appendingPathComponent("Zone/ReleaseNotes"))
    private var library: ReleaseNotesLibrary { Self.loaded.library }

    func testEveryFileParses() {
        XCTAssertEqual(Self.loaded.problems, [])
        XCTAssertFalse(library.notes.isEmpty)
    }

    /// A version cannot ship without notes: `scripts/testflight.sh` runs these tests before it
    /// uploads, and this one fails until `Zone/ReleaseNotes/<version>.md` exists.
    func testTheVersionInProjectYmlHasNotes() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(project.components(separatedBy: "\n").first { $0.contains("MARKETING_VERSION:") },
                                 "project.yml has no MARKETING_VERSION")
        let text = line.components(separatedBy: "MARKETING_VERSION:")[1]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t"))
        let version = try XCTUnwrap(AppVersion(text), "MARKETING_VERSION \"\(text)\" is not a version")
        XCTAssertNotNil(library.note(for: version),
                        "Zone \(version) has no release notes. Add Zone/ReleaseNotes/\(version).md (see next-build/README.md).")
    }

    /// The version about to ship stars a few changes for the What's New sheet: enough to say what
    /// the update is, few enough that the sheet stays one short list.
    func testTheShippingVersionStarsAFewChanges() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(project.components(separatedBy: "\n").first { $0.contains("MARKETING_VERSION:") })
        let text = line.components(separatedBy: "MARKETING_VERSION:")[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t"))
        let note = try XCTUnwrap(library.note(for: AppVersion(text)), "no notes for \(text)")
        XCTAssertGreaterThanOrEqual(note.highlights.count, 3, "\(note.id): star three to six changes with \"* \"")
    }

    func testEveryPublicVersionSoFarIsThere() {
        for version in ["1.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4", "1.0.5", "1.0.6"] {
            XCTAssertNotNil(library.note(for: AppVersion(version)), version)
        }
    }

    func testDatesFollowTheVersions() {
        let dated = library.notes.reversed().compactMap { note in note.day.map { (note.id, $0) } }
        XCTAssertEqual(dated.count, library.notes.count, "every version has a date")
        for (earlier, later) in zip(dated, dated.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.1, later.1, "\(earlier.0) is dated after \(later.0)")
        }
    }

    /// The rules in `next-build/README.md` that a test can check: a few groups, one short line per
    /// change, plain punctuation. From 1.0.5 on a sentence is at most 110 characters, so a line is
    /// two or three rows on an iPhone, and a starred one at most 90, so the What's New sheet fits a
    /// screen. The versions before it were written as cards and keep their longer lines.
    func testNotesAreShortAndPlain() throws {
        let tight = try XCTUnwrap(AppVersion("1.0.5"))
        for note in library.notes {
            var texts = [note.summary, note.name ?? ""]
            XCTAssertLessThanOrEqual(note.summary.count, 150, "\(note.id) summary")
            XCTAssertLessThanOrEqual(note.name?.count ?? 0, 16, "\(note.id) name")
            XCTAssertFalse(note.name?.contains(" ") ?? false, "\(note.id): the name is one word, shown as \"The \(note.name ?? "") update\"")
            XCTAssertLessThanOrEqual(note.groups.count, 8, "\(note.id) has too many groups to scan")
            XCTAssertLessThanOrEqual(note.highlights.count, 6, "\(note.id): the What's New sheet shows every starred change")
            XCTAssertGreaterThanOrEqual(note.highlights.count, 1, "\(note.id) stars nothing for the What's New sheet")
            let limit = note.version >= tight ? 110 : 170
            for group in note.groups {
                XCTAssertLessThanOrEqual(group.title.count, 24, "\(note.id): \(group.title)")
                texts.append(group.title)
                for item in group.items {
                    XCTAssertLessThanOrEqual(item.title?.count ?? 0, note.version >= tight ? 32 : ReleaseNotesParser.titleLimit,
                                             "\(note.id): \(item.title ?? "")")
                    XCTAssertLessThanOrEqual(item.text.count, limit, "\(note.id): \(item.title ?? item.text) is too long for one line")
                    if item.isHighlight, note.version >= tight {
                        XCTAssertLessThanOrEqual(item.text.count, 90, "\(note.id): \(item.title ?? "") is starred, so it is shorter")
                    }
                    XCTAssertLessThanOrEqual(item.tag?.count ?? 0, 14, "\(note.id): \(item.title ?? "") tag")
                    texts += [item.title ?? "", item.text, item.tag ?? ""]
                }
            }
            for text in texts {
                for dash in ["\u{2014}", "\u{2013}", " - ", "--"] {
                    XCTAssertFalse(text.contains(dash), "\(note.id): a dash in \"\(text)\"")
                }
                XCTAssertFalse(text.contains("<unk>"), "\(note.id): \"\(text)\"")
                XCTAssertFalse(text.contains("**") || text.contains("`"), "\(note.id): Markdown styling is not drawn: \"\(text)\"")
            }
        }
    }

    /// Each change is told once: in one version, in one group. This catches the copy and paste
    /// kind of repeat (the same sentence in two places); a change reworded in a second place still
    /// needs a person to notice it.
    func testNothingIsSaidTwice() {
        var seen: [String: String] = [:]
        func check(_ text: String, _ place: String) {
            for sentence in text.components(separatedBy: ". ") {
                let key = sentence.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                // Short stock phrases ("It is off until you turn it on") may recur.
                guard key.count > 40 else { continue }
                if let first = seen[key] {
                    XCTFail("\"\(sentence)\" is in \(first) and again in \(place)")
                }
                seen[key] = place
            }
        }
        for note in library.notes {
            var titles = Set<String>()
            for group in note.groups {
                for item in group.items {
                    if let title = item.title {
                        XCTAssertTrue(titles.insert(title.lowercased()).inserted, "\(note.id): two changes called \(title)")
                    }
                    check(item.text, "\(note.id), \(group.title)")
                }
            }
        }
    }

    #if canImport(AppKit)
    func testEverySymbolExists() {
        for note in library.notes {
            for group in note.groups {
                XCTAssertNotNil(NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil),
                                "\(note.id): \"\(group.symbol)\" is not an SF Symbol (\(group.title))")
            }
        }
    }
    #endif
}
