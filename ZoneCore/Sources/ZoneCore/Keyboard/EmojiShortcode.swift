// by zayd/cold @ zayd.wtf

import Foundation

/// The text around a colon that this keyboard actually typed. A match may be shown from local
/// keystrokes, but a replacement needs the host to confirm this anchor and an empty selection.
public struct EmojiShortcode: Equatable, Sendable {
    public private(set) var literal = ":"
    private let left: String
    private let right: String

    public var query: String { String(literal.dropFirst()) }
    public var isSearchable: Bool { literal.utf8.count >= 3 }

    public init?(before: String?, after: String?, selection: String?, hasText: Bool) {
        guard selection?.isEmpty != false, before != nil || after != nil || !hasText else { return nil }
        let before = before ?? ""
        let after = after ?? ""
        guard before.last.map({ $0.isWhitespace || "([{".contains($0) }) ?? true,
              after.first.map({ $0.isWhitespace || ")]},.!?;".contains($0) }) ?? true,
              !Self.isCode(before) else { return nil }
        left = String(before.suffix(16))
        right = String(after.prefix(32))
    }

    public mutating func append(_ character: String) -> Bool {
        guard literal.utf8.count <= 48, character.utf8.count == 1, let byte = character.utf8.first,
              (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                  || byte == 95 || byte == 45 || (byte == 43 && literal == ":") else { return false }
        literal += character
        return true
    }

    public mutating func removeLast() -> Bool {
        guard literal.count > 1 else { return false }
        literal.removeLast()
        return true
    }

    private static func isCode(_ before: String) -> Bool {
        let text = before.suffix(512)
        // Common inline code and fenced blocks, when visible in the document proxy's window.
        var fence = false, inline = false, ticks = 0
        for character in text + " " {
            if character == "`" { ticks += 1; continue }
            if ticks >= 3 { fence.toggle(); inline = false }
            else if ticks > 0, !fence { inline.toggle() }
            ticks = 0
        }
        if fence || inline { return true }
        let line = (text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            .trimmingCharacters(in: .whitespaces)
        return line.last.map { "=<>/\\|&*".contains($0) } == true
            || (line.contains("=") && ["let ", "var ", "const "].contains(where: line.hasPrefix))
            || (line.contains("(") && line.hasPrefix("func "))
    }

    public func couldBeEcho(of text: String, before: String?, after: String?, selection: String?) -> Bool {
        guard selection?.isEmpty != false, String((after ?? "").prefix(32)) == right else { return false }
        let before = before ?? ""
        if before.hasSuffix(left + text) { return true }
        if left.isEmpty, before.isEmpty { return true }
        for length in 0..<text.count where before.hasSuffix(left + text.prefix(length)) {
            if length > 0 || !left.isEmpty { return true }
        }
        return false
    }

    public func owns(_ text: String, before: String?, after: String?, selection: String?) -> Bool {
        guard selection?.isEmpty != false, let before else { return false }
        return (left.isEmpty ? before == text : before.hasSuffix(left + text)) && String((after ?? "").prefix(32)) == right
    }
}

/// Text metadata for the existing panel's emoji. The catalog still owns glyph availability and
/// skin tones. The first column joins to that catalog; the other columns hold aliases and keywords.
public struct EmojiSearchIndex: Sendable {
    public struct Match: Equatable, Sendable {
        public let emoji: String
        public let name: String
    }

    private struct Entry: Sendable {
        let emoji: Substring
        let aliases: [Substring]
        let keywords: [Substring]
    }

    private let entries: [Entry]
    public var count: Int { entries.count }

    // Reviewed single-word aliases. CLDR search terms such as "you", "nice" and "face"
    // are useful for browsing but too broad to put beside a spelling correction.
    private static let names = Set("""
    smile grin laughing rofl wink blush kissing hugging smirk sleepy sleeping cowboy
    sunglasses cry sob scream angry skull poop clown ghost alien robot heartbeat heart
    kiss zzz thumbsup thumbsdown fist clap handshake pray selfie brain lungs tooth bone
    eyes tongue lips astronaut firefighter ninja prince princess santa superhero fairy
    vampire mermaid elf genie zombie skier snowboarder footprints fingerprint monkey
    gorilla orangutan dog poodle wolf fox raccoon cat tiger leopard horse moose donkey
    unicorn zebra deer bison cow pig boar sheep goat camel llama giraffe elephant mammoth
    rhino hippopotamus hamster rabbit chipmunk beaver hedgehog bear koala sloth otter
    skunk kangaroo badger chicken rooster penguin dove eagle duck swan owl dodo feather
    flamingo peacock parrot goose phoenix frog crocodile turtle lizard snake dragon
    whale dolphin orca blowfish shark octopus coral jellyfish crab lobster shrimp squid
    oyster snail butterfly ant bee beetle cockroach spider scorpion mosquito worm microbe
    bouquet lotus rose hibiscus sunflower tulip hyacinth seedling cactus shamrock
    mushroom grapes melon watermelon tangerine lemon lime banana pineapple mango apple
    pear peach cherries strawberry blueberries kiwi tomato olive coconut avocado eggplant
    potato carrot corn cucumber broccoli garlic onion peanuts beans chestnut bread croissant
    flatbread pretzel bagel pancakes waffle cheese bacon hamburger fries pizza hotdog
    sandwich taco burrito tamale falafel egg stew fondue salad popcorn butter bento rice
    curry ramen spaghetti sushi dumpling icecream doughnut cookie birthday cake cupcake
    pie candy lollipop custard milk coffee teapot tea champagne cocktail beer beers
    chopsticks spoon fireworks sparkler firecracker sparkles balloon ribbon gift trophy
    medal soccer baseball softball basketball volleyball football tennis bowling hockey
    lacrosse badminton golf sled kite joystick pinata yarn compass mountain volcano camping
    beach desert island stadium hospital hotel school factory wedding church mosque
    synagogue fountain tent sunrise tram monorail train bus ambulance taxi truck tractor
    motorcycle bike scooter skateboard lighthouse anchor sailboat canoe ferry ship
    airplane parachute helicopter rocket luggage hourglass stopwatch thermometer star
    rainbow umbrella snowflake snowman comet meteor fire droplet ocean eyeglasses goggles
    necktie jeans scarf gloves socks kimono bikini purse handbag sandal boot crown lipstick
    microphone headphones radio saxophone trumpet trombone accordion guitar violin banjo
    drum maracas flute harp telephone pager battery computer printer keyboard projector
    camera candle flashlight books notebook newspaper bookmark coin receipt envelope
    mailbox paintbrush crayon pencil eraser briefcase calendar clipboard pushpin paperclip
    scissors hammer axe boomerang shield wrench screwdriver toolbox magnet ladder shovel
    microscope telescope satellite syringe crutch stethoscope elevator mirror couch toilet
    plunger shower bathtub razor broom basket bucket soap bubbles toothbrush sponge
    wheelchair biohazard infinity trident
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    // Each extra pair was checked against that entry's CLDR keywords or aliases.
    // First choice wins with no history. Frequency and recency can change it.
    private static let alternatives = [
        "crying": ["sob", "cry"], "cry": ["cry", "sob"],
        "lol": ["joy", "rofl", "laughing"], "laugh": ["laughing", "joy", "rofl"],
        "birthday": ["birthday", "partying_face"], "donut": ["doughnut"]
    ]
    private static let denied: Set<String> = ["the", "and", "for", "you", "but", "can", "may", "will", "as", "it", "in", "is"]

    public static func mayPredict(_ word: String) -> Bool {
        let word = word.lowercased()
        return !denied.contains(word) && (names.contains(word) || alternatives[word] != nil)
    }

    private let predictionEntries: [String: Int]

    public func prediction(_ text: String, history: EmojiHistory = EmojiHistory()) -> Match? {
        let word = text.lowercased()
        guard Self.mayPredict(word) else { return nil }
        let recents = history.recents.map(EmojiHistory.base)
        var best: Match?
        var bestWeight = -1
        for name in Self.alternatives[word] ?? [word] {
            guard let index = predictionEntries[name] else { continue }
            let entry = entries[index]
            guard entry.aliases.contains(word[...]) || entry.keywords.contains(word[...]) else { continue }
            let weight = history.searchWeight(String(entry.emoji), recentBases: recents)
            if weight > bestWeight {
                best = Match(emoji: String(entry.emoji), name: name)
                bestWeight = weight
            }
        }
        return best
    }

    public init(tsv: String, available: Set<String>) {
        entries = tsv.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 || fields.count == 3,
                  available.contains(String(fields[0])) else { return nil }
            let aliases = fields[1].split(separator: "|")
            guard !aliases.isEmpty else { return nil }
            let keywords = fields.count == 3 ? fields[2].split(separator: "|") : []
            return Entry(emoji: fields[0], aliases: aliases, keywords: keywords)
        }
        let targets = Self.names.union(Self.alternatives.values.joined())
        predictionEntries = Dictionary(entries.enumerated().compactMap { index, entry in
            let name = String(entry.aliases[0])
            return targets.contains(name) ? (name, index) : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    public static func loadBundled(available: Set<String>) -> Self? {
        guard !available.isEmpty, let url = Bundle.module.url(forResource: "emoji-search", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let index = Self(tsv: text, available: available)
        return index.count > 0 ? index : nil
    }

    public func exact(_ text: String) -> String? {
        let query = text.lowercased()
        // Canonical aliases, then secondary aliases, in stable catalog order. Keywords and
        // fuzzier names are only for browsing and never convert without a deliberate tap.
        let match = entries.first { $0.aliases.first == query[...] }
            ?? entries.first { $0.aliases.contains(query[...]) }
        return match.map { String($0.emoji) }
    }

    private static let common: Set<Substring> = ["fire", "heart", "thumbsup", "joy", "sob", "skull", "pray", "laughing", "smile", "eyes", "tada", "100", "clap"]

    public func matches(_ text: String, history: EmojiHistory = EmojiHistory(), limit: Int = 3) -> [Match] {
        let query = text.lowercased()[...]
        guard query.utf8.count >= 2, limit > 0 else { return [] }
        let recentBases = history.recents.map(EmojiHistory.base)
        var hits: [(index: Int, tier: Int, use: Int)] = []
        for (index, entry) in entries.enumerated() {
            let tier: Int
            if entry.aliases.first == query { tier = 0 }
            else if entry.aliases.contains(query) {
                // Two-letter country aliases still convert exactly with a closing colon.
                // While browsing, prefer ordinary names such as fire over Finland for :fi, and
                // the country itself over flags that only mention it (:us is not flag_um).
                tier = query.utf8.count == 2 && entry.aliases[0].hasPrefix("flag_") ? 4 : 1
            }
            // A transposition in a common reaction is a strong match even when the same
            // letters are a prefix of longer codes. Keep those longer codes in the next slots.
            else if query.utf8.count >= 4, Self.common.contains(entry.aliases[0]),
                    Self.oneEditOrSwap(query.utf8, entry.aliases[0].utf8, allowSingleEdit: false) { tier = 2 }
            else if entry.aliases.contains(where: { $0.hasPrefix(query) }) {
                // "us_virgin_islands" begins with "us" too: another flag's long name waits
                // behind the flag whose code this is.
                tier = query.utf8.count == 2 && entry.aliases[0].hasPrefix("flag_") ? 5 : 3
            }
            else if entry.keywords.contains(query) { tier = 6 }
            else if entry.keywords.contains(where: { $0.hasPrefix(query) }) { tier = 7 }
            else if query.count >= 3, entry.aliases.contains(where: { $0.contains(query) }) { tier = 8 }
            else { continue }
            let use = history.searchWeight(String(entry.emoji), recentBases: recentBases)
            hits.append((index, tier, use))
        }
        // Search common typos only when the ordinary results don't already fill the strip.
        if hits.count < limit, query.utf8.count >= 4 {
            let found = Set(hits.map(\.index))
            for (index, entry) in entries.enumerated() where !found.contains(index) {
                if entry.aliases.contains(where: { Self.oneEditOrSwap(query.utf8, $0.utf8) }) {
                    hits.append((index, 9, history.searchWeight(String(entry.emoji), recentBases: recentBases)))
                }
            }
        }
        return hits.sorted {
            let left = entries[$0.index], right = entries[$1.index]
            // With no personal history, a short canonical prefix gets the most useful slot.
            let leftPrefix = $0.tier == 3 && left.aliases[0].hasPrefix(query) ? left.aliases[0].utf8.count : 100
            let rightPrefix = $1.tier == 3 && right.aliases[0].hasPrefix(query) ? right.aliases[0].utf8.count : 100
            let leftCommon = Self.common.contains(left.aliases[0]) ? 0 : 1
            let rightCommon = Self.common.contains(right.aliases[0]) ? 0 : 1
            return ($0.tier, -$0.use, leftPrefix, leftCommon, $0.index) < ($1.tier, -$1.use, rightPrefix, rightCommon, $1.index)
        }.prefix(limit).map {
            let entry = entries[$0.index]
            return Match(emoji: String(entry.emoji), name: String(entry.aliases[0]))
        }
    }

    /// One missing, extra, replaced, or transposed ASCII byte.
    private static func oneEditOrSwap(_ a: Substring.UTF8View, _ b: Substring.UTF8View,
                                      allowSingleEdit: Bool = true) -> Bool {
        guard abs(a.count - b.count) <= (allowSingleEdit ? 1 : 0) else { return false }
        if a.count > b.count { return oneEditOrSwap(b, a, allowSingleEdit: allowSingleEdit) }
        var i = a.startIndex, j = b.startIndex
        while i != a.endIndex, j != b.endIndex, a[i] == b[j] {
            a.formIndex(after: &i)
            b.formIndex(after: &j)
        }
        if a.count != b.count {
            return j != b.endIndex && a[i...].elementsEqual(b[b.index(after: j)...])
        }
        guard i != a.endIndex else { return true }
        let ai = a.index(after: i), bj = b.index(after: j)
        return (allowSingleEdit && a[ai...].elementsEqual(b[bj...]))
            || (ai != a.endIndex && bj != b.endIndex && a[i] == b[bj] && a[ai] == b[j]
                && a[a.index(after: ai)...].elementsEqual(b[b.index(after: bj)...]))
    }
}
