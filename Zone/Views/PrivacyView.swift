// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The privacy policy, inside the app (App Review 5.1.1(i) wants it reachable here as well
/// as from the App Store page).
struct PrivacyView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var recognitionMode = KeyboardVoiceRoute.Mode.standard
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?

    /// Names of the paired computers. With any, the text of the library is on them too, and
    /// this screen says so.
    private var paired: [String] { link?.computers.map(\.name) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisplayText("Your words.\nYour control.", size: 34)
                Text("I don’t collect your dictations. After the speech model is downloaded, you can dictate on your iPhone without a signal.")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(Zone.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Hairline().padding(.vertical, 4)
                Eyebrow("Details")
                paragraph("What Zone collects", "Zone has no account, analytics service, crash reporting service or servers of its own. The App Store label is Data Not Collected. Send feedback opens a draft in your mail app. By default it includes the Zone version and build, iPhone model, iOS version and speech model. You can leave those details out and read the whole email before you send it.")
                paragraph("Your voice", "With standby on, the Zone app keeps the microphone open in the background. iOS shows its microphone indicator. Between recordings Zone discards the sound. With standby on, the app transcribes your words on this iPhone and passes the text back through Zone’s shared storage. While the handoff is waiting, the text in shared preferences is eligible for iPhone backup. Zone clears the handoff after insertion or dismissal. Meetings can keep recording when you lock the phone.")
                paragraph("Keyboard recording", KeyboardModelCopy.privacyNote(
                    mode: recognitionMode, enabled: settings.dictatesInKeyboard,
                    neverApple: settings.neverAppleSpeech))
                paragraph("Optional keyboard recognition", "Fluid Speech Mini in WebKit downloads its model when you ask and processes speech on iPhone. Zone Link GPU sends each finished keyboard recording and the configured model name to your saved provider. Its operator controls how that recording is handled. Your keyboard applies personal vocabulary and writing preferences on this device. Select Zone default to stop sending recordings.")
                paragraph("Notes and backups", LinkCopy.privacyBackups)
                paragraph("Dictation history", LinkCopy.privacyHistory)
                paragraph("Clipboard history", "Clipboard history is off by default. You can turn it on in History or Settings. Zone then keeps text and images when you tap Paste in Zone or its keyboard. The Save to Zone Clipboard shortcut also accepts text. If you also turn on Automatically save copies, Zone saves current text and images while the app or its keyboard is visible. iOS may ask for paste permission. Copies replaced while both are closed are unavailable. With automatic saving off, the keyboard checks only whether a copy is available. The keyboard needs Full Access to save or show copies. Passwords and API keys are kept by default, including copies marked private or temporary by a password manager. With the filter off, this includes copies made in or just after a password, code or card field. Only turning on the filter skips sensitive copies. The filter uses the field labels and private markers other apps provide. If the clipboard changes during a paste, tap Paste again. The keyboard can insert text directly. For images, use Paste in the receiving app. The shortcut receives text without field labels or private markers. Turn on “Skip things that look like passwords” to skip copies marked private or temporary, and text that looks like a password, code, card number or access key. These checks can miss a secret, so delete anything you didn’t mean to keep. Images use up to 2 MiB each plus a small preview, with 32 MiB for all images and previews together. A single text copy can use up to the 1.5 MB text history budget. Copies expire after 30 days by default, or 24 hours or 7 days if you choose. Past 200 copies or about 1.5 MB of text, the oldest copies you haven’t chosen to keep go first. A copy you set to Keep until I delete it stays until you delete it. iOS encrypts clipboard history while your iPhone is locked. " + LinkCopy.clipboardStorage + " Zone Link doesn’t sync it. A copy leaves this iPhone only when you share it, open it as a link or send it to a computer. Add to Notes makes a separate note that works like your other notes: iPhone and Zone backups can include it, Messages can show it and Zone Link syncs it to a paired computer. Deleting the copy leaves that note. You can delete one copy or all of them. When you turn clipboard history off, you choose whether to keep or delete the copies already saved.")
                paragraph("Computers (optional, Beta)", LinkCopy.privacyComputers + (LinkCopy.privacyParagraph(paired, keeping: link?.computers.keepingNames ?? []).map { " " + $0 } ?? ""))
                    .accessibilityIdentifier("privacy.computers")
                paragraph("Camera", "Zone uses the camera only to read a computer’s pairing code. It doesn’t save or send a photo.")
                paragraph("Full Access", "You can type without Full Access. Turning it on lets the keyboard and app share data on this iPhone. In the active field the keyboard can read the selection and the text iOS provides around the cursor. For dictation it passes the app up to 64 characters before the cursor to help with spacing, capitals and nearby names. Keyboard speech recognition runs locally by default. Choosing a Zone Link GPU provider sends the completed keyboard recording to the HTTPS endpoint you save. iOS switches to its system keyboard in secure password fields.")
                paragraph("Autocorrect", "When you undo an autocorrection, the keyboard can remember the spelling you kept. It keeps up to 5,000 of these words on this iPhone. It also saves average tap positions for each key as numbers. With Full Access, it caches the contact names, spellings and text replacements iOS supplies for typing, swipe and dictation. This local vocabulary cache is excluded from iPhone backups.")
                paragraph("Recording recovery", "While you dictate, Zone saves temporary audio on this iPhone for recovery. It stays out of iPhone and Zone backups. Zone deletes the audio after safely saving the transcript. If an ordinary dictation finishes under eight seconds with no words, Zone discards it. For voice notes, check Recovery for audio without a transcript. You have seven days to retry a failed recording. Zone cleans up expired audio the next time it checks. If Zone stopped mid-recording, that week starts when it finds the interrupted recording. You can delete a recovery from Home.")
                paragraph("Recording log", "The app and keyboard keep a local log of events such as starts, stops, interruptions and errors. It records timings and counts without recording what you said. Zone excludes both new and existing recording logs from iPhone backups. Zone’s own backup leaves out the log. You can choose to share it from the Recording log screen.")
                paragraph("My words", LinkCopy.privacyWords)
                paragraph("Model downloads", "The app uses \(coordinator.selectedModel.displayName) for on-device dictation. Zone downloads it from Hugging Face (\(coordinator.selectedModel.downloadHost)), about \(coordinator.selectedModel.sizeLabel), and runs it on the phone with FluidAudio. Meeting speaker labels use a separate download from Hugging Face, about \(MeetingDiarizer.downloadBytes.byteCountLabel). iPhone backups can include text saved by earlier versions until you delete it in Your data. Zone backups omit those legacy files. The download host sees ordinary connection details such as your IP address. After the models you need are installed, you can use them in airplane mode. Speed up speech in Zone is off by default. It uses the same download and can help while Zone is on screen.")
                paragraph("Your controls", LinkCopy.privacyControls)
                paragraph("Watch and Messages", "Watch text entry uses Apple’s system input. Zone saves your note on the Watch, queues it for your paired iPhone and marks it received when the iPhone confirms the save. In Messages, Zone reads a local copy of recent notes and dictations. Tap one to insert it into your draft. You decide when to send.")
                paragraph("License", "Zone’s code is under the MIT License.")
                Text("Questions: zayd@zayd.wtf").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        .onAppear { recognitionMode = KeyboardVoiceRoute.load().mode }
        .navigationTitle("Privacy")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
            Text(body).font(.body).foregroundStyle(.secondary)
        }
    }
}
