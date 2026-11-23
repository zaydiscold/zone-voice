// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SmartPunctuationTests: XCTestCase {
    /// What Apple's keyboard left in a default text view for each typed string, one key tap at a
    /// time, on the iOS 26.2 simulator (2026-11-14, `AppleSmartPunctuationOracle`). The same
    /// recording with autocorrection off matched on every row; with both smart traits off nothing
    /// changed. Record it again when the iOS version changes.
    static let apple: [(typed: String, apple: String)] = [
        ("\"hi\"", "\u{201C}hi\u{201D}"),
        ("he said \"hi\"", "he said \u{201C}hi\u{201D}"),
        ("(\"hi\")", "(\u{201C}hi\u{201D})"),
        ("[\"hi\"]", "[\u{201C}hi\u{201D}]"),
        ("a\"", "a\u{201D}"),
        ("a \"", "a \u{201C}"),
        ("\"\"", "\u{201C}\u{201D}"),
        ("say \"hi\".", "say \u{201C}hi\u{201D}."),
        ("x=\"y\"", "x=\u{201C}y\u{201D}"),
        ("a-\"b\"", "a-\u{201C}b\u{201D}"),
        ("a/\"b\"", "a/\u{201C}b\u{201D}"),
        ("5\"", "5\u{201D}"),
        ("5'10\"", "5\u{2019}10\u{201D}"),
        ("\"'hi'\"", "\u{201C}\u{2018}hi\u{2019}\u{201D}"),
        ("a\n\"b\"", "a\n\u{201C}b\u{201D}"),
        ("a.\"b\"", "a.\u{201D}b\u{201D}"),
        ("1\"2", "1\u{201D}2"),
        ("don't", "don\u{2019}t"),
        ("'hi'", "\u{2018}hi\u{2019}"),
        ("he said 'hi'", "he said \u{2018}hi\u{2019}"),
        ("'tis", "\u{2018}tis"),
        ("'90s", "\u{2018}90s"),
        ("the '90s", "the \u{2018}90s"),
        ("rock 'n' roll", "rock \u{2018}n\u{2019} roll"),
        ("dogs' toys", "dogs\u{2019} toys"),
        ("a'", "a\u{2019}"),
        ("''", "\u{2018}\u{2019}"),
        ("('a')", "(\u{2018}a\u{2019})"),
        ("5'", "5\u{2019}"),
        ("a-'b'", "a-\u{2018}b\u{2019}"),
        ("'em", "\u{2018}em"),
        ("a 'b", "a \u{2018}b"),
        ("1'2", "1\u{2019}2"),
        ("a--b", "a\u{2014}b"),
        ("a -- b", "a \u{2014} b"),
        ("a---b", "a\u{2014}-b"),
        ("a --- b", "a \u{2014}- b"),
        ("--", "\u{2014}"),
        ("---", "\u{2014}-"),
        ("----", "\u{2014}\u{2014}"),
        ("a-b", "a-b"),
        ("a - b", "a - b"),
        ("-- ", "\u{2014} "),
        ("--a", "\u{2014}a"),
        ("1--2", "1\u{2013}2"),
        ("a-- b", "a\u{2014} b"),
        ("a --b", "a \u{2014}b"),
        ("-->", "\u{2014}>"),
        ("--flag", "\u{2014}flag"),
        ("...", "\u{2026}"),
        ("wait...", "wait\u{2026}"),
        ("(c)", "(c)"),
        ("1/2", "1/2"),
        ("->", "->"),
        ("=>", "=>"),
        ("!=", "!="),
        ("https://a.com/?q=\"x\"", "https://a.com/?q=\u{201C}x\u{201D}"),
        ("me@a-b.com", "me@a-b.com"),
        ("print(\"hi\")", "print(\u{201C}hi\u{201D})"),
        ("it's a \"test\"--ok", "it\u{2019}s a \u{201C}test\u{201D}\u{2014}ok"),
    ]

    /// Where Zone deliberately differs from Apple, and what it writes instead.
    static let departures: [String: String] = [
        // A leading apostrophe is an apostrophe. Apple opens a quote.
        "'90s": "\u{2019}90s", "the '90s": "the \u{2019}90s", "rock 'n' roll": "rock \u{2019}n\u{2019} roll",
        // Feet and inches stay straight when no quote is open.
        "5\"": "5\"", "5'10\"": "5'10\"", "1\"2": "1\"2", "5'": "5'", "1'2": "1'2",
        // Addresses are never rewritten.
        "https://a.com/?q=\"x\"": "https://a.com/?q=\"x\"",
        // A divider line and an arrow survive.
        "---": "---", "----": "----", "-->": "-->",
    ]

    private func type(_ text: String, quotes: Bool = true, dashes: Bool = true) -> String {
        var field = ""
        for character in text {
            if let change = SmartPunctuation.edit(typing: character, before: field, quotes: quotes, dashes: dashes) {
                field.removeLast(change.deleteCount)
                field += change.insert
            } else {
                field.append(character)
            }
        }
        return field
    }

    func testMatchesAppleExceptWhereListed() {
        var differences: [String] = []
        for row in Self.apple {
            let expected = Self.departures[row.typed] ?? row.apple
            let got = type(row.typed)
            XCTAssertEqual(got, expected, "typed \(row.typed)")
            if got != row.apple { differences.append(row.typed) }
        }
        XCTAssertEqual(Set(differences), Set(Self.departures.keys), "every difference from Apple is listed, and only those")
    }

    func testElisionsAreFixedWhenTheWordEnds() {
        XCTAssertEqual(type("'tis "), "\u{2019}tis ")
        XCTAssertEqual(type("get 'em."), "get \u{2019}em.")
        XCTAssertEqual(type("'Twas the"), "\u{2019}Twas the")
        XCTAssertEqual(type("'til then"), "\u{2019}til then")
        // A quoted word that happens to be one of them keeps its quotes; any other word does too.
        XCTAssertEqual(type("'em' "), "\u{2018}em\u{2019} ")
        XCTAssertEqual(type("'hi' there"), "\u{2018}hi\u{2019} there")
        XCTAssertEqual(type("say 'emma' "), "say \u{2018}emma\u{2019} ")
    }

    func testNumbersAndQuotes() {
        XCTAssertEqual(type("the 90's"), "the 90\u{2019}s")
        XCTAssertEqual(type("\"in 2024\""), "\u{201C}in 2024\u{201D}")
        XCTAssertEqual(type("'top 10'"), "\u{2018}top 10\u{2019}")
        XCTAssertEqual(type("\"it's 5\" ok"), "\u{201C}it\u{2019}s 5\u{201D} ok")
        XCTAssertEqual(type("6'2\" tall"), "6'2\" tall")
    }

    func testOpeningAndClosingAcrossLinesAndBrackets() {
        XCTAssertEqual(type("a\n\"b\""), "a\n\u{201C}b\u{201D}")
        XCTAssertEqual(type("{\"a\"}"), "{\u{201C}a\u{201D}}")
        XCTAssertEqual(type("well\u{2014}\"no\""), "well\u{2014}\u{201C}no\u{201D}")
        XCTAssertEqual(type("y'all's"), "y\u{2019}all\u{2019}s")
        XCTAssertEqual(type("\"Done.\" \"Next\""), "\u{201C}Done.\u{201D} \u{201C}Next\u{201D}")
    }

    func testDashes() {
        XCTAssertEqual(type("wait--what"), "wait\u{2014}what")
        XCTAssertEqual(type("pages 3--5"), "pages 3\u{2013}5")
        XCTAssertEqual(type("a\n---\nb"), "a\n---\nb")
        XCTAssertEqual(type("<!-- x -->"), "<!-- x -->")
        XCTAssertEqual(type("a-b - c"), "a-b - c")
        XCTAssertEqual(type("so... yes"), "so\u{2026} yes")
        XCTAssertEqual(type("...."), "\u{2026}.")
        XCTAssertEqual(type(".."), "..")
    }

    func testAddressesAndCodeStayAsTyped() {
        XCTAssertEqual(type("see https://x.com/a--b?q='1' now"), "see https://x.com/a--b?q='1' now")
        XCTAssertEqual(type("me@site--x.com"), "me@site--x.com")
        XCTAssertEqual(type("www.a.com/'x'"), "www.a.com/'x'")
        XCTAssertEqual(type("run `git log --oneline 'x'` ok"), "run `git log --oneline 'x'` ok")
        // After the address or the code span ends, prose is smart again.
        XCTAssertEqual(type("https://x.com \"hi\""), "https://x.com \u{201C}hi\u{201D}")
        XCTAssertEqual(type("`a` \"hi\"--ok"), "`a` \u{201C}hi\u{201D}\u{2014}ok")
        // A handle in a sentence is prose.
        XCTAssertEqual(type("ask @sam \"why\""), "ask @sam \u{201C}why\u{201D}")
    }

    func testEachTraitAlone() {
        XCTAssertEqual(type("\"a\"--b...", quotes: false), "\"a\"\u{2014}b\u{2026}")
        XCTAssertEqual(type("\"a\"--b...", dashes: false), "\u{201C}a\u{201D}--b...")
        XCTAssertEqual(type("\"a\"--b... 'tis ", quotes: false, dashes: false), "\"a\"--b... 'tis ")
    }

    /// Backspace after a change puts back exactly what plain typing would have left.
    func testPlainIsWhatTypingWouldHaveLeft() {
        for row in Self.apple + [("'tis ", ""), ("the 90's", ""), ("rock 'n' roll", "")] {
            var field = ""
            for character in row.typed {
                if let change = SmartPunctuation.edit(typing: character, before: field, quotes: true, dashes: true) {
                    let plain = field + String(character)
                    field.removeLast(change.deleteCount)
                    XCTAssertEqual(field + change.plain, plain, "typed \(row.typed)")
                    field += change.insert
                } else {
                    field.append(character)
                }
            }
        }
    }

    func testPreferenceDefaultsOffAndSurvivesOldRecords() throws {
        XCTAssertFalse(KeyboardPreferences().smartPunctuation)
        let old = Data(#"{"autocorrectEnabled":true}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(KeyboardPreferences.self, from: old).smartPunctuation)
        let on = KeyboardPreferences(smartPunctuation: true)
        XCTAssertTrue(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(on)).smartPunctuation)
    }
}
