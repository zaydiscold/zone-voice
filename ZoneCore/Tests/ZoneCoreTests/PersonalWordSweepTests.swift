// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// False-positive sweeps for the sound-alike personal word pass: every word in the bundled list,
/// lowercase and written as a name, against a realistic personal dictionary; then common first
/// names and surnames that are not in it.
final class PersonalWordSweepTests: XCTestCase {
    /// What a real person's list looks like: their own and friends' names, tools, places, brands.
    private static let personal = [
        "Zayd", "Dahlsson", "Snakebyte", "Mothership", "Tailscale", "Claude", "Anthropic", "Hermes", "Moonshine",
        "Parakeet", "Wispr", "Superwhisper", "Granola", "Raycast", "Kubernetes", "Supabase", "Vercel", "Figma",
        "Linear", "Nguyen", "Siobhan", "Aoife", "Priya", "Xiaoming", "Oluwaseun", "Saoirse", "Joaquin", "Ximena",
        "Khalid", "Fatima", "Yusuf", "Imran", "Ayesha", "Bilal", "Hamza", "Rizwan", "Tanvir", "Nadia", "Omar",
        "Brooklyn", "Oakland", "Cupertino", "Hyderabad", "Karachi", "Lahore", "Dubai", "Hooke", "Hydra", "Codex",
    ]
    private static let rank: @Sendable (String) -> Int? = TextStyle.wordRank

    /// Lowercase dictionary words are prose: the matcher must never touch one, whatever its rank.
    func testNoLowercaseDictionaryWordIsEverRewritten() throws {
        let words = Stress.bundledWords.map(\.word).filter { $0.allSatisfy(\.isLetter) && $0 == $0.lowercased() }
        try XCTSkipIf(words.count < 50_000, "bundled word list not found")
        let matcher = PersonalWordMatcher(words: Self.personal, rank: Self.rank)
        let text = "so " + words.joined(separator: " ")
        let out = matcher.correct(text)
        let before = text.split(separator: " "), after = out.split(separator: " ")
        XCTAssertEqual(before.count, after.count)
        let changed = zip(before, after).filter { $0 != $1 }.map { "\($0)->\($1)" }
        XCTAssertEqual(changed, [], "rewritten: \(changed.prefix(30))")
    }

    /// Written as a name mid-sentence, an everyday word (rank under 5,000) still never changes;
    /// a rarer one may, only one letter away from a personal word. The full list of those is
    /// pinned here so a change to the matcher that widens it shows up in review.
    func testCapitalizedDictionaryWordsOnlyYieldToCloseRareMatches() throws {
        let entries = Stress.bundledWords.filter { $0.word.count >= 3 && $0.word.allSatisfy(\.isLetter) }
        try XCTSkipIf(entries.count < 50_000, "bundled word list not found")
        let matcher = PersonalWordMatcher(words: Self.personal, rank: Self.rank)
        let capitalized = entries.map { $0.word.prefix(1).uppercased() + $0.word.dropFirst().lowercased() }
        let out = matcher.correct("so " + capitalized.joined(separator: " "))
        let after = out.split(separator: " ").dropFirst().map(String.init)
        XCTAssertEqual(after.count, capitalized.count)
        var rewritten: [String] = []
        for (index, word) in capitalized.enumerated() where after[index] != word {
            let rank = Self.rank(word.lowercased()) ?? Int.max
            XCTAssertGreaterThanOrEqual(rank, 5_000, "everyday word \(word) became \(after[index])")
            XCTAssertLessThanOrEqual(PersonalWordMatcher.editDistance(word.lowercased(), after[index].lowercased()), 1)
            rewritten.append("\(word)->\(after[index])")
        }
        // Rare words written as a name, one letter from a personal word. Pinned: "Captain Hook"
        // becoming "Captain Hooke" is the known cost of the rule; anything new needs a decision.
        // ("hoke" left the word list in scripts/wordlist-drop.txt.)
        XCTAssertEqual(Set(rewritten), ["Hook->Hooke", "Clade->Claude", "Hooky->Hooke", "Hydro->Hydra",
                                        "Liner->Linear", "Snakebite->Snakebyte"])
    }

