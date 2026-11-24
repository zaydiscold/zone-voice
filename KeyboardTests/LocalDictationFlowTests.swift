// by zayd/cold @ zayd.wtf

import AVFAudio
import SwiftUI
import UIKit
import XCTest
import ZoneCore

/// The mic key recording in the keyboard (`MicController` with `LocalDictationHost`), driven
/// with a fake recorder in place of the web view. Each test is one sequence a phone can produce;
/// the numbers in the names are the review findings of 2026-11-19 they pin.
@MainActor
final class LocalDictationFlowTests: XCTestCase {
    func testDictationRequestsAnInterruptionWithoutChangingBluetoothPolicy() {
        let options = AudioSessionForCapture.recordingOptions
        XCTAssertFalse(options.contains(.mixWithOthers))
        XCTAssertFalse(options.contains(.duckOthers))
        XCTAssertTrue(options.contains(.allowBluetoothA2DP))
        XCTAssertFalse(AudioSessionForCapture.release(id: UUID()), "A stale recorder must not release someone else’s session")
    }

    #if targetEnvironment(simulator)
    func testStaleKeyboardReleaseCannotEndTheCurrentCaptureSession() {
        let recording = UUID()
        _ = AudioSessionForCapture.prepare(id: recording)
        defer { AudioSessionForCapture.release(id: recording) }
        XCTAssertEqual(AudioSessionForCapture.owner, recording)
        XCTAssertFalse(AudioSessionForCapture.release(id: UUID()))
        XCTAssertEqual(AudioSessionForCapture.owner, recording)
        AudioSessionForCapture.release(id: recording)
        XCTAssertNil(AudioSessionForCapture.owner)
    }
    #endif

    final class FakeDictation: LocalDictating {
        var onEvent: ((UUID, LocalDictationEvent) -> Void)?
        var onStart: (() -> Void)?
        private(set) var current: UUID?
        private(set) var calls: [String] = []
        var startCueDuration: TimeInterval = 0
        var kept: UUID?
        var isBusy: Bool { current != nil }
        private(set) var isPrepared = false
        func prepare(in host: UIView) {
            calls.append("prepare")
            isPrepared = true
        }
        func start(id: UUID, in host: UIView) {
            calls.append("start")
            current = id
            onStart?()
        }
        func setPaused(_ paused: Bool) { calls.append(paused ? "pause" : "resume") }
        func stop() {
            calls.append("stop")
            if let current { onEvent?(current, .recognizing) }
        }
        func recoverInput() { calls.append("recover"); emit(.held(false)) }
        func release() {
            calls.append("release")
            isPrepared = false
        }
        func cancel(discardAudio: Bool) {
            calls.append("cancel")
            current = nil
        }
        private(set) var acknowledgements: [Bool] = []
        var onSaved: ((UUID) -> Void)?
        func saved(_ id: UUID, durable: Bool) {
            acknowledgements.append(durable)
            onSaved?(id)
        }
        func keptRecording(excluding: Set<UUID>) -> UUID? { kept.flatMap { excluding.contains($0) ? nil : $0 } }
        /// False stands for a kept file that cannot be read.
        var keptReadable = true
        var keptDate: Date?
        func keptStart(id: UUID) -> Date? { keptDate }
        func retryKept(id: UUID) -> Bool {
            calls.append("retry")
            kept = nil
            guard keptReadable else { return false }
            current = id
            return true
        }
        /// What the web view and the recognizer would report next.
        func emit(_ event: LocalDictationEvent) {
            guard let id = current else { return XCTFail("nothing is recording") }
            switch event {
            case .finished, .savedForZone, .failed: current = nil
            default: break
            }
            onEvent?(id, event)
        }
    }

    final class Proxy: TextProxyActions {
        var text = ""
        var opened: [URL] = []
        var session: String? = "field-1"
        func userTouchedKeyboard() {}
        func insert(_ text: String) { self.text += text }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        func adjustTextPosition(byCharacterOffset offset: Int) {}
        func contextBefore() -> String? { text }
        func contextAfter() -> String? { "" }
        func fieldHasText() -> Bool { !text.isEmpty }
        func selectedText() -> String? { nil }
        func currentInputSession() -> String? { session }
        var returnKeyLabel: String { "return" }
        var autocapitalizesSentences: Bool { false }
        var fieldNeverCapitalizes: Bool { false }
        var allowsAutocorrection: Bool { true }
        var allowsSwipeTyping: Bool { true }
        var allowsSmartQuotes: Bool { true }
        var allowsSmartDashes: Bool { true }
        var prefersNumbers: Bool { false }
        var fieldKeys: [String] { [] }
        var capitalization: FieldCapitalization { .none }
        var isSearchField: Bool { false }
        var dimsReturnWhenEmpty: Bool { false }
        var hasOpenAccess = true
        var explicitDarkAppearance: Bool? { nil }
        var needsGlobeKey: Bool { false }
        func advanceToNextInputMode() {}
        func playClick() {}
        func open(_ url: URL) { opened.append(url) }
    }

    private var store: InMemorySharedStore!
    private var fake: FakeDictation!
    private var host: LocalDictationHost!
    private var defaults: UserDefaults!
    private var suite = ""
    private var recoveries: [Date?] = []
    private var statsStarts: [Date?] = []
    private var history: [DictationResult] = []
    private var clock = Date()
    private let view = UIView()
    private var proxies: [Proxy] = []

