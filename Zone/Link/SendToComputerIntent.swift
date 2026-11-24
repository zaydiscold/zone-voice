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
    static let description = IntentDescription("Sends text to one paired computer. Choose which computer when more than one can receive it. Put Get Clipboard before it to send what you copied. Zone stays in the background.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What should Zone send to your computer?")
    var text: String

    @Parameter(title: "Computer")
    var computer: ShortcutComputer?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$computer)")
    }

    /// iOS gives a background intent about 30 seconds. The connection gives up on an
    /// unreachable computer after 20, so this is long enough to know either way.
    private static let waitSeconds: TimeInterval = 24

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let choices = await ShortcutComputer.Query().suggestedEntities()
        var chosen = computer
        if chosen == nil, choices.count > 1 {
            chosen = try await $computer.requestDisambiguation(among: choices, dialog: "Which computer should receive this text?")
        }
        return .result(dialog: IntentDialog(stringLiteral: try await Self.send(text, computerID: chosen?.id)))
    }

    /// Everything the intent does, and the sentence it answers with. Development builds also
    /// call this from `-zoneLinkClipShortcut`, since the simulator has no Shortcuts app.
    @MainActor
    static func send(_ text: String, computerID: String? = nil) async throws -> String {
        // What's New must never open on a visit a Shortcut began.
        AppEntry.noteAutomation("clipShortcut")
        guard let link = LinkCoordinator.shared else {
            // The app's coordinator is not up (it always should be). Queue it for the next sync.
            return try queueOnly(text, computerID: computerID)
        }
        guard link.isPaired else {
            throw DictationCoordinator.ShortcutFailure(message: "Pair a computer first, in Zone under Settings > Computers.")
        }
        let clip: LinkClip
        do {
            let target = try destination(computerID, from: link.computers)
            clip = try link.sendClip(text, source: .shortcut, to: target.endpointID)
        } catch let failure as LinkClipFailure {
            throw DictationCoordinator.ShortcutFailure(message: failure.plainMessage)
        }
        // `sendClip` returned, so the clip was saved; nil here means it was removed while the
        // shortcut waited (a removed row, or Delete everything).
        guard let settled = await link.clipSettled(clip.id, within: waitSeconds) else {
            return LinkClipCopy.removed
        }
        return LinkClipCopy.outcome(settled, names: link.computerNames)
    }

    static func destination(_ id: String?, from computers: [PairedComputer]) throws -> PairedComputer {
        let enabled = computers.filter { !$0.isPaused }
        if let id, let match = computers.first(where: { $0.endpointID == id }) {
            guard !match.isPaused else {
                throw DictationCoordinator.ShortcutFailure(message: "In Zone, open Settings > Computers and turn on sending to \(match.name).")
            }
            return match
        }
        if id == nil, enabled.count == 1 { return enabled[0] }
        throw DictationCoordinator.ShortcutFailure(message: enabled.isEmpty
            ? "Open Settings > Computers in Zone and turn on sending to a computer."
            : "Choose an available computer for this shortcut.")
    }

    /// Writes the clip to the outbox without sending. Zone sends it the next time it syncs.
    private static func queueOnly(_ text: String, computerID: String?) throws -> String {
        let store = LinkCoordinator.makeStore()
        let computers = store.computers()
        guard !computers.isEmpty else {
            throw DictationCoordinator.ShortcutFailure(message: "Pair a computer first, in Zone under Settings > Computers.")
        }
        let target = try destination(computerID, from: computers)
        do {
            try store.clips.add(text, source: .shortcut, to: [target.endpointID])
        } catch let failure as LinkClipFailure {
            throw DictationCoordinator.ShortcutFailure(message: failure.plainMessage)
        }
        return "Saved. Zone sends it to \(target.name) the next time it syncs."
    }
}

struct ShortcutComputer: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Computer")
    static let defaultQuery = Query()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    struct Query: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [ShortcutComputer] {
            LinkCoordinator.makeStore().computers().filter { identifiers.contains($0.endpointID) }.map {
                ShortcutComputer(id: $0.endpointID, name: $0.name)
            }
        }

        func suggestedEntities() async -> [ShortcutComputer] {
            LinkCoordinator.makeStore().computers().filter { !$0.isPaused }.map {
                ShortcutComputer(id: $0.endpointID, name: $0.name)
            }
        }
    }
}