    /// Other people's names, the most common US first names and surnames, are not misheard
    /// personal words: only the listed sound-alike spellings may change.
    func testCommonNamesSurviveARealisticPersonalList() {
        let names = """
        James Mary Robert Patricia John Jennifer Michael Linda David Elizabeth William Barbara Richard Susan Joseph Jessica \
        Thomas Sarah Charles Karen Christopher Lisa Daniel Nancy Matthew Betty Anthony Sandra Mark Margaret Donald Ashley \
        Steven Kimberly Andrew Emily Paul Donna Joshua Michelle Kenneth Carol Kevin Amanda Brian Melissa George Deborah \
        Timothy Stephanie Ronald Dorothy Jason Rebecca Edward Sharon Jeffrey Laura Ryan Cynthia Jacob Amy Gary Kathleen \
        Nicholas Angela Eric Shirley Jonathan Brenda Stephen Emma Larry Anna Justin Pamela Scott Nicole Brandon Samantha \
        Benjamin Katherine Samuel Christine Gregory Debra Alexander Rachel Patrick Carolyn Frank Janet Raymond Maria \
        Jack Olivia Dennis Heather Jerry Helen Tyler Catherine Aaron Diane Jose Julie Adam Victoria Nathan Joyce Henry \
        Lauren Zachary Kelly Douglas Christina Peter Ruth Kyle Joan Noah Virginia Ethan Judith Jeremy Evelyn Christian \
        Hannah Walter Andrea Keith Megan Austin Cheryl Roger Jacqueline Terry Madison Sean Teresa Gerald Abigail Carl \
        Sophia Dylan Martha Harold Sara Jordan Gloria Jesse Janice Bryan Kathryn Lawrence Ann Arthur Isabella Gabriel \
        Judy Bruce Charlotte Logan Julia Billy Grace Joe Amber Alan Alice Juan Jean Elijah Denise Willie Frances Albert \
        Danielle Wayne Marilyn Randy Natalie Mason Beverly Vincent Diana Liam Brittany Roy Theresa Bobby Kayla Caleb \
        Alexis Bradley Doris Russell Lori Lucas Tiffany Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez \
        Martinez Hernandez Lopez Gonzalez Wilson Anderson Taylor Moore Jackson Martin Lee Perez Thompson White Harris \
        Sanchez Clark Ramirez Lewis Robinson Walker Young Allen King Wright Hill Flores Green Adams Nelson Baker Hall \
        Rivera Campbell Mitchell Carter Roberts Patel Khan Ali Ahmed Chen Wang Li Zhang Liu Kim Park Singh Kumar Tran \
        Pham Le Hoang Mohammed Muhammad Said Saad Sayed Zaid Zane Zeke Sade Zach Clyde Claudia Hermann Herman Linnea \
        Priyanka Fatimah Fadi Omari Nadine Bilan Imani Hamish Yousef Joaquim Ximenez Mathson Mattsson Dahlson Zade
        """.split(separator: " ").map(String.init)
        // Spellings a speech model would produce for a personal word; changing them is the point.
        let intended: Set<String> = ["Zaid", "Zade", "Dahlson", "Mathson", "Mattsson", "Yousef", "Joaquim", "Fatimah", "Herman", "Hermann"]
        // Known false positive: a different name that is a personal word plus one letter and not
        // in the dictionary. The matcher has no list of names to tell them apart.
        let knownFalsePositives: Set<String> = ["Omari"]
        let matcher = PersonalWordMatcher(words: Self.personal, rank: Self.rank)
        var surprises: [String] = []
        for name in names {
            let out = matcher.correct("I met \(name) today")
            if out != "I met \(name) today", !intended.contains(name), !knownFalsePositives.contains(name) { surprises.append("\(name)->\(out)") }
        }
        XCTAssertEqual(surprises, [], "names rewritten into personal words")
    }

    func testFiveHundredPersonalWordsCorrectQuickly() {
        var rng = StressRNG(seed: 0xA11CE)
        let consonants = Array("bcdfghjklmnpqrstvwxz"), vowels = Array("aeiouy")
        let personal = (0..<500).map { _ -> String in
            let syllables = rng.int(2...4)
            let word = (0..<syllables).map { _ in String([rng.pick(consonants), rng.pick(vowels)]) }.joined()
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        let matcher = PersonalWordMatcher(words: personal, rank: Self.rank)
        let words = Stress.bundledWords.prefix(3_000).map(\.word)
        let text = (0..<2_000).map { _ in rng.pick(words) }.joined(separator: " ")
        let seconds = Stress.time { _ = matcher.correct(text) }
        XCTAssertLessThan(seconds, 0.05, "2,000 words against 500 personal words took \(seconds) s")
        let build = Stress.time { _ = PersonalWordMatcher(words: personal, rank: Self.rank) }
        XCTAssertLessThan(build, 0.02)
    }
}
