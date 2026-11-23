// by zayd/cold @ zayd.wtf

import SwiftUI

/// A short, skippable tour of what Zone does once it is set up. It shows once after the setup
/// walkthrough and opens again from Settings. One idea per card, swiped or stepped through.
struct TourView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    /// Set once the tour has been shown, finished or skipped, so it never opens by itself again.
    static let seenKey = "zone.tour.seen"

    private struct Card: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
    }

    private let cards: [Card] = [
        Card(id: 0, symbol: "mic.fill", title: "Talk where you type",
             body: "Tap the mic key in Zone's strip, talk, then tap Stop. Words go straight to your cursor."),
        Card(id: 1, symbol: "keyboard.chevron.compact.down", title: "Hide the keys",
             body: "Tap the keyboard icon to leave just the mic, Delete, and Return. Tap again to bring the letters back."),
        Card(id: 2, symbol: "text.quote", title: "Pick a text style",
             body: "Tap Z for casual, very casual, formal., or excited!. Say \"comma\", \"new line\", or \"bullet point\" out loud."),
        Card(id: 3, symbol: "waveform", title: "Quick voice notes",
             body: "Bind Voice note to the Action Button or Control Center. Press to start, press again to stop, without leaving your app."),
        Card(id: 4, symbol: "person.2.fill", title: "Meetings",
             body: "Set your phone down for long conversations. Zone transcribes when you stop and separates speakers locally."),
        Card(id: 5, symbol: "sparkles", title: "Clean up drafts",
             body: "Strip filler words and tighten rough transcripts on device. Compare both versions and keep whichever reads better."),
    ]

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
            Button(page == cards.count - 1 ? "Try cleanup" : "Next") {
                if page == cards.count - 1 {
                    UserDefaults.standard.set(HomeMode.cleanup.rawValue, forKey: "zone.home.mode")
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
                .foregroundStyle(Zone.accentText(scheme))
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
