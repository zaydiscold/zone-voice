// by zayd/cold @ zayd.wtf

import Foundation

/// What a row shows of a kept copy: its own words, and how much of it there is.
///
/// A row has two lines, and a copy is exact text that often opens with a web address: a page
/// selected in Safari, a shared article, a forwarded message, each with its words after a blank
/// line. Shown from its first character, such a copy is a row of nothing but the address. On
/// Zayd's phone on November 23, 2026, three passages of 1,460 to 3,360 characters and five real
/// links all read as links, and the three passages as the same link.
///
/// So the row starts at the first line that is not a bare web address, runs line breaks and blank
/// lines together so two lines carry words, and the quiet line says how long the copy is whenever
/// the row cannot show all of it. Only what a row shows changes: the copy that is inserted,
/// copied or searched is always the whole stored text.
public struct ClipboardPreview: Equatable, Sendable {
    /// The words a row shows, on one line (line breaks are spaces), at most `limit` characters.
    public let text: String
    /// Words in the copy, not counting the web addresses it opens with.
    public let words: Int
    /// Bare web addresses the copy opens with, which `text` leaves out. Zero when the copy is
    /// nothing but web addresses (`links`).
    public let leadingLinks: Int
    /// How many web addresses the copy is, when it is nothing else. Zero otherwise.
    public let links: Int
    /// The row cannot show all of the words.
    public let isLong: Bool

    /// - Parameters:
    ///   - limit: the most characters a row is given. Two lines never show more, and the keyboard
    ///     has little memory to lay out a 64,000 byte copy it will cut at two lines anyway.
    ///   - rowCharacters: about what two lines of a row hold at the standard text size.
    public init(_ text: String, limit: Int = 240, rowCharacters: Int = 80) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let opening = lines.prefix { ClipboardPolicy.link(in: $0) != nil }.count
        if opening == lines.count {
            // A link, or a list of links: the addresses are the copy.
            links = opening
            leadingLinks = 0
            words = opening
            let shown = lines.joined(separator: " ")
            isLong = shown.count > rowCharacters && opening > 1
            self.text = String(shown.prefix(limit))
            return
        }
        links = 0
        leadingLinks = opening
        var shown = ""
        var count = 0
        for line in lines.dropFirst(opening) {
            for word in line.split(whereSeparator: \.isWhitespace) {
                count += 1
                // Past the limit only the count matters.
                guard shown.count <= limit else { continue }
                if !shown.isEmpty { shown.append(" ") }
                shown.append(contentsOf: word)
            }
        }
        words = count
        isLong = shown.count > rowCharacters
        self.text = String(shown.prefix(limit))
    }

    /// The row's quiet line beside the time: "Link", "3 links", "503 words", "Link and 503 words".
    /// Nil for a short copy the row shows whole.
    public var detail: String? {
        if links > 0 { return links == 1 ? "Link" : "\(links.formatted()) links" }
        let length = words == 1 ? "1 word" : "\(words.formatted()) words"
        if leadingLinks == 1 { return "Link and \(length)" }
        if leadingLinks > 1 { return "\(leadingLinks.formatted()) links and \(length)" }
        return isLong ? length : nil
    }
}
