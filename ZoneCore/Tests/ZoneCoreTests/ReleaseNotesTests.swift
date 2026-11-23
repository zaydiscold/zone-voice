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
    summary: Two cards and a short list.

    ## The first card
    symbol: mic.fill
    tag: Beta
    where: Settings > Somewhere

    A sentence that runs
    over two lines. And a second one.

    A second paragraph.

    ## The second card
    symbol: keyboard
    Straight into the text.

    ## Also in this version

    - One fix.
    - A fix that wraps
      onto the next line.
    * A third, with a star.
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
        XCTAssertEqual(note.summary, "Two cards and a short list.")
        XCTAssertEqual(note.features, [
            ReleaseFeature(title: "The first card", symbol: "mic.fill", tag: "Beta", location: "Settings > Somewhere",
                           body: "A sentence that runs over two lines. And a second one.\n\nA second paragraph."),
            ReleaseFeature(title: "The second card", symbol: "keyboard", body: "Straight into the text."),
        ])
        XCTAssertEqual(note.fixes, ["One fix.", "A fix that wraps onto the next line.", "A third, with a star."])
    }

    func testBriefIsTheSheetLineAndTheFirstSentenceStandsIn() throws {
        let note = try ReleaseNotesParser.parse("""
        # 1.0
        summary: s

        ## With a brief
        symbol: mic
        brief: The short line.

        A long body. With more.

        ## Without one
        symbol: mic

        Get zone at github.com/zaydiscold/zone-mcp, version 2.5 or later. Then pair it.

        ## One sentence
        symbol: mic

        No period at the end
        """)
        XCTAssertEqual(note.features.map(\.brief), ["The short line.", nil, nil])
        XCTAssertEqual(note.features.map(\.headline), [
            "The short line.",
            "Get zone at github.com/zaydiscold/zone-mcp, version 2.5 or later.",
            "No period at the end",
        ])
        XCTAssertEqual(note.features[0].body, "A long body. With more.")
    }

    func testDateIsOptionalAndWindowsLineEndingsRead() throws {
        let note = try ReleaseNotesParser.parse("# 2.0\r\nsummary: No date yet.\r\n\r\n## Also in this version\r\n- Only a fix.\r\n")
        XCTAssertNil(note.day)
        XCTAssertEqual(note.features, [])
        XCTAssertEqual(note.fixes, ["Only a fix."])
    }

    func testCommentsAreForEditorsOnly() throws {
        let note = try ReleaseNotesParser.parse("""
        # 1.0
        summary: Comments vanish. <!-- even here -->
        <!-- TODO(integrator): add the card
             when the branch merges. ## Not a heading
        -->

        ## A card
        symbol: mic
        Text before <!-- inline --> and after.
        <!-- a whole line -->
        More text.
        """)
        XCTAssertEqual(note.summary, "Comments vanish.")
        XCTAssertEqual(note.features.map(\.body), ["Text before and after. More text."])
        XCTAssertEqual(failure("# 1.0\nsummary: s\n<!-- never closed\n## A\nsymbol: mic\nText.")?.message, "a comment is never closed")
    }

    func testASentenceWithAColonIsNotAKey() throws {
        let note = try ReleaseNotesParser.parse("""
        # 1.0
        summary: Colons are fine: really.

        ## A card
        symbol: mic

        note: this line follows a blank line, so it is a sentence.
        Ask: what did I say?
        """)
        XCTAssertEqual(note.summary, "Colons are fine: really.")
        XCTAssertEqual(note.features.first?.body, "note: this line follows a blank line, so it is a sentence. Ask: what did I say?")
    }

    func testMistakesAreErrorsWithTheirLine() {
        XCTAssertEqual(failure("")?.message, "the file must start with \"# \" and the version")
        XCTAssertEqual(failure("Hello\n# 1.0")?.line, 1)
        XCTAssertEqual(failure("# one point oh\nsummary: s")?.message, "\"one point oh\" is not a version like 1.0.4")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n# 1.1")?.message, "one version per file")
        XCTAssertEqual(failure("# 1.0\n\n## A\nsymbol: mic\nText.")?.message, "the version needs a summary: line before its first section")
        XCTAssertEqual(failure("# 1.0\nsummary: s")?.message, "the version has no notes")
        XCTAssertEqual(failure("# 1.0\ndate: tomorrow\nsummary: s")?.message, "\"tomorrow\" is not a date like 2026-11-15")
        XCTAssertEqual(failure("# 1.0\nsummary: s\nauthor: someone")?.message, "\"author:\" is not known here (date, summary)")
        XCTAssertEqual(failure("# 1.0\nsummary: s\nsummary: t")?.message, "summary: appears twice")
        XCTAssertEqual(failure("# 1.0\nsummary: s\nLoose text.")?.message, "text must sit under a \"## \" section")

        let noSymbol = failure("# 1.0\nsummary: s\n\n## A card\nText.")
        XCTAssertEqual(noSymbol?.message, "\"A card\" needs a symbol: line (an SF Symbol name)")
        XCTAssertEqual(noSymbol?.line, 4)
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A card\nsymbol: mic\n\n## Another\nsymbol: mic\nText.")?.message,
                       "\"A card\" has no text under it")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\nicon: mic\nText.")?.message,
                       "\"icon:\" is not known here (symbol, tag, where, brief)")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\nText.\n\n## A\nsymbol: mic\nText.")?.message, "\"A\" appears twice")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## A\nsymbol: mic\nText.\n### Deeper")?.message, "use \"## \" for a section")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## Also in this version\nNot a bullet.")?.message,
                       "lines under \"Also in this version\" start with \"- \"")
        XCTAssertEqual(failure("# 1.0\nsummary: s\n\n## Also in this version\n- A fix.\n\n## Late card\nsymbol: mic\nText.")?.message,
                       "\"Also in this version\" must be the last section")
    }
}

