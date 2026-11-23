// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Every Settings > Experimental option on at once, through the keyboard's casual insert, the way
/// Zayd dictates (November 16: Smart @, scratch that and no wait, caps lock drops punctuation,
/// faces, 1st 2nd 3rd as numbers and California Mode on Aggressive, all together). Inputs are the
/// recognizer's text as Fluid Speech Mini wrote it, commas at every breath included.
final class ExperimentalTogetherTests: XCTestCase {
    private func insert(_ raw: String, contextBefore: String? = nil, opening: DictationOpening = .automatic) -> String {
        TextStyle.casual.insertion(of: raw, contextBefore: contextBefore, fieldCapitalizesSentences: true, opening: opening,
                                   mentions: true, handles: ["zayd"], spokenCorrections: true,
                                   capsLockDropsPunctuation: true, emoticons: true, smallOrdinals: true,
                                   california: .aggressive)
    }

    /// The raw text of Zayd's dictation on November 16, where he listed what was not working.
    /// The ordinals and faces are each written one way (four faces in a row are emoticons even
    /// after "a"), and "Scratch that and No8" is a topic, so nothing is removed.
    func testZaydsDictationAboutTheExperimentalOptions() {
        let raw = "I don't know if second, third, fourth, ninth, 127th, 9,772nd is all is all gonna work. Under your a smiley face, "
            + "sad face, winky face, upside down smiley face. Should be like the other side. I don't know if Scratch that and No8 "
            + "work. I'm pretty sure it they don't. And I haven't seen the unsure words thing pop up."
        XCTAssertEqual(insert(raw),
                       "I don't know if 2nd 3rd 4th 9th 127th 9,772nd is all is all gonna work. Under your a :) :( ;) (: "
                       + "Should be like the other side. I don't know if Scratch that and No8 "
                       + "work. I'm pretty sure it they don't. And I haven't seen the unsure words thing pop up")
    }

    /// The same options, each one used for real in one dictation.
    func testEveryOptionDoingItsJobInOneDictation() {
        let raw = "This is the second point. Tell at zayd we meet Tuesday, scratch that, Wednesday smiley face. They're crazy flat "
            + "scratch that crazy fast. I came in second place lol upside down smiley face. See you at 3, No8, 4 winky face."
        XCTAssertEqual(insert(raw),
                       "This is the 2nd point. Tell @zayd we meet Wednesday :) They're crazy fast. I came in 2nd place lol (: "
                       + "See you at 4 ;)")
        // After text already in the field, mid-sentence.
        XCTAssertEqual(insert("and they're crazy flat scratch that crazy fast smiley face", contextBefore: "lol "),
                       "and they're crazy fast :)")
    }

    /// Caps lock on top: capitals, no commas or apostrophes, and the faces keep their marks.
    func testCapsLockWithEveryOption() {
        let raw = "This is the second point. Tell at zayd we meet Tuesday, scratch that, Wednesday smiley face. They're crazy flat "
            + "scratch that crazy fast. I came in second place lol upside down smiley face. See you at 3, No8, 4 winky face."
        XCTAssertEqual(insert(raw, opening: .capsLock),
                       "THIS IS THE 2ND POINT TELL @zayd WE MEET WEDNESDAY :) THEYRE CRAZY FAST I CAME IN 2ND PLACE LOL (: "
                       + "SEE YOU AT 4 ;)")
    }
}
