// by zayd/cold @ zayd.wtf

import Foundation

/// How the island's pet grows: by the words dictated in all, and only ever upward.
///
/// It has no hunger, no health and no streak. Nothing is lost by a day, a week or a year
/// away, and nothing here ever asks the person to come back: the research on virtual pets is
/// clear that neglect mechanics hold people through guilt, not delight. A pet that only grows
/// is a record of what the person has said, drawn as a creature.
public enum IslandPetGrowth {
    public static let firstBox = 1_000

    public static func hasWordBox(_ words: Int) -> Bool { words >= firstBox }

    public struct Stage: Equatable, Sendable {
        public let index: Int
        public let name: String
        /// Words dictated in all at which the pet reaches this stage.
        public let words: Int
    }

    /// The first step is small on purpose: the egg hatches within the first few dictations.
    public static let stages: [Stage] = [
        Stage(index: 0, name: "Egg", words: 0),
        Stage(index: 1, name: "Hatchling", words: 100),
        Stage(index: 2, name: "Listener", words: 2_000),
        Stage(index: 3, name: "Companion", words: 15_000),
        Stage(index: 4, name: "Sovereign", words: 75_000),
        Stage(index: 5, name: "Starlit", words: 250_000),
    ]

    public static func stage(forWords words: Int) -> Stage {
        stages.last { words >= $0.words } ?? stages[0]
    }

    /// The stage after this many words, or nil at the last one.
    public static func next(afterWords words: Int) -> Stage? {
        stages.first { $0.words > max(0, words) }
    }

    /// 0...1 through the current stage; 1 at the last.
    public static func progress(forWords words: Int) -> Double {
        let words = max(0, words)
        let current = stage(forWords: words)
        guard let next = next(afterWords: words) else { return 1 }
        return Double(max(0, words - current.words)) / Double(next.words - current.words)
    }

    /// "412 of 2,000 words to Listener", or nil when fully grown.
    public static func line(forWords words: Int, locale: Locale = .current) -> String? {
        guard let next = next(afterWords: words) else { return nil }
        let format = IntegerFormatStyle<Int>.number.locale(locale)
        return "\(max(0, words).formatted(format)) of \(next.words.formatted(format)) words to \(next.name)"
    }
}

/// A projection of deduplicated numeric dictation receipts. No transcript text is needed.
public struct IslandGardenProgress: Equatable, Sendable {
    public var earnedAccessory: UInt8 = 0
    public var activeDays = 0
    public var sessions = 0
    public var longest: Double = 0
    public var todayCount = 0
    public var todaySeconds: Double = 0
    public var day: Date = .distantPast
    public init() {}

    public func sessionsToday(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.isDate(date, inSameDayAs: day) ? todayCount : 0
    }

    public func dailyEnergy(on date: Date = Date(), calendar: Calendar = .current) -> UInt8 {
        guard sessionsToday(on: date, calendar: calendar) > 0 else { return 0 }
        if todayCount >= 5 || todaySeconds >= 150 { return 3 }
        if todayCount >= 2 || todaySeconds >= 45 { return 2 }
        return 1
    }

    /// A copper pin, a silk scarf, then a star. One unbroken streak is never required.
    public var accessory: UInt8 {
        if activeDays >= 7 && sessions >= 20 { return 3 }
        if activeDays >= 3 && longest >= 20 { return max(earnedAccessory, 2) }
        return max(earnedAccessory, sessions >= 3 ? 1 : 0)
    }

    public func stage(words: Int) -> IslandPetGrowth.Stage {
        let earned: Int
        switch (activeDays, sessions) {
        case (60..., 200...): earned = 5
        case (30..., 80...): earned = 4
        case (12..., 30...): earned = 3
        case (3..., 8...): earned = 2
        case (_, 3...): earned = 1
        default: earned = 0
        }
        return IslandPetGrowth.stages[max(earned, IslandPetGrowth.stage(forWords: words).index)]
    }
}

extension DictationReceipts {
    func garden(on date: Date, calendar: Calendar) -> IslandGardenProgress {
        var result = IslandGardenProgress()
        let today = calendar.startOfDay(for: date)
        result.day = today
        var days = Set<Date>()
        for entry in entries.values where entry.rankOnly != true && entry.words > 0 && entry.seconds > 0 {
            let start = Date(timeIntervalSince1970: entry.start)
            guard start <= date else { continue }
            let day = calendar.startOfDay(for: start)
            days.insert(day)
            result.sessions += 1
            result.longest = max(result.longest, entry.seconds)
            if day == today {
                result.todayCount += 1
                result.todaySeconds += entry.seconds
            }
        }
        result.activeDays = days.count
        return result
    }
}
