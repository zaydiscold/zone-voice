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
                        PasteButton(payloadType: String.self) { values in
                            let pasted = values.joined(separator: "\n")
                            Task { @MainActor in send(pasted, source: .clipboard) }
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(link.clipTargets.isEmpty)
                        .accessibilityIdentifier("clips.paste")
                        Spacer(minLength: 0)
                        Button("Send") { send(text, source: .typed) }
                            .buttonStyle(.borderedProminent)
                            .disabled(link.clipTargets.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("clips.send")
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(failed ? Color.red : Zone.muted(scheme))
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
                                        .foregroundStyle(clip.isSent ? Zone.accentText(scheme) : Zone.muted(scheme))
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
            .tint(Zone.accentText(scheme))
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
            message = "Sending…"
            waitingOn = clip.id
            Task {
                let settled = await link.clipSettled(clip.id, within: Self.settleSeconds)
                // A newer send owns the line now.
                guard waitingOn == clip.id else { return }
                waitingOn = nil
                message = settled.map { LinkClipCopy.outcome($0, names: link.computerNames) }
            }
        } catch let failure as LinkClipFailure {
            failed = true
            message = failure.plainMessage
        } catch {
            failed = true
            message = "Couldn't save clip. Try again."
        }
    }
}
