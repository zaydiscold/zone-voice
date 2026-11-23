// by zayd/cold @ zayd.wtf

import UIKit

/// Touch-down feedback for keys, as the system keyboard gives it: the input click (which follows
/// the user's Keyboard Clicks setting) and a light tap from the Taptic Engine. Haptics in a
/// keyboard extension need Full Access, and the app's Haptics setting can turn them off.
@MainActor
final class KeyFeedback {
    private weak var proxy: TextProxyActions?
    /// Mirrors `KeyboardPreferences.hapticsEnabled`, read from the shared store when the keyboard appears.
    var hapticsEnabled = true
    /// Refreshed on appearance; hasFullAccess performs a synchronous TCC preflight on device.
    var hasFullAccess = false
    private var generator: UIImpactFeedbackGenerator?
    /// The strip's and the mic's taps, one generator per style, kept while the keyboard is up.
    private var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    /// Count of haptics fired, for the debug log; the Simulator has no Taptic Engine to feel.
    private var fired = 0

    init(proxy: TextProxyActions) {
        self.proxy = proxy
    }

    func keyDown() {
        proxy?.playClick()
        guard hapticsEnabled, hasFullAccess else { return }
        let generator = self.generator ?? UIImpactFeedbackGenerator(style: .soft)
        self.generator = generator
        // The plain call: impactOccurred(intensity:) builds a feedback-parameters object on
        // every key (seen in the phone profile). The soft style is about as gentle as 0.7 light.
        generator.impactOccurred()
        // Keeps the engine warm for the next key, which arrives within a few hundred ms while typing.
        generator.prepare()
        #if DEBUG
        fired += 1
        KeyboardLog.typing.debug("haptic \(self.fired)")
        #endif
    }

    /// A tap for the mic and strip controls, behind the same cached Full Access and Haptics
    /// flags as the keys: no TCC preflight and no preferences decode per tap.
    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard hapticsEnabled, hasFullAccess else { return }
        let generator = impactGenerators[style] ?? UIImpactFeedbackGenerator(style: style)
        impactGenerators[style] = generator
        generator.impactOccurred()
    }

    /// Lets the Taptic Engine idle once the keyboard is gone.
    func release() {
        generator = nil
        impactGenerators = [:]
    }
}
