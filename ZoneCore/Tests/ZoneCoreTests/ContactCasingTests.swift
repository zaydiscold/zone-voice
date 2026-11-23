// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A contact card is not a dictionary. Address books hold "The Barber", "Guy From Gym" and "Mom And
/// Dad", and the system lexicon hands every word of them over as a term. Those words are ordinary
/// English everywhere else, so they must not carry a capital into a swiped or dictated sentence.
final class ContactCasingTests: XCTestCase {
    private let layout = SwipeLayout.qwerty()

    /// Contact fields that are also everyday words.
    private let ordinary = ["The", "And", "From", "Man", "Min", "Go", "Or", "But", "With", "At", "He", "My", "Am",
                            "As", "Work", "Call", "City", "Guy", "Dude", "Son", "Uncle", "Amazing", "Fix", "Barber",
                            "Tutor", "Driver", "Healthy", "Shoes", "BTW", "sAd"]
    /// Terms that are names first: unknown words, given names and mixed-case brands.
    private let names = ["John", "Mark", "Jack", "Timothy", "Grace", "Nika", "Nita", "iPhone"]

    private func snapshot(_ words: [String]) -> SystemLexiconSnapshot {
        SystemLexiconSnapshot(entries: words.map { (input: $0.lowercased(), text: $0) })
    }

    private func path(_ word: String) -> [SwipePoint] {
        let keys = word.lowercased().utf8.filter { (97...122).contains($0) }.map { Int($0 - 97) }
        var result: [SwipePoint] = []
        for (a, b) in zip(keys, keys.dropFirst()) where a != b {
            for j in 0..<12 {
                let t = Float(j) / 12
                result.append(SwipePoint(x: layout.x[a] + t * (layout.x[b] - layout.x[a]),
                                        y: layout.y[a] + t * (layout.y[b] - layout.y[a]), t: Float(result.count) / 60))
            }
        }
        result.append(SwipePoint(x: layout.x[keys.last!], y: layout.y[keys.last!], t: Float(result.count) / 60))
        return result
    }

    func testOrdinaryWordsOnContactCardsAreNotSwipeNames() {
        let words = snapshot(ordinary + names).swipeWords
        for word in ordinary { XCTAssertFalse(words.contains(word), word) }
        for word in names { XCTAssertTrue(words.contains(word), word) }
    }

    /// The reported messages: "No I have to fight The old Man", "stay late And learn From me".
    func testSwipingAnOrdinaryWordStaysLowercaseWithThoseContacts() throws {
        var tuning = SwipeTuning(); tuning.visitRadius = 0; tuning.shortlist = 160
        let decoder = SwipeDecoder(words: try XCTUnwrap(WordList.shared), tuning: tuning)
        decoder.setPersonalWords(snapshot(ordinary + names).swipeWords)
        for word in ["the", "and", "from", "man", "go", "or", "but", "with", "work", "call", "guy", "amazing"] {
            let candidates = decoder.decode(path(word), layout: layout, limit: 96)
            let found = try XCTUnwrap(candidates.first { $0.word.lowercased() == word }, word)
            XCTAssertEqual(found.word, word)
        }
        for name in ["John", "Nika", "Nita"] {
            let candidates = decoder.decode(path(name), layout: layout, limit: 96)
            XCTAssertEqual(candidates.first { $0.word.lowercased() == name.lowercased() }?.word, name)
        }
    }

    func testDictationKeepsOrdinaryWordsLowercaseWithThoseContacts() {
        let words = snapshot(ordinary + names).speechWords
        let said = "my uncle is amazing and the barber can fix my shoes with a tutor"
        XCTAssertEqual(TextStyle.casual.apply(said, systemWords: words), TextStyle.casual.apply(said))
        XCTAssertEqual(TextStyle.casual.apply("i saw nika and nita", systemWords: words), "I saw Nika and Nita")
    }

