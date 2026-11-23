// by zayd/cold @ zayd.wtf

import Foundation

/// One emoji in the keyboard's panel, with its five skin tones when it has them.
public struct Emoji: Equatable, Hashable, Sendable {
    /// One skin tone of a base emoji, light to dark.
    public struct Tone: Equatable, Hashable, Sendable {
        public let text: String
        /// The Unicode emoji version that added it ("E13.1" is 13.1).
        public let version: Double
    }

    public let text: String
    public let version: Double
    /// Empty, or exactly five: light, medium-light, medium, medium-dark, dark.
    public let tones: [Tone]

    public init(text: String, version: Double, tones: [Tone] = []) {
        self.text = text
        self.version = version
        self.tones = tones
    }
}

/// A tab of the emoji panel, in Apple's order and with Apple's names.
public struct EmojiCategory: Equatable, Sendable {
    public let name: String
    public let emoji: [Emoji]
}

/// Every emoji the panel offers, parsed from `emoji.tsv` (written by
/// `scripts/make-emoji-catalog.py` from Unicode's emoji-test.txt).
public struct EmojiCatalog: Equatable, Sendable {
    /// iOS 17.0, the oldest system Zone runs on, draws every emoji up to Unicode emoji 15.0.
    /// Only newer ones need a check against the running system's emoji font.
    public static let guaranteedVersion = 15.0

    public let categories: [EmojiCategory]

    public init(categories: [EmojiCategory]) {
        self.categories = categories
    }

    /// The catalog shipped in the package. Nil only if the resource is missing or corrupt.
    public static func loadBundled() -> EmojiCatalog? {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return EmojiCatalog(tsv: text)
    }

    /// Parses `@Category` lines, each followed by `version<TAB>emoji[<TAB>v:tone v:tone ...]`.
    /// `#` lines are comments. Nil when any line is malformed or a tone list is not five long,
    /// so a bad resource fails in tests rather than drawing a broken panel.
    public init?(tsv: String) {
        var categories: [EmojiCategory] = []
        var name: String?
        var emoji: [Emoji] = []
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("@") {
                if let name { categories.append(EmojiCategory(name: name, emoji: emoji)) }
                name = String(line.dropFirst())
                emoji = []
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard name != nil, fields.count == 2 || fields.count == 3,
                  let version = Double(fields[0]), !fields[1].isEmpty else { return nil }
            var tones: [Emoji.Tone] = []
            if fields.count == 3 {
                for token in fields[2].split(separator: " ") {
                    let parts = token.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let toneVersion = Double(parts[0]), !parts[1].isEmpty else { return nil }
                    tones.append(Emoji.Tone(text: String(parts[1]), version: toneVersion))
                }
                guard tones.count == 5 else { return nil }
            }
            emoji.append(Emoji(text: String(fields[1]), version: version, tones: tones))
        }
        if let name { categories.append(EmojiCategory(name: name, emoji: emoji)) }
        guard !categories.isEmpty else { return nil }
        self.categories = categories
    }

    /// The catalog without anything this system cannot draw. `draws` is asked only about emoji
    /// newer than `guaranteedVersion`; a base it rejects goes, and so do its tones. Tones go
    /// together: the long-press row shows all five or none.
    public func drawable(_ draws: (String) -> Bool) -> EmojiCatalog {
        func check(_ text: String, _ version: Double) -> Bool { version <= Self.guaranteedVersion || draws(text) }
        var filtered: [EmojiCategory] = []
        for category in categories {
            var emoji: [Emoji] = []
            for base in category.emoji where check(base.text, base.version) {
                let tones = base.tones.allSatisfy { check($0.text, $0.version) } ? base.tones : []
                emoji.append(Emoji(text: base.text, version: base.version, tones: tones))
            }
            filtered.append(EmojiCategory(name: category.name, emoji: emoji))
        }
        return EmojiCatalog(categories: filtered)
    }

    /// Every emoji or skin tone the catalog offers, mapped to its base: what recents and the
    /// remembered tones check against.
    public func baseIndex() -> [String: String] {
        var index: [String: String] = [:]
        for category in categories {
            for emoji in category.emoji {
                index[emoji.text] = emoji.text
                for tone in emoji.tones { index[tone.text] = emoji.text }
            }
        }
        return index
    }
}

/// Recently used emoji and the skin tone last chosen for each base, kept on the phone by the
/// keyboard (its own defaults, no Full Access needed). Emoji only, never the text around them.
public struct EmojiHistory: Codable, Equatable, Sendable {
    /// Newest first, as typed (a toned emoji stays toned).
    public private(set) var recents: [String]
    /// Base emoji to the tone last chosen for it. A base chosen plain removes its entry.
    public private(set) var tones: [String: String]

    public static let recentLimit = 30

    public init(recents: [String] = [], tones: [String: String] = [:]) {
        self.recents = recents
        self.tones = tones
    }

    /// `text` was typed. `base` is its base emoji when it has skin tones, so the next plain tap
    /// on that emoji types the same tone.
    public mutating func use(_ text: String, base: String?) {
        recents.removeAll { $0 == text }
        recents.insert(text, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        if let base {
            if base == text { tones[base] = nil } else { tones[base] = text }
        }
    }

    /// What a tap on `emoji` types: its remembered tone, if one is still offered.
    public func shown(_ emoji: Emoji) -> String {
        guard let tone = tones[emoji.text], emoji.tones.contains(where: { $0.text == tone }) else { return emoji.text }
        return tone
    }

    /// Recents the catalog still offers (an emoji from a newer system, say, after a restore).
    public func recents(in index: [String: String]) -> [String] {
        recents.filter { index[$0] != nil }
    }

    public init(from decoder: Decoder) throws {
        // Field by field, like `KeyboardPreferences`: one bad value never loses the rest.
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recents = (try? values.decodeIfPresent([String].self, forKey: .recents)) ?? []
        tones = (try? values.decodeIfPresent([String: String].self, forKey: .tones)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case recents, tones }
}
