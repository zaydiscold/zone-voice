// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Editorial checks for the notes people read in Settings > About > Version and the What's New sheet, from
/// 1.0.6 on. The reasons, and the papers behind each rule, are in
/// `docs/investigations/2026-11-21-plain-copy.md`. Earlier versions keep the words they shipped with.
///
/// Readability formulas are deliberately not used: they do not rank single sentences reliably
/// (arXiv:2301.02975). These are checks a writer can act on: sentence length, words only the team
/// uses, a real place to tap, where to turn on what is off, and nothing promised that has not shipped.
final class PlainReleaseCopyTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let library = ReleaseNotesLibrary.load(folder: root.appendingPathComponent("Zone/ReleaseNotes")).library
    private static let plainFrom = AppVersion("1.0.6")!

    /// Every Swift file a person sees text from: the app and the keyboard.
    private static let shownStrings: String = {
        var text = ""
        for folder in ["Zone", "ZoneKeyboard"] {
            let base = root.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        return text
    }()

    private var notes: [ReleaseNote] { Self.library.notes.filter { $0.version >= Self.plainFrom } }

    private func lines(_ note: ReleaseNote) -> [(group: String, item: ReleaseItem)] {
        note.groups.flatMap { group in group.items.map { (group.title, $0) } }
    }

    private func sentences(_ text: String) -> [String] {
        text.components(separatedBy: ". ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }.filter { !$0.isEmpty }
    }

    private func words(_ sentence: String) -> [Substring] {
        sentence.split(whereSeparator: { $0 == " " })
    }

    func testThereIsAPlainVersionToCheck() {
        XCTAssertFalse(notes.isEmpty, "no notes from \(Self.plainFrom) on")
    }

    /// Short sentences are the one plain-language measure that holds up across exemplars
    /// (Riddell and Igarashi, RANLP 2021). 16 words fits a line of the What's New sheet in two rows.
    func testSentencesAreShort() {
        for note in notes {
            var total = 0, count = 0
            for sentence in sentences(note.summary) + lines(note).flatMap({ sentences($0.item.text) }) {
                let n = words(sentence).count
                XCTAssertLessThanOrEqual(n, 16, "\(note.id): \"\(sentence)\" has \(n) words")
                total += n
                count += 1
            }
            XCTAssertLessThanOrEqual(Double(total) / Double(max(count, 1)), 11, "\(note.id): sentences average over 11 words")
        }
    }

    /// Words the team uses and people do not. Release note readers ask for jargon to be explained
    /// (arXiv:2203.15592); in a one-line note there is no room to explain, so the word goes.
    func testNoTeamWords() {
        let team = ["queue", "csv", "neural engine", "route", "routing", "segment", "evict", "eviction", "cold",
                    "in transit", "explicitly", "shortcode", "diariz", "transcriber", "fallback", "persist",
                    "debug", "regression", "app group", "extension", "a pass", "foreground", "background"]
        for note in notes {
            for (group, item) in lines(note) {
                let text = " " + ((item.title ?? "") + " " + item.text).lowercased() + " "
                for word in team where text.contains(word) {
                    XCTFail("\(note.id), \(group): \"\(word)\" in \"\(item.title ?? item.text)\"")
                }
            }
        }
    }

    func testThisReleaseDoesNotAdvertiseTheWithheldModel() throws {
        let note = try XCTUnwrap(Self.library.note(for: Self.plainFrom))
        for text in [note.summary] + lines(note).map({ ($0.item.title ?? "") + ": " + $0.item.text }) {
            for phrase in ["speech pro", "coming soon"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), "\(note.id): \(text)")
            }
        }
    }

    /// A path like Settings > About > Version names screens and rows that exist, so "what to tap"
    /// is true. Each step must start with a label the app or keyboard shows as a string literal.
    /// Experimental is the old name a line says was replaced.
    func testEverySettingsPathExists() {
        let retired: Set<String> = ["Experimental"]
        var checked = 0
        for note in notes {
            for (_, item) in lines(note) {
                let parts = item.text.components(separatedBy: "Settings > ")
                for path in parts.dropFirst() {
                    for step in path.components(separatedBy: " > ") {
                        let stepWords = words(step).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
                        let found = (1...max(1, stepWords.count)).contains { n in
                            let label = stepWords.prefix(n).joined(separator: " ")
                            return retired.contains(label) || Self.shownStrings.contains("\"\(label)\"")
                                || Self.shownStrings.contains("\"\(label) ")
                        }
                        XCTAssertTrue(found, "\(note.id): no screen or row starts \"\(step)\" in \"\(item.text)\"")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 5, "the notes stopped naming places to tap")
    }

    /// A change that is off until someone turns it on says where (app reviewers in the Play Store
    /// study complained of a feature "hidden in the options", Yang et al., EMSE 2022).
    func testOffByDefaultSaysWhereToTurnItOn() throws {
        let offByDefault = ["Clipboard history", "Speed up speech in Zone", "One-handed keyboard"]
        for note in notes {
            for title in offByDefault {
                guard let item = lines(note).first(where: { $0.item.title == title })?.item else { continue }
                XCTAssertTrue(item.text.contains("Turn it on in"), "\(note.id): \(title) does not say where to turn it on")
            }
        }
    }

    /// The What's New sheet carries the changes this rewrite was asked to make findable: notes, emoji by
    /// name, clipboard history and meetings.
    func testTheSheetShowsTheVersionDefiningChanges() throws {
        let note = try XCTUnwrap(Self.library.note(for: Self.plainFrom))
        let starred = Set(note.highlights.map { $0.group.title })
        for group in ["Dictation", "Keyboard", "Voice notes", "Meetings", "Home and library"] {
            XCTAssertTrue(starred.contains(group), "1.0.6 stars nothing in \(group)")
        }
        XCTAssertTrue(note.highlights.contains { $0.item.title == "Clipboard history" && $0.item.text.contains("Off until") },
                      "the starred clipboard line says it is off until you turn it on")
    }
}