final class ReleaseNotesLibraryTests: XCTestCase {
    private func note(_ version: String) throws -> ReleaseNote {
        ReleaseNote(version: try XCTUnwrap(AppVersion(version)), day: nil, summary: "s", features: [], fixes: ["f"])
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
        let good = "summary: s\n\n## Also in this version\n- f\n"
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
        XCTAssertEqual(ReleaseNotesLibrary.load(folder: folder.appendingPathComponent("missing")).library.notes, [])
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

    /// The What's New sheet shows one line per card. The version about to ship writes each line on
    /// purpose (`brief:`), so the sheet never falls back to the first sentence of a long card.
    func testTheShippingVersionGivesEveryCardABrief() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(project.components(separatedBy: "\n").first { $0.contains("MARKETING_VERSION:") })
        let text = line.components(separatedBy: "MARKETING_VERSION:")[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t"))
        let note = try XCTUnwrap(library.note(for: AppVersion(text)), "no notes for \(text)")
        for feature in note.features {
            XCTAssertFalse((feature.brief ?? "").isEmpty, "\(note.id): \"\(feature.title)\" needs a brief: line for the What's New sheet")
        }
    }

    func testEveryPublicVersionSoFarIsThere() {
        for version in ["1.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4", "1.0.5"] {
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

    /// The rules in `next-build/README.md` that a test can check: plain punctuation, and cards
    /// short enough to read as cards.
    func testNotesAreShortAndPlain() {
        for note in library.notes {
            var texts = [note.summary] + note.fixes
            XCTAssertLessThanOrEqual(note.summary.count, 150, "\(note.id) summary")
            XCTAssertFalse(note.features.isEmpty, "\(note.id) has no cards")
            for feature in note.features {
                XCTAssertLessThanOrEqual(feature.title.count, 44, "\(note.id): \(feature.title)")
                XCTAssertLessThanOrEqual(feature.body.count, 360, "\(note.id): \(feature.title) is too long for a card")
                XCTAssertFalse(feature.body.contains("\n"), "\(note.id): \(feature.title) is one paragraph")
                XCTAssertLessThanOrEqual(feature.tag?.count ?? 0, 14, "\(note.id): \(feature.title) tag")
                // The What's New sheet lists every card as one line, so that line must stay short.
                XCTAssertLessThanOrEqual(feature.headline.count, 90,
                                         "\(note.id): \(feature.title) needs a brief: line of 90 characters or fewer")
                texts += [feature.title, feature.body, feature.tag ?? "", feature.location ?? "", feature.brief ?? ""]
            }
            for fix in note.fixes {
                XCTAssertLessThanOrEqual(fix.count, 170, "\(note.id): \(fix)")
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

    /// Each change is told once: in one version, as a card or as a line, never both. This catches
    /// the copy and paste kind of repeat (the same sentence in two places); a change reworded in a
    /// second place still needs a person to notice it.
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
            for feature in note.features {
                XCTAssertTrue(titles.insert(feature.title.lowercased()).inserted, "\(note.id): two cards called \(feature.title)")
                check(feature.body, "\(note.id), \(feature.title)")
            }
            for fix in note.fixes { check(fix, "\(note.id), Also in this version") }
        }
    }

    /// A card's short line is for the What's New sheet, where the body is not shown, so it may
    /// say the same thing as the body. It must not be the body itself: then it adds nothing.
    func testABriefIsShorterThanItsCard() {
        for note in library.notes {
            for feature in note.features {
                guard let brief = feature.brief else { continue }
                XCTAssertLessThan(brief.count, feature.body.count, "\(note.id): \(feature.title) brief repeats its whole card")
            }
        }
    }

    #if canImport(AppKit)
    func testEverySymbolExists() {
        for note in library.notes {
            for feature in note.features {
                XCTAssertNotNil(NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil),
                                "\(note.id): \"\(feature.symbol)\" is not an SF Symbol (\(feature.title))")
            }
        }
    }
    #endif
}
