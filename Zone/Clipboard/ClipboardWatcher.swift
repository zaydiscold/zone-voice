// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZoneCore

@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// The board's change count. Metadata: reading it makes iOS ask nothing and reads no text.
    private let changeCount: () -> Int

    init(changeCount: @escaping () -> Int = { UIPasteboard.general.changeCount }) {
        self.changeCount = changeCount
    }

    /// A Save tap arrived: the token names the change it is pasting. Each tap keeps its own, so
    /// two taps whose text arrives in the reverse order are each judged by their own change.
    func noteTap() -> ClipboardPasteToken {
        ClipboardPasteToken(changeCount: changeCount())
    }

    /// The delivered provider carries its text and its privacy markers. Whether it is kept also
    /// depends on what Zone's keyboard recorded about the copy (`ClipboardCapture.keepDelivered`):
    /// with the filter enabled, a copy it saw made for a password, code or card field is not kept here either, nor is one
    /// made after it was last in such a field and before it looked anywhere else.
    func keepPasted(_ text: String, types: [String], token: ClipboardPasteToken, settings: AppSettings) -> ClipboardCapture.Outcome {
        guard settings.clipboardHistoryEnabled else { return .off }
        guard let history = ClipboardHistory.shared else { return .failed }
        return keep(text, types: types, token: token,
                    settings: .init(enabled: true, skipsSecrets: settings.clipboardSkipsSecrets),
                    history: history, seen: SharedClipboardSeenStore())
    }

    /// Judges one delivery against the board as it is now, by the token of the tap that started it.
    func keep(_ text: String, types: [String], token: ClipboardPasteToken, settings: ClipboardCapture.Settings,
              history: ClipboardHistory, seen: ClipboardSeenStore?) -> ClipboardCapture.Outcome {
        ClipboardCapture.keepDelivered(text, types: types, token: token, deliveredChangeCount: changeCount(),
                                       settings: settings, history: history, seen: seen)
    }
}

/// UIKit supplies the providers for the user's tap. This control reads no text from the general
/// board; it notes only the board's change count when the tap arrives.
struct SaveCopyControl: UIViewRepresentable {
    var saveImage: ((ClipboardImage?, [String], ClipboardPasteToken) -> Void)? = nil
    let save: (String, [String], ClipboardPasteToken) -> Void

    @MainActor final class Target: NSObject, UIPasteConfigurationSupporting {
        var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(acceptableTypeIdentifiers: ClipboardPasteText.acceptedTypes)
        var saveImage: ((ClipboardImage?, [String], ClipboardPasteToken) -> Void)?
        var save: (String, [String], ClipboardPasteToken) -> Void
        private let tap: @MainActor () -> ClipboardPasteToken

        init(tap: @escaping @MainActor () -> ClipboardPasteToken = { ClipboardWatcher.shared.noteTap() },
             save: @escaping (String, [String], ClipboardPasteToken) -> Void) {
            self.tap = tap
            self.save = save
        }

        func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
            itemProviders.contains { ClipboardPasteText.supports($0) || (saveImage != nil && $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)) }
        }

        func paste(itemProviders: [NSItemProvider]) {
            guard canPaste(itemProviders) else { return }
            let token = tap()
            let types = itemProviders.flatMap(\.registeredTypeIdentifiers)
            let imageOffered = saveImage != nil && types.contains { UTType($0)?.conforms(to: .image) == true }
            ClipboardPasteText.loadCopy(from: itemProviders, includeImages: imageOffered) { [weak self] value in
                Task { @MainActor in
                    switch value {
                    case .text(let text): self?.save(text, types, token)
                    case .image(let image): self?.saveImage?(image, types, token)
                    case nil:
                        if imageOffered { self?.saveImage?(nil, types, token) }
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Target {
        let target = Target(save: save)
        target.saveImage = saveImage
        return target
    }

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityLabel = "Paste"
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.save = save
        context.coordinator.saveImage = saveImage
    }
}

struct ClipboardWatch: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let settings: AppSettings
    @State private var automaticCapture: ClipboardCapture?

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            if scenePhase == .active { checkAutomatic() }
        }.task(id: AutoWatchState(phase: scenePhase, enabled: settings.clipboardHistoryEnabled && settings.clipboardAutomatic, filtered: settings.clipboardSkipsSecrets)) {
            guard scenePhase == .active, settings.clipboardHistoryEnabled, settings.clipboardAutomatic else {
                // The system paste-permission sheet can make the foreground app inactive.
                if scenePhase == .background || !settings.clipboardHistoryEnabled || !settings.clipboardAutomatic {
                    automaticCapture?.cancelAutomaticRead()
                }
                return
            }
            while !Task.isCancelled {
                checkAutomatic()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // What has aged out comes off the disk while Zone is open anyway.
            let history = ClipboardHistory.shared
            Task.detached(priority: .utility) { history?.purgeExpired() }
        }
    }

    private struct AutoWatchState: Equatable {
        let phase: ScenePhase
        let enabled: Bool
        let filtered: Bool
    }

    @MainActor private func checkAutomatic() {
        guard settings.clipboardHistoryEnabled, settings.clipboardAutomatic,
              UIApplication.shared.applicationState == .active else { return }
        if automaticCapture == nil, let history = ClipboardHistory.shared, let seen = SharedClipboardSeenStore() {
            automaticCapture = ClipboardCapture(source: SystemClipboard(), history: history, seen: seen)
        }
        automaticCapture?.captureAutomatically(route: .app, eligibility: {
            guard UIApplication.shared.applicationState != .background, settings.clipboardHistoryEnabled,
                  settings.clipboardAutomatic else { return nil }
            return .init(enabled: true, skipsSecrets: settings.clipboardSkipsSecrets, automatic: true)
        })
    }
}

/// What a result of keeping a copy reads as, in the app and in the shortcut's answer.
enum ClipboardCopyText {
    static func notKept(_ reason: ClipboardSkip) -> String {
        switch reason {
        case .own: return "That is already in Zone."
        case .concealed: return "Not kept: the app that copied it marked it private."
        case .privateField: return "Not kept: it may have been copied in a password, code or card field."
        case .code: return "Not kept: it looks like a code."
        case .card: return "Not kept: it looks like a card number."
        case .password: return "Not kept: it looks like a password."
        case .key: return "Not kept: it looks like an access key."
        case .tooLong: return "This copy exceeds the 1.5 MB clipboard history limit."
        case .empty: return "Nothing to keep: the clipboard has no text."
        }
    }

    /// "Not kept: 3 that looked like passwords or codes, 1 marked private by its app." or nil.
    static func tally(_ skips: [ClipboardSkip: Int]) -> String? {
        let secrets = skips.filter { $0.key.isSecretGuess }.values.reduce(0, +)
        let concealed = skips[.concealed, default: 0]
        let fields = skips[.privateField, default: 0]
        let long = skips[.tooLong, default: 0]
        var parts: [String] = []
        if secrets > 0 { parts.append("\(secrets) that looked like \(secrets == 1 ? "a password or code" : "passwords or codes")") }
        if concealed > 0 { parts.append("\(concealed) marked private by \(concealed == 1 ? "its app" : "their apps")") }
        if fields > 0 { parts.append("\(fields) that may have come from a password, code or card field") }
        if long > 0 { parts.append("\(long) too long") }
        guard !parts.isEmpty else { return nil }
        return "Not kept: " + parts.joined(separator: ", ") + "."
    }
}
