// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Computers: the computers this iPhone sends its library to, and how to add one.
struct ComputersView: View {
    @Environment(LinkCoordinator.self) private var link
    @Environment(\.colorScheme) private var scheme
    @State private var showsScanner = false
    @State private var scanned: String?
    @State private var showsPaste = false
    @State private var pasted = ""
    @State private var forgetting: PairedComputer?
    @State private var showsClips = ComputersView.opensClips

    /// `-zoneLinkClipSheet` (development builds): Send text is open when the screen appears.
    private static var opensClips: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-zoneLinkClipSheet")
        #else
        return false
        #endif
    }

    var body: some View {
        Form {
            if link.isPaired {
                Section {
                    Button { showsClips = true } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LinkClipCopy.row)
                                Text(clipNote)
                                    .font(.footnote)
                                    .foregroundStyle(Zone.muted(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("computers.sendTextNote")
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Zone.muted(scheme))
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("computers.sendText")
                }
                .listRowBackground(Zone.card(scheme))
            }
            ForEach(link.computers) { computer in
                Section {
                    Toggle("Send to this computer", isOn: Binding(get: { !computer.isPaused },
                                                                set: { link.setSending($0, to: computer.endpointID) }))
                        .accessibilityIdentifier("computers.sending")
                    Toggle(LinkCopy.keepSwitch, isOn: Binding(get: { computer.keepsDeleted },
                                                              set: { link.setKeepsDeleted($0, for: computer.endpointID) }))
                        .accessibilityIdentifier("computers.keepDeleted")
                    LabeledContent("Last sync", value: lastSync(computer))
                    if let date = computer.lastFlashAt {
                        LabeledContent("Last flash", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Items sent", value: computer.itemsSent.formatted())
                    if let error = computer.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("computers.error")
                    }
                    Button("Sync now") { link.syncNow(computer.endpointID) }
                        .disabled(computer.isPaused || link.syncing.contains(computer.endpointID))
                        .accessibilityIdentifier("computers.syncNow")
                    Button("Send everything again") { link.sendEverythingAgain(computer.endpointID) }
                        .disabled(computer.isPaused || link.syncing.contains(computer.endpointID))
                        .accessibilityIdentifier("computers.sendAgain")
                    Button("Forget this computer", role: .destructive) { forgetting = computer }
                    // Not a step after syncing: the other way in, for when there is no connection.
                    Button { link.flashTarget = computer } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No connection? Send by Flash")
                            Text("Offline QR transfer when Wi-Fi or networks block traffic.")
                                .font(.footnote)
                                .foregroundStyle(Zone.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("computers.flash")
                } header: {
                    HStack(spacing: 8) {
                        Text(computer.name)
                        if computer.isPaused {
                            Text("Paused")
                                .font(.caption2.weight(.semibold))
                                .textCase(nil)
                                .foregroundStyle(Zone.muted(scheme))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder(Zone.rule(scheme), lineWidth: 1))
                                .accessibilityIdentifier("computers.paused")
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if computer.isPaused {
                            Text("Paused until you turn this back on, then syncs only what changed\(computer.keepsDeleted ? "" : ", deletions included"). Send by Flash still works.")
                                .accessibilityIdentifier("computers.pausedNote")
                        }
                        Text(LinkCopy.keepFooter(computer.name, on: computer.keepsDeleted))
                            .accessibilityIdentifier("computers.keepNote")
                    }
                }
                .listRowBackground(Zone.card(scheme))
            }

            Section {
                Button { showsScanner = true } label: {
                    Label("Pair a computer", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("computers.pair")
                Button { showsPaste = true } label: {
                    Label("Paste link", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("computers.paste")
                // The link is needed on the computer, so the row opens it here and shares it there.
                HStack(spacing: 12) {
                    Link(destination: ZoneLinks.computerApp) {
                        Label("Get Zone for your computer", systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("computers.getZone")
                    Spacer(minLength: 0)
                    ShareLink(item: ZoneLinks.computerApp) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(minWidth: 44, minHeight: 32)
                    }
                    .accessibilityLabel("Share the link to Zone for your computer")
                    .accessibilityIdentifier("computers.shareZone")
                }
                .buttonStyle(.borderless)
            } footer: {
                SettingsNote("Sync dictations, notes, and meeting transcripts straight to your computer so local tools and AI agents can query them.", points: [
                    "**Pair:** on your computer, open Zone and choose Pair a phone (or run `zone pair`), then scan the QR code.",
                    "**Install:** Get Zone for your computer opens the download page, or tap Share to send the link to your computer.",
                    "**Beta:** nothing is sent until you pair a computer.",
                    "**End-to-end encrypted:** text only, and audio stays on your iPhone. A relay may pass it along but cannot read it.",
                    "**Automatic:** once paired, new items sync within seconds.",
                    "**Send text:** push links, codes, or clipboard snippets straight to your computer, or bind the Send to Computer shortcut.",
                    "**Send by Flash:** offline fallback using rapid screen QR codes when you have no network.",
                    "**Deletions:** deleting here removes the computer's copy unless **\(LinkCopy.keepSwitch)** is on. Items that only age out of History stay there.",
                ])
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .tint(Zone.accentText(scheme))
        .navigationTitle("Computers")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
        .sheet(isPresented: $showsScanner, onDismiss: {
            // The question is asked by the root view, which can only present once this sheet is gone.
            if let code = scanned { link.offerPairing(code) }
            scanned = nil
        }) {
            PairingScannerSheet(onCode: { code in
                scanned = code
                showsScanner = false
            }, onPaste: {
                showsScanner = false
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    showsPaste = true
                }
            })
        }
        .sheet(isPresented: $showsClips) { ClipSendSheet() }
        .alert("Paste link", isPresented: $showsPaste) {
            TextField("zone://pair?…", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Pair") {
                let text = pasted
                pasted = ""
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    link.offerPairing(text)
                }
            }
            Button("Cancel", role: .cancel) { pasted = "" }
        } message: {
            Text("On your computer, open Zone and choose Pair a phone (or run zone pair). Paste the link it shows.")
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "this computer")?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { computer in
            Button("Forget this computer", role: .destructive) { link.forget(computer.endpointID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Stops syncing to this computer. Items already sent remain there.")
        }
    }

    /// Under the Send text row: what it is for, or what is still waiting to go.
    private var clipNote: String {
        let waiting = link.clips.filter { !$0.isSent }.count
        guard waiting > 0 else { return LinkClipCopy.rowNote }
        return waiting == 1 ? "1 text is waiting for a computer." : "\(waiting) texts are waiting for a computer."
    }

    private func lastSync(_ computer: PairedComputer) -> String {
        // Off wins over a session that is still being cut short.
        if computer.isPaused, computer.lastSyncAt == nil { return "Paused" }
        if link.syncing.contains(computer.endpointID), !computer.isPaused { return "Syncing…" }
        if let date = computer.lastSyncAt { return date.formatted(date: .abbreviated, time: .shortened) }
        return computer.confirmed ? "Not yet" : "Waiting for the computer"
    }
}

/// The two things pairing can say, shown from the root so they appear wherever the person is:
/// the question before anything is sent, and one line about how it went.
struct LinkPairingPrompts: ViewModifier {
    @Environment(LinkCoordinator.self) private var link

    func body(content: Content) -> some View {
        content
            .alert("Send your Zone library to \(link.pendingPairing?.name ?? "this computer")?",
                   isPresented: Binding(get: { link.pendingPairing != nil }, set: { if !$0 { link.declinePairing() } })) {
                Button("Send") { link.confirmPairing() }
                Button("Cancel", role: .cancel) { link.declinePairing() }
            } message: {
                Text("Your dictations, notes and meeting transcripts go to this computer, and new ones follow. Only pair a computer you trust.")
            }
            .fullScreenCover(item: Binding(get: { link.flashTarget }, set: { link.flashTarget = $0 })) { computer in
                FlashSenderView(computer: computer)
            }
            #if DEBUG
            .sheet(isPresented: Binding(get: { link.debugShowsComputers && link.flashTarget == nil },
                                        set: { if !$0 { link.debugShowsComputers = false } })) {
                NavigationStack { ComputersView() }
            }
            #endif
            .background {
                Color.clear
                    // Waits for Send by Flash to close: an alert from here would take the Flash screen down.
                    .alert("Computers", isPresented: Binding(get: { link.notice != nil && link.flashTarget == nil },
                                                             set: { if !$0 { link.notice = nil } })) {
                        Button("OK", role: .cancel) { link.notice = nil }
                    } message: {
                        Text(link.notice ?? "")
                    }
            }
    }
}
