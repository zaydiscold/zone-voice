// by zayd/cold @ zayd.wtf

/// Describes the saved choice for a new recording. The model that actually finished an
/// individual take is recorded separately, after any fallbacks.
public enum KeyboardModelCopy {
    public static let neverAppleTitle = "Never use Apple’s speech model"

    public static func settingsNote(mode: KeyboardVoiceRoute.Mode, enabled: Bool, neverApple: Bool) -> String {
        guard enabled else {
            return "Dictate without opening Zone is off. The app handles new keyboard dictations. Turn this on to record from the keyboard when standby is off."
        }
        let selected: String
        switch mode {
        case .standard:
            selected = "Zone default tries Zone’s on-device model."
        case .webView:
            selected = "Fluid Speech Mini tries to transcribe recordings up to 40 seconds on this iPhone. Longer recordings and failed attempts use Zone default."
        case .computer:
            selected = "Zone Link GPU sends finished keyboard audio to your selected HTTPS server. If the server can’t finish, the keyboard tries Zone default on iPhone. Retrying saved audio stays on iPhone."
        }
        let fallback = neverApple
            ? "Apple’s speech model is off."
            : "Zone default can fall back to Apple’s on-device speech model if available."
        return "On iOS 26 or later, the keyboard can record first with standby off, even if no speech model is ready. " + selected + " " + fallback +
            " If the keyboard can’t finish the saved recording, it asks Zone to finish. You can also open Zone yourself."
    }

    public static func privacyNote(mode: KeyboardVoiceRoute.Mode, enabled: Bool, neverApple: Bool) -> String {
        let capture = enabled ? " Audio is captured in a web view on this iPhone." : ""
        return settingsNote(mode: mode, enabled: enabled, neverApple: neverApple)
            + capture + " You can delete saved keyboard recordings from recovery."
    }
}
