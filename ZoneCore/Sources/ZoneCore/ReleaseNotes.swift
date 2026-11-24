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

/// One change in a version's notes: an optional short name and one plain sentence or two.
public struct ReleaseItem: Equatable, Sendable, Identifiable {
    public var id: String { (title ?? "") + "|" + text }
    /// A few words that name the change ("Finish when quiet"). Optional: a small fix is only a sentence.
    public let title: String?
    /// A small label beside the title, such as "Beta". Written after the title in brackets.
    public let tag: String?
    public let text: String
    /// Starred in the file: one of the few changes the What's New sheet shows.
    public let isHighlight: Bool

    public init(title: String? = nil, tag: String? = nil, text: String, isHighlight: Bool = false) {
        self.title = title
        self.tag = tag
        self.text = text
        self.isHighlight = isHighlight
    }
}

/// The changes to one part of Zone ("Keyboard"), with the picture that stands for it.
public struct ReleaseGroup: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    /// An SF Symbol name.
    public let symbol: String
    public let items: [ReleaseItem]

    public init(title: String, symbol: String, items: [ReleaseItem]) {
        self.title = title
        self.symbol = symbol
        self.items = items
    }
}

/// A starred change and the group it belongs to, for the What's New sheet.
public struct ReleaseHighlight: Equatable, Sendable, Identifiable {
    public var id: String { group.title + "|" + item.id }
    public let group: ReleaseGroup
    public let item: ReleaseItem
}

/// One version's release notes: what the history screen and the What's New sheet show.
public struct ReleaseNote: Equatable, Sendable, Identifiable {
    public var id: String { version.description }
    public let version: AppVersion
    /// Nil until the version has a release day.
    public let day: ReleaseDay?
    /// What the update is called ("Curate"), shown as "The Curate update". Optional.
    public let name: String?
    /// One sentence under the version number.
    public let summary: String
    /// Every change, grouped by the part of Zone it belongs to.
    public let groups: [ReleaseGroup]

    public init(version: AppVersion, day: ReleaseDay?, name: String? = nil, summary: String, groups: [ReleaseGroup]) {
        self.version = version
        self.day = day
        self.name = name
        self.summary = summary
        self.groups = groups
    }

    /// How many changes the version lists.
    public var count: Int { groups.reduce(0) { $0 + $1.items.count } }

    /// The starred changes, in the file's order.
    public var highlights: [ReleaseHighlight] {
        groups.flatMap { group in group.items.filter(\.isHighlight).map { ReleaseHighlight(group: group, item: $0) } }
    }
}

/// Reads one version's notes from the Markdown in `Zone/ReleaseNotes/`.
///
/// ```
/// # 1.0.5
/// date: 2026-11-20
/// name: Curate
/// summary: One sentence about the version.
///
/// ## Keyboard
/// symbol: keyboard
///
/// * Next word: Finish a word and the row above the keys offers the next one.
/// - Hold space to talk (Beta): Hold the space bar, speak, let go.
/// - A plain sentence for a small fix.
/// ```
///
/// A version is a few groups, one per part of Zone, and each change is one bullet: a short name,
/// a colon and one sentence or two. A star in place of the dash marks one of the few changes the
/// What's New sheet shows. `date` and `name` are optional. Everything else is required, and a
/// mistake is an error with its line number, not a guess: these files ship inside the app.
public enum ReleaseNotesParser {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// The longest text before a colon that is read as a change's name.
    public static let titleLimit = 40

