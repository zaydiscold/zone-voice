// by zayd/cold @ zayd.wtf

import Foundation
import OSLog
import Speech
import UIKit
import ZoneCore

/// Apple's speech asset for dictations the keyboard records by itself (Settings > Zone keyboard >
/// Dictate without opening Zone, on by default). The asset belongs to the system and is shared.
///
/// The keyboard tries `SpeechTranscriber` first and `DictationTranscriber` second
/// (`LocalSpeech`), so the same two are checked here in that order: an iPhone with no
/// `SpeechTranscriber` (the A13 models) or whose asset will not install still gets the route.
///
/// The keyboard records by itself only once the app has found the asset installed
/// (`SharedStore.keyboardSpeechReady`, read by `KeyboardCapture.route`): without it a tap would
/// record, then lose the words to a download that cannot finish inside a keyboard. Until then
/// the tap opens Zone, as it always could.
enum KeyboardSpeechAssets {
    /// The keyboard's own recognition needs `SpeechTranscriber`, which arrived in iOS 26.
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Whether someone may use the route: the switch is on and the Zone keyboard has been seen
    /// with Full Access. Someone who never types with the keyboard never downloads the asset.
    static func shouldFetch(setupDone: Bool, enabled: Bool, fullAccess: Bool, active: Bool, unlocked: Bool) -> Bool {
        setupDone && enabled && fullAccess && active && unlocked
    }

    /// Check again after each suspension before asking iOS to start a transfer.
    @MainActor
    static func refresh(store: SharedStore, downloadRequested: Bool, canFetch: @MainActor () -> Bool) async {
        guard #available(iOS 26.0, *) else {
            store.keyboardSpeechReady = false
            return
        }
        guard !Task.isCancelled, canFetch() else { return }
        // The same modules and locale as the keyboard's `LocalSpeech`, in its order.
        let modules = await candidates()
        for candidate in modules where await AssetInventory.status(forModules: [candidate.module]) == .installed {
            store.keyboardSpeechReady = true
            return
        }
        store.keyboardSpeechReady = false
        guard downloadRequested, !Task.isCancelled, canFetch(), !store.keyboardPreferences.neverAppleSpeech else { return }
        for candidate in modules {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [candidate.module]) {
                    guard downloadRequested, !Task.isCancelled, canFetch(), !store.keyboardPreferences.neverAppleSpeech else { return }
                    try await request.downloadAndInstall()
                }
                let installed = await AssetInventory.status(forModules: [candidate.module]) == .installed
                Journal.log("keyboardSpeechAsset", ["installed": String(installed), "module": candidate.name])
                if installed {
                    store.keyboardSpeechReady = true
                    return
                }
            } catch {
                Journal.log("keyboardSpeechAsset", ["installed": "false", "module": candidate.name,
                                                    "error": JournalFormat.error(error)])
            }
        }
    }

    /// Apple's recognizers that support English on this iPhone, the preferred one first.
    @available(iOS 26.0, *)
    private static func candidates() async -> [(name: String, module: any SpeechModule)] {
        let english = Locale(identifier: "en-US")
        var found: [(name: String, module: any SpeechModule)] = []
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: english) {
            found.append(("speech", AppleSpeechEngine.makeModule(.speech, locale: locale).module))
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: english) {
            found.append(("dictation", AppleSpeechEngine.makeModule(.dictation, locale: locale).module))
        }
        return found
    }
}
