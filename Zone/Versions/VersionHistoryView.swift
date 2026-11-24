// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > About > Version: every version of Zone up to the installed one, newest first, as a
/// timeline. The installed version is marked, and each row opens that version's notes.
struct VersionHistoryView: View {
    @Environment(WhatsNewGate.self) private var gate
    @Environment(\.colorScheme) private var scheme
    /// Set inside the What's New sheet, which needs its own way out.
    var onDone: (() -> Void)?

    var body: some View {
        let notes = gate.history
        // The installed version leads the list even when nobody has written its notes yet.
        let unwritten = gate.installed.flatMap { version in notes.contains { $0.version == version } ? nil : version }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DisplayText("Every version\nof Zone.", size: 34)
                Text("Newest first. Tap a version to read what changed.")
                    .font(.subheadline)
                    .foregroundStyle(Zone.muted(scheme))
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                if let unwritten {
                    VersionTimelineRow(isInstalled: true, isLast: notes.isEmpty) {
                        VersionCard(version: unwritten.description, name: nil, date: nil, isInstalled: true,
                                    summary: "The notes for this version are not written yet.", symbols: [], opens: false)
                    }
                    .accessibilityIdentifier("versionHistory.unwritten")
                }
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                    let installed = gate.installed == note.version
                    VersionTimelineRow(isInstalled: installed, isLast: index == notes.count - 1) {
                        NavigationLink {
                            ReleaseNotesView(note: note)
                        } label: {
                            VersionCard(version: note.version.description, name: note.name, date: note.day?.date(),
                                        isInstalled: installed, summary: note.summary, symbols: note.groups.map(\.symbol),
                                        opens: true)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .accessibilityHint("Opens the notes for this version")
                        .accessibilityIdentifier("versionHistory.row.\(note.version.description)")
                    }
                }
                if notes.isEmpty, unwritten == nil {
                    Text("This copy of Zone has no release notes in it.")
                        .font(.body)
                        .foregroundStyle(Zone.muted(scheme))
                }
                if let installed = gate.installed {
                    Text("Zone \(installed.description), build \(gate.build)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Zone.muted(scheme).opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                        .accessibilityIdentifier("versionHistory.build")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Version history")
        .onAppear { gate.readLibraryIfNeeded() }
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ZoneBarItem(.confirmationAction, prominent: true) { Button("Done", action: onDone) }
            }
        }
        .zoneScreen()
    }
}

/// One step of the timeline: a dot on a line down the leading edge, and the version beside it.
private struct VersionTimelineRow<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let isInstalled: Bool
    let isLast: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isInstalled ? Zone.accentTone(scheme) : Zone.paper(scheme))
                    .overlay(Circle().strokeBorder(isInstalled ? Zone.accentStroke(scheme) : Zone.muted(scheme).opacity(0.6), lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .padding(.top, 24)
                if !isLast {
                    Rectangle().fill(Zone.rule(scheme)).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 11)
            .accessibilityHidden(true)
            content
                .padding(.bottom, 14)
        }
    }
}

/// A version in the list: its number in the serif, the date and name, one sentence, and the
/// pictures of its groups as a hint of what is inside.
private struct VersionCard: View {
    @Environment(\.colorScheme) private var scheme
    let version: String
    /// What the update is called, when it has a name.
    let name: String?
    let date: Date?
    let isInstalled: Bool
    let summary: String
    let symbols: [String]
    let opens: Bool

    var body: some View {
        let shape = Zone.cardShape
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The pill sits beside the number while it fits, and under it at the largest text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) { numberAndPill }
                    VStack(alignment: .leading, spacing: 6) { numberAndPill }
                }
                Spacer(minLength: 0)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Zone.muted(scheme).opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            if let line = dateLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Zone.muted(scheme))
            }
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(Zone.ink(scheme).opacity(0.86))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !symbols.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(symbols.prefix(6).enumerated()), id: \.offset) { _, symbol in
                        Image(systemName: ReleaseSymbol.name(symbol))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Zone.accentTone(scheme))
                            .frame(width: 18, height: 18)
                    }
                    if symbols.count > 6 {
                        Text("+\(symbols.count - 6)")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(Zone.muted(scheme))
                    }
                }
                .padding(.top, 4)
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { shape.fill(Zone.card(scheme)).sunShadow(scale: 0.8) }
        .overlay(shape.strokeBorder(isInstalled ? Zone.accentStroke(scheme).opacity(0.7) : Zone.rule(scheme), lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var numberAndPill: some View {
        Text(version)
            .font(.system(.title, design: .serif, weight: .semibold).monospacedDigit())
            .foregroundStyle(Zone.ink(scheme))
        if isInstalled { InstalledPill() }
    }

    /// "November 20, 2026 · The Curate update", or whichever half the version has.
    private var dateLine: String? {
        let parts = [date?.formatted(date: .long, time: .omitted), name.map { "The \($0) update" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private var label: String {
        var parts = ["Version \(version)"]
        if isInstalled { parts.append("installed on this iPhone") }
        if let date { parts.append(date.formatted(date: .long, time: .omitted)) }
        if let name { parts.append("the \(name) update") }
        return parts.joined(separator: ", ") + ". " + summary
    }
}
