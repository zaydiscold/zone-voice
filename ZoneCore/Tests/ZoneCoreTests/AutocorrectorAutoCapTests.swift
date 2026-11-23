// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AutocorrectorAutoCapTests: XCTestCase {
    func testSentenceStartTypoIsFixedLikeMidSentence() {
        let corrector = Autocorrector(words: WordListTests.list)
        let lower = corrector.evaluate("ehat").replacement
        XCTAssertNotNil(lower)
        XCTAssertEqual(corrector.evaluate("Ehat", autoCapitalized: true).replacement?.lowercased(), lower?.lowercased())
    }
}