    /// A surname that is also a word takes its capital only where a surname goes.
    func testSurnamesThatAreWordsFollowAFirstNameOrTitle() {
        let book = snapshot(ordinary + names + ["Sarah", "Brown", "Stone", "Will", "Long"])
        XCTAssertTrue(book.surnames.isSuperset(of: ["brown", "stone"]))
        XCTAssertTrue(book.surnames.isDisjoint(with: ["will", "long", "the", "man", "work", "call"]))
        let words = book.speechWords
        XCTAssertEqual(TextStyle.formal.apply("i met sarah brown and doctor stone", systemWords: words), "I met Sarah Brown and doctor Stone.")
        XCTAssertEqual(TextStyle.casual.apply("ask Dr. brown or Mr stone", systemWords: words), "Ask Dr. Brown or Mr Stone")
        XCTAssertEqual(TextStyle.veryCasual.apply("i met Sarah Brown", systemWords: words), "i met Sarah Brown")
        for said in ["The brown house by the stone wall.", "Grace will call John long before then.", "My uncle is healthy."] {
            XCTAssertEqual(TextStyle.formal.apply(said, systemWords: words), said)
        }
        XCTAssertTrue(ContactSurnames.follows("I met Sarah "))
        XCTAssertTrue(ContactSurnames.follows("ask Dr. "))
        for before in ["I met sarah ", "the old ", "Sarah", "Sarah, ", "v2 ", ""] { XCTAssertFalse(ContactSurnames.follows(before), before) }
    }

    /// A contact field is not a text replacement the person wrote.
    func testCaseOnlyPairsForOrdinaryWordsAreNotReplacements() {
        let book = SystemLexiconSnapshot(entries: [(input: "the", text: "The"), (input: "iphone", text: "iPhone"), (input: "omw", text: "On my way!")])
        XCTAssertEqual(book.replacements, ["iphone": "iPhone", "omw": "On my way!"])
    }

    /// Zayd, November 14: a contact with "idiot" on the card capitalized the word in every sentence.
    /// The card's words reach the formatter (for "Sarah Brown") but are not recognizer hints.
    func testOrdinaryCardWordsAreNotRecognizerHints() {
        let words = snapshot(ordinary + names + ["Idiot", "Boss", "Dentist", "Landlord", "Spam", "Brown", "Sarah"]).speechWords
        let hints = SystemLexiconSnapshot.recognizerHints(from: words)
        for word in ["Idiot", "Boss", "Dentist", "Landlord", "Spam", "Brown", "The"] { XCTAssertFalse(hints.contains(word), word) }
        for word in ["Nika", "Nita", "Sarah", "iPhone"] { XCTAssertTrue(hints.contains(word), word) }
        XCTAssertEqual(TextStyle.casual.apply("you idiot i met sarah brown", systemWords: words), "You idiot I met Sarah Brown")
    }

    /// A word the keyboard already writes in lowercase from its current-words list is ordinary too.
    func testCurrentWordsOnContactCardsStayLowercase() {
        let book = snapshot(["Bestie", "Nika"])
        XCTAssertEqual(book.swipeWords, ["Nika"])
        XCTAssertEqual(book.replacements, ["nika": "Nika"])
        XCTAssertEqual(TextStyle.casual.apply("ask my bestie and nika", systemWords: book.speechWords), "Ask my bestie and Nika")
    }

    /// "Mark" is a name and a word. Undoing the capital once teaches swipe, as it teaches taps.
    func testAKeptLowercaseWordIsNoLongerSwipedAsTheContact() throws {
        let book = snapshot(["Mark", "Bill", "Nika"])
        XCTAssertEqual(book.swipeWords(keptLowercase: []), ["Mark", "Bill", "Nika"])
        // A kept "nika" is not an ordinary word, so it is still the contact.
        XCTAssertEqual(book.swipeWords(keptLowercase: ["mark", "nika"]), ["Bill", "Nika"])
        var tuning = SwipeTuning(); tuning.visitRadius = 0; tuning.shortlist = 160
        let decoder = SwipeDecoder(words: try XCTUnwrap(WordList.shared), tuning: tuning)
        decoder.setPersonalWords(book.swipeWords(keptLowercase: ["mark"]) + ["mark"])
        XCTAssertEqual(decoder.decode(path("mark"), layout: layout, limit: 8).first?.word, "mark")
        XCTAssertEqual(decoder.decode(path("bill"), layout: layout, limit: 8).first?.word, "Bill")
        let engine = Autocorrector(words: try XCTUnwrap(WordList.shared), learnedWords: ["mark"])
        engine.setSystemLexicon(names: book.names, replacements: book.replacements)
        XCTAssertNil(engine.evaluate("mark").replacement)
        XCTAssertEqual(engine.evaluate("bill").replacement, "Bill")
    }
}
