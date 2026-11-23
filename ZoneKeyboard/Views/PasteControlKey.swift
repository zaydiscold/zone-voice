// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives what Apple's paste button hands over. Reading `UIPasteboard` directly makes iOS ask
/// "Allow Paste" each time; a tap on the system's own button is the permission.
@MainActor final class PasteTarget: NSObject, UIPasteConfigurationSupporting {
    var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
    /// The host's input session, read when the tap arrives and again when the text does.
    private let session: () -> String?
    private let insert: (String) -> Void

    init(session: @escaping () -> String?, insert: @escaping (String) -> Void) {
        self.session = session
        self.insert = insert
    }

    func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: String.self) }
    }

    func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
        let tapped = session()
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text, !text.isEmpty else { return }
            Task { @MainActor in
                // The clipboard arrives a moment after the tap. If the person moved to another
                // field meanwhile, the text belongs to the field they left: drop it.
                guard let self, self.session() == tapped else { return }
                self.insert(text)
            }
        }
    }
}

/// Apple's paste button, drawn as one of the strip's keys.
struct PasteControlKey: UIViewRepresentable {
    let theme: KeyboardTheme
    let session: () -> String?
    let insert: (String) -> Void

    func makeCoordinator() -> PasteTarget { PasteTarget(session: session, insert: insert) }

    func makeUIView(context: Context) -> UIPasteControl {
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityLabel = "Paste"
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        // The control cannot be restyled in place; the strip rebuilds it when the theme flips
        // (`.id(theme.isDark)` where it is used).
    }

    private var configuration: UIPasteControl.Configuration {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = KeyboardTheme.cornerRadius
        configuration.baseBackgroundColor = UIColor(theme.key)
        configuration.baseForegroundColor = UIColor(theme.text)
        return configuration
    }
}
