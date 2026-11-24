// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZoneCore

/// Clipboard history's part in a paste. `tap` runs when the tap arrives and binds the paste to
/// the board change it was made on (nil: nothing is kept, as with history off or no Full
/// Access); `keep` gets the delivered text with that same token. Inserting the text never
/// depends on either.
struct PasteSaving {
    let tap: @MainActor () -> ClipboardPasteToken?
    var image: (@MainActor (ClipboardImage?, [String], ClipboardPasteToken?) -> Void)? = nil
    let keep: @MainActor (String, [String], ClipboardPasteToken) -> Void
}

/// Receives what Apple's paste button hands over. Reading `UIPasteboard` directly makes iOS ask
/// "Allow Paste" each time; a tap on the system's own button is the permission.
@MainActor final class PasteTarget: NSObject, UIPasteConfigurationSupporting {
    var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(acceptableTypeIdentifiers: ClipboardPasteText.acceptedTypes)
    /// The host's input session, read when the tap arrives and again when the text does.
    private let session: () -> String?
    private let saving: PasteSaving?
    private let insert: (String) -> Void

    init(session: @escaping () -> String?, saving: PasteSaving? = nil, insert: @escaping (String) -> Void) {
        self.session = session
        self.saving = saving
        self.insert = insert
    }

    func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { ClipboardPasteText.supports($0) || (saving?.image != nil && $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)) }
    }

    func paste(itemProviders: [NSItemProvider]) {
        guard canPaste(itemProviders) else { return }
        let tapped = session()
        let token = saving?.tap()
        let types = itemProviders.flatMap(\.registeredTypeIdentifiers)
        let imageOffered = saving?.image != nil && types.contains { UTType($0)?.conforms(to: .image) == true }
        ClipboardPasteText.loadCopy(from: itemProviders, includeImages: imageOffered && token != nil) { [weak self] value in
            Task { @MainActor in
                guard let self, self.session() == tapped else { return }
                switch value {
                case .text(let text):
                    self.insert(text)
                    if let token { self.saving?.keep(text, types, token) }
                case .image(let image): self.saving?.image?(image, types, token)
                case nil:
                    if imageOffered { self.saving?.image?(nil, types, token) }
                }
            }
        }
    }
}

/// Shared appearance for the grid and the strip. UIKit owns the glyph and press tracking.
@MainActor final class KeyboardPasteControl: UIPasteControl {
    var gridOwnsPoint: ((CGPoint) -> Bool)?
    private let faceColor: UIColor
    private let downColor: UIColor
    private let surface: String

    init(theme: KeyboardTheme, target: PasteTarget, surface: String) {
        self.surface = surface
        faceColor = UIColor(theme.key)
        downColor = UIColor(theme.pressedKey)
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = KeyboardTheme.cornerRadius
        configuration.baseBackgroundColor = faceColor
        configuration.baseForegroundColor = UIColor(theme.text)
        super.init(configuration: configuration)
        self.target = target
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        // UIKit dims the entire button face when the clipboard is empty. Give it the same
        // underlay as the other keys so the disabled glyph can dim without the cap going dark.
        backgroundColor = faceColor
        layer.cornerCurve = .continuous
        layer.cornerRadius = KeyboardTheme.cornerRadius
        accessibilityLabel = "Paste"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        logState(window == nil ? "detached" : "attached")
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { logState("availability") } }
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? downColor : faceColor
            if isHighlighted != oldValue { logState("highlight") }
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        gridOwnsPoint?(point) ?? super.point(inside: point, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // UIKit clears the highlight on drag-out, but UIPasteControl can still paste on an
        // outside lift. Cancel those touches before UIKit runs the native paste action.
        let inside = Set(touches.filter { point(inside: $0.location(in: self), with: event) })
        let outside = touches.subtracting(inside)
        if !outside.isEmpty { touchesCancelled(outside, with: event) }
        if !inside.isEmpty { super.touchesEnded(inside, with: event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        isHighlighted = false
    }

    private func logState(_ event: String) {
        KeyboardLog.typing.info("Paste \(self.surface, privacy: .public) \(event, privacy: .public): frame=\(NSCoder.string(for: self.frame), privacy: .public) dark=\(self.overrideUserInterfaceStyle == .dark, privacy: .public) enabled=\(self.isEnabled, privacy: .public) highlighted=\(self.isHighlighted, privacy: .public)")
    }
}

/// Apple's paste button, drawn as one of the strip's keys.
struct PasteControlKey: UIViewRepresentable {
    let theme: KeyboardTheme
    let session: () -> String?
    var saving: PasteSaving? = nil
    let insert: (String) -> Void

    func makeCoordinator() -> PasteTarget { PasteTarget(session: session, saving: saving, insert: insert) }

    func makeUIView(context: Context) -> UIPasteControl {
        KeyboardPasteControl(theme: theme, target: context.coordinator, surface: "strip")
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        // The control cannot be restyled in place; the strip rebuilds it when the theme flips
        // (`.id(theme.isDark)` where it is used).
    }
}
