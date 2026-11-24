// by zayd/cold @ zayd.wtf

import SwiftUI

/// A short, skippable tour of what Zone does once it is set up. It shows once after the setup
/// walkthrough and opens again from Settings. One idea per card, swiped or stepped through.
struct TourView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var page = 0

    /// Set once the tour has been shown, finished or skipped, so it never opens by itself again.
    static let seenKey = "zone.tour.seen"

    private struct Card: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
    }

    private var cards: [Card] { [
        Card(id: 0, symbol: "mic.fill", title: "Talk where you type",
             body: "Tap the mic key in Zone's strip, talk, then tap Stop (■). Words go straight to your cursor."),
        Card(id: 1, symbol: "space", title: "Hold the space bar",
             body: settings.spaceHold == .talk ? settings.spaceHoldTalkHint : "Hold Space and slide to move the cursor."),
        Card(id: 2, symbol: "text.quote", title: "Pick a text style",
             body: settings.hideHomeButton ? "Hold the mic to choose a style for your next dictation." : "Tap Z to choose a style for your next dictation."),
        Card(id: 3, symbol: "waveform", title: "Quick voice notes",
             body: SetupDevice.hasActionButton ? "Add Voice note to the Action Button. Press to start, then press again to save." : "Add Voice note to Control Center. Tap to start, then tap again to save."),
        Card(id: 4, symbol: "person.2.fill", title: "Meetings",
             body: "Set your phone down for long conversations. Zone transcribes when you stop and separates speakers locally."),
        Card(id: 5, symbol: "mic.fill", title: "Record your first note",
             body: "On Home, tap New note and say a sentence. Tap the checkmark to save it."),
    ] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(page + 1) of \(cards.count)")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .accessibilityLabel("Tour step \(page + 1) of \(cards.count)")
                Spacer()
                Button("Skip") { finish() }
                    .buttonStyle(ZoneLinkButtonStyle())
                    .accessibilityHint("Closes the tour")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(cards) { card in
                    cardView(card).tag(card.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            HStack(spacing: 12) {
            if page > 0 {
                Button("Back") { withAnimation(Zone.motion) { page -= 1 } }
                    .buttonStyle(ZoneQuietButtonStyle())
            }
            Button(page == cards.count - 1 ? "Go to Home" : "Next") {
                if page == cards.count - 1 {
                    UserDefaults.standard.set(HomeMode.transcribe.rawValue, forKey: "zone.home.mode")
                    finish()
                } else {
                    withAnimation(Zone.motion) { page += 1 }
                }
            }
            .buttonStyle(ZonePrimaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Zone.paper(scheme).ignoresSafeArea())
        .onAppear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
    }

    private func cardView(_ card: Card) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: card.symbol)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Zone.accentTone(scheme))
                .frame(height: 52, alignment: .leading)
                .accessibilityHidden(true)
            DisplayText(card.title, size: 34)
            Text(card.body)
                .font(.body)
                .foregroundStyle(Zone.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }
}
