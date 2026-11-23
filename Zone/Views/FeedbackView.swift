// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// True while the Send feedback screen is up. Its composer alone takes dictated words then, and
/// Apple's rating prompt waits: someone describing a problem is not asked for stars.
@MainActor
enum FeedbackSession {
    static var isOpen = false
}

/// Settings > Help > Send feedback, and the milestone note's button. The person says or types
/// what they think; Zone writes it into an email in their own mail app. Zone sends nothing:
/// the App Store label stays Data Not Collected because the email is theirs to send.
struct FeedbackView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includesDetails = true
    /// No app answered the mail link; the screen offers the address and the text to copy.
    @State private var mailUnavailable = false
    @State private var copied: String?

    private var details: FeedbackEmail.Details {
        let info = Bundle.main.infoDictionary ?? [:]
        return FeedbackEmail.Details(appVersion: info["CFBundleShortVersionString"] as? String ?? "",
                                     build: info["CFBundleVersion"] as? String ?? "",
                                     system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                                     device: Self.deviceIdentifier,
                                     speechModel: coordinator.selectedModel.displayName)
    }

    private var hasMessage: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DisplayText("Tell me.", size: 34)
                    Text("What works, what's broken, what you wish Zone did. Say it out loud, that's what the mic is for.")
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(Zone.ink(scheme))
                    Text("Zayd")
                        .font(.system(.title2, design: .serif).italic())
                        .foregroundStyle(Zone.accentText(scheme))
                        .accessibilityLabel("Signed, Zayd")
                    Hairline().padding(.vertical, 2)
                    Toggle("Add app and iPhone details", isOn: $includesDetails)
                        .tint(Zone.accentGraphic)
                        .accessibilityIdentifier("feedback.details")
                    Text(includesDetails
                         ? "Adds this line under your words: \(details.line)"
                         : "Only your words go in the email.")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    Text("Email opens your mail app with this written out. Nothing is sent until you send it there.")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    if mailUnavailable {
                        mailFallback.id(Self.fallbackAnchor)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            // The card appears below the fold, behind the composer and the keyboard: bring it up.
            .onChange(of: mailUnavailable) { _, unavailable in
                guard unavailable else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(Zone.motion) { reader.scrollTo(Self.fallbackAnchor, anchor: .bottom) }
                }
            }
            }
            .safeAreaInset(edge: .bottom) {
                Composer(text: $message, placeholder: "Say it or type it", forFeedback: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.cancellationAction) { Button("Cancel") { dismiss() } }
                ZoneBarItem(.confirmationAction, prominent: true) {
                    Button("Email") { openMail() }
                        .disabled(!hasMessage || coordinator.activity.isBusy)
                        .accessibilityIdentifier("feedback.email")
                }
            }
            .zoneScreen()
        }
        .onAppear { FeedbackSession.isOpen = true }
        .onDisappear {
            FeedbackSession.isOpen = false
            // A recording left running would land in Home's test field with nobody watching.
            if coordinator.activity.isRecording { coordinator.cancelDictation() }
        }
    }

    /// Shown when no mail app took the link (none installed, or none set up).
    private var mailFallback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No mail app opened. Send your words to \(FeedbackEmail.address) from anywhere you like.")
                .font(.subheadline).foregroundStyle(Zone.ink(scheme))
            HStack(spacing: 8) {
                Button(copied == "message" ? "Copied" : "Copy my words") {
                    Clipboard.copy(FeedbackEmail.body(message: message, details: includesDetails ? details : nil))
                    copied = "message"
                }
                Button(copied == "address" ? "Copied" : "Copy address") {
                    Clipboard.copy(FeedbackEmail.address)
                    copied = "address"
                }
            }
            .buttonStyle(ZonePillButtonStyle())
        }
        .zoneCard(padding: 14)
        .accessibilityIdentifier("feedback.fallback")
    }

    private static let fallbackAnchor = "feedback.fallback"

    private func openMail() {
        // Put the keyboard away first, so whatever comes next (the mail app or the copy card) is seen.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard let url = FeedbackEmail.mailto(message: message, details: includesDetails ? details : nil,
                                             appVersion: details.appVersion) else {
            mailUnavailable = true
            return
        }
        UIApplication.shared.open(url) { opened in
            Task { @MainActor in
                if opened {
                    Haptics.success()
                    dismiss()
                } else {
                    withAnimation(Zone.motion) { mailUnavailable = true }
                }
            }
        }
    }

    /// "iPhone17,1": the hardware identifier, which is what tells two iPhones apart in a report.
    private static let deviceIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
}

/// The note Home shows once when the word count passes a mark (`WordMilestones`): the number, a
/// line from Zayd, and a way to answer him. Closing it or answering it puts it away for good.
struct MilestoneCard: View {
    @Environment(\.colorScheme) private var scheme
    let note: MilestoneNote
    let reply: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(note.title)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(Zone.ink(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .foregroundStyle(Zone.muted(scheme))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("milestone.close")
            }
            Text(note.line)
                .font(.subheadline)
                .foregroundStyle(Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text("Zayd")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(Zone.accentText(scheme))
                    .accessibilityLabel("Signed, Zayd")
                Spacer(minLength: 8)
                Button("Tell Zayd", action: reply)
                    .buttonStyle(ZoneInkPillButtonStyle())
                    .accessibilityIdentifier("milestone.reply")
            }
        }
        .zoneCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("milestone.card")
    }
}
