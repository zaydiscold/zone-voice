// by zayd/cold @ zayd.wtf

#if canImport(JavaScriptCore)
import AVFAudio
import JavaScriptCore
import XCTest
@testable import ZoneCore

/// The keyboard's capture page under JavaScriptCore, with a fake microphone whose
/// `getUserMedia` resolves only when the test says so. WebKit is not involved: this pins the
/// page's own rules (epochs, cancelled starts, track events), not the web view.
final class KeyboardCapturePageTests: XCTestCase {
    private var context: JSContext!

    private static let fakes = #"""
    var posted = [];
    var webkit = { messageHandlers: { zone: { postMessage: (m) => posted.push(m) } } };
    var pending = [];
    var tracks = [];
    var contexts = [];
    var connected = 0;
    var devices = [{ kind: "audioinput", label: "iPhone Microphone", deviceId: "builtin" },
                   { kind: "audioinput", label: "AirPods", deviceId: "airpods" }];
    function makeTrack(label) {
      const t = { label: label, muted: false, stopped: false, onended: null, onmute: null, onunmute: null,
                  stop() { this.stopped = true; }, getSettings() { return { deviceId: label === "iPhone Microphone" ? "builtin" : "airpods" }; } };
      tracks.push(t);
      return t;
    }
    var navigator = { mediaDevices: {
      getUserMedia: (constraints) => new Promise((resolve, reject) => pending.push({ constraints: constraints, resolve: resolve, reject: reject })),
      enumerateDevices: () => Promise.resolve(devices)
    } };
    function grant(index, label, muted = false) {
      const t = makeTrack(label || "iPhone Microphone");
      t.muted = muted;
      pending[index].resolve({ getTracks: () => [t], getAudioTracks: () => [t] });
    }
    function refuse(index) { pending[index].reject({ name: "NotAllowedError", message: "denied" }); }
    var clock = 0;
    var performance = { now: () => clock };
    var timers = [];
    function setInterval(f, ms) { timers.push({ f: f, ms: ms, live: true }); return timers.length; }
    function clearInterval(id) { if (timers[id - 1]) timers[id - 1].live = false; }
    // Moves the clock on and runs every live timer once, as half a second passing would.
    function pass(ms) { clock += ms; timers.filter((t) => t.live).forEach((t) => t.f()); }
    function liveTimers() { return timers.filter((t) => t.live).length; }
    class AudioContext {
      constructor() { this.sampleRate = 48000; this.closed = false; this.state = "running"; this.onstatechange = null; this.destination = { name: "speaker" }; contexts.push(this); }
      resume() { return Promise.resolve(); }
      close() { this.closed = true; return Promise.resolve(); }
      createMediaStreamSource() { return { connect() { connected += 1; }, disconnect() { connected -= 1; } }; }
      createScriptProcessor() { const n = { onaudioprocess: null, to: null, connect(x) { this.to = x; }, disconnect() {} }; this.node = n; return n; }
      createGain() { const g = { gain: { value: 1 }, to: null, connect(x) { this.to = x; }, disconnect() {} }; this.sink = g; return g; }
    }
    function block(value) {
      return { inputBuffer: { getChannelData: () => new Float32Array([value, -value, value, -value]) } };
    }
    var btoa = (s) => "b" + s.length;
    function types() { return posted.map((m) => m.type + ":" + m.epoch); }
    """#

    override func setUp() {
        super.setUp()
        context = JSContext()
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(Self.fakes)
        context.evaluateScript(KeyboardCapturePage.script)
    }

    /// Runs `script`, then lets every promise job it queued settle.
    private func run(_ script: String) {
        context.evaluateScript(script)
        context.evaluateScript("0")
    }

    private func value(_ expression: String) -> JSValue { context.evaluateScript(expression) }
    private var posted: [String] { value("types()").toArray() as? [String] ?? [] }

    func testAStartPostsStartedWithItsEpoch() {
        run("zoneStart(1, false)")
        XCTAssertEqual(value("pending.length").toInt32(), 1)
        run("grant(0)")
        XCTAssertEqual(posted, ["started:1"])
        XCTAssertEqual(value("posted[0].rate").toInt32(), 48000)
        run("contexts[0].node.onaudioprocess(block(0.5))")
        XCTAssertEqual(posted, ["started:1", "pcm:1"])
        XCTAssertEqual(value("posted[1].rms").toDouble(), 0.5, accuracy: 0.001)
    }

    /// Cancel while getUserMedia is still pending, then tap again: the first microphone, when
    /// it arrives, is stopped at once and never starts a second capture.
    func testACancelThenRetapNeverRunsTwoCaptures() {
        run("zoneStart(1, false)")
        run("zoneStop(1)")
        run("zoneStart(2, false)")
        XCTAssertEqual(value("pending.length").toInt32(), 2)
        run("grant(0)")
        XCTAssertTrue(value("tracks[0].stopped").toBool(), "the cancelled start's microphone is let go")
        XCTAssertEqual(posted, [], "nothing is posted for a cancelled start")
        run("grant(1)")
        XCTAssertEqual(posted, ["started:2"])
        XCTAssertEqual(value("connected").toInt32(), 1, "one processor, not two")
        XCTAssertEqual(value("contexts.length").toInt32(), 1)
    }

    /// A stop meant for the last dictation never stops, or reports for, the new one.
    func testALateStopForTheLastDictationIsIgnored() {
        run("zoneStart(1, false)")
        run("grant(0)")
        run("zoneStop(1)")
        XCTAssertEqual(posted, ["started:1", "stopped:1"])
        run("zoneStart(2, false)")
        run("grant(1)")
        run("zoneStop(1)")
        XCTAssertEqual(posted, ["started:1", "stopped:1", "started:2"])
        XCTAssertFalse(value("tracks[1].stopped").toBool())
        run("contexts[1].node.onaudioprocess(block(0.2))")
        XCTAssertEqual(posted.last, "pcm:2")
        // The stopped capture's processor has no handler left, so its blocks can post nothing.
        XCTAssertTrue(value("contexts[0].node.onaudioprocess === null").toBool())
        XCTAssertEqual(posted.last, "pcm:2")
        XCTAssertEqual(posted.count, 4)
    }

    func testANewerStartReplacesARunningOne() {
        run("zoneStart(1, false)")
        run("grant(0)")
        run("zoneStart(2, false)")
        XCTAssertTrue(value("tracks[0].stopped").toBool())
        XCTAssertTrue(value("contexts[0].closed").toBool())
        run("grant(1)")
        XCTAssertEqual(posted, ["started:1", "started:2"])
        run("zoneStart(2, false)")
        XCTAssertEqual(value("pending.length").toInt32(), 2, "the same start twice asks once")
    }

    func testARefusedMicrophoneIsAnErrorWithItsEpoch() {
        run("zoneStart(3, false)")
        run("refuse(0)")
        XCTAssertEqual(posted, ["error:3"])
        XCTAssertTrue(value("posted[0].message").toString().contains("NotAllowedError"))
        // A refusal for a start already cancelled says nothing.
        run("zoneStart(4, false); zoneStop(4)")
        run("refuse(1)")
        XCTAssertEqual(posted, ["error:3"])
    }

    /// iOS taking the microphone away, or muting it, reaches the keyboard as a message instead
    /// of a recording that silently goes on.
    func testATrackThatEndsOrMutesIsReported() {
        run("zoneStart(5, false)")
        run("grant(0)")
        run("tracks[0].onmute()")
        run("tracks[0].onunmute()")
        run("tracks[0].onended()")
        XCTAssertEqual(posted, ["started:5", "muted:5", "unmuted:5", "ended:5"])
        XCTAssertEqual(value("posted[3].reason").toString(), "track")
        run("zoneStop(5)")
        XCTAssertEqual(posted, ["started:5", "muted:5", "unmuted:5", "ended:5"])
        XCTAssertTrue(value("tracks[0].stopped").toBool())
        XCTAssertTrue(value("tracks[0].onended === null").toBool(), "a stopped track's handlers are removed")
    }

    /// From stephancill/ios-keyboard-dictation: a keyboard that stops answering (suspended,
    /// ended by iOS) must not leave the microphone open. The page closes it by itself.
    func testAKeyboardThatGoesQuietLosesTheMicrophone() {
        run("zoneStart(9, false)")
        run("grant(0)")
        // Beats keep it open however long the recording runs.
        for _ in 0..<20 {
            run("pass(500); zoneBeat(9)")
        }
        XCTAssertEqual(posted, ["started:9"])
        XCTAssertFalse(value("tracks[0].stopped").toBool())
        // A beat for another capture is no sign of life for this one.
        run("pass(1500); zoneBeat(8)")
        run("pass(1000)")
        XCTAssertEqual(posted, ["started:9"], "2.5 s quiet is within the limit")
        run("pass(1000)")
        XCTAssertEqual(posted, ["started:9", "ended:9"])
        XCTAssertEqual(value("posted[1].reason").toString(), "heartbeat")
        XCTAssertTrue(value("tracks[0].stopped").toBool(), "the microphone is let go")
        XCTAssertTrue(value("contexts[0].closed").toBool())
        XCTAssertEqual(value("liveTimers()").toInt32(), 0)
        // Nothing more is posted for it, and the next start works.
        run("contexts[0].node && contexts[0].node.onaudioprocess && contexts[0].node.onaudioprocess(block(0.2))")
        run("zoneStop(9)")
        XCTAssertEqual(posted, ["started:9", "ended:9"])
        run("zoneStart(10, false)")
        run("grant(1)")
        XCTAssertEqual(posted.last, "started:10")
    }

    func testStartingMuteHasHalfASecondToClear() {
        run("zoneStart(1, false)"); run("grant(0, null, true)")
        run("pass(250); zoneBeat(1); tracks[0].muted = false; tracks[0].onunmute(); pass(500)")
        XCTAssertEqual(posted, ["started:1"])
        run("zoneStart(2, false)"); run("grant(1, null, true)")
        run("pass(500)")
        XCTAssertEqual(posted.suffix(2), ["started:2", "muted:2"])
    }

    func testAStopEndsTheWatchSoNoLateEndingIsPosted() {
        run("zoneStart(11, false)")
        run("grant(0)")
        XCTAssertEqual(value("liveTimers()").toInt32(), 1)
        run("zoneStop(11)")
        XCTAssertEqual(value("liveTimers()").toInt32(), 0)
        run("pass(10000)")
        XCTAssertEqual(posted, ["started:11", "stopped:11"])
    }

    func testInterruptedContextHoldsAndRunningResumesWithoutClosingTrack() {
        run("zoneStart(12, false)")
        run("grant(0)")
        run("contexts[0].state = 'interrupted'; contexts[0].onstatechange()")
        XCTAssertEqual(posted, ["started:12", "context:12"])
        XCTAssertTrue(value("posted[1].held").toBool())
        XCTAssertFalse(value("tracks[0].stopped").toBool())
        run("contexts[0].state = 'running'; zoneBeat(12)")
        XCTAssertEqual(posted.last, "context:12")
        XCTAssertFalse(value("posted[2].held").toBool())
    }

    func testHeartbeatDetectsSessionHoldAndReleaseWithoutStateEvents() {
        run("navigator.audioSession = { state: 'active', onstatechange: null }")
        run("zoneStart(13, false)")
        run("grant(0)")
        run("navigator.audioSession.state = 'interrupted'; zoneBeat(13); zoneBeat(13)")
        XCTAssertEqual(posted, ["started:13", "session:13"])
        run("navigator.audioSession.state = 'active'; navigator.audioSession.onstatechange()")
        XCTAssertEqual(posted, ["started:13", "session:13", "session:13"])
        XCTAssertFalse(value("posted[2].held").toBool())
    }

    func testReturnedInputUsesTheSameLiveTrackAndRecording() {
        run("navigator.audioSession = { state: 'active' }; zoneStart(7, false)")
        run("grant(0)")
        run("tracks[0].muted = true; navigator.audioSession.state = 'interrupted'; zoneBeat(7)")
        run("navigator.audioSession.state = 'active'; tracks[0].muted = false; zoneBeat(7)")
        XCTAssertEqual(value("pending.length").toInt32(), 1)
        XCTAssertFalse(value("tracks[0].stopped").toBool())
        XCTAssertEqual(posted.last, "unmuted:7")
        run("contexts[0].node.onaudioprocess(block(0.4))")
        XCTAssertEqual(posted.last, "pcm:7")
    }

    func testNativeInterruptionDefersMuteTimeoutUntilTheHoldEnds() {
        run("zoneStart(3, false)")
        run("grant(0)")
        run("zoneNativeHold(3, true); tracks[0].muted = true")
        for _ in 0..<15 { run("pass(1000); zoneBeat(3)") }
        XCTAssertEqual(posted, ["started:3", "muted:3"])
        run("zoneNativeHold(3, false); zoneBeat(3)")
        for _ in 0..<12 { run("pass(1000); zoneBeat(3)") }
        XCTAssertEqual(value("posted[posted.length-1].reason").toString(), "stuck-muted")
        XCTAssertEqual(value("pending.length").toInt32(), 1)
        XCTAssertTrue(value("tracks[0].stopped").toBool())
    }

    func testAResumeTapRechecksTheOriginalTrackAndContext() {
        run("zoneStart(4, false)")
        run("grant(0)")
        run("tracks[0].muted = true; zoneBeat(4)")
        run("zoneRecover(4, true)")
        XCTAssertEqual(posted.last, "muted:4")
        run("zoneStop(4); zoneRecover(4, true)")
        XCTAssertEqual(value("pending.length").toInt32(), 1)
        XCTAssertEqual(posted.last, "stopped:4")
    }

    /// The processor must lead to the output to run at all; the gain in between is zero, so the
    /// microphone can never be heard from the speaker.
    func testTheMicrophoneNeverReachesTheSpeaker() {
        run("zoneStart(14, false)")
        run("grant(0)")
        XCTAssertEqual(value("contexts[0].sink.gain.value").toDouble(), 0)
        XCTAssertTrue(value("contexts[0].node.to === contexts[0].sink").toBool())
        XCTAssertTrue(value("contexts[0].sink.to === contexts[0].destination").toBool())
    }

    /// From anomalyco/hex #2005: ask for the iPhone's own microphone so AirPods keep music.
    func testPreferBuiltInAsksForTheIPhonesMicrophone() {
        run("zoneStart(6, true)")
        XCTAssertEqual(value("pending[0].constraints.audio.deviceId.exact").toString(), "builtin")
        XCTAssertFalse(value("pending[0].constraints.audio.echoCancellation").toBool())
        run("grant(0)")
        XCTAssertEqual(posted, ["started:6"])
        XCTAssertEqual(value("posted[0].device").toString(), "iPhone Microphone")
        run("zoneStop(6); zoneStart(7, false)")
        XCTAssertTrue(value("pending[1].constraints.audio.deviceId === undefined").toBool(), "CarPlay: the system's choice")
    }

    /// Labels can read empty before the first grant; the page then asks again by id.
    func testPreferBuiltInAsksAgainWhenTheFirstGrantWasAnotherMicrophone() {
        run("devices = [{ kind: 'audioinput', label: '', deviceId: 'builtin' }]")
        run("zoneStart(8, true)")
        XCTAssertTrue(value("pending[0].constraints.audio.deviceId === undefined").toBool())
        run("devices = [{ kind: 'audioinput', label: 'iPhone Microphone', deviceId: 'builtin' }]")
        run("grant(0, 'AirPods')")
        XCTAssertTrue(value("tracks[0].stopped").toBool())
        XCTAssertEqual(value("pending.length").toInt32(), 2)
        XCTAssertEqual(value("pending[1].constraints.audio.deviceId.exact").toString(), "builtin")
        run("grant(1)")
        XCTAssertEqual(posted, ["started:8"])
    }

    func testSpeechFixtureThroughBothRecordingMeters() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let clip = Bundle(for: Self.self).url(forResource: "test-clip", withExtension: "wav")
            ?? repo.appendingPathComponent("Zone/Resources/test-clip.wav")
        let file = try AVAudioFile(forReading: clip)
        let rate = file.processingFormat.sampleRate
        // 2,048 frames at the phone's 48 kHz, expressed in this 16 kHz speech file.
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount((rate * 2048 / 48000).rounded())))
        var app = RecordingLevelWindow()
        var peakSinceAppPost: Float = 0
        var pairs: [(Float, Float)] = []
        var allBlocks: [Float] = []
        run("zoneStart(1, false)")
        run("grant(0)")
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
            context.setObject(samples, forKeyedSubscript: "fixture" as NSString)
            run("contexts[0].node.onaudioprocess({inputBuffer: {getChannelData: () => fixture}})")
            let rms = Float(value("posted[posted.length - 1].rms").toDouble())
            let time = Double(file.framePosition) / rate
            let native = app.sample(samples, at: time)
            let keyboard = KeyboardCapture.level(rootMeanSquare: rms)
            allBlocks.append(keyboard)
            peakSinceAppPost = max(peakSinceAppPost, keyboard)
            if let native {
                pairs.append((native, peakSinceAppPost))
                peakSinceAppPost = 0
            }
        }
        let duration = Double(file.length) / rate
        XCTAssertEqual(Double(allBlocks.count) / duration, 48000.0 / 2048, accuracy: 0.3)
        XCTAssertEqual(Double(pairs.count) / duration, 48000.0 / 4096, accuracy: 0.3)
        let error = pairs.map { abs($0.0 - $0.1) }.max() ?? 1
        XCTAssertLessThan(error, 0.00001)
        print("Fixture meter keyboard=\(allBlocks.count) app=\(pairs.count) maxDifference=\(error)")
    }

    func testThePageNamesTheHandlerAndHostTheWebViewUses() {
        XCTAssertTrue(KeyboardCapturePage.script.contains("messageHandlers.\(KeyboardCapturePage.handler)."))
        XCTAssertTrue(KeyboardCapturePage.html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(KeyboardCapturePage.html.contains("function zoneStart(epoch, preferBuiltIn)"))
    }
}
#endif
