// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Computers > Send text to your computer: a paste bin from this iPhone to the
/// paired computers. Type or paste, and it is on the computer a moment later; below, what was
/// sent and what is still waiting for a computer that could not be reached.
struct ClipSendSheet: View {
    @Environment(LinkCoordinator.self) private var link
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// One line under the buttons: how the last send went, or why it could not be queued.
    @State private var message: String?
    @State private var failed = false
    @State private var waitingOn: UUID?
    @FocusState private var typing: Bool

    /// How long the line under the buttons waits for the computers before saying a clip is
    /// queued. The connection gives up on an unreachable computer after 20 seconds.
    private static let settleSeconds: TimeInterval = 30

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Type or paste text", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($typing)
                        .disabled(link.clipTargets.isEmpty)
                        .accessibilityIdentifier("clips.text")
                    HStack(spacing: 12) {
                        // The system's own paste button: one tap sends what is on the
                        // clipboard, and iOS shows no "Allow Paste" question for it.
                        ClipPasteControl(fill: Zone.controlFill(scheme), ink: Zone.controlInk(scheme)) {
                            send($0, source: .clipboard)
                        }
                        .id(PasteAppearance(accent: AccentStore.shared.choice, scheme: scheme))
                        .fixedSize()
                        .disabled(link.clipTargets.isEmpty)
                        .accessibilityIdentifier("clips.paste")
                        Spacer(minLength: 0)
                        Button("Send") { send(text, source: .typed) }
                            .buttonStyle(ZonePrimaryButtonStyle())
                            .disabled(link.clipTargets.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("clips.send")
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(failed ? Zone.live : Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("clips.message")
                    }
                } footer: {
                    Text(destination)
                        .accessibilityIdentifier("clips.destination")
                }
                .listRowBackground(Zone.card(scheme))

                if !link.clips.isEmpty {
                    Section {
                        ForEach(link.clips) { clip in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(clip.preview)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Image(systemName: clip.isSent ? "checkmark.circle.fill" : "clock")
                                        .foregroundStyle(clip.isSent ? Zone.accentTone(scheme) : Zone.muted(scheme))
                                        .accessibilityHidden(true)
                                    Text(status(clip))
                                        .accessibilityIdentifier("clips.status")
                                    Text(clip.createdAt.formatted(date: .omitted, time: .shortened))
                                }
                                .font(.footnote)
                                .foregroundStyle(Zone.muted(scheme))
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("clips.row")
                            .swipeActions {
                                Button("Remove", role: .destructive) { link.removeClip(clip.id) }
                            }
                        }
                        if link.clips.contains(where: \.isSent) {
                            Button("Clear sent") { link.clearSentClips() }
                                .accessibilityIdentifier("clips.clear")
                        }
                    } header: {
                        Text("Sent")
                    } footer: {
                        Text("Run `zone clip` on your computer to print the latest clip. Removing an entry here leaves the computer's copy intact.")
                    }
                    .listRowBackground(Zone.card(scheme))
                }
            }
            .scrollContentBackground(.hidden)
            .tint(Zone.inlineInk(scheme))
            .navigationTitle("Send text")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.confirmationAction, prominent: true) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("clips.done")
                }
            }
            .zoneScreen()
        }
    }

    /// Where a clip sent now goes.
    private var destination: String {
        let names = link.clipTargets.map(\.name)
        guard !names.isEmpty else { return LinkClipFailure.noComputer.plainMessage }
        return "Goes to \(ListFormatter.localizedString(byJoining: names)) encrypted. Offline targets receive it on the next sync."
    }

    private func status(_ clip: LinkClip) -> String {
        // A sync with a computer it waits for is running right now.
        if !clip.isSent, clip.waiting.contains(where: { link.syncing.contains($0) }) {
            let names = clip.waiting.filter { link.syncing.contains($0) }.map { link.computerNames[$0] ?? "the computer" }
            return "Sending to \(ListFormatter.localizedString(byJoining: names))…"
        }
        return LinkClipCopy.status(clip, names: link.computerNames)
    }

    private func send(_ value: String, source: LinkClipSource) {
        do {
            let clip = try link.sendClip(value, source: source)
            if source == .typed { text = "" }
            failed = false
            message = LinkClipCopy.sending
            waitingOn = clip.id
            Task {
                let settled = await link.clipSettled(clip.id, within: Self.settleSeconds)
                // A newer send owns the line now.
                guard waitingOn == clip.id else { return }
                waitingOn = nil
                message = settled.map { LinkClipCopy.outcome($0, names: link.computerNames) } ?? LinkClipCopy.removed
            }
        } catch let failure as LinkClipFailure {
            failed = true
            message = failure.plainMessage
        } catch {
            failed = true
            message = "Zone could not queue this text for your computer. Tap Send to try again."
        }
    }
}

/// UIKit owns the trusted paste interaction and applies both colors to its native face.
private struct PasteAppearance: Hashable {
    let accent: AccentChoice
    let scheme: ColorScheme
}

private struct ClipPasteControl: UIViewRepresentable {
    let fill: Color
    let ink: Color
    let send: (String) -> Void

    @MainActor final class Target: NSObject, UIPasteConfigurationSupporting {
        var pasteConfiguration: UIPasteConfiguration? = UIPasteConfiguration(acceptableTypeIdentifiers: ClipboardPasteText.acceptedTypes)
        var send: (String) -> Void

        init(send: @escaping (String) -> Void) { self.send = send }

        func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
            itemProviders.contains(where: ClipboardPasteText.supports)
        }

        func paste(itemProviders: [NSItemProvider]) {
            Task {
                var strings: [String] = []
                for provider in itemProviders where ClipboardPasteText.supports(provider) {
                    let value: String? = await withCheckedContinuation { continuation in
                        ClipboardPasteText.load(provider) { value in
                            continuation.resume(returning: value)
                        }
                    }
                    if let value { strings.append(value) }
                }
                if !strings.isEmpty { send(strings.joined(separator: "\n")) }
            }
        }
    }

    func makeCoordinator() -> Target { Target(send: send) }

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.baseForegroundColor = UIColor(ink)
        configuration.baseBackgroundColor = UIColor(fill)
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityIdentifier = "clips.paste"
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.send = send
        control.isUserInteractionEnabled = context.environment.isEnabled
        control.alpha = context.environment.isEnabled ? 1 : 0.45
    }
}
