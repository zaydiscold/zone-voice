// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

final class DictationRestyleTests: XCTestCase {
    private let said = "Hello, sorry, does later tonight work? I'm gonna be free around seven, maybe eight."

    private func inserted(_ style: TextStyle, before: String, opening: DictationOpening = .automatic,
                          transcript: String? = nil) -> InsertedDictation {
        let text = style.insertion(of: transcript ?? said, contextBefore: before, fieldCapitalizesSentences: true, opening: opening)
        return InsertedDictation(transcript: transcript ?? said, inserted: text, style: style, opening: opening)
    }

    /// What the keyboard does: delete, insert, and what the field holds afterwards.
    private func restyle(_ field: String, _ last: InsertedDictation, to style: TextStyle) -> String? {
        guard let edit = RestylePlan.edit(contextBefore: field, last: last, render: { before in
            style.insertion(of: last.transcript, contextBefore: before, fieldCapitalizesSentences: true, opening: last.opening)
        }) else { return nil }
        return String(field.dropLast(edit.deletions)) + edit.insertion
    }

    func testPickingAStyleRewritesTheDictationInPlace() {
        let casual = inserted(.casual, before: "")
        XCTAssertEqual(casual.inserted, "Hello sorry does later tonight work? I'm gonna be free around 7 maybe 8")
        XCTAssertEqual(restyle(casual.inserted, casual, to: .formal),
                       "Hello, sorry, does later tonight work? I'm going to be free around seven, maybe eight.")
        XCTAssertEqual(restyle(casual.inserted, casual, to: .veryCasual),
                       "hello sorry does later tonight work? i'm gonna be free around 7 maybe 8")
        XCTAssertEqual(restyle(casual.inserted, casual, to: .excited),
                       "Hello, sorry, does later tonight work? I'm gonna be free around seven, maybe eight!")
    }

    /// Every style to every other, and back: the field always holds exactly what dictating in
    /// that style would have written.
    func testEveryStyleRewritesToEveryOtherAndBack() {
        for before in ["", "Earlier text. ", "and then ", "line one\n"] {
            for from in TextStyle.allCases {
                let first = inserted(from, before: before)
                for to in TextStyle.allCases where to != from {
                    let direct = inserted(to, before: before)
                    let field = before + first.inserted
                    guard first.inserted != direct.inserted else { continue }
                    XCTAssertEqual(restyle(field, first, to: to), before + direct.inserted, "\(from) to \(to) after \(before.debugDescription)")
                    XCTAssertEqual(restyle(before + direct.inserted, direct, to: from), field, "\(to) back to \(from)")
                }
            }
        }
    }

    func testTheTextBeforeTheDictationIsNeverTouched() {
        let before = "Hey Aalia. "
        let casual = inserted(.casual, before: before)
        let edit = RestylePlan.edit(contextBefore: before + casual.inserted, last: casual) { _ in
            self.inserted(.formal, before: before).inserted
        }
        XCTAssertNotNil(edit)
        XCTAssertLessThanOrEqual(edit!.deletions, casual.inserted.count, "never deletes past the dictation")
    }

    func testOnlyThePartThatDiffersIsRetyped() {
        let edit = RestylePlan.edit(contextBefore: "x Hello there friend", from: " Hello there friend", to: " Hello there, friend.")
        XCTAssertEqual(edit, RestylePlan.Edit(deletions: 7, insertion: ", friend.", result: " Hello there, friend."))
        // An accent or emoji is one backspace, as Undo counts it.
        let accented = RestylePlan.edit(contextBefore: "café 👍🏽 ok", from: "café 👍🏽 ok", to: "café 👍🏽 OK.")
        XCTAssertEqual(accented, RestylePlan.Edit(deletions: 2, insertion: "OK.", result: "café 👍🏽 OK."))
    }

    func testNoPlanOnceTheFieldChangedOrNothingWouldChange() {
        let casual = inserted(.casual, before: "")
        let render: (String) -> String = { _ in "Something else." }
        XCTAssertNil(RestylePlan.edit(contextBefore: casual.inserted + " and more", last: casual, render: render), "typed after it")
        XCTAssertNil(RestylePlan.edit(contextBefore: String(casual.inserted.dropLast()), last: casual, render: render), "a letter deleted")
        XCTAssertNil(RestylePlan.edit(contextBefore: "", last: casual, render: render), "sent, the field is empty")
        XCTAssertNil(RestylePlan.edit(contextBefore: nil, last: casual, render: render), "the host gave no context")
        XCTAssertNil(RestylePlan.edit(contextBefore: casual.inserted, last: casual, render: { _ in casual.inserted }), "same text")
        XCTAssertNil(RestylePlan.edit(contextBefore: casual.inserted, last: casual, render: { _ in "" }), "never empties the field")
    }

    /// A dictation that continued a sentence was joined in lowercase; the rewrite keeps that.
    func testARewriteKeepsHowTheDictationJoinedTheSentence() {
        let before = "I was thinking"
        let casual = inserted(.casual, before: before, transcript: "And maybe seven works, I guess.")
        XCTAssertEqual(casual.inserted, " and maybe 7 works I guess")
        XCTAssertEqual(restyle(before + casual.inserted, casual, to: .formal), "I was thinking and maybe seven works, I guess.")
    }

    func testARewriteKeepsShift() {
        let lower = inserted(.formal, before: "", opening: .lowercase, transcript: "Sounds good. See you at seven.")
        XCTAssertEqual(lower.inserted, "sounds good. See you at seven.")
        XCTAssertEqual(restyle(lower.inserted, lower, to: .casual), "sounds good. See you at 7")
    }
}
