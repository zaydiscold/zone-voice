// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The word list had dropped every "'s" contraction as a possessive (that's, it's, what's), so a
/// slip next to one ("thata") could only reach "that", and retyping a selected typo as "thats"
/// saved it as a protected personal word.
final class ContractionAutocorrectTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }

    func testCommonContractionsAreDictionaryWords() {
        for word in ["it's", "that's", "what's", "there's", "here's", "let's", "he's", "she's", "who's",
                     "where's", "how's", "when's", "what'd", "where'd", "there'll", "what'll", "everyone's"] {
            XCTAssertNotNil(WordListTests.list.lookup(word), word)
        }
    }

    func testAKeySlipBesideTheSReachesTheContraction() {
        XCTAssertEqual(corrector.evaluate("thata").replacement, "that's")
        XCTAssertEqual(corrector.evaluate("therea").replacement, "there's")
        XCTAssertEqual(corrector.evaluate("Thata", autoCapitalized: true).replacement, "That's")
    }

    func testBareContractionsGetTheirApostrophe() {
        let cases = ["thats": "that's", "hows": "how's", "whens": "when's", "someones": "someone's",
                     "everyones": "everyone's", "whatd": "what'd", "thatd": "that'd", "heres": "here's"]
        for (typed, fixed) in cases { XCTAssertEqual(corrector.evaluate(typed).replacement, fixed, typed) }
    }

    func testRealWordsThatLookBareStayAsTyped() {
        for word in ["its", "lets", "well", "were", "ill", "wed", "shell", "hell", "yall"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }

    func testSuggestionsNeverRepeatACandidate() {
        for typed in ["whata", "thata", "whatz", "ots"] {
            let texts = corrector.evaluate(typed).suggestions.map { $0.text.lowercased() }
            XCTAssertEqual(texts.count, Set(texts).count, "\(typed): \(texts)")
        }
    }

    func testABareContractionSavedAsAPersonalWordNoLongerBlocksTheFix() {
        let c = corrector
        c.setPersonalWords(["thats", "Hooke", "dont"])
        XCTAssertEqual(c.evaluate("thats").replacement, "that's")
        XCTAssertEqual(c.evaluate("dont").replacement, "don't")
        XCTAssertNil(c.evaluate("hooke").replacement.flatMap { $0 == "Hooke" ? nil : $0 })
    }

    func testBareContractionDetection() {
        let c = corrector
        for word in ["thats", "Thats", "hows", "theyll", "dont", "im", "whatd"] { XCTAssertTrue(c.isBareContraction(word), word) }
        for word in ["its", "lets", "well", "were", "yall", "imma", "that", "hello", "that's"] { XCTAssertFalse(c.isBareContraction(word), word) }
    }
}

/// Long dictations are recognized in segments cut at pauses; a cut can fall mid-sentence.
final class SegmentSeamTests: XCTestCase {
    func testAMidSentenceCutLosesTheRecognizersCapital() {
        XCTAssertEqual(SegmentText.join("so this was", "This was one of those times"), "so this was this was one of those times")
        XCTAssertEqual(SegmentText.join(["It was not bad", "So I slept", "And then left."]), "It was not bad so I slept and then left.")
    }

    func testASentenceEndKeepsTheCapital() {
        for end in ["this was.", "really?", "wow!", "so…", "he said “stop.”", "note:"] {
            XCTAssertEqual(SegmentText.join(end, "This was"), end + " This was", end)
        }
    }

    func testNamesPronounAndAcronymsKeepTheirCapitals() {
        XCTAssertEqual(SegmentText.join("I told", "Sarah hi"), "I told Sarah hi")
        XCTAssertEqual(SegmentText.join("and then", "I left"), "and then I left")
        XCTAssertEqual(SegmentText.join("we use", "NASA data"), "we use NASA data")
        XCTAssertEqual(SegmentText.join("on my", "iPhone"), "on my iPhone")
    }

    /// From LibriSpeech test-other through Fluid Speech Mini on FluidAudio 0.17.7.
    func testTheUnknownTokenIsNeverText() {
        XCTAssertEqual(SegmentText.cleaned("<unk>OK,<unk> he said."), "OK, he said.")
        XCTAssertEqual(SegmentText.cleaned("<unk>Please, Mr. Buzzard, please tell us the story,<unk> he begged."),
                       "Please, Mr. Buzzard, please tell us the story, he begged.")
        XCTAssertEqual(SegmentText.cleaned("<unk>"), "")
        // From dictations on the phone: the marker stood for an apostrophe and an ampersand.
        XCTAssertEqual(SegmentText.cleaned("I<unk>ll send you the Bio stuff too."), "I'll send you the Bio stuff too.")
        XCTAssertEqual(SegmentText.cleaned("don<unk>t, it<unk>s, they<unk>re, we<unk>ve, I<unk>m, she<unk>d"),
                       "don't, it's, they're, we've, I'm, she'd")
        XCTAssertEqual(SegmentText.cleaned("questions on the R<unk>D side. A Q<unk>A after"), "questions on the R&D side. A Q&A after")
        // A gap in a spelling is not an ampersand, and a word is not a contraction.
        XCTAssertEqual(SegmentText.cleaned("D<unk>N."), "D N.")
        XCTAssertEqual(SegmentText.cleaned("A<unk>NNA"), "A NNA")
        XCTAssertEqual(SegmentText.cleaned("the<unk>tree and<unk>stop"), "the tree and stop")
        XCTAssertEqual(SegmentText.cleaned(" so this was it "), "so this was it")
    }

    func testEmptyRunsAddNothing() {
        XCTAssertEqual(SegmentText.join(["", "Hello there", "  ", "World"]), "Hello there world")
        XCTAssertEqual(SegmentText.join("", "Hello"), "Hello")
    }
}
