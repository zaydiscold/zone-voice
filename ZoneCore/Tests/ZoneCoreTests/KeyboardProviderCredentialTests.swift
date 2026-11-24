import Foundation
import XCTest
@testable import ZoneCore

final class KeyboardProviderCredentialTests: XCTestCase {
    private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let path = request.url!.lastPathComponent
            let headers = path == "declared" ? ["Content-Length": String(ComputerSpeechProvider.responseLimit + 1)] : [:]
            let status = path == "offline" ? 503 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if path == "chunked" {
                let part = Data(repeating: 32, count: ComputerSpeechProvider.responseLimit / 2 + 1)
                client?.urlProtocol(self, didLoad: part)
                client?.urlProtocol(self, didLoad: part)
            } else { client?.urlProtocol(self, didLoad: Data(#"{"text":"Synthetic test","words":[]}"#.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func testProviderBoundsActualAndDeclaredResponsesAndFailsUnavailableHost() async throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: wav) }
        try Data("synthetic audio fixture".utf8).write(to: wav)
        for path in ["ok", "offline", "declared", "chunked"] {
            var route = KeyboardVoiceRoute()
            route.mode = .computer
            route.endpoint = "https://test.invalid/" + path
            route.model = "fixture"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            let submitted = expectation(description: "submitted one " + path + " request")
            submitted.assertForOverFulfill = true
            do {
                let response = try await ComputerSpeechProvider.recognize(wav, using: route, timeout: 4, configuration: configuration) {
                    submitted.fulfill()
                }
                XCTAssertEqual(path, "ok")
                XCTAssertEqual(response.text, "Synthetic test")
            } catch let error as URLError {
                XCTAssertNotEqual(path, "ok")
                XCTAssertEqual(error.code, path == "offline" ? .badServerResponse : .dataLengthExceedsMaximum)
            }
            await fulfillment(of: [submitted], timeout: 1)
        }

        do {
            _ = try await ComputerSpeechProvider.recognize(wav, using: .init(), timeout: 1) {
                XCTFail("No audio was submitted for an invalid provider")
            }
            XCTFail("The default route has no GPU endpoint")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL)
        }
    }

    func testEditingProviderKeepsCredentialOnlyForTheSameHTTPSOrigin() throws {
        var saved = KeyboardVoiceRoute()
        saved.endpoint = "https://first.example/v1/audio/transcriptions"
        saved.token = "test-credential"
        let restored = try JSONDecoder().decode(KeyboardVoiceRoute.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored, saved)
        var draft = restored
        draft.endpoint = "https://FIRST.example:443/updated"
        XCTAssertEqual(draft.token, saved.token)
        for endpoint in ["https://second.example/updated", "https://first.example:8443/updated", "http://first.example"] {
            draft = restored
            draft.endpoint = endpoint
            XCTAssertEqual(draft.token, "")
            XCTAssertEqual(saved.token, "test-credential")
        }
    }
}
