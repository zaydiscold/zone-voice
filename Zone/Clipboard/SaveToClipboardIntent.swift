// by zayd/cold @ zayd.wtf

import AppIntents
import UIKit
import Foundation
import ZoneCore

/// "Save to Zone Clipboard": text in, and it is in Zone's clipboard history.
///
/// In Shortcuts, Get Clipboard followed by this keeps what was just copied with one press, from
/// the Action Button, Back Tap, a Home Screen icon or the Shortcuts control in Control Center.
/// Shortcuts supplies the text and manages its own permissions.
/// As a personal automation ("When Safari is closed", Run Immediately) it keeps the copy made
/// in an app the moment that app is left, with no press at all.
struct SaveToClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Save to Zone Clipboard"
    static let description = IntentDescription("Keeps text you pass to Zone. Get Clipboard supplies plain text without its source app’s privacy marks.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What should Zone keep?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) to Zone's clipboard history")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try Self.save(text)))
    }

    /// Everything the intent does, and the sentence it answers with. Development builds also call
    /// this from `-zoneClipboardShortcut`, since the simulator has no Shortcuts app.
    @MainActor
    static func save(_ text: String) throws -> String {
        // What's New must never open on a visit a Shortcut began.
        AppEntry.noteAutomation("clipboardShortcut")
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "zone.settings.clipboardHistory") else {
            throw DictationCoordinator.ShortcutFailure(message: "Clipboard history is off. Turn it on in Zone, under History, then Clipboard.")
        }
        guard let history = ClipboardHistory.shared else {
            throw DictationCoordinator.ShortcutFailure(message: "Zone could not reach its storage. Open Zone and try again.")
        }
        let skipsSecrets = defaults.object(forKey: "zone.settings.clipboardSkipsSecrets") as? Bool ?? false
        switch history.add(text, route: .shortcut, skipsSecrets: skipsSecrets) {
        case .saved: return "Saved to Zone."
        case .alreadySaved: return "Already in Zone."
        case .skipped(let reason): return ClipboardCopyText.notKept(reason)
        case .failed:
            throw DictationCoordinator.ShortcutFailure(message: "Zone could not save this clipboard text. Unlock your iPhone and try again.")
        }
    }
}

#if DEBUG
/// Launch arguments for clipboard history on a simulator:
/// `-zoneClipboardSeed "first|second"` keeps those texts (oldest first) before the first screen,
/// `-zoneClipboardClear` empties the list and `-zoneClipboardShortcut "text"` exercises the intent.
enum ClipboardDebug {
    @MainActor static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let requested = ["-zoneClipboardClear", "-zoneClipboardSeed", "-zoneClipboardShortcut"].filter(arguments.contains)
        guard let history = ClipboardHistory.shared else {
            // A build without entitlements (CODE_SIGNING_ALLOWED=NO) has no App Group, so there is
            // no store to seed. Say so: otherwise every seeded UI test fails later as "not found".
            if !requested.isEmpty {
                NSLog("ClipboardDebug: %@ ignored, the App Group %@ is out of reach. Sign simulator builds with CODE_SIGN_IDENTITY=- so the entitlements are kept.",
                      requested.joined(separator: " "), ZoneContract.appGroup)
            }
            return
        }
        if arguments.contains("-zoneClipboardClear") {
            history.deleteAll()
            // Whatever the simulator's clipboard holds is counted as dealt with, so a test starts
            // from its own copies and iOS has no reason to ask anything. The counter reads nothing.
            SharedClipboardSeenStore()?.seenChangeCount = SystemClipboard().changeCount
        }
        if arguments.contains("-zoneClipboardImage") {
            UIPasteboard.general.image = UIImage(systemName: "leaf.fill")?.withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
        }
        if let seed = value("-zoneClipboardSeed") {
            let texts = seed.split(separator: "|").map(String.init)
            for (index, text) in texts.enumerated() {
                // A minute apart, so the order is the order given.
                history.add(text, route: .pasteKey, skipsSecrets: false,
                            now: Date().addingTimeInterval(TimeInterval(index - texts.count) * 60))
            }
        }
        if let text = value("-zoneClipboardShortcut") {
            let answer = (try? SaveToClipboardIntent.save(text)) ?? "failed"
            print("zoneClipboardShortcut: \(answer)")
        }
    }
}
#endif
