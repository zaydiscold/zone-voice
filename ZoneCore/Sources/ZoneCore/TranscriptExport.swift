// by zayd/cold @ zayd.wtf

import Foundation

/// Several dictations as one block of text to paste into a chat or a document: each one under
/// its date and time, oldest first so the paste reads in the order things were said.
public enum TranscriptExport {
    public struct Item: Equatable, Sendable {
        public let date: Date
        public let text: String
        public init(date: Date, text: String) {
            self.date = date
            self.text = text
        }
    }

    /// "Nov 3, 2026 at 9:01 PM" on its own line, the text, then a blank line before the next.
    public static func text(for items: [Item], calendar: Calendar = .current, locale: Locale = .current,
                            timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return items
            .sorted { $0.date < $1.date }
            .map { item in
                let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return formatter.string(from: item.date) + "\n" + (body.isEmpty ? "(nothing heard)" : body)
            }
            .joined(separator: "\n\n")
    }
}
