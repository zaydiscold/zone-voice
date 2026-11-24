// by zayd/cold @ zayd.wtf

import Foundation

/// The page the keyboard's hidden web view loads to hold the microphone (`LocalDictation` in
/// the keyboard). Kept here, apart from the web view, so its rules run under JavaScriptCore in
/// `KeyboardCapturePageTests` with a fake microphone.
///
/// Every start carries an epoch from the keyboard, and every message the page posts echoes it.
/// A start replaces any older one, a stop applies only to its own epoch, and a microphone that
/// arrives for a start already cancelled is stopped at once. So a cancel then a quick retap can
/// never run two captures, and a late "stopped" from the last dictation is never taken for the
/// new one's.
///
/// The page also ends a capture by itself, with `ended` and a reason, when the keyboard stops
/// answering: `zoneBeat` must arrive at least every `beatLimit` (the keyboard sends one a
/// second), so a keyboard that iOS suspended or ended can never leave the microphone open
/// behind the person's back. Temporary interruptions hold the recording. A track that iOS
/// ends permanently finishes it. The heartbeat and the interruption handlers are from
/// stephancill/ios-keyboard-dictation (MIT, see THIRD-PARTY-NOTICES.md).
///
/// Messages: `started` (rate, device, muted), `pcm` (base64 16-bit samples and the block's
/// RMS), `stopped`, `muted`, `unmuted`, `ended` (the capture was taken away or the page ended
/// it; `reason` says which) and `error`.
public enum KeyboardCapturePage {
    /// How long the page records without a `zoneBeat` before it stops the microphone itself.
    public static let beatLimit: TimeInterval = 3
    /// How often the keyboard sends `zoneBeat` while a capture runs.
    public static let beatEvery: TimeInterval = 1

    /// The message handler name the page posts to.
    public static let handler = "zone"
    /// The page's origin. An https base URL makes it a secure context, which `getUserMedia`
    /// requires; nothing is ever fetched from it.
    public static let host = "keyboard.zone.invalid"

