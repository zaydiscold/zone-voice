// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The privacy policy, inside the app (App Review 5.1.1(i) wants it reachable here as well
/// as from the App Store page).
struct PrivacyView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?

    /// Names of the paired computers. With any, the text of the library is on them too, and
    /// this screen says so.
    private var paired: [String] { link?.computers.map(\.name) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisplayText("Your words.\nYour control.", size: 34)
                // The details below are what App Review reads.
                Text("I don't collect any of your data. Speech recognition runs locally on your iPhone, so it works offline, on a plane, or anywhere without signal.")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(Zone.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Hairline().padding(.vertical, 4)
                Eyebrow("Details")
                // Matches the published policy; the download size and host
                // come from the model in use so they never drift from it.
                paragraph("What Zone collects", "Nothing. No account, no analytics, no crash reporting, no Zone servers. App Store privacy label: Data Not Collected. Send feedback writes an email in your own mail app, and you see all of it before you send.")
                if let computers = LinkCopy.privacyParagraph(paired, keeping: link?.computers.keepingNames ?? []) {
                    paragraph("Computers", computers)
                        .accessibilityIdentifier("privacy.computers")
                }
                paragraph("Your voice", "While standby is on, the mic stays open so keyboard dictation starts immediately, and iOS shows its orange mic indicator. Audio is processed only while you dictate, transcribed locally, and never uploaded. Text passes to the keyboard via a private App Group container and is cleared from that handoff once inserted or dismissed.")
                paragraph("Dictation history", "Zone stores dictation text (never audio) locally and excludes it from iPhone backups. By default it stays until you delete it, since plain text uses almost no space. You can switch retention to 7 days, 30 days, or Off in History; Off still rescues cut-off dictations until you copy or delete them. Notes are separate and unaffected." + (LinkCopy.privacyHistoryNote(paired).map { " " + $0 } ?? ""))
                paragraph("Notes and backups", "Notes, meetings, and stats stay on your iPhone. Backup and export saves notes, history, meetings, speaker names, and meeting audio to any folder in Files, including iCloud Drive. Automatic folder backups run only while Zone is open. iCloud Drive sync is handled by Apple, never a Zone server. Deleting Zone clears its internal library, while exported backups in Files remain until you delete them.")
                paragraph("Full Access", "iOS requires Full Access so the keyboard and main app can share text locally. The keyboard passes up to 64 characters before the cursor so Zone gets spacing, capitalization, and nearby names right, then reads the finished transcript back. The keyboard extension has no network permission and never connects to the internet.")
                paragraph("Autocorrect", "Revert an autocorrected word and the keyboard stops changing it. Tap positions on keys are stored locally as numeric averages with no text.")
                paragraph("iPhone vocabulary", "With Full Access, iOS exposes contact names, custom spellings, and text replacements to the keyboard. Zone caches a local copy in its private container (excluded from backups) so typing, swipe, and dictation can recognize them.")
                paragraph("Recording recovery", "During dictation, Zone streams audio to a temporary local file (excluded from backups) so a call or crash doesn't lose your words. Once transcribed and saved, the audio is deleted. Empty clips under 8 seconds are discarded immediately; longer failed clips stay retryable for 7 days.")
                paragraph("My words", "Custom words in My words guide dictation and prevent unwanted autocorrect. With Learn from corrections on, retyping a selected word or the last word of a dictation teaches Zone your spelling locally. Saved @ handles live in the same local list.")
                paragraph("Model downloads", downloadParagraph)
                paragraph("Your controls", "Revoke mic access in Settings → Privacy & Security → Microphone. Turn off Full Access or remove the keyboard in Settings → Apps → Zone → Keyboards. Delete notes and history inside Zone, or delete the app to wipe all local storage." + (LinkCopy.privacyControlsNote(paired).map { " " + $0 } ?? ""))
                paragraph("Watch and Messages", "The Watch app saves notes locally first and holds them until your iPhone confirms receipt. Watch input uses watchOS system dictation. The iMessage app reads recent notes and dictations from Zone's shared container and inserts whichever you tap into your draft without sending.")
                paragraph("License", "MIT licensed. Source release planned after beta.")
                Text("Questions: zayd@zayd.wtf").font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Privacy")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var downloadParagraph: String {
        let model = coordinator.selectedModel
        let first = model.needsDownload
            ? "Before your first dictation, Zone downloads its speech model, \(model.shortName) (about \(model.sizeLabel)), from \(model.downloadHost)."
            : "The speech model in use, \(model.shortName), is built into iOS, so there’s nothing to download."
        return first + " The speaker model for meetings also comes from Hugging Face (huggingface.co). Like any download, the request includes ordinary connection details such as your IP address, and nothing about you beyond that. Once you have a model, Zone works in airplane mode."
    }

    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
            Text(body).font(.body).foregroundStyle(Zone.muted(scheme))
        }
    }
}
