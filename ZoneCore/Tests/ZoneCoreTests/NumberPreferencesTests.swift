// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class NumberPreferencesTests: XCTestCase {
    func testModesAndStyleSwitches() {
        for style in TextStyle.allCases {
            for mode in NumberPreferences.Mode.allCases {
                let input = "I saw 7 birds and twelve ducks"
                XCTAssertEqual(style.apply(input, numbers: .init(mode: mode, styles: [])), style.apply(input))
                let output = style.apply(input, numbers: .init(mode: mode, styles: [style])).lowercased()
                XCTAssertTrue(output.contains(mode == .words ? "seven birds" : "7 birds"), output)
                XCTAssertTrue(output.contains("12 ducks"), output)
            }
        }
    }

    func testUpgradeAndRoundTrip() throws {
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.numbers, NumberPreferences())
        XCTAssertFalse(old.numbers.styles.contains(.veryCasual))
        var changed = old
        changed.numbers = .init(mode: .words, styles: [.veryCasual])
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(changed)).numbers, changed.numbers)
    }

    func testStructuredNumbersAndIdioms() {
        let examples = [
            ("meet at three thirty", "meet at 3:30"), ("May seven", "May 7"),
            ("one dollar", "1 dollar"), ("five percent", "5%"), ("2%", "2%"),
            ("one two three four five six seven eight nine zero", "1234567890"),
            ("7 Oak Street", "7 Oak Street"), ("version three", "version 3"),
            ("one meter", "1 meter"), ("five point two", "5.2"), ("3.14", "3.14"),
            ("three of twelve", "3 of 12"), ("three to seven", "3 to 7"),
            ("age seven", "age 7"), ("seven-year-old", "7-year-old"),
            ("one-hour walk", "1-hour walk"), ("7 West Oak Road", "7 West Oak Road"),
            ("meet at 3 tomorrow", "meet at 3 tomorrow"), ("a couple", "a couple"), ("a hundred", "100"),
            ("twenty twenty six", "2026"), ("that one", "that one"), ("one of those", "one of those"),
            ("one day", "one day"), ("one second!", "one second!"),
            ("for one day", "for 1 day"), ("one second of audio", "1 second of audio"),
            ("Claude one shot the task", "Claude one shot the task"),
            ("building 1 and 2", "building 1 and 2"), ("GTA 6", "GTA 6"),
            ("noon to two", "noon to 2"), ("at 7, 8 p.m.", "at 7, 8 p.m."),
            ("8 or 9, maybe seven", "8 or 9, maybe 7"),
            ("the red one", "the red one"), ("one by one", "one by one"), ("high five", "high five")
        ]
        for mode in [SpokenNumbers.Small.alwaysDigits, .words] {
            for (input, expected) in examples {
                XCTAssertEqual(SpokenNumbers.writingDigits(input, small: mode), expected, input)
                XCTAssertEqual(SpokenNumbers.writingDigits(expected, small: mode), expected, expected)
            }
        }
    }

    func testSentenceStartAndExplicitCounts() {
        let numbers = NumberPreferences(mode: .words)
        XCTAssertEqual(TextStyle.formal.apply("7 birds came", numbers: numbers), "Seven birds came.")
        XCTAssertEqual(TextStyle.formal.apply("Seven birds came", numbers: .init(mode: .digits)), "7 birds came.")
        XCTAssertEqual(SpokenNumbers.writingDigits("I have one apple and two pears", small: .alwaysDigits), "I have 1 apple and 2 pears")
        XCTAssertEqual(TextStyle.formal.apply("May third", numbers: numbers), "May 3rd.")
        XCTAssertEqual(TextStyle.formal.apply("second place", numbers: numbers), "Second place.")
        XCTAssertEqual(TextStyle.formal.apply("second place", smallOrdinals: true, numbers: numbers), "2nd place.")
        XCTAssertEqual(TextStyle.formal.apply("see `7 cats` below", numbers: numbers), "See `7 cats` below.")
    }
}
