// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class FileDigestTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSHA256MatchesKnownDigest() throws {
        // `printf hello | shasum -a 256`
        let url = try file("hello")
        XCTAssertTrue(try FileDigest.sha256("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824").matches(fileAt: url))
        XCTAssertFalse(try FileDigest.sha256(String(repeating: "0", count: 64)).matches(fileAt: url))
    }

    func testGitBlobMatchesGitHashObject() throws {
        // `printf hello | git hash-object --stdin`
        let url = try file("hello")
        XCTAssertTrue(try FileDigest.gitBlob("b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0").matches(fileAt: url))
    }

    func testDigestIsCaseInsensitive() throws {
        let url = try file("hello")
        XCTAssertTrue(try FileDigest.sha256("2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824").matches(fileAt: url))
    }
}
