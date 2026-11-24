// by zayd/cold @ zayd.wtf
import XCTest
import UIKit
@testable import ZoneCore

@MainActor final class KeyboardVoiceRouteTests: XCTestCase {
    func testProviderRequiresAnExplicitHTTPSDestinationAndPlainModelName() {
        var route = KeyboardVoiceRoute()
        XCTAssertEqual(route.mode, .standard)
        route.model = "large-v3"
        for address in ["http://example.org/transcribe", "https://user:pass@example.org/a", "https://example.org/a?token=x", "file:///private/data"] {
            route.endpoint = address
            XCTAssertNil(route.providerURL)
        }
        route.endpoint = "https://computer.example.ts.net:18473/v1/audio/transcriptions"
        XCTAssertEqual(route.providerURL?.port, 18473)
        route.model = "large\r\nx"
        XCTAssertNil(route.providerURL)
    }

    func testOlderAndRetargetedRecordingsStayLocal() {
        var route = KeyboardVoiceRoute()
        route.mode = .computer
        route.endpoint = "https://first.example/v1/audio/transcriptions"
        route.model = "large-v3"
        XCTAssertEqual(route.forRecording(startedWith: route, retrying: false), route)
        XCTAssertEqual(route.forRecording(startedWith: route, retrying: true).mode, .standard)
        XCTAssertEqual(route.forRecording(startedWith: nil, retrying: false).mode, .standard)
        let old = route
        route.endpoint = "https://second.example/v1/audio/transcriptions"
        XCTAssertEqual(route.forRecording(startedWith: old, retrying: false).mode, .standard)
    }

    #if DEBUG && targetEnvironment(simulator)
    @available(iOS 26, *)
    func testUnavailableGPUFallsBackLocallyForTheSameRetainedRecording() async throws {
        try await assertLocalFallback(using: LocalDictation())
    }

