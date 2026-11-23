// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CleanupTokenizerTests: XCTestCase {
    func testDuplicateTokenIDsFailInsteadOfCrashing() throws {
        let data = Data(#"{"model":{"vocab":{"a":1,"b":1},"merges":[]}}"#.utf8)
        XCTAssertThrowsError(try CleanupTokenizer(data: data))
    }

    func testMissingByteTokenThrowsInsteadOfDroppingText() throws {
        let data = Data(#"{"model":{"vocab":{"a":1},"merges":[]}}"#.utf8)
        let tokenizer = try CleanupTokenizer(data: data)
        XCTAssertThrowsError(try tokenizer.encode("ab"))
        XCTAssertThrowsError(try tokenizer.decode([999]))
    }
}
