// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A slip in one of the person's own words is fixed to that word, in the spelling they saved.
/// The pairs were written before the rule was run.
final class OwnWordCorrectionTests: XCTestCase {
    private static let saved = ["Aalia", "Kriya", "Mattson", "Figma", "Dahlsson", "Qorvex", "Zone Link", "og", "Ali", "Will", "Apple", "iPhone", "McKinsey"]

    private func engine() -> Autocorrector {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setPersonalWords(Self.saved)
        return engine
    }

    func testASlipInASavedWordBecomesThatWord() {
        let engine = engine()
        let pairs = [
            ("aalua", "Aalia"), ("Aalua", "Aalia"), ("aaloa", "Aalia"), ("aalai", "Aalia"), ("aaliaa", "Aalia"), ("alia", "Aalia"),
            ("kriys", "Kriya"), ("Krija", "Kriya"), ("kirya", "Kriya"),
            ("mattsin", "Mattson"), ("matson", "Mattson"), ("Mattsom", "Mattson"),
            ("dahlsson", "Dahlsson"), ("dahlsso", "Dahlsson"), ("dshlsson", "Dahlsson"),
            ("qorvez", "Qorvex"), ("qotvex", "Qorvex"),
            ("figna", "Figma"),
        ]
        var missed: [String] = []
        for (typed, want) in pairs where engine.evaluate(typed).replacement ?? typed != want {
            missed.append("\(typed): \(engine.evaluate(typed).replacement ?? "kept"), wanted \(want)")
        }
        XCTAssertTrue(missed.isEmpty, missed.joined(separator: "; "))
    }

    /// Words the dictionary knows, other names, short words and far-off strings are left as they
    /// were before My words could fix a slip.
    func testOtherWordsAreNotPulledOntoASavedWord() {
        let with = engine()
        let without = Autocorrector(words: WordListTests.list)
        let typed = ["alias", "aria", "maria", "korea", "matters", "mattress", "mason", "figs", "fight", "zone", "link", "linked",
                     "all", "also", "of", "on", "will", "apple", "the", "hello", "krill", "Maria", "Julia", "India", "Alana",
                     "qwerty", "asdfgh", "aaaaa", "matt", "Matt", "dahl", "figure", "karma", "kayak", "media", "pizza"]
        var changed: [String] = []
        for word in typed {
            let now = with.evaluate(word).replacement, before = without.evaluate(word).replacement
            if now != before { changed.append("\(word): \(before ?? "kept") became \(now ?? "kept")") }
        }
        XCTAssertTrue(changed.isEmpty, changed.joined(separator: "; "))
    }

    /// A saved word typed in lowercase takes the capitals it was saved with. A word of a phrase,
    /// an everyday word, a lowercase entry and a spelling the person kept stay as typed.
    func testASavedSpellingTakesItsCapitals() {
        let engine = engine()
        for (typed, want) in [("aalia", "Aalia"), ("dahlsson", "Dahlsson"), ("mckinsey", "McKinsey"), ("ali", "Ali"), ("iphone", "iPhone")] {
            XCTAssertEqual(engine.evaluate(typed).replacement, want, typed)
        }
        for typed in ["zone", "link", "og", "will", "apple", "Aalia", "AALIA"] {
            XCTAssertNil(engine.evaluate(typed).replacement, typed)
        }
        engine.learn("aalia")
        XCTAssertNil(engine.evaluate("aalia").replacement, "kept lowercase once, stays lowercase")
    }

    func testFiveHundredSavedWordsStayQuick() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setPersonalWords((0..<500).map { "Zq\(String($0, radix: 26).map { Character(UnicodeScalar(UInt8(97 + Int(String($0), radix: 26)!))) }.reduce("") { $0 + String($1) })wort" })
        let start = Date()
        for i in 0..<200 { _ = engine.evaluate("zqxbwors\(i % 2 == 0 ? "t" : "")") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
