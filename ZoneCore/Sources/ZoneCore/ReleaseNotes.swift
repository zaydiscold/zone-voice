// by zayd/cold @ zayd.wtf

import Foundation

/// A marketing version such as 1.0.4, compared number by number (1.0.10 is newer than 1.0.9, and
/// 1.0 equals 1.0.0).
public struct AppVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    /// The version as it was written, which is how it is shown.
    public let description: String

    /// Nil unless the text is numbers separated by dots.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
        self.description = trimmed
    }

    private var padded: [Int] {
        var parts = parts
        while let last = parts.last, last == 0, parts.count > 1 { parts.removeLast() }
        return parts
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.padded == b.padded }
    public func hash(into hasher: inout Hasher) { hasher.combine(padded) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = (a.padded, b.padded)
        for index in 0..<max(x.count, y.count) {
            let (l, r) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
            if l != r { return l < r }
        }
        return false
    }
}

/// The day a version came out, as written in its notes (2026-11-14). A calendar day, not a
/// moment: it reads the same in every time zone.
public struct ReleaseDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard components.isValidDate(in: Calendar(identifier: .gregorian)) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (a: ReleaseDay, b: ReleaseDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Noon on that day in the given calendar, for a date formatter.
    public func date(in calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}

/// One card in a version's notes: a short title, a picture, and one to three plain sentences.
public struct ReleaseFeature: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    /// An SF Symbol name.
    public let symbol: String
    /// A small label above the title, such as "Beta" or "Keyboard". Optional.
    public let tag: String?
    /// Where to turn it on or find it, such as "Settings > Computers". Optional.
    public let location: String?
    public let body: String
    /// One short line for the What's New sheet, which lists every card as a line. Optional: without
    /// it the sheet shows the body's first sentence.
    public let brief: String?

    public init(title: String, symbol: String, tag: String? = nil, location: String? = nil, body: String,
                brief: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.tag = tag
        self.location = location
        self.body = body
        self.brief = brief
    }

    /// The line the What's New sheet shows under the title: `brief`, or the body's first sentence.
    public var headline: String {
        if let brief, !brief.isEmpty { return brief }
        return Self.firstSentence(of: body)
    }

    /// Up to and including the first ". ", "! " or "? " that ends a sentence. A period inside a
    /// web address or a number ("github.com", "2.5") is followed by a letter or digit, so it never
    /// ends one.
    static func firstSentence(of text: String) -> String {
        let paragraph = text.components(separatedBy: "\n").first ?? text
        let characters = Array(paragraph)
        for index in characters.indices where ".!?".contains(characters[index]) {
            let next = index + 1
            if next == characters.count { return paragraph }
            if characters[next] == " " { return String(characters[...index]) }
        }
        return paragraph
    }
}

/// One version's release notes: what the history screen and the What's New sheet show.
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    public var id: String { version.description }
    public let version: AppVersion
    /// Nil until the version has a release day.
    public let day: ReleaseDay?
    /// One sentence under the version number.
    public let summary: String
    public let features: [ReleaseFeature]
    /// "Also in this version": smaller changes and fixes, one line each.
    public let fixes: [String]

    public init(version: AppVersion, day: ReleaseDay?, summary: String, features: [ReleaseFeature], fixes: [String]) {
        self.version = version
        self.day = day
        self.summary = summary
        self.features = features
        self.fixes = fixes
    }
}

/// Reads one version's notes from the Markdown in `Zone/ReleaseNotes/`.
///
/// ```
/// # 1.0.4
/// date: 2026-11-15
/// summary: One sentence about the version.
///
/// ## A short title
/// symbol: desktopcomputer
/// tag: Beta
/// where: Settings > Computers
/// brief: One short line for the What's New sheet.
///
/// One to three plain sentences.
///
/// ## Also in this version
///
/// - A smaller change.
/// ```
///
/// `date`, `tag`, `where` and `brief` are optional. Everything else is required, and a mistake is an
/// error with its line number, not a guess: these files ship inside the app.
public enum ReleaseNotesParser {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// The heading that starts the list of smaller changes.
    public static let fixesHeading = "Also in this version"

