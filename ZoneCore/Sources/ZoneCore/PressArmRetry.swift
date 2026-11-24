// by zayd/cold @ zayd.wtf

import Foundation

/// A press (the Action Button, a Control Center control, a Shortcut) that has to switch the
/// microphone on from the background, and is refused by iOS on the first try.
///
/// Zayd's phone, November 12 to 20: of 41 such presses with Zone off, 14 were refused. In 12 the
/// audio session activated and `AVAudioEngine.start` then failed with `what` (2003329396); in 2
/// activation itself failed with `!act` (561015905) with no call or Siri running. On the
/// phone's own microphone, every time the person pressed again within 2 to 13 seconds the same
/// start worked (4 of 4), with nothing else changed. So the press tries again itself, inside
/// the same intent, before it gives up and says "press again".
///
/// In the car the same error repeated four times in nine seconds (November 19, CarAudio
/// route), so a press there is not retried: it would only delay the answer.
public enum PressArmRetry {
    /// Waits before the second, third and fourth try: 2.4 s in all, past the 1.8 s after which
    /// a second press was seen to work.
    public static let pauses: [Duration] = [.milliseconds(400), .milliseconds(800), .milliseconds(1200)]

    /// `AVAudioEngine.start` refused from the background ("what").
    public static let engineStartRefused = 2_003_329_396
    /// `AVAudioSession.setActive` refused as busy ("!act").
    public static let sessionBusy = 561_015_905

    /// Whether another try inside the same press is worth its wait.
    public static func worthRetrying(domain: String, code: Int, inFront: Bool, carPlay: Bool) -> Bool {
        // In front the microphone starts or it does not: there is no background grant to wait for.
        guard !inFront, !carPlay else { return false }
        switch (domain, code) {
        case ("com.apple.coreaudio.avfaudio", engineStartRefused), (NSOSStatusErrorDomain, sessionBusy): return true
        default: return false
        }
    }
}
