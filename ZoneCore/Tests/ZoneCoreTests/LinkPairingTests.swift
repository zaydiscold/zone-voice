// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class LinkPairingTests: XCTestCase {
    private let endpoint = "523c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea"
    private let secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    private func link(v: String? = "1", n: String? = nil, s: String? = nil, name: String? = "frostbyte", extra: String = "") -> String {
        var parts: [String] = []
        if let v { parts.append("v=\(v)") }
        parts.append("n=\(n ?? endpoint)")
        parts.append("s=\(s ?? secret)")
        if let name { parts.append("name=\(name)") }
        return "zone://pair?" + parts.joined(separator: "&") + extra
    }

    private func failure(_ text: String) -> LinkPairingLink.Failure? {
        do { _ = try LinkPairingLink.parse(text); return nil }
        catch { return error as? LinkPairingLink.Failure }
    }

    func testAValidLink() throws {
        let parsed = try LinkPairingLink.parse(link())
        XCTAssertEqual(parsed, LinkPairingLink(endpointID: endpoint, secret: secret, name: "frostbyte", relay: nil))
        XCTAssertEqual(try LinkPairingLink.parse("  \(link())\n"), parsed, "a pasted link may carry spaces around it")
        XCTAssertEqual(try LinkPairingLink.parse(URL(string: link())!), parsed)
        XCTAssertEqual(try LinkPairingLink.parse(link() + "&future=1"), parsed, "unknown fields are ignored")
    }

    func testNameIsPercentDecodedAndCleaned() throws {
        XCTAssertEqual(try LinkPairingLink.parse(link(name: "Zayd%27s%20MacBook%20Pro")).name, "Zayd's MacBook Pro")
        XCTAssertEqual(try LinkPairingLink.parse(link(name: "a%0A%0Ab%09c")).name, "a b c", "no line breaks in the question")
        XCTAssertEqual(try LinkPairingLink.parse(link(name: String(repeating: "x", count: 500))).name.count, 60)
        XCTAssertEqual(try LinkPairingLink.parse(link(name: nil)).name, "Unnamed computer")
        XCTAssertEqual(try LinkPairingLink.parse(link(name: "%20%20")).name, "Unnamed computer")
    }

    func testEndpointIDIsStrict() throws {
        XCTAssertEqual(try LinkPairingLink.parse(link(n: endpoint.uppercased())).endpointID, endpoint, "hex is read in either case")
        let base32 = String(repeating: "abcdefghijklmnopqrstuvwxyz234567", count: 2).prefix(52)
        XCTAssertEqual(try LinkPairingLink.parse(link(n: String(base32))).endpointID, String(base32))
        for bad in [String(endpoint.dropLast()), endpoint + "0", String(endpoint.dropLast()) + "g", "", "not-an-endpoint-id",
                    String(base32.dropLast()), String(base32.dropLast()) + "1", String(base32).uppercased()] {
            XCTAssertEqual(failure(link(n: bad)), .badEndpoint, bad)
        }
        XCTAssertEqual(failure("zone://pair?v=1&s=\(secret)&name=x"), .badEndpoint)
    }

    func testSecretIsExactlySixtyFourLowercaseHex() {
        for bad in [String(secret.dropLast()), secret + "0", secret.uppercased(), String(secret.dropLast()) + "g", "",
                    String(repeating: "z", count: 64)] {
            XCTAssertEqual(failure(link(s: bad)), .badSecret, bad)
        }
        XCTAssertEqual(failure("zone://pair?v=1&n=\(endpoint)&name=x"), .badSecret)
    }

    func testOnlyVersionOnePairingLinksAreRead() {
        XCTAssertEqual(failure(link(v: "2")), .unsupportedVersion)
        XCTAssertEqual(failure(link(v: nil)), .notAPairingLink)
        XCTAssertEqual(failure(link().replacingOccurrences(of: "zone://pair", with: "zone://dictate")), .notAPairingLink)
        XCTAssertEqual(failure(link().replacingOccurrences(of: "zone://", with: "https://")), .notAPairingLink)
        XCTAssertEqual(failure("zone://pair"), .notAPairingLink)
        XCTAssertEqual(failure(""), .notAPairingLink)
        XCTAssertEqual(failure(link() + "&s=" + secret), .notAPairingLink, "a field given twice is refused")
        XCTAssertEqual(failure(link() + "&name=" + String(repeating: "y", count: 3_000)), .notAPairingLink, "too long")
    }

    func testRelayMustBeAWebAddress() throws {
        XCTAssertEqual(try LinkPairingLink.parse(link(extra: "&r=https%3A%2F%2Frelay.example.org%2F")).relay, "https://relay.example.org/")
        XCTAssertNil(try LinkPairingLink.parse(link(extra: "&r=")).relay)
        XCTAssertEqual(failure(link(extra: "&r=ftp%3A%2F%2Frelay.example.org")), .badRelay)
        XCTAssertEqual(failure(link(extra: "&r=relay")), .badRelay)
    }

    func testPairingURLsAreRecognizedBeforeTheyAreParsed() {
        XCTAssertTrue(LinkPairingLink.isPairingURL(URL(string: "zone://pair?v=9")!))
        XCTAssertTrue(LinkPairingLink.isPairingURL(URL(string: "ZONE://PAIR")!))
        XCTAssertFalse(LinkPairingLink.isPairingURL(URL(string: "zone://dictate?id=1")!))
        XCTAssertFalse(LinkPairingLink.isPairingURL(URL(string: "zone://meeting")!))
    }

    /// Checked against an independent HKDF-SHA256 (Python hmac): empty salt, info "zone-flash/1".
    func testFlashKeyDerivation() throws {
        let parsed = try LinkPairingLink.parse(link())
        XCTAssertEqual(parsed.secretBytes.count, 32)
        XCTAssertEqual(parsed.secretBytes.first, 0x00)
        XCTAssertEqual(parsed.secretBytes.last, 0xff)
        XCTAssertEqual(parsed.flashKey.map { String(format: "%02x", $0) }.joined(),
                       "2aa1c9688b3389d76a0ee0b8e25c14bc529d1d8ee629fee3d1a20e28c9240033")
    }
}
