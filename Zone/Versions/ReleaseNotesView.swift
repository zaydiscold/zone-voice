// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// One version's release notes: the version, its name and date, then every change as one line,
/// grouped by the part of Zone it belongs to. A long version opens with its groups folded. The history screen pushes it, and the What's New
/// sheet opens the same page from "All changes".
struct ReleaseNotesView: View {
    @Environment(WhatsNewGate.self) private var gate
    let note: ReleaseNote

    var body: some View {
        ScrollView {
            ReleaseNotesContent(note: note, eyebrow: "Zone", isInstalled: gate.installed == note.version,
                                build: gate.installed == note.version ? gate.build : nil)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Version \(note.version.description)")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

/// The notes themselves, without a screen around them.
struct ReleaseNotesContent: View {
    @Environment(\.colorScheme) private var scheme
    let note: ReleaseNote
    /// The small label above the version number.
    let eyebrow: String
    var isInstalled = false
    /// Shown small at the very end, for the installed version only.
    var build: String?

    /// The most changes a version shows unfolded.
    static let openLimit = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReleaseNotesHeader(note: note, eyebrow: eyebrow, isInstalled: isInstalled, showsCount: true)
                .padding(.bottom, 26)
            // A short version shows every line. A long one opens as its groups, each naming its
            // changes, so the whole version reads on one screen and a tap opens the part you want.
            let startsOpen = note.count <= Self.openLimit
            ForEach(note.groups) { group in
                ReleaseGroupSection(group: group, startsOpen: startsOpen)
                    .padding(.bottom, startsOpen ? 26 : 18)
            }
            if let build, !build.isEmpty {
                Text("Build \(build)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Zone.muted(scheme).opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("releaseNotes.build")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The top of a version's notes: the number, what the update is called, its date and one sentence.
struct ReleaseNotesHeader: View {
    @Environment(\.colorScheme) private var scheme
    let note: ReleaseNote
    let eyebrow: String
    var isInstalled = false
    /// The full page says how many changes follow; the sheet shows only a few.
    var showsCount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(eyebrow)
            HeroNumber(text: note.version.description)
                .accessibilityLabel("Version \(note.version.description)")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("releaseNotes.version")
            if let name = note.name {
                Text("The \(name) update")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(Zone.ink(scheme))
                    .accessibilityIdentifier("releaseNotes.name")
            }
            // Side by side while they fit; at the largest text sizes the pill drops under the date.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { dateAndPill }
                VStack(alignment: .leading, spacing: 6) { dateAndPill }
            }
            Text(note.summary)
                .font(.body)
                .foregroundStyle(Zone.ink(scheme).opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    @ViewBuilder private var dateAndPill: some View {
        if let line = dateLine {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(Zone.muted(scheme))
        }
        if isInstalled { InstalledPill() }
    }

    private var dateLine: String? {
        let date = note.day?.date().map { $0.formatted(date: .long, time: .omitted) }
        let count = showsCount ? (note.count == 1 ? "1 change" : "\(note.count) changes") : nil
        let parts = [date, count].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

/// "Installed": marks the version this iPhone is running.
struct InstalledPill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label("Installed", systemImage: "checkmark")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Zone.controlInk(scheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Zone.controlFill(scheme), in: Capsule())
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Installed on this iPhone")
    }
}

/// One part of Zone and its changes. Folded, it is the group's picture, name and count over the
/// names of its changes; a tap unfolds it into a line per change, a hairline apart on the page.
/// No cards: the list is the design.
private struct ReleaseGroupSection: View {
    @Environment(\.colorScheme) private var scheme
    let group: ReleaseGroup
    @State private var open: Bool

    init(group: ReleaseGroup, startsOpen: Bool) {
        self.group = group
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Zone.motion) { open.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: ReleaseSymbol.name(group.symbol))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Zone.accentTone(scheme))
                            .frame(width: ReleaseItemRow.gutter)
                        Text(group.title)
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(Zone.ink(scheme))
                        Spacer(minLength: 8)
                        Text("\(group.items.count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Zone.muted(scheme))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Zone.muted(scheme).opacity(0.8))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    if !open {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(Zone.muted(scheme))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .padding(.leading, ReleaseItemRow.gutter + 9)
                    }
                }
                .padding(.bottom, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(group.title), \(group.items.count == 1 ? "1 change" : "\(group.items.count) changes")")
            .accessibilityValue(open ? "Open" : preview)
            .accessibilityHint(open ? "Folds this group" : "Shows each change")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("releaseNotes.group")
            Hairline()
            if open {
                ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Hairline().padding(.leading, ReleaseItemRow.gutter + 9) }
                    ReleaseItemRow(item: item)
                }
            }
        }
    }

    /// The names of the group's changes, which is the whole group at a glance. A group of unnamed
    /// fixes shows its first one.
    private var preview: String {
        let names = group.items.compactMap(\.title)
        if names.isEmpty { return group.items.first?.text ?? "" }
        let unnamed = group.items.count - names.count
        return names.joined(separator: ", ") + (unnamed > 0 ? ", and \(unnamed) more" : "")
    }
}

/// One change: its name in ink, then its sentence in the quieter color, as one paragraph. A
/// starred change carries a small dot in the margin.
struct ReleaseItemRow: View {
    @Environment(\.colorScheme) private var scheme
    static let gutter: CGFloat = 22
    let item: ReleaseItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(item.isHighlight ? Zone.accentTone(scheme) : .clear)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                .frame(width: Self.gutter)
                .accessibilityHidden(true)
            ReleaseItemText(item: item)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("releaseNotes.item")
    }
}

/// A change as one run of text: "Next word BETA  Finish a word and the row offers the next one."
struct ReleaseItemText: View {
    @Environment(\.colorScheme) private var scheme
    let item: ReleaseItem

    var body: some View {
        if let title = item.title {
            let name = Text(title).fontWeight(.semibold).foregroundStyle(Zone.ink(scheme))
            let sentence = Text(item.text).foregroundStyle(Zone.muted(scheme))
            if let tag = item.tag {
                let label = Text(tag.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Zone.ink(scheme))
                Text("\(name) \(label)  \(sentence)")
            } else {
                Text("\(name)  \(sentence)")
            }
        } else {
            Text(item.text).foregroundStyle(Zone.muted(scheme))
        }
    }
}

/// An SF Symbol on a small tinted square. A name this iOS does not have falls back to a
/// sparkle rather than an empty tile.
struct ReleaseSymbolTile: View {
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title3) private var side: CGFloat = 46
    let symbol: String

    init(symbol: String, side: CGFloat = 46) {
        self.symbol = symbol
        _side = ScaledMetric(wrappedValue: side, relativeTo: .title3)
    }

    var body: some View {
        Image(systemName: ReleaseSymbol.name(symbol))
            .font(.system(size: side * 0.44, weight: .medium))
            .foregroundStyle(Zone.ink(scheme))
            .frame(width: side, height: side)
            .background(Zone.accentTone(scheme).opacity(scheme == .dark ? 0.18 : 0.12),
                        in: Zone.fieldShape)
            .accessibilityHidden(true)
    }
}

enum ReleaseSymbol {
    static func name(_ symbol: String) -> String {
        UIImage(systemName: symbol) == nil ? "sparkles" : symbol
    }
}
