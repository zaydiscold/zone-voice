// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

/// A thumb that stops short of the space bar types the letter above it: x to n beside 123 and
/// globe or emoji, z to n beside 123 alone. Zayd's November 6, 2026 sentence, typed on Zone: "i
/// don't know of wr gould incestigstecthus butcibpressed v an awful lotvinstead if soacebar"
/// (four of sixteen spaces typed a letter), and on November 8 "youxarexproud". Three defenses,
/// tested here: the space bar claims the bottom of those keys after a finished word, autocorrect
/// reads one or more slipped spaces back out (weighing where the slipped key was tapped), and
/// the learned touch offsets never learn from a slipped space.
final class SpaceSlipTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }

    private let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
    ])
    private let bottomLetters = Array("zxcvbnm")
    private let space = KeyGridGeometry.Position(row: 3, index: 2)

    /// The keyboard's closure: letters and the space bar from the table, nothing else.
    private func closure(_ table: NextLetterLikelihood) -> (KeyGridGeometry.Position) -> Double? {
        { position in
            switch position.row {
            case 0: return table.nextKeyProbability(of: String(Array("qwertyuiop")[position.index]))
            case 1: return table.nextKeyProbability(of: String(Array("asdfghjkl")[position.index]))
            case 2: return (1...7).contains(position.index) ? table.nextKeyProbability(of: String(self.bottomLetters[position.index - 1])) : nil
            default: return position == self.space ? table.nextKeyProbability(of: " ") : nil
            }
        }
    }

    /// A raw touch `fromBottom` points above the bottom edge of a bottom-row letter's cap.
    private func lowOn(_ letter: Character, fromBottom: CGFloat) -> CGPoint {
        let cap = grid.caps[2][bottomLetters.firstIndex(of: letter)! + 1]
        return CGPoint(x: cap.midX, y: cap.maxY - fromBottom + KeyGridGeometry.touchBias)
    }

    private func table(_ prefix: String) throws -> NextLetterLikelihood {
        try XCTUnwrap(NextLetterModel.likelihood(after: prefix, in: WordListTests.list))
    }

    // MARK: Autocorrect

    func testZaydsSlippedSpacesReadBack() {
        for (typed, expected) in [("lotvinstead", "lot instead"), ("butcibpressed", "but I pressed"),
                                  ("incestigstecthus", "investigate thus"), ("forbvacation", "for vacation"),
                                  ("messagebearlier", "message earlier"), ("inbhouston", "in Houston"),
                                  ("absolutelybeverything", "absolutely everything"), ("Lotvinstead", "Lot instead")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
    }

    /// x sits over the space bar on every iPhone layout, and was missing from the slipped letters
    /// until November 8: "youxare" became "you're" and "youxarexproud" stayed as typed.
    func testSpacesTypedAsXReadBack() {
        for (typed, expected) in [("youxarexproud", "you are proud"), ("youxare", "you are"), ("thexbest", "the best"),
                                  ("inxthe", "in the"), ("nextxtime", "next time"), ("goodxmorning", "good morning"),
                                  ("whatxare", "what are"), ("andxthen", "and then"), ("itxwas", "it was")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // Words with an x in them are words.
        for word in ["taxes", "boxer", "boxed", "exactly", "relaxing", "maxim", "sixty", "taxiing", "fixed"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }

    /// The keyboard hands over the letters its own layout puts above the space bar. Beside 123
    /// alone z is one of them; m never is (it sits over return).
    func testTheSlippedLettersFollowTheLayout() {
        let corrector = self.corrector
        XCTAssertNil(corrector.evaluate("itzwas").replacement)
        corrector.spaceBarLetters = ["z", "x", "c", "v", "b", "n"]
        XCTAssertEqual(corrector.evaluate("itzwas").replacement, "it was")
        XCTAssertEqual(corrector.evaluate("youxarexproud").replacement, "you are proud")
        // Without globe or emoji, x is still there; with both, the space bar starts at c.
        corrector.spaceBarLetters = ["c", "v", "b", "n"]
        XCTAssertNotEqual(corrector.evaluate("youxare").replacement, "you are")
        XCTAssertEqual(corrector.evaluate("lotvinstead").replacement, "lot instead")
        XCTAssertFalse(Autocorrector.defaultSpaceBarLetters.contains("m"))
    }

    /// Where the slipped key was tapped decides an ambiguous run: a thumb that stopped short of
    /// the space bar lands low on c ("you are"); a tap on c's center meant c ("you care").
    func testATapLowOnTheKeyIsASpaceAndATapOnItsCenterIsTheLetter() {
        func touches(_ word: String, at index: Int, dy: Float) -> [KeyTouch] {
            var touches = Array(repeating: KeyTouch.center, count: word.count)
            touches[index] = KeyTouch(dx: 0, dy: dy)
            return touches
        }
        XCTAssertEqual(corrector.evaluate("youcare", touches: touches("youcare", at: 3, dy: 0.38)).replacement, "you are")
        XCTAssertEqual(corrector.evaluate("youcare", touches: touches("youcare", at: 3, dy: 0)).replacement, "you care")
        // Without touches (pasted, or touches lost) the slip reading stands, as before.
        XCTAssertEqual(corrector.evaluate("youcare").replacement, "you are")
        // A clear slip survives a centered tap only when no other reading exists.
        XCTAssertEqual(corrector.evaluate("youxarexproud", touches: touches("youxarexproud", at: 3, dy: 0)).replacement,
                       "you are proud")
        // The cost moves monotonically with depth on the key, and only with a touch.
        XCTAssertEqual(Autocorrector.slipTouchCost(nil), 0)
        let costs = stride(from: Float(-0.2), through: 0.6, by: 0.05).map { Autocorrector.slipTouchCost(KeyTouch(dx: 0, dy: $0)) }
        XCTAssertEqual(costs, costs.sorted(by: >))
        XCTAssertEqual(Autocorrector.slipTouchCost(KeyTouch(dx: 0, dy: .nan)), 0)
    }

    func testEarlierSplitsStillHold() {
        for (typed, expected) in [("thisis", "this is"), ("inthe", "in the"), ("iam", "I am"), ("thankyou", "thank you"),
                                  ("inbthe", "in the"), ("canbyou", "can you"), ("inaminute", "in a minute")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
    }

    func testAOneWordFixBeatsASplitIntoRarerWords() {
        XCTAssertEqual(corrector.evaluate("toomrow").replacement, "tomorrow")
        XCTAssertEqual(corrector.evaluate("oremeber").replacement, "remember")
    }

    /// Splits the simulated typists showed reading nonsense into names, brands and typos: chains of
    /// short list "words" ("st", "ms", "tho"), several misspelled parts, a lone letter that is
    /// really the start of "in".
    func testNoNonsenseSplits() {
        for typed in ["gymboree", "bigstorms", "bethonkong", "inconveneocme", "ophistication", "indallas",
                      "midctober", "stanblately", "avacationbtobny", "subdaybafternoon", "dahlsson", "thisxaople"] {
            let fix = corrector.evaluate(typed).replacement
            XCTAssertFalse(fix?.contains(" ") ?? false, "\(typed) -> \(fix ?? "nil")")
        }
    }

    // MARK: Dynamic hit targets

    func testAFinishedWordLetsTheSpaceBarClaimTheBottomOfV() throws {
        let lot = try table("lot")
        XCTAssertGreaterThan(lot.wordEnd, 0.3)
        let touch = lowOn("v", fromBottom: 4)
        XCTAssertEqual(grid.key(at: touch), grid.key(at: touch, likelihood: nil))
        XCTAssertEqual(grid.key(at: touch)?.row, 2, "without a prefix the tap is v")
        XCTAssertEqual(grid.key(at: touch, likelihood: closure(lot)), space)
        // The claim is bounded: v's own center always stays v.
        let center = lowOn("v", fromBottom: grid.caps[2][4].height / 2)
        XCTAssertEqual(grid.key(at: center, likelihood: closure(lot))?.row, 2)
    }

    func testMidWordAndRareOrNameWordsLeaveTheSpaceBarAlone() throws {
        // Not a word yet, a rare word ("lo", "gab"), or a name ("ali", of "alina"): no opinion.
        for prefix in ["lotv", "lo", "gab", "ali", "investigat"] {
            if let table = NextLetterModel.likelihood(after: prefix, in: WordListTests.list) {
                XCTAssertNil(table.nextKeyProbability(of: " "), prefix)
            }
        }
    }

    func testBareContractionsKeepTheirLetter() throws {
        // "isnt", "shouldnt", "ive", "im": the letter after a complete word goes on to a
        // contraction, so the space bar takes no room from it.
        for (prefix, letter) in [("is", "n"), ("should", "n"), ("i", "v"), ("i", "m"), ("do", "n"), ("was", "n")] {
            let table = try table(prefix)
            XCTAssertNotEqual(table.contractionLetters & (1 << UInt32(Character(letter).asciiValue! - 0x61)), 0, prefix + letter)
            XCTAssertEqual(grid.key(at: lowOn(Character(letter), fromBottom: 4), likelihood: closure(table))?.row, 2, prefix + letter)
        }
    }

    func testTheSpaceBarNeverGivesRoomAway() throws {
        // After "i", n is far likelier than the word ending, but a tap on the top of the space bar
        // stays a space.
        let cap = grid.caps[3][2]
        let top = CGPoint(x: grid.caps[2][6].midX, y: cap.minY + 3 + KeyGridGeometry.touchBias)
        XCTAssertEqual(grid.key(at: top, likelihood: closure(try table("i"))), space)
    }

    // MARK: Learned touch offsets

    func testASlippedSpaceNeverTeachesItsKeyToSitLower() {
        // "lotvinstead" kept as typed: the v landed low (dy 0.45), as a space bar tap does.
        var touches = Array(repeating: KeyTouch.center, count: 11)
        touches[3] = KeyTouch(dx: 0, dy: 0.45)
        var unrecognized = TouchAdaptation()
        for _ in 0..<40 { unrecognized.learn(typed: "lotvinstead", committed: "lotvinstead", touches: touches, recognized: false) }
        XCTAssertEqual(unrecognized.offset(for: UInt8(ascii: "v")).dy, 0, accuracy: 0.0001)
        // Its other taps still teach.
        XCTAssertGreaterThan(unrecognized.taps, 300)
        // The same taps in a word the keyboard knows do teach v.
        var recognized = TouchAdaptation()
        var vTouches = Array(repeating: KeyTouch.center, count: 4)
        vTouches[0] = KeyTouch(dx: 0, dy: 0.45)
        for _ in 0..<40 { recognized.learn(typed: "very", committed: "very", touches: vTouches, recognized: true) }
        XCTAssertGreaterThan(recognized.offset(for: UInt8(ascii: "v")).dy, 0.2)
    }

    func testForgettingTheBottomRowKeepsTheOtherRows() {
        var model = TouchAdaptation()
        let low = Array(repeating: KeyTouch(dx: 0.1, dy: 0.3), count: 4)
        for _ in 0..<50 {
            model.learn(typed: "very", committed: "very", touches: low)
            model.learn(typed: "time", committed: "time", touches: low)
        }
        XCTAssertGreaterThan(model.offset(for: UInt8(ascii: "v")).dy, 0.2)
        let t = model.offset(for: UInt8(ascii: "t"))
        model.forgetBottomRow()
        for c in "zxcvbnm" { XCTAssertEqual(model.offset(for: c.asciiValue!), .center, String(c)) }
        XCTAssertEqual(model.offset(for: UInt8(ascii: "t")), t)
    }
}