    /// Voice processing off: the recognizer wants the microphone as it is, not a call's
    /// echo-cancelled, gain-ridden version. 2,048 frames a block is about 43 ms at 48 kHz.
    ///
    /// `preferBuiltIn` (from anomalyco/hex #2005) asks for the iPhone's own microphone by id,
    /// so AirPods or a headset keep playing music in stereo instead of switching to call audio,
    /// which pauses it and stalls the start. The keyboard passes false in CarPlay, where the
    /// car's microphone is the lesser cost (see `CarAudioRoute` in the app).
    public static let script = #"""
    let current = null;
    let wanted = 0;
    const BEAT_LIMIT = \#(Int(beatLimit * 1000));
    const post = (m) => webkit.messageHandlers.zone.postMessage(m);
    const base = { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false };
    const session = () => { try { return navigator.audioSession || null; } catch (e) { return null; } };
    function closeCapture(c) {
      if (!c) return;
      if (c.watch) { clearInterval(c.watch); c.watch = null; }
      if (c.ctx) c.ctx.onstatechange = null;
      const a = session();
      if (a && c.watchesSession) { a.onstatechange = null; c.watchesSession = false; }
      try { if (c.node) { c.node.onaudioprocess = null; c.node.disconnect(); } if (c.source) c.source.disconnect(); if (c.sink) c.sink.disconnect(); } catch (e) {}
      if (c.stream) c.stream.getTracks().forEach((t) => { t.onended = null; t.onmute = null; t.onunmute = null; t.stop(); });
      if (c.ctx) { try { c.ctx.close().catch(() => {}); } catch (e) {} }
      c.stream = null; c.ctx = null; c.source = null; c.node = null; c.sink = null;
    }
    // The page ends the capture itself and says why. Whatever was said so far is the keyboard's
    // to recognize, when there is still a keyboard to hear this.
    function endCapture(c, reason) {
      if (current !== c) return;
      current = null;
      wanted = 0;
      closeCapture(c);
      post({ type: "ended", epoch: c.epoch, reason: reason });
    }
    function zoneBeat(epoch) {
      if (!current || current.epoch !== epoch) return;
      current.beat = performance.now();
      poll(current);
    }
    function changed(c, type, held) {
      if (current !== c || !!c[type] === held) return;
      c[type] = held;
      post({ type: type, epoch: c.epoch, held: held });
    }
    function poll(c) {
      if (current !== c) return;
      if (c.ctx.state === "closed") return endCapture(c, "context-closed");
      const a = session();
      if (c.refreshHolds) {
        // The person explicitly cleared the native UI holds. Reconcile its state
        // on the next poll if WebKit still reports an interruption.
        c.refreshHolds = false;
        c.session = false;
        c.context = false;
        c.trackMuted = false;
      }
      changed(c, "context", c.ctx.state !== "running");
      changed(c, "session", !!a && a.state === "interrupted");
      const track = c.stream.getAudioTracks()[0];
      if (track && !!track.muted !== c.trackMuted) reportMute(c, !!track.muted);
      if (c.trackMuted && !c.nativeHold && !c.session && !c.context) {
        c.muteSince ??= performance.now();
        if (performance.now() - c.muteSince >= 12000) return endCapture(c, "stuck-muted");
      } else { c.muteSince = null; }
    }
    function zoneNativeHold(epoch, held) {
      if (!current || current.epoch !== epoch) return;
      current.nativeHold = held;
      if (held) current.muteSince = null;
    }
    function reportMute(c, muted) {
      if (current !== c) return;
      if (!muted) c.initialMuteUntil = 0;
      if (muted && performance.now() < c.initialMuteUntil) return;
      if (c.trackMuted === muted) return;
      c.trackMuted = muted;
      c.muteSince = null;
      post({ type: muted ? "muted" : "unmuted", epoch: c.epoch });
    }
    function bindTrack(c, track) {
      if (!track) return;
      track.onended = () => endCapture(c, "track");
      track.onmute = () => reportMute(c, true);
      track.onunmute = () => reportMute(c, false);
    }
    // A recording owns the track originally granted to it. The session can report
    // that same track live again, or the mute deadline can end the partial recording.
    function zoneRecover(epoch, manual = false) {
      const c = current;
      if (!c || c.epoch !== epoch) return;
      if (manual) {
        c.nativeHold = false;
        c.refreshHolds = true;
        poll(c);
      }
    }
    async function builtInMicrophone() {
      try {
        const inputs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "audioinput");
        const found = inputs.find((d) => /iphone|ipad|built-in/i.test(d.label));
        return found ? found.deviceId : null;
      } catch (e) { return null; }
    }
    async function zoneStart(epoch, preferBuiltIn) {
      if (wanted === epoch) return;
      wanted = epoch;
      if (current) { closeCapture(current); current = null; }
      const c = { epoch: epoch };
      try {
        let id = preferBuiltIn ? await builtInMicrophone() : null;
        if (wanted !== epoch) return;
        c.stream = await navigator.mediaDevices.getUserMedia({ audio: id ? Object.assign({}, base, { deviceId: { exact: id } }) : base });
        if (wanted !== epoch) return closeCapture(c);
        if (preferBuiltIn && !id) {
          // Device labels are only readable once a capture is allowed.
          id = await builtInMicrophone();
          if (wanted !== epoch) return closeCapture(c);
          const first = c.stream.getAudioTracks()[0];
          if (id && first && first.getSettings().deviceId !== id) {
            closeCapture(c);
            c.stream = await navigator.mediaDevices.getUserMedia({ audio: Object.assign({}, base, { deviceId: { exact: id } }) });
            if (wanted !== epoch) return closeCapture(c);
          }
        }
        c.ctx = new AudioContext();
        await c.ctx.resume();
        if (wanted !== epoch) return closeCapture(c);
        const track = c.stream.getAudioTracks()[0];
        c.trackMuted = false;
        c.initialMuteUntil = track && track.muted ? performance.now() + 500 : 0;
        bindTrack(c, track);
        c.source = c.ctx.createMediaStreamSource(c.stream);
        c.node = c.ctx.createScriptProcessor(2048, 1, 1);
        c.node.onaudioprocess = (event) => {
          if (current !== c) return;
          const input = event.inputBuffer.getChannelData(0);
          const pcm = new Int16Array(input.length);
          let sum = 0;
          for (let i = 0; i < input.length; i++) {
            const s = Math.max(-1, Math.min(1, input[i]));
            sum += s * s;
            pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
          }
          const bytes = new Uint8Array(pcm.buffer);
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          post({ type: "pcm", epoch: epoch, data: btoa(binary), rms: Math.sqrt(sum / Math.max(1, input.length)) });
        };
        // A processor only runs while it leads to the output. The silent gain in between means
        // nothing the microphone hears can ever reach the speaker.
        c.sink = c.ctx.createGain();
        c.sink.gain.value = 0;
        c.source.connect(c.node);
        c.node.connect(c.sink);
        c.sink.connect(c.ctx.destination);
        current = c;
        c.ctx.onstatechange = () => poll(c);
        const a = session();
        if (a) {
          c.watchesSession = true;
          a.onstatechange = () => poll(c);
        }
        c.beat = performance.now();
        c.watch = setInterval(() => { if (performance.now() - c.beat > BEAT_LIMIT) endCapture(c, "heartbeat");
          else if (c.initialMuteUntil && performance.now() >= c.initialMuteUntil) { c.initialMuteUntil = 0; poll(c); } }, 500);
        post({ type: "started", epoch: epoch, rate: c.ctx.sampleRate, device: track ? track.label : "", muted: track ? !!track.muted : false });
        poll(c);
      } catch (error) {
        closeCapture(c);
        if (wanted !== epoch) return;
        wanted = 0;
        post({ type: "error", epoch: epoch, message: (error && (error.name + ": " + error.message)) || String(error) });
      }
    }
    function zoneStop(epoch) {
      if (wanted !== epoch) return;
      wanted = 0;
      const c = current;
      current = null;
      if (!c) return;
      closeCapture(c);
      post({ type: "stopped", epoch: epoch });
    }
    """#

    public static var html: String {
        "<!doctype html><meta charset=\"utf-8\"><script>\n\(script)\n</script>"
    }
}
