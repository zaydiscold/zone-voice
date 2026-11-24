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
    public static let clipboardStorage = "Clipboard history is excluded from iPhone and Zone backups."
    public static let backupContents = "A Zone backup includes notes, dictation history, meetings with speaker names, voice prints and audio, a plain-text transcript copy, My words, saved handles and learned spellings."
    public static let voicePrivacy = "A Zone backup keeps each meeting’s speaker names and voice prints. Your separate voice setup stays on this iPhone and is left out of all backups. iPhone backups and Zone Link leave out all voice prints."
    public static let vocabularyPrivacy = "Zone includes your dictionary in the backups you choose in Backup and export. The shared word list stays out of ordinary iPhone backups. Zone Link does not send it to paired computers."

    public static let privacyBackups = "Zone keeps your notes and word count on this iPhone. Ordinary iPhone backups can include notes. Zone leaves its meeting library, including transcripts, speaker names and audio, out of those backups. In Backup and export you can save notes, dictation history, meetings, speaker names and meeting audio to a folder you choose in Files. The backup includes a readable text copy and each meeting’s voice prints, the patterns Zone uses to match speakers. Your separate voice setup stays on this iPhone and is excluded from both kinds of backup. Ordinary iPhone backups and Zone Link leave out all voice prints. If you choose iCloud Drive, Apple syncs it. Optional automatic backups update that folder while Zone is running and keep items you later delete from the app."
    public static let privacyHistory = "Zone excludes the dictation history file from ordinary iPhone backups. Zone also excludes the copy of recent notes and dictations that Messages reads, including copies from earlier versions. By default, your dictations stay until you delete them. You can choose 7 days, 30 days or Off. With history off, Zone discards a finished dictation but keeps interrupted text for you to use or delete. You can delete one dictation or clear the history. Clearing it also removes the files Zone kept to recover unreadable, imported or interrupted dictations, except text from a dictation still in progress. A shorter period or Off doesn’t remove those recovery files."
    public static let privacyComputers = "Zone Link is off until you pair your computer by scanning its code or pasting its link. Once paired, Zone sends dictations, notes and finished meeting transcripts with details such as dates, speaker names and timings. The computer also receives the iPhone name, an ID for this installation, and the Zone version and build. Audio stays out of the transfer. The connection is encrypted end to end. The iroh discovery service uses public device keys and relay addresses. If a direct connection fails, an n0 relay can see the network addresses and forward the encrypted data without reading your words. You can also send text you choose, or use Send by Flash to show it as codes for a computer’s camera without a network connection. Text you send this way, including a clipboard copy, stays on a computer that received it, even when you delete it here. Removing a send that is still waiting, or choosing Delete everything, keeps Zone from sending it, but a send already on its way can still arrive. The Sent list on this iPhone keeps any send still waiting and up to 20 delivered sends, shortened to their first 160 characters, until you remove them or choose Delete everything. When you delete an item yourself, Zone asks the computer to delete its copy at the next sync unless you chose Keep what I delete here. A dictation that ages out stays on the computer. Forgetting a computer or deleting Zone leaves the copies already there."
    public static let privacyWords = "Words and @handles you save are shared locally between Zone and its keyboard. With Learn from corrections on, replacing a selected word or correcting the last dictated word can teach Zone your spelling. You can turn learning off and edit the list in Settings. Zone backups include My words, saved handles and learned spellings. Opening the keyboard with Full Access also makes its kept words and correction choices available for backup. The shared dictionary stays out of ordinary iPhone backups and Zone Link. The keyboard’s own preferences can be backed up with your iPhone."
    public static let privacyControls = "You can turn off microphone access in Settings, Privacy & Security, Microphone. In Settings, Apps, Zone, Keyboards you can turn off Full Access or remove the keyboard. In Zone, Delete everything clears finished dictation history and the files kept to recover it, saved clipboard copies including kept ones, notes, meetings, listed recovery recordings, rewrites saved by earlier versions, the Sent list and any text still waiting to go to a computer. Waiting text won’t be sent, but a send already on its way can still arrive, and a computer keeps sent text it already received. Text from a dictation still in progress stays, so it isn’t lost. While a meeting is recording, Delete everything deletes nothing, so finish the meeting first. If Zone can’t remove dictation history or text waiting for a computer, it says so. Delete everything keeps My words, the keyboard’s learned spellings and tap data, settings, recording logs and separately saved diagnostic clips. Deleting the app removes its private library. Delete copies you exported outside Zone’s folder separately in Files. When you share a note, dictation or meeting transcript, you choose the destination in the iOS share sheet."

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

    /// The line under the History setting. History is left out of iPhone backups but is in Zone's
    /// own Backup and export, so it says both; "out of backups" alone contradicted that page.
    public static func historyFooter(_ names: [String]) -> String {
        let rest = "Text takes almost no space, so it stays until you delete it. Pick 7 or 30 days to clear old ones automatically, or Off to stop keeping them. A dictation that gets cut off is always saved. Notes are never touched."
        guard let who = who(names) else {
            return "Text only, never audio, kept on this iPhone. iPhone backups leave it out; Backup and export keeps it. \(rest)"
        }
        return "Text only, never audio, kept on this iPhone and sent to \(who), which \(names.count == 1 ? "keeps" : "keep") dictations after they are cleared here. iPhone backups leave it out; Backup and export keeps it. \(rest)"
    }

    /// The line under Settings > Your data. Computers are paired in Computers, so with one paired the
    /// line says where the text also goes instead of offering to pair.
    public static func yourDataFooter(_ names: [String]) -> String {
        guard let who = who(names) else {
            return "Stored on this iPhone. Back up to Files, or pair a computer in Settings > Computers."
        }
        return "Dictations, notes and meeting transcripts go to \(who). Back up your library and dictionary to Files. Manage computers in Settings > Computers."
    }

    /// The Privacy screen's paragraph about paired computers. Nil when there are none.
    public static func privacyParagraph(_ names: [String], keeping: [String] = []) -> String? {
        guard let who = who(names) else { return nil }
        return "You paired \(who). \(privacyDeletes(names, keeping: keeping))"
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

    /// Pairing sends text to a computer independently of the keyboard recognition route.
    public static func inviteClaim(sendsToComputer: Bool) -> String {
        sendsToComputer ? "I can send my words straight to my paired computer." : "I can dictate offline with the on-device model."
    }
}
