// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class PersonalWordMatcherTests: XCTestCase {
    private let ranks: [String: Int] = ["snakebite": 24_000, "made": 150, "said": 220, "the": 0, "use": 300,
                                        "and": 2, "stone": 2_400, "cloud": 2_100, "google": 900]
    private func matcher(_ words: [String]) -> PersonalWordMatcher {
        let ranks = self.ranks
        return PersonalWordMatcher(words: words, rank: { ranks[$0] })
    }

    func testMisheardNamesTakeTheStoredSpelling() {
        let m = matcher(["Zayd", "Dahlsson", "Snakebyte"])
        XCTAssertEqual(m.correct("My name is Zade Dahlson and I use Snakebite."),
                       "My name is Zayd Dahlsson and I use Snakebyte.")
        XCTAssertEqual(m.correct("Tell Zaid hi"), "Tell Zayd hi")
    }

    func testOrdinaryWordsAreLeftAlone() {
        let m = matcher(["Zayd", "Snakebyte", "Stoney"])
        // Lowercase common words are prose, not names.
        XCTAssertEqual(m.correct("he got snakebite on the trip"), "he got snakebite on the trip")
        XCTAssertEqual(m.correct("she said it was made of stone"), "she said it was made of stone")
        // A sentence-start capital is not evidence of a name.
        XCTAssertEqual(m.correct("Snakebite is serious."), "Snakebite is serious.")
    }

    func testOtherPeoplesNamesAndEverydayWordsSurvive() {
        let m = matcher(["Zayd", "Dahlsson", "Claude"])
        XCTAssertEqual(m.correct("I met Saad and Sayed today"), "I met Saad and Sayed today")
        XCTAssertEqual(m.correct("ask Said about it"), "ask Said about it")
        XCTAssertEqual(m.correct("Google Cloud is down"), "Google Cloud is down")
        XCTAssertEqual(m.correct("Zaid and Zade"), "Zayd and Zayd")
    }

    /// The guard against replacing everyday words reads the rank Zone's dictation uses, and words
    /// only the current-words list knows ("repo", "Hoka") count as known. Measured on 2026-11-18
    /// with a 306-name list as My Words: "repo" became "REAP" 29 times, Hoka became Hooke.
    func testWordsOnlyTheCurrentWordsListKnowsAreLeftAlone() {
        let m = PersonalWordMatcher(words: ["REAP", "Hooke", "Zayd"], rank: TextStyle.personalWordRank)
        XCTAssertEqual(m.correct("push it to the repo"), "push it to the repo")
        XCTAssertEqual(m.correct("I bought new Hoka shoes"), "I bought new Hoka shoes")
        // A real mishearing of a saved name is still fixed beside them.
        XCTAssertEqual(m.correct("Tell Zade the repo is ready"), "Tell Zayd the repo is ready")
    }

    func testShortAndDistantWordsNeverMatch() {
        let m = matcher(["Ann", "Zayd"])
        XCTAssertEqual(m.correct("Tell Anne and Zebedee"), "Tell Anne and Zebedee")
    }

    func testSoundKeysFoldCommonSpellings() {
        XCTAssertEqual(PersonalWordMatcher.soundKey("Zade"), PersonalWordMatcher.soundKey("Zayd"))
        XCTAssertEqual(PersonalWordMatcher.soundKey("Snakebite"), PersonalWordMatcher.soundKey("Snakebyte"))
        XCTAssertEqual(PersonalWordMatcher.soundKey("Philip"), PersonalWordMatcher.soundKey("Filip"))
        // A soft c is an s; a hard c stays a k.
        XCTAssertEqual(PersonalWordMatcher.soundKey("Vercel"), PersonalWordMatcher.soundKey("Versel"))
        XCTAssertEqual(PersonalWordMatcher.soundKey("Marcy"), PersonalWordMatcher.soundKey("Marsy"))
        XCTAssertNotEqual(PersonalWordMatcher.soundKey("Coda"), PersonalWordMatcher.soundKey("Soda"))
    }

    func testSoftCNamesAreFound() {
        let m = matcher(["Vercel"])
        XCTAssertEqual(m.correct("Deploy it on Versel."), "Deploy it on Vercel.")
    }
}

final class PersonalWordsInStyleTests: XCTestCase {
    func testStyleAppliesStoredSpellingEndToEnd() {
        XCTAssertEqual(TextStyle.formal.apply("My name is Zade Dahlson and I use Snakebite.", personalWords: ["Zayd", "Dahlsson", "Snakebyte"]),
                       "My name is Zayd Dahlsson and I use Snakebyte.")
        XCTAssertEqual(TextStyle.formal.apply("He got snakebite.", personalWords: ["Snakebyte"]), "He got snakebite.")
    }
}