    @available(iOS 26, *)
    func testEmptyGPUResponseFallsBackOnceForTheSameAudibleRecording() async throws {
        let submitted = expectation(description: "exactly one provider request")
        submitted.assertForOverFulfill = true
        let recorder = LocalDictation { audio, _, _, stamp in
            XCTAssertGreaterThan(try Data(contentsOf: audio).count, 44)
            stamp()
            submitted.fulfill()
            return try JSONDecoder().decode(ComputerSpeechProvider.Transcript.self,
                                            from: Data(#"{"text":" <unk> "}"#.utf8))
        }
        try await assertLocalFallback(using: recorder, reason: "emptyTranscript")
        await fulfillment(of: [submitted], timeout: 1)
    }

    @available(iOS 26, *)
    private func assertLocalFallback(using recorder: LocalDictation, reason: String? = nil) async throws {
        let group = try XCTUnwrap(KeyboardVoiceRoute.group)
        let config = group.appendingPathComponent("Library/Application Support/KeyboardVoice/route.json")
        let script = group.appendingPathComponent("keyboard-local-speech.txt")
        let previousRoute = try? Data(contentsOf: config)
        let previousScript = try? Data(contentsOf: script)
        defer {
            for (url, original) in [(config, previousRoute), (script, previousScript)] {
                if let original { try? original.write(to: url, options: [.atomic, .completeFileProtection]) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
        let expected = "The original recording reached local recognition."
        try Data(expected.utf8).write(to: script, options: .atomic)
        var route = KeyboardVoiceRoute()
        route.mode = .computer
        route.endpoint = "https://127.0.0.1:1/v1/audio/transcriptions"
        route.model = "fixture"
        try route.save()

        let id = UUID()
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-clip", withExtension: "wav"))
        recorder.fixtureForTesting = source
        let host = UIView()
        let finished = expectation(description: "one local result")
        finished.assertForOverFulfill = true
        defer { recorder.cancel(discardAudio: true); recorder.saved(id, durable: true); recorder.release() }
        recorder.onEvent = { reported, event in
            XCTAssertEqual(reported, id)
            switch event {
            case .finished(let words, let duration, let module, _):
                XCTAssertNotEqual(module, "zoneLinkGPU")
                XCTAssertGreaterThan(duration, 0)
                XCTAssertFalse(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if module == "scripted" { XCTAssertEqual(words, expected) }
                finished.fulfill()
            case .savedForZone, .failed:
                XCTFail("Local fallback did not deliver the recording")
                finished.fulfill()
            default: break
            }
        }
        recorder.start(id: id, in: host)
        await fulfillment(of: [finished], timeout: 70)
        let attempts = try XCTUnwrap(KeyboardLog.journal).events().filter {
            $0.r == String(id.uuidString.prefix(8)) && $0.name == "keyboardRecognitionRouteFallback"
        }
        XCTAssertEqual(attempts.map { $0.f["route"] }, ["computer"])
        if let reason { XCTAssertEqual(attempts.first?.f["reason"], reason) }
        let inbox = try XCTUnwrap(KeyboardAudioFile.inbox)
        let wav = inbox.appendingPathComponent(KeyboardCapture.handoffName(id))
        XCTAssertGreaterThan(try Data(contentsOf: wav).count, 44)
        let stamp = try XCTUnwrap(KeyboardAudioAttempts.read(from: wav))
        XCTAssertEqual(stamp.count, 1)
        XCTAssertEqual(stamp.outcome, .transcribed)
    }
    #endif

    func testOptedInComputerRecognizesPublicFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let configFile = env["ZONE_GPU_TEST_CONFIG"], let wav = env["ZONE_WEB_TEST_WAV"] else {
            throw XCTSkip("Supply a private test provider configuration and public WAV to exercise the GPU route")
        }
        let route = try JSONDecoder().decode(KeyboardVoiceRoute.self, from: Data(contentsOf: URL(fileURLWithPath: configFile)))
        let result = try await ComputerSpeechProvider.recognize(URL(fileURLWithPath: wav), using: route, timeout: 40)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Kevin"), result.text)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Thursday"), result.text)
    }

    private func webFixture() async throws -> (model: URL, audio: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let wav = env["ZONE_WEB_TEST_WAV"] else { throw XCTSkip("Supply the synthetic keyboard speech fixture") }
        let audio = URL(fileURLWithPath: wav)
        guard env["ZONE_WEB_TEST_INSTALL"] == "1" else {
            guard let path = env["ZONE_WEB_TEST_MODEL"] else { throw XCTSkip("Supply the model or enable the batch fixture installer") }
            return (URL(fileURLWithPath: path), audio)
        }
        let cache = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let model = cache.appendingPathComponent("KeyboardTestsWebModel/" + FluidWebModel.revision)
        try await FluidWebModel.install(at: model) { _, _ in }
        return (model, audio)
    }

    @available(iOS 26, *)
    func testBundledWebRuntimeTranscribesTheExternalFixture() async throws {
        let (model, audio) = try await webFixture()
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let result = try await Watchdog.run(what: "Test WebKit recognition", limit: 50) {
            try await KeyboardWebSpeech(audio: audio, model: model)
                .recognize(in: host.view)
        }
        XCTAssertEqual(result.module, "fluidMiniWeb")
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Kevin"), result.text)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Thursday"), result.text)
        XCTAssertNotNil(result.doubts)
    }
    @available(iOS 26, *)
    func testPreloadingNeedsOnlyTheModelAndPreservesTheSpokenWords() async throws {
        let (model, audio) = try await webFixture()
        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let sealed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: sealed) }
        let job = KeyboardWebSpeech(audio: sealed, model: model)
        defer { job.cancel() }
        job.prepare(in: host.view)
        let deadline = ContinuousClock.now + .seconds(45)
        while !job.modelReady && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(job.modelReady, "Prepare can finish before the recording exists")
        try FileManager.default.copyItem(at: audio, to: sealed)
        let result = try await Watchdog.run(what: "Preloaded keyboard model", limit: 40) {
            try await job.recognize(in: host.view)
        }
        XCTAssertEqual(result.fields["webModelReadyAtStop"], "true")
        XCTAssertEqual(result.module, "fluidMiniWeb")
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Kevin"))
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Thursday"))
    }

}
