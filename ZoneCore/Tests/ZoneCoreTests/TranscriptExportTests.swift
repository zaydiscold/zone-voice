// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class TranscriptExportTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_US_POSIX")
    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 3
        components.hour = hour; components.minute = minute
        components.timeZone = zone
        return calendar.date(from: components)!
    }

    /// Foundation puts a narrow no-break space before AM and PM; the test reads it as a space.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testOldestFirstWithDateLineAndBlankLineBetween() {
        let items = [
            TranscriptExport.Item(date: date(21, 5), text: "  second one  "),
            TranscriptExport.Item(date: date(9, 1), text: "first one"),
        ]
        let text = TranscriptExport.text(for: items, calendar: calendar, locale: locale, timeZone: zone)
        XCTAssertEqual(plain(text), "Nov 3, 2026 at 9:01 AM\nfirst one\n\nNov 3, 2026 at 9:05 PM\nsecond one")
    }

    func testEmptyTextSaysNothingHeardAndEmptyListIsEmpty() {
        let items = [TranscriptExport.Item(date: date(12, 0), text: " ")]
        XCTAssertEqual(plain(TranscriptExport.text(for: items, calendar: calendar, locale: locale, timeZone: zone)),
                       "Nov 3, 2026 at 12:00 PM\n(nothing heard)")
        XCTAssertEqual(TranscriptExport.text(for: []), "")
    }
}
