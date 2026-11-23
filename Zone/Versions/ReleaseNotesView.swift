// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// One version's release notes: a big version number and date, a card for each feature, then
/// the smaller changes in a compact list. The history screen pushes it; the What's New sheet
/// shows the same content under its own heading.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
                .padding(.bottom, 8)
            ForEach(Array(note.features.enumerated()), id: \.element.id) { index, feature in
                ReleaseFeatureCard(feature: feature, leads: index == 0)
            }
            if !note.fixes.isEmpty {
                ReleaseFixList(fixes: note.fixes)
                    .padding(.top, 12)
            }
            if let build, !build.isEmpty {
                Text("Build \(build)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Zone.muted(scheme).opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                    .accessibilityIdentifier("releaseNotes.build")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(eyebrow)
            HeroNumber(text: note.version.description)
                .accessibilityLabel("Version \(note.version.description)")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("releaseNotes.version")
            // Side by side while they fit; at the largest text sizes the pill drops under the date.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { dateAndPill }
                VStack(alignment: .leading, spacing: 6) { dateAndPill }
            }
            Text(note.summary)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

extension ReleaseNotesContent {
    @ViewBuilder private var dateAndPill: some View {
        if let date = note.day?.date() {
            Text(date.formatted(date: .long, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(Zone.muted(scheme))
        }
        if isInstalled { InstalledPill() }
    }
}

/// "Installed": marks the version this iPhone is running.
struct InstalledPill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label("Installed", systemImage: "checkmark")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Zone.accentText(scheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Zone.accentGraphic(scheme).opacity(scheme == .dark ? 0.2 : 0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Installed on this iPhone")
    }
}

/// A feature: its picture, an optional label such as Beta, a short serif title, one to three
/// sentences, and where to find it. The first card of a version leads with a wide banner.
private struct ReleaseFeatureCard: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let feature: ReleaseFeature
    let leads: Bool

    var body: some View {
        let shape = Zone.cardShape
        VStack(alignment: .leading, spacing: 0) {
            if leads {
                ReleaseBanner(symbol: feature.symbol, seed: feature.title)
                    .frame(height: 112)
            }
            VStack(alignment: .leading, spacing: 12) {
                // At the largest text sizes the picture sits above the title, not beside it.
                if leads {
                    titleBlock
                } else if typeSize.isAccessibilitySize {
                    ReleaseSymbolTile(symbol: feature.symbol)
                    titleBlock
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        ReleaseSymbolTile(symbol: feature.symbol)
                        titleBlock
                    }
                }
                Text(feature.body)
                    .font(.body)
                    .foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let location = feature.location {
                    Label {
                        Text(location).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.turn.down.right")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Zone.accentText(scheme))
                    .accessibilityLabel("Find it in \(location.replacingOccurrences(of: " > ", with: ", "))")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(shape)
        .background { shape.fill(Zone.card(scheme)).sunShadow(scale: 0.8) }
        .overlay(shape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("releaseNotes.feature")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let tag = feature.tag {
                Text(tag.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Zone.accentText(scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Zone.accentText(scheme).opacity(0.5), lineWidth: 1))
                    .accessibilityLabel(tag)
            }
            Text(feature.title)
                .font(.system(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
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
            .foregroundStyle(Zone.accentText(scheme))
            .frame(width: side, height: side)
            .background(Zone.accentGraphic(scheme).opacity(scheme == .dark ? 0.18 : 0.12),
                        in: Zone.fieldShape)
            .accessibilityHidden(true)
    }
}

enum ReleaseSymbol {
    static func name(_ symbol: String) -> String {
        UIImage(systemName: symbol) == nil ? "sparkles" : symbol
    }
}

/// The lead card's picture: the feature's symbol over a still waveform, Zone's own mark. The
/// bars are drawn from the feature's title, so each version's banner is its own and never
/// changes between launches.
private struct ReleaseBanner: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let seed: String

    var body: some View {
        ZStack(alignment: .leading) {
            Zone.field(scheme)
            Canvas { context, size in
                // The bars begin beside the symbol, never behind it.
                let start: CGFloat = 86
                let span = max(0, size.width - start - 14)
                let heights = Self.heights(seed: seed, count: max(8, Int(span / 9)))
                let step = span / CGFloat(heights.count)
                let width = max(2, step * 0.42)
                for (index, height) in heights.enumerated() {
                    let tall = max(4, CGFloat(height) * size.height * 0.72)
                    let rect = CGRect(x: start + CGFloat(index) * step + (step - width) / 2, y: (size.height - tall) / 2,
                                      width: width, height: tall)
                    // Quiet beside the symbol, fuller toward the trailing edge.
                    let fade = 0.2 + 0.5 * Double(index) / Double(heights.count)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                                 with: .color(Zone.accentGraphic(scheme).opacity(fade)))
                }
            }
            Image(systemName: ReleaseSymbol.name(symbol))
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Zone.accentText(scheme))
                .frame(width: 50)
                .padding(.leading, 18)
                .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Zone.rule(scheme)).frame(height: 1) }
        .accessibilityHidden(true)
    }

    /// Bar heights from 0 to 1, shaped like speech: swells and pauses, the same for the same seed.
    static func heights(seed: String, count: Int) -> [Double] {
        var state = seed.unicodeScalars.reduce(UInt64(0x9E37_79B9_7F4A_7C15)) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
        let phase = next() * .pi * 2
        return (0..<count).map { index in
            let position = Double(index) / Double(max(1, count - 1))
            let swell = 0.5 + 0.5 * sin(position * .pi * 5 + phase)
            return min(1, 0.12 + swell * (0.35 + 0.65 * next()))
        }
    }
}

/// "Also in this version": the smaller changes as a compact list. A long one shows its first
/// few lines and opens on a tap.
private struct ReleaseFixList: View {
    @Environment(\.colorScheme) private var scheme
    let fixes: [String]
    @State private var showsAll = false
    private static let collapsedCount = 5

    var body: some View {
        let collapses = fixes.count > Self.collapsedCount + 1
        let shown = collapses && !showsAll ? Array(fixes.prefix(Self.collapsedCount)) : fixes
        VStack(alignment: .leading, spacing: 12) {
            Text("Also in this version")
                .font(.system(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(Zone.ink(scheme))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(shown, id: \.self) { fix in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Zone.accentGraphic(scheme))
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            .accessibilityHidden(true)
                        Text(fix)
                            .font(.subheadline)
                            .foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("releaseNotes.fix")
                }
                if collapses {
                    Button(showsAll ? "Show fewer" : "Show all \(fixes.count)") {
                        withAnimation(Zone.motion) { showsAll.toggle() }
                    }
                    .buttonStyle(ZoneLinkButtonStyle())
                    .padding(.bottom, -8)
                    .accessibilityIdentifier("releaseNotes.showAll")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .zoneCard(padding: 18)
        }
    }
}
