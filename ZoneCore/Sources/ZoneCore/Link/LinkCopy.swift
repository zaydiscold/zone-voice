// by zayd/cold @ zayd.wtf

import Foundation

/// What the app says about where words go once a computer is paired.
///
/// Without a paired computer the text of dictations, notes and meetings stays on the phone, and
/// the app says so. With one, that text is on the computer too, and a delete on the phone only
/// reaches the computer at the next sync. Every function here takes the names of the paired
/// computers and returns nil (or the unchanged sentence) when there are none, so each screen
/// keeps its plain wording until pairing makes it untrue. A computer whose "Keep what I delete
/// here" switch is on is not told about deletes, so the sentences about deleting also take the
/// names of those (`keeping`) and say they keep their copies.
public enum LinkCopy {
    /// "frostbyte", "frostbyte and studio", or "your paired computers".
    public static func who(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "your paired computers"
        }
    }

    /// The name of the per-computer switch that spares a computer the phone's deletes.
    public static let keepSwitch = "Keep what I delete here"

    /// Under that switch, for one computer: what a delete on the phone does there now.
    public static func keepFooter(_ name: String, on: Bool) -> String {
        on ? "\(name) keeps its copy of anything you delete on this iPhone while this is on. Turning it off later does not reach back: those copies stay, and only what you delete after that is deleted there."
            : "Deleting a dictation, note or meeting here also deletes the copy on \(name) the next time Zone syncs. Turn on \(keepSwitch) and \(name) keeps its copy instead."
    }

    /// The paired computers split by what a delete on the phone does there, and how to name
    /// each group in a sentence. A group of three or more is not listed by name.
    struct DeleteGroups {
        var deleting: [String]
        var keepers: [String]
        var deleteWho: String?
        var keepWho: String?

        init(_ names: [String], keeping: [String]) {
            var left = keeping
            var deleting: [String] = [], keepers: [String] = []
            for name in names {
                if let index = left.firstIndex(of: name) {
                    left.remove(at: index)
                    keepers.append(name)
                } else {
                    deleting.append(name)
                }
            }
            self.deleting = deleting
            self.keepers = keepers
            deleteWho = deleting.count > 2 && !keepers.isEmpty ? "your other computers" : LinkCopy.who(deleting)
            if keepers.count > 2, !deleting.isEmpty {
                keepWho = deleting.count > 2 ? "the computers set to keep what you delete" : "your other computers"
            } else {
                keepWho = LinkCopy.who(keepers)
            }
        }
    }

    private static func capitalized(_ who: String) -> String { who.prefix(1).uppercased() + who.dropFirst() }

    /// Added to a confirmation before a delete the person asked for: one dictation, a range,
    /// everything, a note, a meeting. Computers are told to delete too, except the ones in
    /// `keeping` (their "Keep what I delete here" switch is on), which keep their copies.
    public static func deleteNote(_ names: [String], keeping: [String] = [], what: String = "copies") -> String? {
        guard !names.isEmpty else { return nil }
        func theirs(_ count: Int) -> String {
            what == "copies" ? (count == 1 ? "its copies" : "their copies") : (count == 1 ? "its \(what)" : "their \(what)")
        }
        let groups = DeleteGroups(names, keeping: keeping)
        var parts: [String] = []
        if let who = groups.deleteWho {
            parts.append("\(capitalized(who)) \(groups.deleting.count == 1 ? "deletes" : "delete") \(theirs(groups.deleting.count)) the next time Zone syncs.")
        }
        if let who = groups.keepWho {
            parts.append("\(capitalized(who)) \(groups.keepers.count == 1 ? "keeps" : "keep") \(theirs(groups.keepers.count)).")
        }
        return parts.joined(separator: " ")
    }

    /// Added where the phone drops dictations by age (a shorter History setting): the computer
    /// is the long-term copy and is never told to delete those.
    public static func agedOutNote(_ names: [String]) -> String? {
        guard let who = who(names) else { return nil }
        return "Copies already on \(who) stay there."
    }

    /// The line under the History setting.
    public static func historyFooter(_ names: [String]) -> String {
        let rest = "Text takes almost no space, so it stays until you delete it. Pick 7 or 30 days to clear old ones automatically, or Off to stop keeping them. A dictation that gets cut off is always saved. Notes are never touched."
        guard let who = who(names) else {
            return "Text only, never audio, kept on this iPhone and out of backups. \(rest)"
        }
        return "Text only, never audio, kept on this iPhone and out of backups, and sent to \(who), which \(names.count == 1 ? "keeps" : "keep") dictations after they are cleared here. \(rest)"
    }

    /// The line under Settings > Your data. Computers are paired in Setup, so with one paired the
    /// line says where the text also goes instead of offering to pair.
    public static func yourDataFooter(_ names: [String]) -> String {
        guard let who = who(names) else {
            return "Stored on this iPhone. Back up to Files, or pair a computer in Setup."
        }
        return "Stored on this iPhone and sent to \(who). Back up to Files, or manage computers in Setup."
    }

    /// The Privacy screen's paragraph about paired computers. Nil when there are none.
    public static func privacyParagraph(_ names: [String], keeping: [String] = []) -> String? {
        guard let who = who(names) else { return nil }
        let one = names.count == 1
        return "You paired \(who). Zone sends \(one ? "it" : "them") the text of your dictations, notes and meeting transcripts, and new ones follow a few seconds after you make them. Audio is never sent. The text is encrypted from this iPhone to the computer. When the two cannot reach each other directly, a relay run by the makers of iroh passes the encrypted data along: it can see that this iPhone and the computer are talking and their network addresses, not your words. Send by Flash uses no network at all. Zone has no server of its own in any of this. \(privacyDeletes(names, keeping: keeping)) Forgetting a computer in Settings > Computers, or deleting Zone, stops the sending and leaves what the computer already has."
    }

    /// The Privacy paragraph's sentences about what a delete on the phone does on the computers.
    static func privacyDeletes(_ names: [String], keeping: [String]) -> String {
        let groups = DeleteGroups(names, keeping: keeping)
        let aged = "dictations that only age out of History stay on the computer"
        guard let keepWho = groups.keepWho else {
            return "Deleting something here tells the computer to delete its copy the next time Zone syncs; \(aged)."
        }
        let one = groups.keepers.count == 1
        let kept = "You turned on \(keepSwitch) for \(keepWho), so deleting something here leaves \(one ? "its copy" : "their copies") there."
        guard let deleteWho = groups.deleteWho else {
            return "\(kept) Dictations that only age out of History stay on the computer too."
        }
        return "Deleting something here tells \(deleteWho) to delete \(groups.deleting.count == 1 ? "its copy" : "their copies") the next time Zone syncs. \(kept) \(capitalized(aged))."
    }

    /// Added to the Privacy screen's history paragraph.
    public static func privacyHistoryNote(_ names: [String]) -> String? {
        guard let who = who(names) else { return nil }
        return "While \(who) \(names.count == 1 ? "is" : "are") paired, this text is sent there too (see Computers)."
    }

    /// Added to the Privacy screen's list of controls.
    public static func privacyControlsNote(_ names: [String]) -> String? {
        guard let who = who(names) else { return nil }
        return "Deleting Zone does not remove what is already on \(who): delete it on the computer."
    }

    /// The sentence after the pitch when Zone is shared with a friend. "Nothing you say leaves
    /// your phone" is true until the person sharing has chosen to send their words to a computer.
    public static func inviteClaim(sendsToComputer: Bool) -> String {
        sendsToComputer ? "Your voice is turned into text on the phone itself." : "Nothing you say leaves your phone."
    }
}
