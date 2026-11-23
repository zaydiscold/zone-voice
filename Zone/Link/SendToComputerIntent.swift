// by zayd/cold @ zayd.wtf

import AppIntents
import Foundation
import ZoneCore

/// "Send to Computer": text in, and it is on the paired computers a moment later.
///
/// In Shortcuts, Get Clipboard followed by this sends what was copied with one press, from the
/// Action Button, Back Tap, a Home Screen icon or the Shortcuts control in Control Center, and
/// Shortcuts reads the clipboard without the paste question. Zone does not open: the intent
/// runs in the app in the background, queues the clip and waits for the computers to
/// acknowledge it. One that cannot be reached in that time keeps the clip queued for the next
/// sync, and the answer says so.
struct SendToComputerIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Computer"
    static let description = IntentDescription("Sends text to the computers you paired with Zone, ready to paste there. Put Get Clipboard before it to send what you copied. Zone stays in the background.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What should Zone send to your computer?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to my computer")
    }

    /// iOS gives a background intent about 30 seconds. The connection gives up on an
    /// unreachable computer after 20, so this is long enough to know either way.
    private static let waitSeconds: TimeInterval = 24

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await Self.send(text)))
    }

    /// Everything the intent does, and the sentence it answers with. Development builds also
    /// call this from `-zoneLinkClipShortcut`, since the simulator has no Shortcuts app.
    @MainActor
    static func send(_ text: String) async throws -> String {
        // What's New must never open on a visit a Shortcut began.
        AppEntry.noteAutomation("clipShortcut")
        guard let link = LinkCoordinator.shared else {
            // The app's coordinator is not up (it always should be). Queue it for the next sync.
            return try queueOnly(text)
        }
        guard link.isPaired else {
            throw DictationCoordinator.ShortcutFailure(message: "Pair a computer first, in Zone under Settings > Computers.")
        }
        let clip: LinkClip
        do {
            clip = try link.sendClip(text, source: .shortcut)
        } catch let failure as LinkClipFailure {
            throw DictationCoordinator.ShortcutFailure(message: failure.plainMessage)
        }
        guard let settled = await link.clipSettled(clip.id, within: waitSeconds) else {
            throw DictationCoordinator.ShortcutFailure(message: "Zone could not save that. Unlock your iPhone and try again.")
        }
        return LinkClipCopy.outcome(settled, names: link.computerNames)
    }

    /// Writes the clip to the outbox without sending. Zone sends it the next time it syncs.
    private static func queueOnly(_ text: String) throws -> String {
        let store = LinkCoordinator.makeStore()
        let targets = store.computers().filter { !$0.isPaused }
        guard !store.computers().isEmpty else {
            throw DictationCoordinator.ShortcutFailure(message: "Pair a computer first, in Zone under Settings > Computers.")
        }
        do {
            try store.clips.add(text, source: .shortcut, to: targets.map(\.endpointID))
        } catch let failure as LinkClipFailure {
            throw DictationCoordinator.ShortcutFailure(message: failure.plainMessage)
        }
        return "Saved. Zone sends it to \(LinkClipCopy.list(targets.map(\.name))) the next time it syncs."
    }
}