    override func setUp() async throws {
        try await super.setUp()
        suite = "LocalDictationFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = InMemorySharedStore()
        store.keyboardSpeechReady = true
        store.defaultTextStyle = .casual
        fake = FakeDictation()
        history = []
        clock = Date()
        host = LocalDictationHost(store: store, dictation: fake, defaults: defaults,
                                  writeHistory: { [weak self] result, _, _, start, recovery, done in
                                      self?.recoveries.append(recovery)
                                      self?.statsStarts.append(start)
                                      self?.history.append(result)
                                      done(true)
                                  },
                                  now: { [weak self] in self?.clock ?? Date() })
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testFiveSecondsQuietStopsOnceAfterSpeechAndReleasesClaim() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: url) }
        store.quickSettingInbox = QuickSettingInbox(directory: url)
        var moment = 0.0
        host.uptime = { moment }
        let (mic, _) = makeMic()
        mic.quickSettingsReachable = { true }
        let error = await mic.submitQuickSetting(.quiet(enabled: true, wait: 5))
        XCTAssertNil(error)
        XCTAssertNil(store.keyboardPreferences.finishWhenQuietWait)
        _ = try await recordHere(mic)
        func feed(_ rms: Float, samples: Int) {
            for _ in 0..<samples {
                fake.emit(.samples(rms: rms))
                moment += 0.05
            }
        }
        feed(0, samples: 300)
        XCTAssertTrue(host.isRecording)
        feed(0.7, samples: 12)
        feed(0, samples: 55)
        XCTAssertEqual(mic.quietFinishIn, 3)
        feed(0, samples: 40)
        XCTAssertEqual(mic.quietFinishIn, 1)
        XCTAssertTrue(host.isRecording)
        feed(0, samples: 18)
        XCTAssertEqual(fake.calls.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(host.isRecognizing)
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    func testQuietBackgroundCanMoveGraphicWithoutArmingFinish() async throws {
        store.keyboardPreferences.finishWhenQuietWait = 2
        var time = 0.0
        host.uptime = { time }
        let (mic, _) = makeMic()
        _ = try await recordHere(mic)
        func feed(_ rms: Float, blocks: Int) {
            for _ in 0..<blocks { fake.emit(.samples(rms: rms)); time += 0.05 }
        }
        feed(0.0008, blocks: 20)
        feed(0.003, blocks: 6)
        XCTAssertGreaterThan(mic.levels.max() ?? 0, 0.05)
        feed(0, blocks: 60)
        XCTAssertTrue(host.isRecording)
        feed(0.09, blocks: 12)
        feed(0, blocks: 60)
        XCTAssertEqual(fake.calls.filter { $0 == "stop" }.count, 1)
    }

    func testStartCueCannotArmQuietFinishButLaterSpeechCan() async throws {
        fake.startCueDuration = 0.4
        store.keyboardPreferences.finishWhenQuietWait = 2
        var time = 0.0
        host.uptime = { time }
        let (mic, _) = makeMic()
        _ = try await recordHere(mic)
        func feed(_ rms: Float, _ blocks: Int) {
            for _ in 0..<blocks { fake.emit(.samples(rms: rms)); time += 0.05 }
        }
        feed(0.8, 8)
        feed(0, 60)
        XCTAssertTrue(host.isRecording)
        feed(0.8, 10)
        feed(0, 60)
        XCTAssertEqual(fake.calls.filter { $0 == "stop" }.count, 1)
    }

    func testQuietFinishWaitsThroughSystemAndUserPause() async throws {
        store.keyboardPreferences.finishWhenQuietWait = 5
        var moment = 1.0
        host.uptime = { moment }
        let (mic, _) = makeMic()
        _ = try await recordHere(mic)
        for _ in 0..<20 { fake.emit(.samples(rms: 0)); moment += 0.05 }
        for _ in 0..<12 { fake.emit(.samples(rms: 0.7)); moment += 0.05 }
        mic.tapPause()
        fake.emit(.held(true))
        moment += 20
        fake.emit(.samples(rms: 0))
        fake.emit(.held(false))
        XCTAssertTrue(mic.isPaused)
        XCTAssertTrue(host.isRecording)
        mic.tapPause()
        fake.emit(.held(true))
        XCTAssertTrue(mic.isPaused)
        mic.tapPause()
        XCTAssertFalse(mic.isPaused)
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["recover", "resume"])
        moment += 20
        fake.emit(.samples(rms: 0))
        XCTAssertFalse(mic.isPaused)
        for _ in 0..<90 { fake.emit(.samples(rms: 0)); moment += 0.05 }
        XCTAssertTrue(host.isRecording)
        for _ in 0..<20 { fake.emit(.samples(rms: 0)); moment += 0.05 }
        XCTAssertEqual(fake.calls.filter { $0 == "stop" }.count, 1)
    }

    #if DEBUG && targetEnvironment(simulator)
    private final class WriterObserver: LocalDictationObserver {
        var update: (LocalDictationHost.Update) -> Void = { _ in }
        func localDictation(_ request: DictationRequest, reported update: LocalDictationHost.Update) {
            self.update(update)
        }
    }
    func testRealWriterDropsHeldSamplesAndResumesInSameFile() async throws {
        let recorder = LocalDictation()
        recorder.fixtureForTesting = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-clip", withExtension: "wav"))
        let id = UUID()
        let wav = (KeyboardAudioFile.inbox ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(KeyboardCapture.recordingName(id))
        let firstAudio = expectation(description: "first block")
        let held = expectation(description: "two overlapping interruptions")
        let resumed = expectation(description: "both cleared")
        var sawAudio = false
        var transitions: [Bool] = []
        let realHost = LocalDictationHost(store: store, dictation: recorder, defaults: defaults)
        let listener = WriterObserver()
        listener.update = { event in
            switch event {
            case .level where !sawAudio:
                sawAudio = true
                firstAudio.fulfill()
            case .paused(let value):
                transitions.append(value)
                if value { held.fulfill() } else { resumed.fulfill() }
            default: break
            }
        }
        let request = DictationRequest(id: id, generation: 1, createdAt: Date(), inputSession: nil, contextBefore: nil)
        realHost.start(request, in: view, observer: listener)
        defer { realHost.cancel(); withExtendedLifetime(listener) {} }
        await fulfillment(of: [firstAudio], timeout: 5)
        func native(_ type: AVAudioSession.InterruptionType, reason: AVAudioSession.InterruptionReason = .default) {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue, AVAudioSessionInterruptionReasonKey: reason.rawValue])
        }
        func size() throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: wav.path)
            return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        }
        native(.began, reason: .appWasSuspended)
        XCTAssertTrue(transitions.isEmpty)
        DarwinNotifier.post(.debugKeyboardInterrupt)
        await fulfillment(of: [held], timeout: 2)
        native(.began)
        DarwinNotifier.post(.debugKeyboardResume)
        let before = try size()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try size(), before)
        XCTAssertEqual(transitions, [true])
        // This interruption never ends. Live PCM must release the native hold.
        await fulfillment(of: [resumed], timeout: 4)
        for _ in 0..<40 where try size() == before { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(try size(), before)
        XCTAssertEqual(transitions, [true, false])
        KeyboardLog.journal?.flush()
        for event in KeyboardLog.journal?.events().filter({ $0.r == String(id.uuidString.prefix(8)) }) ?? [] {
            print("Fixture journal", event.t, event.name, event.f)
        }
    }
    #endif

    private func makeMic() -> (MicController, Proxy) {
        let proxy = Proxy()
        proxies.append(proxy)
        let mic = MicController(store: store, proxy: proxy, feedback: KeyFeedback(proxy: proxy), localHost: host)
        mic.localCapability = { (true, true) }
        mic.alternateSpeechReady = { false }
        mic.captureHost = { [view] in view }
        mic.keyboardDidAppear()
        return (mic, proxy)
    }

    func testSelectedAlternateEngineCanRecordWithoutAppleAssets() async throws {
        store.keyboardSpeechReady = false
        let (mic, _) = makeMic()
        mic.alternateSpeechReady = { true }
        _ = try await recordHere(mic)
        XCTAssertTrue(host.isRecording)
    }

    private func settle(_ milliseconds: Int = 320) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Tap, let the probe pass with no app answering, and have the microphone start.
    private func recordHere(_ mic: MicController) async throws -> UUID {
        let started = expectation(description: "Keyboard capture started")
        fake.onStart = { started.fulfill() }
        defer { fake.onStart = nil }
        mic.tapMic()
        await fulfillment(of: [started], timeout: 4)
        let id = try XCTUnwrap(host.request?.id, "Recorder calls: \(fake.calls), mic state: \(mic.state)")
        fake.emit(.started)
        return id
    }

    private func isRecording(_ mic: MicController) -> Bool {
        if case .recording = mic.state { return true }
        return false
    }

    func testPanelYieldsToRecordingAndFoldingPreservesTheTake() async throws {
        let (mic, proxy) = makeMic()
        let originalMode = mic.mode
        defer { if mic.mode != originalMode { mic.toggleMode() } }
        if mic.mode == .type { mic.toggleMode() }
        mic.showPanel(.styles)
        XCTAssertEqual(mic.mode, .dictate)
        XCTAssertEqual(mic.displayMode, .type)
        XCTAssertEqual(mic.panelSection, .styles)
        mic.openDestination(.settings)
        XCTAssertEqual(mic.displayMode, .dictate)
        XCTAssertEqual(proxy.opened.last, ZoneContract.Destination.settings.url)
        mic.showPanel(.home)
        _ = try await recordHere(mic)
        XCTAssertNil(mic.panelSection)
        XCTAssertEqual(mic.displayMode, .dictate)
        let opened = proxy.opened
        mic.toggleMode()
        mic.openDestination(.home)
        mic.showPanel(.styles)
        XCTAssertNil(mic.panelSection)
        XCTAssertEqual(proxy.opened, opened)
        XCTAssertTrue(isRecording(mic))
        XCTAssertEqual(mic.mode, .type)
    }

    func testZonePanelFitsAt15ProWidthInBothAppearances() throws {
        let (mic, proxy) = makeMic()
        let model = KeyboardModel(proxy: proxy)
        model.apply(KeyboardPreferences(meterStyle: .lanes, oneHandedEnabled: true))
        mic.showPanel(.home)
        for (screen, width): (CGFloat, CGFloat) in [(393, 393), (375, 375), (393, 275), (375, 262)] {
            let metrics = KeyGridMetrics.standard(width: screen)
            let height = 4 + 3 * metrics.rowPitch + metrics.keyHeight + metrics.bottomInset
            for dark in [false, true] {
                let theme = KeyboardTheme(isDark: dark)
                let panel = ZonePanelView(mic: mic, model: model, theme: theme, section: .home)
                    .frame(width: width, height: height)
                    .background(theme.background)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .dynamicTypeSize(.large)
                let host = UIHostingController(rootView: panel)
                host.safeAreaRegions = []
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                window.layoutIfNeeded()
                func scrollView(in view: UIView) -> UIScrollView? {
                    if let scroll = view as? UIScrollView { return scroll }
                    return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
                }
                let scroll = try XCTUnwrap(scrollView(in: host.view))
                print("Z menu at \(width) pt, \(dark ? "dark" : "light"): content \(scroll.contentSize.height), available \(height)")
                XCTAssertGreaterThan(scroll.contentSize.height, 0)
                XCTAssertLessThanOrEqual(scroll.contentSize.height, height + 1)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                    window.layer.render(in: context.cgContext)
                }
                let shot = XCTAttachment(image: image)
                shot.name = "Zone tiles \(dark ? "dark" : "light") \(Int(width))pt"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    func testPanelThumbnailsRenderAllTenStylesAndReuseImages() throws {
        XCTAssertEqual(MeterStyle.allCases.count, 10)
        for style in MeterStyle.allCases {
            let image = PanelThumbnail.image(for: style)
            XCTAssertEqual(image.size, CGSize(width: 40, height: 16))
            XCTAssertTrue(image === PanelThumbnail.image(for: style))
            let cg = try XCTUnwrap(image.cgImage)
            var alpha = [UInt8](repeating: 0, count: cg.width * cg.height)
            let visible = alpha.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                context.setBlendMode(.destinationOut)
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return bytes.contains { $0 < 240 }
            }
            XCTAssertTrue(visible, style.label)
        }
    }

    func testQuickSettingErrorsAndLocalOverlay() async throws {
        let (mic, proxy) = makeMic()
        proxy.hasOpenAccess = false
        let denied = await mic.submitQuickSetting(.sounds(false))
        XCTAssertTrue(denied?.contains("Settings > Apps > Zone > Keyboards") == true)
        proxy.hasOpenAccess = true
        mic.quickSettingsReachable = { false }
        let unreachable = await mic.submitQuickSetting(.sounds(false))
        XCTAssertEqual(unreachable, MicController.unreachableMessage)
        mic.quickSettingsReachable = { true }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        store.quickSettingInbox = QuickSettingInbox(directory: url)
        let failure = await mic.submitQuickSetting(.sounds(false))
        XCTAssertEqual(failure, "Could not save this setting. Try again.")
        try FileManager.default.removeItem(at: url)
        let saved = await mic.submitQuickSetting(.sounds(false))
        XCTAssertNil(saved)
        XCTAssertFalse(host.preferenceReader.current().soundsEnabled)
        XCTAssertTrue(store.keyboardPreferences.soundsEnabled)
    }

    func testPanelBlocksGridHitsAndRestylesLastInsertion() async throws {
        let (mic, proxy) = try await dictateHere("hello there")
        let originalMode = mic.mode
        defer { if mic.mode != originalMode { mic.toggleMode() } }
        if mic.mode != .type { mic.toggleMode() }
        let model = KeyboardModel(proxy: proxy)
        let grid = KeyGridView(model: model, mic: mic, controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 393, height: 210)
        grid.layoutIfNeeded()
        let point = CGPoint(x: 35, y: 30)
        XCTAssertNotNil(grid.hitTest(point, with: nil))
        mic.showPanel(.styles)
        XCTAssertEqual(mic.panelSection, .styles)
        XCTAssertNil(grid.hitTest(point, with: nil))
        let inserted = proxy.text
        mic.choosePanelStyle(.excited)
        XCTAssertNil(mic.panelSection)
        XCTAssertNotEqual(proxy.text, inserted)
        XCTAssertTrue(proxy.text.trimmingCharacters(in: .whitespaces).hasSuffix("!"), proxy.text)
        XCTAssertEqual(mic.style, .excited)
    }

    // MARK: Finding 1: once the keyboard records, the local path is authoritative

    func testFinding1_ALateAppAnswerNeverOrphansTheRecording() async throws {
        let (mic, _) = makeMic()
        mic.tapMic()
        await settle()
        let id = try XCTUnwrap(host.request?.id)
        XCTAssertEqual(mic.state, .requesting)
        // The app read the request inside the probe and answers now, after the hand-over.
        mic.tapMic()
        XCTAssertEqual(mic.pressMessage, RecordingRefusal.starting)
        for phase in [DictationPhase.needsApp, .failed, .recording, .cancelled] {
            store.status = DictationStatus(requestID: id, generation: host.request!.generation, phase: phase,
                                           updatedAt: Date(), message: "late")
            mic.handleStatusChanged()
            await settle(150)
            XCTAssertEqual(mic.state, .requesting, "\(phase) must not move a local dictation")
        }
        fake.emit(.started)
        XCTAssertTrue(isRecording(mic))
        mic.tapStop()
        XCTAssertEqual(fake.calls.suffix(1), ["stop"])
        XCTAssertEqual(mic.state, .transcribing)
        XCTAssertNil(mic.pressMessage)
        mic.tapMic()
        XCTAssertEqual(mic.pressMessage, RecordingRefusal.writing)
        XCTAssertEqual(mic.state, .transcribing)
    }

    func testFinding1_TheHandOverTellsAnAppThatReadTheRequestToDropIt() async throws {
        let (mic, _) = makeMic()
        mic.tapMic()
        let id = try XCTUnwrap(store.request?.id)
        await settle()
        XCTAssertNil(store.request, "withdrawn")
        XCTAssertNil(store.status)
        XCTAssertEqual(store.control?.requestID, id)
        XCTAssertEqual(store.control?.action, .cancel)
    }

    func testAnotherControllerCannotReplaceALiveRecording() async throws {
        let (first, _) = makeMic()
        let id = try await recordHere(first)
        let (second, proxy) = makeMic()
        second.tapMic()
        XCTAssertTrue(proxy.opened.isEmpty)
        XCTAssertEqual(fake.calls.filter { $0 == "start" || $0 == "cancel" }, ["start"])
        XCTAssertEqual(host.request?.id, id)
        XCTAssertEqual(store.keyboardRecordingClaim?.requestID, id)
        guard case .error(let reason) = second.state else { return XCTFail("Missing refusal") }
        XCTAssertTrue(reason.contains("recording"))
    }

    func testUnreadableLockCannotKeepAStaleRecordingPulseBusy() async throws {
        let path = try XCTUnwrap(store.microphoneOwnership.file)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: path) }
        var session = SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: Date(), recording: true)
        session.holdsMicrophoneLease = true
        store.session = session
        let (mic, _) = makeMic()
        mic.tapMic()
        await settle()
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, 1)
    }

    func testKilledAppWithFreshMeetingPulseReleasesTheMic() async throws {
        let (mic, proxy) = makeMic()
        var session = SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: Date(), recording: true)
        session.holdsMicrophoneLease = true
        store.session = session
        var app = MicrophoneLease(at: store.microphoneOwnership.file)
        XCTAssertNotNil(app)
        mic.tapMic()
        guard case .error = mic.state else { return XCTFail("Missing meeting refusal") }
        app = nil
        mic.tapMic()
        await settle()
        XCTAssertTrue(proxy.opened.isEmpty)
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, 1)
    }

    #if DEBUG && targetEnvironment(simulator)
    func testFinding1_CancelWithNoOwnerStillEndsALocalRecording() async throws {
        let (mic, _) = makeMic()
        _ = try await recordHere(mic)
        // Something dropped the owner while the microphone was live (a screenshot fixture here).
        mic.apply(KeyboardFixture.parse("live"))
        mic.tapCancel()
        XCTAssertEqual(fake.calls.last, "cancel")
        XCTAssertFalse(host.isBusy)
        XCTAssertNil(store.keyboardRecordingClaim)
    }
    #endif

    func testFinding8_CancelDuringTheProbePostsTheCancelControl() async throws {
        let (mic, _) = makeMic()
        mic.tapMic()
        let id = try XCTUnwrap(store.request?.id)
        mic.tapCancel()
        XCTAssertEqual(store.control?.requestID, id)
        XCTAssertEqual(store.control?.action, .cancel)
        await settle()
        XCTAssertFalse(fake.calls.contains("start"), "a cancelled probe never records")
        XCTAssertEqual(mic.state, .idle)
    }

    // MARK: Finding 2: leaving before the microphone starts

    func testFinding2_LeavingBeforeTheMicrophoneStartsCancelsWithoutAFailure() async {
        let (mic, _) = makeMic()
        mic.tapMic()
        await settle()
        XCTAssertEqual(mic.state, .requesting)
        XCTAssertTrue(host.isBusy)
        mic.keyboardWillDisappear()
        XCTAssertEqual(fake.calls.last == "release" ? fake.calls.dropLast().last : fake.calls.last, "cancel")
        XCTAssertFalse(host.isBusy)
        XCTAssertEqual(mic.state, .idle)
        XCTAssertEqual(host.failures.count, 0, "leaving is not the route failing")
    }

    func testLeavingMidRecordingStopsAndOffersTheWordsOnReturn() async throws {
        let (mic, proxy) = makeMic()
        _ = try await recordHere(mic)
        mic.keyboardWillDisappear()
        XCTAssertTrue(fake.calls.contains("stop"))
        XCTAssertNil(store.keyboardRecordingClaim, "recognition does not hold the microphone")
        XCTAssertEqual(mic.state, .transcribing)
        fake.emit(.finished(text: "see you at noon", audioSeconds: 2))
        XCTAssertNotEqual(mic.state, .transcribing, "never stuck when nobody is looking")
        XCTAssertEqual(history.count, 1)
        mic.keyboardDidAppear()
        guard case .pendingInsert(let result, _) = mic.state else { return XCTFail("offered on return, got \(mic.state)") }
        XCTAssertEqual(result.text, "see you at noon")
        XCTAssertEqual(proxy.text, "")
    }

    // MARK: Finding 3: a finished dictation is never dropped

    func testValidEmptyWorkerReplyAndCancellationNeverInvokeApple() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        var appleCalls = 0
        let result = try await LocalSpeech.preferred { .init(text: "", module: "zoneMini") } apple: {
            appleCalls += 1
            return .init(text: "extra", module: "speech")
        }
        XCTAssertEqual(result.module, "zoneMini")
        XCTAssertTrue(result.text.isEmpty)
        do {
            _ = try await LocalSpeech.preferred { throw CancellationError() } apple: {
                appleCalls += 1
                return .init(text: "extra", module: "speech")
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(appleCalls, 0)
    }

    func testNeverAppleKeepsColdRecordingForZone() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        let (mic, proxy) = makeMic()
        let id = try await recordHere(mic)
        mic.tapStop()
        store.keyboardPreferences.neverAppleSpeech = true
        do {
            _ = try await LocalSpeech.preferred(recording: id, allowsApple: { false }) {
                throw CocoaError(.fileReadUnknown)
            } apple: {
                XCTFail("Apple's speech model must never start")
                return .init(text: "", module: "speech")
            }
            XCTFail("Expected the audio handoff")
        } catch let failure as LocalSpeech.FallbackFailed {
            XCTAssertEqual(failure.fields["decision"], "noAppleByChoice")
        }
        fake.emit(.savedForZone)
        XCTAssertEqual(mic.state, .error("Finishing your recording in Zone."))
        XCTAssertEqual(proxy.opened, [ZoneContract.homeURL])
        await settle(2200)
        XCTAssertEqual(mic.state, .error("Open Zone to finish your saved recording."))
        XCTAssertEqual(proxy.opened, [ZoneContract.homeURL])
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    func testHoldRecordsThroughReleaseWithAppleDisabledAndNoReadySpeechModel() async {
        store.keyboardSpeechReady = false
        store.keyboardPreferences.neverAppleSpeech = true
        let (mic, proxy) = makeMic()
        XCTAssertTrue(mic.spaceHoldBegan())
        await settle()
        XCTAssertEqual(fake.calls.last, "start")
        fake.emit(.started)
        XCTAssertTrue(isRecording(mic))
        XCTAssertTrue(proxy.opened.isEmpty)
        mic.spaceHoldEnded()
        XCTAssertEqual(fake.calls.last, "stop")
        fake.emit(.savedForZone)
        XCTAssertEqual(proxy.opened, [ZoneContract.homeURL])
    }

    /// With no speech model able to run in the keyboard, the words are recorded first and Zone
    /// is opened once, afterwards, to write them out.
    func testWithNoSpeechModelHereTheKeyboardRecordsFirstAndZoneFinishes() async {
        let (mic, proxy) = makeMic()
        store.keyboardSpeechReady = false
        mic.tapMic()
        await settle()
        XCTAssertEqual(fake.calls.last, "start")
        XCTAssertTrue(proxy.opened.isEmpty, "Zone is not opened before the recording")
        fake.emit(.started)
        XCTAssertTrue(isRecording(mic))
        mic.tapStop()
        fake.emit(.savedForZone)
        XCTAssertEqual(mic.state, .error("Finishing your recording in Zone."))
        XCTAssertEqual(proxy.opened, [ZoneContract.homeURL])
    }

    /// Zone said it was starting and then went quiet (C21). The keyboard takes the press when
    /// the starting wait runs out, rather than ending in "Zone didn't answer".
    func testAStartThatStallsInZoneIsTakenOverByTheKeyboard() async throws {
        let now = Date()
        store.session = SessionState(isArmed: true, armedUntil: now.addingTimeInterval(600), modelReady: true, heartbeat: now)
        let (mic, proxy) = makeMic()
        mic.tapMic()
        let request = try XCTUnwrap(store.request)
        store.status = DictationStatus(requestID: request.id, generation: request.generation, phase: .starting,
                                       updatedAt: Date(), message: nil)
        mic.handleStatusChanged()
        await settle(600)
        XCTAssertFalse(fake.calls.contains("start"), "Zone has its starting wait first")
        await settle(Int(MicController.startingGrace.components.seconds) * 1000 + 800)
        XCTAssertEqual(fake.calls.last, "start", "the keyboard takes the stalled press: \(mic.state)")
        XCTAssertEqual(host.request?.id, request.id)
        XCTAssertTrue(proxy.opened.isEmpty)
        XCTAssertEqual(store.control?.action, .cancel, "a late start in Zone is told to drop the press")
    }

    func testWorkerFallbackCarriesReasonAndHostInsertsOnce() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Needs iOS 26") }
        let (mic, proxy) = makeMic()
        let id = try await recordHere(mic)
        mic.tapStop()
        var calls: [String] = []
        let heard = try await LocalSpeech.preferred(recording: id) {
            calls.append("zoneMini")
            throw CocoaError(.fileWriteOutOfSpace)
        } apple: {
            calls.append("appleSpeech")
            return .init(text: "heard once", module: "appleSpeech")
        }
        fake.emit(.finished(text: heard.text, audioSeconds: 2, module: heard.module))
        XCTAssertEqual(heard.fields["workerReason"], "notEnoughRoom")
        XCTAssertNotNil(heard.fields["workerError"])
        XCTAssertEqual(calls, ["zoneMini", "appleSpeech"])
        XCTAssertEqual(history.map(\.requestID), [id])
        XCTAssertEqual(proxy.text.lowercased().components(separatedBy: "heard once").count, 2)
    }

    func testStandbyOffMeetingRefusesWithoutOpeningZone() {
        let (mic, proxy) = makeMic()
        var session = SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: Date(), recording: true)
        session.microphoneBusyMessage = "A meeting is recording in Zone. Stop it to dictate."
        store.session = session
        mic.tapMic()
        XCTAssertTrue(proxy.opened.isEmpty)
        XCTAssertNil(store.request)
        guard case .error(let message) = mic.state else { return XCTFail("Missing recording notice") }
        XCTAssertEqual(message, session.microphoneBusyMessage)
    }

    func testSilentAppWithFreshRecordingOwnerKeepsItsMicrophone() async {
        let (mic, _) = makeMic()
        store.session = SessionState(isArmed: true, armedUntil: nil, modelReady: true, heartbeat: Date(), recording: true)
        mic.tapMic()
        await settle(1500)
        XCTAssertFalse(fake.calls.contains("start"))
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    func testOlderSystemOpensAppWithModelReady() {
        let (mic, proxy) = makeMic()
        mic.localCapability = { (false, true) }
        mic.tapMic()
        XCTAssertFalse(proxy.opened.isEmpty)
        XCTAssertFalse(fake.calls.contains("start"))
    }

    func testSourceRetiresOnlyAfterHistoryAndPublishedResult() async throws {
        var complete: (@MainActor (Bool) -> Void)?
        host = LocalDictationHost(store: store, dictation: fake, defaults: defaults,
                                  writeHistory: { _, _, _, _, _, done in complete = done })
        let (mic, proxy) = makeMic()
        let id = try await recordHere(mic)
        fake.emit(.recognizing)
        fake.emit(.finished(text: "a saved word", audioSeconds: 1, module: "zoneMini"))
        XCTAssertNil(store.result)
        XCTAssertTrue(proxy.text.isEmpty)
        XCTAssertNil(store.ledger.consumedResultID)
        XCTAssertTrue(fake.acknowledgements.isEmpty)
        fake.onSaved = { [store] retired in
            XCTAssertEqual(retired, id)
            XCTAssertEqual(store?.result?.requestID, id)
        }
        complete?(true)
        // The live observer inserts synchronously and clears the result payload.
        XCTAssertEqual(store.ledger.consumedResultID, id)
        XCTAssertEqual(proxy.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "a saved word")
        XCTAssertNil(store.result)
        XCTAssertEqual(fake.acknowledgements, [true])
    }

    func testAnEmptyMiniResultKeepsNonzeroAudioWithoutCountingAFailure() async throws {
        let (mic, _) = makeMic()
        _ = try await recordHere(mic)
        fake.emit(.recognizing)
        fake.emit(.finished(text: "", audioSeconds: 1, module: "zoneMini"))
        XCTAssertEqual(host.failures.count, 0)
        XCTAssertEqual(fake.acknowledgements, [false])
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    func testDeliveredMiniResultInsertsOnceAndOffersUnsureWord() async throws {
        store.keyboardPreferences.checksDoubtfulWords = true
        let (mic, proxy) = makeMic()
        let id = try await recordHere(mic)
        mic.tapStop()
        let event = LocalDictationEvent.finished(text: "hello there", audioSeconds: 2,
                                                  module: "zoneMini", doubts: [.init(word: "there", confidence: 0.1)])
        fake.emit(event)
        fake.onEvent?(id, event)
        XCTAssertEqual(history.map(\.requestID), [id])
        XCTAssertEqual(proxy.text.lowercased().components(separatedBy: "hello there").count, 2)
        XCTAssertEqual(mic.doubts.map(\.word), ["there"])
    }

    func testFinding3_AFinishedDictationIsWrittenPublishedAndInserted() async throws {
        let (mic, proxy) = makeMic()
        var failures = KeyboardCapture.Failures()
        failures.recordFailure(now: Date())
        host.failures = failures
        let id = try await recordHere(mic)
        let requestedAt = host.request?.createdAt
        mic.tapStop()
        fake.emit(.finished(text: "hello there", audioSeconds: 1.5))
        XCTAssertEqual(history.map(\.requestID), [id])
        XCTAssertTrue(proxy.text.lowercased().contains("hello there"), proxy.text)
        guard case .inserted = mic.state else { return XCTFail("\(mic.state)") }
        XCTAssertEqual(store.ledger.consumedResultID, id)
        XCTAssertEqual(statsStarts, [requestedAt])
        XCTAssertEqual(recoveries, [nil])
        XCTAssertEqual(host.failures.count, 0, "a success clears the count")
    }

    func testInsertionUndoRedoAndUndoOfHistoryReinsertPreserveEarlierCredit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = TranscriptHistory(directory: folder)
        let (mic, _) = makeMic()
        mic.deliveryHistory = { receipts }
        let id = try await recordHere(mic)
        receipts.finish(id: id, text: "two words", audioSeconds: 3, statsStartedAt: Date())
        func check(_ expected: Int, _ status: TranscriptStatus) async {
            await withCheckedContinuation { continuation in
                MicController.deliveryQueue.async { continuation.resume() }
            }
            XCTAssertEqual(receipts.stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0.kept, expected)
            XCTAssertEqual(receipts.record(id: id)?.status, status)
        }
        mic.tapStop()
        fake.emit(.finished(text: "two words", audioSeconds: 3))
        await check(2, .inserted)
        mic.tapUndo()
        await check(0, .dismissed)
        mic.tapRedo()
        await check(2, .inserted)
        mic.reinsert(try XCTUnwrap(receipts.record(id: id)))
        mic.tapUndo()
        await check(2, .inserted)
    }

    /// Generations start over in each controller; another one's cancel at the same number
    /// used to make this result read as cancelled and stay "Transcribing".
    func testFinding3_AnotherControllersCancelAtTheSameGenerationDoesNotDropIt() async throws {
        let (mic, proxy) = makeMic()
        let id = try await recordHere(mic)
        var ledger = store.ledger
        ledger.droppedGeneration = 50
        store.ledger = ledger
        mic.tapStop()
        fake.emit(.finished(text: "still here", audioSeconds: 1))
        XCTAssertEqual(history.map(\.requestID), [id])
        XCTAssertTrue(proxy.text.lowercased().contains("still here"))
        XCTAssertEqual(store.ledger.consumedResultID, id)
        XCTAssertGreaterThan(store.result?.generation ?? 51, 50)
    }

    func testFinding3_ANewerRequestInTheStoreIsNeverOverwritten() async throws {
        let (mic, proxy) = makeMic()
        let id = try await recordHere(mic)
        mic.tapStop()
        let newer = DictationRequest(id: UUID(), generation: 1, createdAt: Date().addingTimeInterval(5),
                                     inputSession: "other", contextBefore: nil)
        store.request = newer
        fake.emit(.finished(text: "kept anyway", audioSeconds: 1))
        XCTAssertEqual(store.request?.id, newer.id)
        XCTAssertNil(store.result)
        XCTAssertEqual(history.map(\.requestID), [id], "the words are in History")
        XCTAssertEqual(mic.state, .error("Your words are in History."))
        XCTAssertEqual(proxy.text, "")
    }

    /// P1: the controller that started it is gone before recognition returns.
    func testP1_ADictationOutlivesItsController() async throws {
        var (mic, _) = makeMic()
        let id = try await recordHere(mic)
        mic.keyboardWillDisappear()
        weak var released = mic
        mic = makeMic().0
        _ = released
        fake.emit(.finished(text: "made it", audioSeconds: 1))
        XCTAssertEqual(history.map(\.requestID), [id])
        XCTAssertEqual(store.result?.requestID, id)
        XCTAssertEqual(store.result?.text, "made it")
    }

    func testP1_ANewControllerShowsTheRecognitionInFlightAndOffersIt() async throws {
        let (first, _) = makeMic()
        let id = try await recordHere(first)
        first.keyboardWillDisappear()
        let (second, secondProxy) = makeMic()
        XCTAssertEqual(second.state, .transcribing, "adopted")
        fake.emit(.finished(text: "hi again", audioSeconds: 1))
        guard case .pendingInsert(let result, _) = second.state else { return XCTFail("\(second.state)") }
        XCTAssertEqual(result.requestID, id)
        XCTAssertEqual(secondProxy.text, "", "a reopened keyboard offers, never inserts on its own")
    }

    // MARK: Finding 4: silence and failures reach the fallback

    func testStuckMuteDeliversPartialWordsAndNextTapOpensZone() async throws {
        let (mic, proxy) = makeMic()
        _ = try await recordHere(mic)
        fake.emit(.stuckMuted)
        fake.emit(.recognizing)
        fake.emit(.finished(text: "before the interruption", audioSeconds: 2))
        XCTAssertEqual(history.last?.text, "before the interruption")
        XCTAssertEqual(host.failures.count, 1)
        mic.tapMic()
        await settle()
        XCTAssertEqual(proxy.opened.count, 1)
    }

    func testSilentCompletionKeepsAudioAndTheNextTapCanRecord() async throws {
        let (mic, proxy) = makeMic()
        _ = try await recordHere(mic)
        mic.tapStop()
        fake.emit(.finished(text: "", audioSeconds: 2, module: "silence"))
        XCTAssertEqual(host.failures.count, 0)
        XCTAssertEqual(fake.acknowledgements.last, false)
        XCTAssertNil(store.keyboardRecordingClaim)
        XCTAssertEqual(mic.state, .error("No words heard. Tap the mic to try again."))
        mic.tapMic()
        await settle()
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, 2)
        XCTAssertTrue(proxy.opened.isEmpty)
    }

    /// If Apple closes the route, at most one tap is spent on it before Zone opens instead.
    func testFinding4_TwoFailuresInARowSendEveryTapToZone() async {
        let (mic, proxy) = makeMic()
        for _ in 0..<2 {
            mic.tapMic()
            await settle()
            fake.emit(.failed(message: "The microphone did not start here.", beforeAudio: true))
            mic.userTypedKey()
        }
        XCTAssertTrue(host.failures.holdsOff(now: Date()))
        let starts = fake.calls.filter { $0 == "start" }.count
        mic.tapMic()
        await settle()
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, starts, "no third attempt")
        XCTAssertEqual(proxy.opened.count, 1)
    }

    // MARK: The recording claim

    func testTheClaimIsHeldOnlyWhileTheMicrophoneIsLive() async throws {
        let (mic, _) = makeMic()
        XCTAssertNil(store.keyboardRecordingClaim)
        mic.tapMic()
        await settle()
        XCTAssertNotNil(store.keyboardRecordingClaim, "reserve the mic before the web view starts")
        let id = try XCTUnwrap(host.request?.id)
        fake.emit(.started)
        XCTAssertEqual(store.keyboardRecordingClaim?.requestID, id)
        let first = try XCTUnwrap(store.keyboardRecordingClaim?.heartbeat)
        clock = clock.addingTimeInterval(1)
        host.refresh(id)
        XCTAssertEqual(store.keyboardRecordingClaim?.heartbeat, first.addingTimeInterval(1))
        mic.tapPause()
        clock = clock.addingTimeInterval(1)
        host.refresh(id)
        XCTAssertNotNil(store.keyboardRecordingClaim, "a paused microphone is still held")
        mic.tapPause()
        mic.tapStop()
        XCTAssertNil(store.keyboardRecordingClaim, "recognition does not hold it")
        fake.emit(.finished(text: "ok", audioSeconds: 1))
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    func testStoppingTheHostReleasesItsLeaseAfterTheSharedClaimVanishes() async throws {
        let (mic, _) = makeMic()
        let id = try await recordHere(mic)
        XCTAssertEqual(store.keyboardRecordingClaim?.requestID, id)
        let peer = MicrophoneOwnership(file: store.microphoneOwnership.file)
        store.keyboardRecordingClaim = nil
        XCTAssertNil(peer.reserveForApp { _, code in XCTFail("Unexpected lock error \(code)") })
        mic.tapStop()
        XCTAssertNotNil(peer.reserveForApp { _, code in XCTFail("Unexpected lock error \(code)") })
    }

    func testTheClaimGoesOnCancelAndOnFailure() async throws {
        let (mic, _) = makeMic()
        _ = try await recordHere(mic)
        XCTAssertNotNil(store.keyboardRecordingClaim)
        mic.tapCancel()
        XCTAssertNil(store.keyboardRecordingClaim)
        mic.userTypedKey()
        _ = try await recordHere(mic)
        XCTAssertNotNil(store.keyboardRecordingClaim)
        fake.emit(.failed(message: "The recording stopped.", beforeAudio: false))
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    func testAPauseHeldPastTheLimitStopsAndKeepsTheWords() async throws {
        let (mic, _) = makeMic()
        let id = try await recordHere(mic)
        mic.tapPause()
        clock = clock.addingTimeInterval(KeyboardCapture.pauseLimit - 1)
        host.refresh(id)
        XCTAssertFalse(fake.calls.contains("stop"))
        clock = clock.addingTimeInterval(2)
        host.refresh(id)
        XCTAssertEqual(fake.calls.last, "stop")
        XCTAssertEqual(mic.state, .transcribing)
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    /// With the route unused (switch off or a capture hold-off), nothing records here and
    /// no claim is ever written: every tap opens Zone exactly as before the feature.
    func testWithTheRouteGoneNoClaimIsEverWrittenAndTheTapOpensZone() async {
        var holdOff = KeyboardCapture.Failures()
        holdOff.recordFailure(now: Date())
        holdOff.recordFailure(now: Date())
        let cases: [(String, () -> Void)] = [
            ("switch off", { self.store.keyboardPreferences = KeyboardPreferences(dictatesInKeyboard: false) }),
            ("hold-off", { self.host.failures = holdOff }),
        ]
        for (name, setUp) in cases {
            store.keyboardPreferences = KeyboardPreferences()
            store.keyboardSpeechReady = true
            host.failures = .init()
            setUp()
            let (mic, proxy) = makeMic()
            mic.tapMic()
            await settle()
            XCTAssertEqual(proxy.opened.count, 1, name)
            XCTAssertEqual(mic.state, .inApp, name)
            XCTAssertNotNil(store.request, "\(name): the request stays for Zone")
            XCTAssertNil(store.keyboardRecordingClaim, name)
        }
        XCTAssertFalse(fake.calls.contains("start"))
        let (mic, proxy) = makeMic()
        mic.localCapability = { (false, true) }
        store.keyboardPreferences = KeyboardPreferences()
        host.failures = .init()
        mic.tapMic()
        XCTAssertEqual(proxy.opened.count, 1, "iOS 25 and earlier")
        XCTAssertNil(store.keyboardRecordingClaim)
    }

    // MARK: A press that outlives Zone's session (phone, 2026-11-22, CarPlay)

    /// A press on a session that reads alive, answered by Zone with "I have to be open".
    private func pressOnASessionThatJustEnded(_ mic: MicController) throws -> DictationRequest {
        let now = Date()
        store.session = SessionState(isArmed: true, armedUntil: now.addingTimeInterval(600), modelReady: true, heartbeat: now)
        mic.tapMic()
        let request = try XCTUnwrap(store.request)
        XCTAssertEqual(mic.state, .requesting)
        return request
    }

    private func zoneAnswersItHasToBeOpen(_ request: DictationRequest, _ mic: MicController) {
        store.session = SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: Date())
        store.status = DictationStatus(requestID: request.id, generation: request.generation, phase: .needsApp,
                                       updatedAt: Date(), message: "Open Zone to start a session.")
        mic.handleStatusChanged()
    }

    /// In the car the session ended 0.06 s and 0.4 s before two taps. Each showed "Zone has to
    /// be open to start the mic" and needed a second tap. The same tap now records here.
    func testAPressOnASessionThatJustEndedRecordsInTheKeyboard() async throws {
        let (mic, proxy) = makeMic()
        let request = try pressOnASessionThatJustEnded(mic)
        zoneAnswersItHasToBeOpen(request, mic)
        await settle()
        mic.handleStatusChanged()
        await settle()
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, 1, "re-reading the reply must keep the same microphone")
        XCTAssertEqual(host.request?.id, request.id)
        XCTAssertTrue(proxy.opened.isEmpty, "Zone stays closed")
        if case .error(let message) = mic.state { XCTFail("no error line: \(message)") }
    }

    /// With no way to record here, the same tap opens Zone, as it would have with no session.
    func testAPressOnASessionThatJustEndedOpensZoneWhenTheKeyboardCannotRecord() async throws {
        let (mic, proxy) = makeMic()
        mic.localCapability = { (false, false) }
        let request = try pressOnASessionThatJustEnded(mic)
        zoneAnswersItHasToBeOpen(request, mic)
        await settle()
        XCTAssertEqual(proxy.opened, [ZoneContract.dictateURL(requestID: request.id)])
        XCTAssertTrue(fake.calls.filter { $0 == "start" }.isEmpty)
        if case .error(let message) = mic.state { XCTFail("no error line: \(message)") }
    }

    /// Seconds after the tap the person has moved on: no jump to Zone out of nowhere.
    func testALateAnswerStaysAnErrorForTheNextTap() async throws {
        let (mic, proxy) = makeMic()
        mic.localCapability = { (false, false) }
        let request = try pressOnASessionThatJustEnded(mic)
        await settle(Int(MicController.freshTapWindow * 1000) + 200)
        zoneAnswersItHasToBeOpen(request, mic)
        await settle()
        XCTAssertTrue(proxy.opened.isEmpty)
        XCTAssertEqual(mic.state, .error(MicController.needsAppMessage))
    }

    // MARK: One set of corrections, whoever recorded (cohesion audit 2026-11-20, finding 5)

    /// A dictation Zone recognized and handed over, as the warm path delivers it.
    private func dictateThroughZone(_ heard: String, doubts: [DoubtfulWord]? = nil) async throws -> (MicController, Proxy) {
        let now = Date()
        store.session = SessionState(isArmed: true, armedUntil: now.addingTimeInterval(600), modelReady: true, heartbeat: now)
        let (mic, proxy) = makeMic()
        wire(mic)
        let startsBefore = fake.calls.filter { $0 == "start" }.count
        mic.tapMic()
        let request = try XCTUnwrap(store.request)
        store.status = DictationStatus(requestID: request.id, generation: request.generation, phase: .recording, updatedAt: Date(), message: nil)
        mic.handleStatusChanged()
        // The keyboard re-reads the store a moment after a ping.
        await settle(400)
        XCTAssertTrue(isRecording(mic), "\(mic.state)")
        XCTAssertEqual(fake.calls.filter { $0 == "start" }.count, startsBefore, "Zone records, not the keyboard")
        mic.tapStop()
        store.result = DictationResult(requestID: request.id, generation: request.generation, text: heard, audioSeconds: 4,
                                       createdAt: Date(), inputSession: request.inputSession, doubts: doubts)
        store.status = DictationStatus(requestID: request.id, generation: request.generation, phase: .ready, updatedAt: Date(), message: nil)
        mic.handleResultReady()
        await settle(400)
        store.session = nil
        return (mic, proxy)
    }

    /// The same words as the keyboard's own recognizer would return them.
    private func dictateHere(_ heard: String) async throws -> (MicController, Proxy) {
        let (mic, proxy) = makeMic()
        wire(mic)
        _ = try await recordHere(mic)
        mic.tapStop()
        fake.emit(.finished(text: heard, audioSeconds: 4))
        return (mic, proxy)
    }

    /// The person's own words, learned fixes, handles and contacts, as both paths read them.
    private func wire(_ mic: MicController) {
        var document = PersonalVocabulary.Document(words: ["QuillBerry", "Zayd"])
        document.handles = ["@quillberry"]
        document.misheard = ["cube berry": "QuillBerry"]
        mic.readVocabulary = { document }
        mic.readSystemWords = { ["Siobhan"] }
    }

    /// The audit's question: the keyboard recording by itself uses Apple's recognizer, so does
    /// its text miss Zone's corrections? It does not. Whatever recognized the words, they are
    /// written by one function (`MicController.insert`), so the same heard text comes out the
    /// same character for character: My words, learned fixes, handles, contact names, spoken
    /// corrections, spoken times, stutter removal, emoticons and the text style.
    func testTheSameHeardWordsAreWrittenTheSameWhicheverPathRecordedThem() async throws {
        var preferences = KeyboardPreferences()
        preferences.spokenCorrections = true
        preferences.handleRecognition = true
        let sentences = [
            // My words and a learned fix, a stutter, a spoken time.
            "i i think quillberry ships at two fifteen pm and cube berry is ready",
            // A spoken correction and a contact name iOS knows.
            "tell siobhan we meet tuesday scratch that wednesday at nine thirty",
            // A handle, an emoticon and an ordinal.
            "thanks at quillberry smiley face see you on the twenty first",
            // A question, a restart and a number.
            "can you can you send me three hundred dollars by friday",
            // Nothing special: plain words stay plain on both.
            "the weather is nice today",
        ]
        for style in [TextStyle.casual, .veryCasual, .formal, .excited] {
            for heard in sentences {
                store.keyboardPreferences = preferences
                store.defaultTextStyle = style
                store.textStylePickedAt = nil
                store.request = nil
                store.result = nil
                store.status = nil
                store.control = nil
                store.ledger = InsertionLedger()
                host.failures = .init()
                let (_, throughZone) = try await dictateThroughZone(heard)
                store.request = nil
                store.result = nil
                store.status = nil
                store.control = nil
                store.ledger = InsertionLedger()
                let (_, here) = try await dictateHere(heard)
                XCTAssertFalse(throughZone.text.isEmpty, "Zone's path wrote nothing for: \(heard)")
                XCTAssertEqual(here.text, throughZone.text, "\(style) differs for: \(heard)")
            }
        }
    }

    func testNumbersFromAppKeyboardDictation() async throws {
        store.defaultTextStyle = .casual
        store.keyboardPreferences.numbers.mode = .words
        let (_, proxy) = try await dictateThroughZone("I saw 7 birds")
        XCTAssertEqual(proxy.text, "I saw seven birds")
    }

    func testNumbersFromKeyboardRecording() async throws {
        store.defaultTextStyle = .casual
        store.keyboardPreferences.numbers.mode = .words
        let (_, proxy) = try await dictateHere("I saw 7 birds")
        XCTAssertEqual(proxy.text, "I saw seven birds")
    }

    func testNumbersOnKeyboardRetry() async throws {
        store.defaultTextStyle = .casual
        store.keyboardPreferences.numbers.mode = .words
        fake.kept = UUID()
        let (mic, proxy) = makeMic()
        fake.emit(.finished(text: "I saw 7 birds", audioSeconds: 3))
        mic.handleResultReady()
        await settle(150)
        guard case .pendingInsert = mic.state else { return XCTFail("The retry did not offer its words") }
        mic.tapInsert()
        XCTAssertEqual(proxy.text, "I saw seven birds")
    }

    func testClearedOfferCannotWriteToHostOrLeaveRecoverButton() {
        let offered = DictationResult(requestID: UUID(), generation: 1, text: "fixture", audioSeconds: 1,
                                      createdAt: Date(), inputSession: nil)
        store.result = offered
        let (mic, proxy) = makeMic()
        guard case .pendingInsert = mic.state else { return XCTFail("Expected an explicit insert offer") }
        store.clearPayloads(for: offered.requestID)
        mic.tapInsert()
        XCTAssertEqual(proxy.text, "")
        XCTAssertEqual(mic.state, .idle)
        XCTAssertNil(store.ledger.claimedResultID)
    }

    func testDismissingOldOfferPreservesReplacementForSameRequest() {
        let offered = DictationResult(requestID: UUID(), generation: 1, text: "first", audioSeconds: 1,
                                      createdAt: Date(), inputSession: nil)
        let replacement = DictationResult(requestID: offered.requestID, generation: 2, text: "second", audioSeconds: 2,
                                          createdAt: Date(), inputSession: nil)
        store.result = offered
        let (mic, proxy) = makeMic()
        guard case .pendingInsert = mic.state else { return XCTFail("Expected the first offer") }
        store.result = replacement
        mic.tapDismissPending()
        XCTAssertEqual(store.result, replacement)
        XCTAssertNil(store.ledger.consumedResultID)
        guard case .pendingInsert(let current, _) = mic.state else { return XCTFail("Expected the replacement offer") }
        XCTAssertEqual(current, replacement)
        XCTAssertEqual(proxy.text, "")
        mic.tapDismissPending()
        XCTAssertEqual(mic.state, .idle)
        XCTAssertNil(store.result)
        XCTAssertEqual(store.ledger.consumedResultID, replacement.requestID)
    }

    func testNumbersOnRestyle() async throws {
        store.defaultTextStyle = .casual
        store.keyboardPreferences.numbers = .init(mode: .words, styles: [.formal])
        let (mic, proxy) = try await dictateHere("I saw 7 birds")
        XCTAssertEqual(proxy.text, "I saw 7 birds")
        mic.chooseStyle(.formal)
        XCTAssertEqual(proxy.text, "I saw seven birds.")
    }

    /// The layers are really at work in that comparison, not skipped on both sides alike.
    func testAKeyboardRecordingGetsMyWordsLearnedFixesTimesAndStutterRemoval() async throws {
        var preferences = KeyboardPreferences()
        preferences.spokenCorrections = true
        store.keyboardPreferences = preferences
        store.defaultTextStyle = .formal
        let (_, proxy) = try await dictateHere("i i think quillberry ships at two fifteen pm and cube berry is ready")
        XCTAssertTrue(proxy.text.contains("QuillBerry ships"), "My words: \(proxy.text)")
        XCTAssertTrue(proxy.text.contains("and QuillBerry is ready"), "a learned fix: \(proxy.text)")
        XCTAssertTrue(proxy.text.contains("2:15"), "a spoken time: \(proxy.text)")
        XCTAssertFalse(proxy.text.lowercased().contains("i i "), "a stutter: \(proxy.text)")
    }

    /// What cannot apply to a keyboard recording: unsure words. They come from the confidences
    /// of Zone's own model, which Apple's recognizer does not give, so a result from the
    /// keyboard carries none and the strip never flags a word it has no measure for.
    func testAKeyboardRecordingCarriesNoUnsureWords() async throws {
        var preferences = KeyboardPreferences()
        preferences.checksDoubtfulWords = true
        store.keyboardPreferences = preferences
        let (mic, _) = try await dictateHere("the weather is nice today")
        XCTAssertNil(store.result?.doubts)
        XCTAssertTrue(mic.doubts.isEmpty)
    }

    // MARK: Taken from anomalyco/hex's fixes after its testers' iPhones (2026-11-20)

    /// #2045: a keyboard near its memory limit is ended by iOS as the capture starts. Short of
    /// room the tap opens Zone, and with room again it records here.
    func testShortOfMemoryTheTapOpensZoneInsteadOfRiskingTheKeyboard() async throws {
        let (mic, proxy) = makeMic()
        mic.memoryAvailable = { 20 * 1_048_576 }
        mic.tapMic()
        await settle()
        XCTAssertEqual(proxy.opened.count, 1)
        XCTAssertEqual(mic.state, .inApp)
        XCTAssertFalse(fake.calls.contains("start"))
        XCTAssertNil(store.keyboardRecordingClaim)
        let (roomy, _) = makeMic()
        roomy.memoryAvailable = { 177 * 1_048_576 }
        _ = try await recordHere(roomy)
        XCTAssertTrue(isRecording(roomy))
    }

    /// #2071: a keyboard process that started before the microphone was allowed reads it as
    /// not allowed until iOS restarts it. The app's published reading lets the tap record here.
    func testAStaleMicrophoneReadingIsCorrectedByTheApps() async throws {
        let (mic, proxy) = makeMic()
        mic.localCapability = { (true, nil) }
        mic.tapMic()
        XCTAssertEqual(proxy.opened.count, 1, "neither reading allows it: Zone opens")
        store.appMicrophoneGranted = true
        let (second, secondProxy) = makeMic()
        second.localCapability = { (true, nil) }
        _ = try await recordHere(second)
        XCTAssertTrue(isRecording(second))
        XCTAssertEqual(secondProxy.opened.count, 0)
    }

    /// #2089: the page is loaded as the keyboard appears, so a tap has only the microphone
    /// left to open. Only for someone who has dictated here, and never the microphone itself.
    func testThePageIsLoadedAheadOnlyAfterSomeoneHasDictatedHere() async throws {
        let (first, _) = makeMic()
        await settle(600)
        XCTAssertFalse(fake.calls.contains("prepare"), "someone who only types never pays for a web view")
        let id = try await recordHere(first)
        XCTAssertNotNil(host.lastDictated)
        first.tapStop()
        fake.emit(.finished(text: "one", audioSeconds: 1))
        XCTAssertNotNil(id)
        first.keyboardWillDisappear()
        XCTAssertFalse(host.isPrepared, "the web view goes with the keyboard")
        let before = fake.calls.count
        let (second, _) = makeMic()
        XCTAssertEqual(fake.calls.count, before, "nothing before the first frames")
        await settle(600)
        XCTAssertEqual(Array(fake.calls[before...]), ["prepare"], "the page, not the microphone")
        XCTAssertTrue(host.isPrepared)
        XCTAssertNil(store.keyboardRecordingClaim)
        XCTAssertEqual(second.state, .idle)
        // Leaving before the moment passes loads nothing.
        second.keyboardWillDisappear()
        let quiet = fake.calls.count
        let (third, _) = makeMic()
        third.keyboardWillDisappear()
        await settle(600)
        XCTAssertFalse(fake.calls[quiet...].contains("prepare"))
    }

    /// With Zone keeping the microphone ready the tap goes to Zone, so no page is loaded.
    func testNoPageIsLoadedAheadWhileZoneKeepsTheMicrophoneReady() async throws {
        let (first, _) = makeMic()
        _ = try await recordHere(first)
        first.tapCancel()
        first.keyboardWillDisappear()
        let now = Date()
        store.session = SessionState(isArmed: true, armedUntil: now.addingTimeInterval(600), modelReady: true, heartbeat: now)
        let before = fake.calls.count
        _ = makeMic()
        await settle(600)
        XCTAssertFalse(fake.calls[before...].contains("prepare"))
    }

    // MARK: Hold space to talk records here too

    /// A hold never opens Zone. With no session it talks through the keyboard's own microphone:
    /// held, it records; let go, it stops and the words are typed.
    func testAHoldOnSpaceRecordsHereWithZoneNotKeepingTheMicrophoneReady() async {
        let (mic, proxy) = makeMic()
        XCTAssertTrue(mic.spaceHoldBegan(), "the hold is talking's")
        XCTAssertEqual(mic.spaceTalkPhase, .starting)
        await settle()
        XCTAssertEqual(fake.calls.last, "start")
        XCTAssertEqual(proxy.opened.count, 0, "a hold never opens Zone")
        fake.emit(.started)
        XCTAssertTrue(isRecording(mic))
        XCTAssertNotNil(store.keyboardRecordingClaim)
        mic.spaceHoldEnded()
        XCTAssertEqual(fake.calls.last, "stop")
        XCTAssertEqual(mic.state, .transcribing)
        fake.emit(.finished(text: "on my way", audioSeconds: 1.5))
        XCTAssertEqual(proxy.text.trimmingCharacters(in: .whitespaces).lowercased(), "on my way")
        XCTAssertEqual(proxy.opened.count, 0)
    }

    /// Letting go before the microphone started calls the start off: nothing records, nothing
    /// counts as a failure and Zone is not opened.
    func testAHoldLetGoBeforeTheMicrophoneStartsRecordsNothing() async {
        let (mic, proxy) = makeMic()
        XCTAssertTrue(mic.spaceHoldBegan())
        mic.spaceHoldEnded()
        await settle()
        XCTAssertFalse(fake.calls.contains("start"))
        XCTAssertFalse(host.isBusy)
        XCTAssertNil(store.request)
        XCTAssertEqual(host.failures.count, 0)
        XCTAssertEqual(proxy.opened.count, 0)
        if case .error(let message) = mic.state { XCTAssertEqual(message, SpaceTalk.tooSoonMessage) } else { XCTFail("\(mic.state)") }
    }

    /// With the route off and no session there is nothing to talk with: the strip says so, as
    /// before, and nothing records or opens.
    func testAHoldWithNoWayToListenStillSaysZoneIsNotReady() async {
        store.keyboardPreferences = KeyboardPreferences(dictatesInKeyboard: false)
        let (mic, proxy) = makeMic()
        XCTAssertTrue(mic.spaceHoldBegan())
        if case .error(let message) = mic.state { XCTAssertEqual(message, SpaceTalk.notReadyMessage) } else { XCTFail("\(mic.state)") }
        await settle()
        XCTAssertFalse(fake.calls.contains("start"))
        XCTAssertEqual(proxy.opened.count, 0)
    }

    /// Recognition failed: the audio was kept, and the next appearance tries once more.
    func testAKeptRecordingIsRetriedOnceAndOffered() async {
        let kept = UUID()
        fake.kept = kept
        fake.keptDate = Date(timeIntervalSince1970: 12345)
        let (mic, _) = makeMic()
        XCTAssertEqual(fake.calls.last, "retry")
        fake.emit(.finished(text: "words from before", audioSeconds: 3))
        XCTAssertEqual(statsStarts, [fake.keptDate])
        XCTAssertEqual(recoveries, [fake.keptDate])
        XCTAssertEqual(history.map(\.requestID), [kept])
        mic.handleResultReady()
        await settle(150)
        guard case .pendingInsert(let result, _) = mic.state else { return XCTFail("\(mic.state)") }
        XCTAssertEqual(result.requestID, kept)
        fake.kept = kept
        _ = makeMic()
        XCTAssertEqual(fake.calls.filter { $0 == "retry" }.count, 1, "one retry only")
    }

    func testRetryReadsCreationDateFromBothInboxNamesAndLegacyTemporaryFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = temporary.appendingPathComponent("KeyboardAudio")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in [inbox, temporary] {
            for name in [KeyboardCapture.retryName, KeyboardCapture.recordingName] {
                let id = UUID()
                let url = directory.appendingPathComponent(name(id))
                try Data().write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                let expected = try XCTUnwrap(url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                XCTAssertEqual(LocalDictation.keptStart(id: id, inbox: inbox, temporary: temporary), expected)
            }
        }
    }

    /// A kept file that cannot be read reports nothing back. The keyboard must not sit on
    /// "Transcribing" for it: the mic is idle and the next tap records.
    func testAnUnreadableKeptRecordingLeavesTheMicFree() async {
        fake.kept = UUID()
        fake.keptReadable = false
        let (mic, _) = makeMic()
        XCTAssertEqual(fake.calls.last, "retry")
        XCTAssertFalse(host.isBusy)
        let (again, _) = makeMic()
        XCTAssertEqual(again.state, .idle)
        _ = mic
    }
}

@available(iOS 26, *)
@MainActor
final class SpeechWorkerLifetimeTests: XCTestCase {
    func testNextConnectionCanStartWhileTimedOutOpenIsStillBlocked() async throws {
        let blocked = AsyncStream<Void>.makeStream()
        defer { blocked.continuation.finish() }
        var attempts = 0
        let worker = ZoneModelSpeech(startupLimit: 0.02) {
            attempts += 1
            if attempts == 1 {
                let wait = Task { for await _ in blocked.stream {} }
                await wait.value
            }
        }
        do {
            try await worker.connect()
            XCTFail("The first open should time out")
        } catch is Watchdog.Stalled {}
        try await worker.connect()
        XCTAssertEqual(attempts, 2)
    }
}