    public static func parse(_ text: String) throws -> ReleaseNote {
        var version: AppVersion?
        var day: ReleaseDay?
        var summary: String?
        var features: [ReleaseFeature] = []
        var fixes: [String] = []

        /// The feature being read.
        var title: String?
        var titleLine = 0
        var fields: [String: String] = [:]
        var paragraphs: [[String]] = []
        var inFixes = false
        var sawFixes = false
        var inComment = false
        /// Keys are only read straight after a heading, before any other text.
        var acceptsKeys = false
        var keysSinceHeading = 0

        func fail(_ line: Int, _ message: String) -> Failure { Failure(line: line, message: message) }

        func closeFeature() throws {
            guard let name = title else { return }
            let body = paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
            guard let symbol = fields["symbol"], !symbol.isEmpty else {
                throw fail(titleLine, "\"\(name)\" needs a symbol: line (an SF Symbol name)")
            }
            guard !body.isEmpty else { throw fail(titleLine, "\"\(name)\" has no text under it") }
            guard !features.contains(where: { $0.title == name }) else {
                throw fail(titleLine, "\"\(name)\" appears twice")
            }
            features.append(ReleaseFeature(title: name, symbol: symbol, tag: fields["tag"], location: fields["where"], body: body,
                                           brief: fields["brief"]))
            title = nil
            fields = [:]
            paragraphs = []
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            var line = raw.trimmingCharacters(in: .whitespaces)

            // Comments are for the people editing the file (a TODO for whoever merges next).
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                inComment = false
                line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            while let start = line.range(of: "<!--") {
                if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                    line = line.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
                } else {
                    line = String(line[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
                    inComment = true
                    break
                }
            }
            if line.isEmpty {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line after the keys ends them, so a sentence that happens to
                    // start with a word and a colon is read as a sentence.
                    if keysSinceHeading > 0 { acceptsKeys = false }
                    if title != nil, let last = paragraphs.last, !last.isEmpty { paragraphs.append([]) }
                }
                continue
            }

            if line.hasPrefix("## ") {
                guard version != nil else { throw fail(number, "the file must start with \"# \" and the version") }
                guard summary != nil else { throw fail(number, "the version needs a summary: line before its first section") }
                guard !sawFixes else { throw fail(number, "\"\(fixesHeading)\" must be the last section") }
                try closeFeature()
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw fail(number, "a section needs a title") }
                if name.caseInsensitiveCompare(fixesHeading) == .orderedSame {
                    inFixes = true
                    sawFixes = true
                    acceptsKeys = false
                } else {
                    title = name
                    titleLine = number
                    paragraphs = [[]]
                    acceptsKeys = true
                    keysSinceHeading = 0
                }
                continue
            }
            if line.hasPrefix("# ") {
                guard version == nil else { throw fail(number, "one version per file") }
                let name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard let parsed = AppVersion(name) else { throw fail(number, "\"\(name)\" is not a version like 1.0.4") }
                version = parsed
                acceptsKeys = true
                keysSinceHeading = 0
                continue
            }
            guard version != nil else { throw fail(number, "the file must start with \"# \" and the version") }
            guard !line.hasPrefix("#") else { throw fail(number, "use \"## \" for a section") }

            if inFixes {
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    guard !item.isEmpty else { throw fail(number, "an empty bullet") }
                    fixes.append(item)
                } else if !fixes.isEmpty, raw.first == " " || raw.first == "\t" {
                    // A wrapped bullet continues on an indented line.
                    fixes[fixes.count - 1] += " " + line
                } else {
                    throw fail(number, "lines under \"\(fixesHeading)\" start with \"- \"")
                }
                continue
            }

            if acceptsKeys, let (key, value) = keyValue(line) {
                keysSinceHeading += 1
                if title == nil {
                    switch key {
                    case "date":
                        guard let parsed = ReleaseDay(value) else { throw fail(number, "\"\(value)\" is not a date like 2026-11-15") }
                        guard day == nil else { throw fail(number, "date: appears twice") }
                        day = parsed
                    case "summary":
                        guard !value.isEmpty else { throw fail(number, "summary: is empty") }
                        guard summary == nil else { throw fail(number, "summary: appears twice") }
                        summary = value
                    default:
                        throw fail(number, "\"\(key):\" is not known here (date, summary)")
                    }
                } else {
                    guard ["symbol", "tag", "where", "brief"].contains(key) else {
                        throw fail(number, "\"\(key):\" is not known here (symbol, tag, where, brief)")
                    }
                    guard !value.isEmpty else { throw fail(number, "\(key): is empty") }
                    guard fields[key] == nil else { throw fail(number, "\(key): appears twice") }
                    fields[key] = value
                }
                continue
            }

            guard title != nil else { throw fail(number, "text must sit under a \"## \" section") }
            acceptsKeys = false
            paragraphs[paragraphs.count - 1].append(line)
        }

        if inComment { throw fail(lines.count, "a comment is never closed") }
        try closeFeature()
        guard let version else { throw fail(1, "the file must start with \"# \" and the version") }
        guard let summary else { throw fail(1, "the version needs a summary: line") }
        guard !features.isEmpty || !fixes.isEmpty else { throw fail(1, "the version has no notes") }
        return ReleaseNote(version: version, day: day, summary: summary, features: features, fixes: fixes)
    }

    /// "symbol: mic" is a key and a value. A sentence with a colon in it is not: a key is one
    /// lowercase word.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return nil }
        return (String(key), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }
}

/// Every version's notes, newest first.
public struct ReleaseNotesLibrary: Equatable, Sendable {
    public let notes: [ReleaseNote]

    public init(_ notes: [ReleaseNote]) {
        var seen = Set<AppVersion>()
        self.notes = notes.sorted { $0.version > $1.version }.filter { seen.insert($0.version).inserted }
    }

    /// Reads every `.md` file in a folder. A file that does not parse is left out and named in
    /// `problems`, so one bad file never empties the history; the tests fail on any problem.
    public static func load(folder: URL) -> (library: ReleaseNotesLibrary, problems: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var notes: [ReleaseNote] = []
        var problems: [String] = []
        for file in files {
            let name = file.lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                problems.append("\(name): cannot be read")
                continue
            }
            do {
                let note = try ReleaseNotesParser.parse(text)
                // The file name is how a person finds a version, so it must not lie.
                guard AppVersion(file.deletingPathExtension().lastPathComponent) == note.version else {
                    problems.append("\(name): holds the notes for \(note.version)")
                    continue
                }
                notes.append(note)
            } catch {
                problems.append("\(name): \(error)")
            }
        }
        return (ReleaseNotesLibrary(notes), problems)
    }

    public func note(for version: AppVersion?) -> ReleaseNote? {
        guard let version else { return nil }
        return notes.first { $0.version == version }
    }

    /// The versions this copy of Zone can honestly list: the installed one and everything before
    /// it. Notes written ahead of a release stay out of sight until the app is that version.
    /// With no readable installed version, everything is listed.
    public func history(installed: AppVersion?) -> [ReleaseNote] {
        guard let installed else { return notes }
        return notes.filter { $0.version <= installed }
    }
}