    public static func parse(_ text: String) throws -> ReleaseNote {
        var version: AppVersion?
        var day: ReleaseDay?
        var name: String?
        var summary: String?
        var groups: [ReleaseGroup] = []

        /// The group being read.
        var title: String?
        var titleLine = 0
        var symbol: String?
        /// Each bullet as written, with whether it was starred and its line.
        var bullets: [(text: String, starred: Bool, line: Int)] = []
        var inComment = false
        /// Keys are only read straight after a heading, before any other text.
        var acceptsKeys = false

        func fail(_ line: Int, _ message: String) -> Failure { Failure(line: line, message: message) }

        func closeGroup() throws {
            guard let group = title else { return }
            guard let picture = symbol, !picture.isEmpty else {
                throw fail(titleLine, "\"\(group)\" needs a symbol: line (an SF Symbol name)")
            }
            guard !bullets.isEmpty else { throw fail(titleLine, "\"\(group)\" has no changes under it") }
            guard !groups.contains(where: { $0.title.caseInsensitiveCompare(group) == .orderedSame }) else {
                throw fail(titleLine, "\"\(group)\" appears twice")
            }
            var items: [ReleaseItem] = []
            for bullet in bullets {
                let item = Self.item(bullet.text, starred: bullet.starred)
                if bullet.starred, item.title == nil {
                    throw fail(bullet.line, "a starred change needs a name and a colon before its sentence")
                }
                items.append(item)
            }
            groups.append(ReleaseGroup(title: group, symbol: picture, items: items))
            title = nil
            symbol = nil
            bullets = []
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
            if line.isEmpty { continue }

            if line.hasPrefix("## ") {
                guard version != nil else { throw fail(number, "the file must start with \"# \" and the version") }
                guard summary != nil else { throw fail(number, "the version needs a summary: line before its first group") }
                try closeGroup()
                let group = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard !group.isEmpty else { throw fail(number, "a group needs a title") }
                title = group
                titleLine = number
                acceptsKeys = true
                continue
            }
            if line.hasPrefix("# ") {
                guard version == nil else { throw fail(number, "one version per file") }
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard let parsed = AppVersion(text) else { throw fail(number, "\"\(text)\" is not a version like 1.0.4") }
                version = parsed
                acceptsKeys = true
                continue
            }
            guard version != nil else { throw fail(number, "the file must start with \"# \" and the version") }
            guard !line.hasPrefix("#") else { throw fail(number, "use \"## \" for a group") }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                guard title != nil else { throw fail(number, "a change must sit under a \"## \" group") }
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !item.isEmpty else { throw fail(number, "an empty bullet") }
                bullets.append((item, line.hasPrefix("* "), number))
                acceptsKeys = false
                continue
            }
            if !bullets.isEmpty, raw.first == " " || raw.first == "\t" {
                // A wrapped bullet continues on an indented line.
                bullets[bullets.count - 1].text += " " + line
                continue
            }

            if acceptsKeys, let (key, value) = keyValue(line) {
                guard !value.isEmpty else { throw fail(number, "\(key): is empty") }
                if title == nil {
                    switch key {
                    case "date":
                        guard let parsed = ReleaseDay(value) else { throw fail(number, "\"\(value)\" is not a date like 2026-11-15") }
                        guard day == nil else { throw fail(number, "date: appears twice") }
                        day = parsed
                    case "name":
                        guard name == nil else { throw fail(number, "name: appears twice") }
                        name = value
                    case "summary":
                        guard summary == nil else { throw fail(number, "summary: appears twice") }
                        summary = value
                    default:
                        throw fail(number, "\"\(key):\" is not known here (date, name, summary)")
                    }
                } else {
                    guard key == "symbol" else { throw fail(number, "\"\(key):\" is not known here (symbol)") }
                    guard symbol == nil else { throw fail(number, "symbol: appears twice") }
                    symbol = value
                }
                continue
            }

            guard title != nil else { throw fail(number, "text must sit under a \"## \" group") }
            throw fail(number, "a change starts with \"- \", or \"* \" for a highlight")
        }

        if inComment { throw fail(lines.count, "a comment is never closed") }
        try closeGroup()
        guard let version else { throw fail(1, "the file must start with \"# \" and the version") }
        guard let summary else { throw fail(1, "the version needs a summary: line") }
        guard !groups.isEmpty else { throw fail(1, "the version has no notes") }
        return ReleaseNote(version: version, day: day, name: name, summary: summary, groups: groups)
    }

    /// "Next word: Finish a word..." is a name and a sentence. The name is short, has no sentence
    /// or path in it ("Settings > Keyboard: ..." is all sentence) and may end with a label in
    /// brackets, "(Beta)".
    static func item(_ text: String, starred: Bool) -> ReleaseItem {
        guard let colon = text.range(of: ": ") else { return ReleaseItem(text: text, isHighlight: starred) }
        var title = String(text[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !rest.isEmpty, title.count <= titleLimit, !title.contains(". "), !title.contains(" > "),
              !title.contains("\"") else {
            return ReleaseItem(text: text, isHighlight: starred)
        }
        var tag: String?
        if title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) {
            let label = String(title[open.upperBound...].dropLast())
            if !label.isEmpty, !label.contains(" ") {
                tag = label
                title = String(title[..<open.lowerBound])
            }
        }
        return ReleaseItem(title: title, tag: tag, text: rest, isHighlight: starred)
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
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return (ReleaseNotesLibrary([]), ["The version notes folder could not be read."])
        }
        let files = contents
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
