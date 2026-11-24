// by zayd/cold @ zayd.wtf

import Foundation

/// A word count held up against texts people know: "That's 1.2 Great Gatsbys." Home shows the
/// biggest one you have passed under the total and cycles through the rest on a tap; the share
/// card carries whichever is showing.
///
/// Word counts are the commonly cited figures (checked 2026-11-15): Gettysburg Address, Bliss
/// copy, 272; US Constitution with signatures, 4,543 (archives.gov); Hamlet about 30,557; The
/// Great Gatsby about 47,094; Harry Potter and the Sorcerer's Stone 76,944 and the series
/// 1,084,170; Moby-Dick about 206,052; The Lord of the Rings 481,103; War and Peace, Maude
/// translation, about 563,000; King James Bible about 783,137; English Wikipedia 5.31 billion
/// (Wikipedia:Size of Wikipedia, 2026-11-15). The Library of Alexandria is the low estimate:
/// Seneca's 40,000 scrolls at Bagnall's 10,000 words a scroll, 400 million words. An average
/// tweet is 33 characters, about 6 words. Text averages about 6 bytes a word.
public enum WordScale {
    public struct Benchmark: Equatable, Sendable {
        public let id: String
        public let words: Double
        /// As it reads mid-sentence: "the Gettysburg Address", "Moby-Dick".
        let title: String
        /// Set when the thing counts naturally ("Great Gatsbys"); otherwise "X, 3 times over".
        let plural: String?
        /// An estimate, said with "About".
        let estimate: Bool
    }

    static let tweet = Benchmark(id: "tweet", words: 6, title: "a tweet", plural: "tweets", estimate: false)
    static let books: [Benchmark] = [
        Benchmark(id: "gettysburg", words: 272, title: "the Gettysburg Address", plural: "Gettysburg Addresses", estimate: false),
        Benchmark(id: "constitution", words: 4_543, title: "the US Constitution", plural: nil, estimate: false),
        Benchmark(id: "hamlet", words: 30_557, title: "Hamlet", plural: "Hamlets", estimate: false),
        Benchmark(id: "gatsby", words: 47_094, title: "The Great Gatsby", plural: "Great Gatsbys", estimate: false),
        Benchmark(id: "potter", words: 76_944, title: "the first Harry Potter book", plural: nil, estimate: false),
        Benchmark(id: "moby", words: 206_052, title: "Moby-Dick", plural: nil, estimate: false),
        Benchmark(id: "rings", words: 481_103, title: "The Lord of the Rings", plural: nil, estimate: false),
        Benchmark(id: "war", words: 563_000, title: "War and Peace", plural: nil, estimate: false),
        Benchmark(id: "bible", words: 783_137, title: "the King James Bible", plural: nil, estimate: false),
        Benchmark(id: "potter-series", words: 1_084_170, title: "every Harry Potter book", plural: nil, estimate: false),
    ]
    static let alexandria = Benchmark(id: "alexandria", words: 400_000_000, title: "the Library of Alexandria", plural: nil, estimate: true)
    static let wikipedia = Benchmark(id: "wikipedia", words: 5_310_000_000, title: "English Wikipedia", plural: nil, estimate: true)

    /// Text averages about 6 bytes a word (The Great Gatsby: 286,681 bytes, 48,196 words).
    public static let bytesPerWord = 6.0

    /// The last line describes the count regardless of where a recording was transcribed.
    public static let closingLine = "Your word count is saved on this iPhone."

    /// The line under the total: the biggest text already passed, or how far into the first.
    public static func headline(words: Int) -> String? {
        guard words > 0 else { return nil }
        let count = Double(words)
        if let passed = books.last(where: { count >= $0.words }) { return phrase(count / passed.words, passed) }
        if count >= books[0].words / 2 { return phrase(count / books[0].words, books[0]) }
        let tweets = (count / tweet.words).rounded(.down)
        if tweets >= 2 { return "That's \(Int(tweets)) tweets." }
        return nil
    }

    /// Every line worth showing for this total, the headline first, then the rest from small
    /// to huge, the Library of Alexandria, Wikipedia, and `closingLine`.
    public static func cycle(words: Int) -> [String] {
        guard words > 0 else { return [] }
        let count = Double(words)
        var lines: [String] = []
        if let headline = headline(words: words) { lines.append(headline) }
        for book in books where count / book.words >= 0.1 && count / book.words <= 2_000 {
            let line = phrase(count / book.words, book)
            if !lines.contains(line) { lines.append(line) }
        }
        lines.append(phrase(count / alexandria.words, alexandria))
        lines.append(phrase(count / wikipedia.words, wikipedia))
        lines.append(closingLine)
        return lines
    }

    /// History's footer: what is kept, how small it is, and the library it would take to fill.
    public static func libraryLine(words: Int, bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(max(bytes, 0)), countStyle: .file)
        let alexandriaSize = ByteCountFormatter.string(fromByteCount: Int64(alexandria.words * bytesPerWord), countStyle: .file)
        let count = words == 1 ? "1 word" : "\(max(words, 0).formatted()) words"
        return "\(count), \(size) of text. The whole Library of Alexandria would be about \(alexandriaSize). Keep talking."
    }

    static func phrase(_ ratio: Double, _ benchmark: Benchmark) -> String {
        let about = benchmark.estimate ? "About " : ""
        if ratio < 1 {
            if ratio >= 0.45 && ratio < 0.55 { return "\(about)Halfway through \(benchmark.title)." }
            if ratio >= 0.9 { return "\(about)Nearly all of \(benchmark.title)." }
            return "\(about)\(percent(ratio)) of \(benchmark.title)."
        }
        if ratio < 1.05 { return "That's all of \(benchmark.title)." }
        let times = amount(ratio)
        if let plural = benchmark.plural { return "That's \(times) \(plural)." }
        if times == "2" { return "\(capitalized(benchmark.title)), twice over." }
        return "\(capitalized(benchmark.title)), \(times) times over."
    }

    /// "1.2" under ten, a whole number after: "14", "1,250".
    static func amount(_ ratio: Double) -> String {
        if ratio < 9.95 {
            let tenths = (ratio * 10).rounded() / 10
            return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
        }
        return Int(ratio.rounded()).formatted()
    }

    /// Whole percents from 1%, two significant figures under that: "40%", "0.25%", "0.000019%".
    static func percent(_ ratio: Double) -> String {
        let value = ratio * 100
        if value >= 1 { return "\(Int(value.rounded(.down)))%" }
        guard value > 0 else { return "0%" }
        let decimals = max(0, 1 - Int(floor(log10(value))))
        var text = String(format: "%.\(decimals)f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return text + "%"
    }

    static func capitalized(_ title: String) -> String {
        title.prefix(1).uppercased() + title.dropFirst()
    }
}
