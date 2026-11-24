// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The word and emoji slots, laid out like the system keyboard's predictive row: the typed word on
/// the left (in quotes when a separator would replace it), then corrections and completions. The
/// slot that space will apply sits on a key-colored chip so the replacement is never a surprise.
struct SuggestionBar: View {
    let suggestions: [Suggestion]
    let theme: KeyboardTheme
    let onChoose: (Suggestion) -> Void

    var body: some View {
        let quoted = suggestions.contains(where: \.autoApplies)
        if suggestions.contains(where: { if case .emoji = $0.kind { true } else { false } }) {
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        slots(suggestions[...], quoted: quoted, fills: true)
                            .frame(minWidth: geometry.size.width)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: suggestions) { _, _ in reader.scrollTo(0, anchor: .leading) }
                    .accessibilityIdentifier("keyboard.wordSuggestions")
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                slots(suggestions[...], quoted: quoted, fills: true)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        slots(suggestions[...], quoted: quoted, fills: false)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: suggestions) { _, _ in
                        proxy.scrollTo(0, anchor: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func slots(_ words: ArraySlice<Suggestion>, quoted pendingReplacement: Bool, fills: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, suggestion in
                if index > 0 {
                    SuggestionDivider(theme: theme)
                }
                slot(suggestion, quoted: pendingReplacement && suggestion.kind == .literal, fills: fills)
                    .id(suggestion.text)
                    .id(index)
            }
        }
    }

    private func slot(_ suggestion: Suggestion, quoted: Bool, fills: Bool) -> some View {
        let isEmoji = if case .emoji = suggestion.kind { true } else { false }
        return Button { onChoose(suggestion) } label: {
            Text(quoted ? "\u{201C}\(suggestion.text)\u{201D}" : suggestion.text)
                .font(.body.weight(suggestion.autoApplies ? .semibold : .regular))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Sharing the row, a slot needs only its word: the 64 pt floor kept three short
                // words from fitting beside the home mark, so the third sat cut off at the edge.
                .padding(.horizontal, fills ? 5 : 8)
                .frame(minWidth: isEmoji ? 34 : fills ? 40 : 64, maxWidth: isEmoji ? 34 : fills ? .infinity : nil, minHeight: 38)
                .background {
                    if suggestion.autoApplies {
                        RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
                            .fill(theme.key)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, fills ? 1 : 3)
        .accessibilityLabel(accessibilityLabel(suggestion))
        .accessibilityHint(suggestion.autoApplies ? "Space will use this word" : "")
    }

    private func accessibilityLabel(_ suggestion: Suggestion) -> String {
        switch suggestion.kind {
        case .literal: return "Keep \(suggestion.text)"
        case .correction, .completion: return suggestion.text
        case .emoji(_, let word, let spaced, _): return spaced ? "Add \(suggestion.text)" : "Replace \(word) with \(suggestion.text)"
        case .prediction: return "\(suggestion.text), next word"
        }
    }
}


/// Emoji choices use the same slot rhythm and dividers as the word suggestion row.
struct EmojiSuggestionBar: View {
    let model: KeyboardModel
    let theme: KeyboardTheme
    @State private var visibilityQuery: DarwinObservation?
    var onChoose: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .horizontal) {
            slots(fill: true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { slots(fill: false) }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.emojiSuggestions) { _, _ in
                        proxy.scrollTo(0, anchor: .leading)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            visibilityQuery = DarwinNotifier.observe(.queryEmojiStrip) {
                DarwinNotifier.post(.emojiStripVisible)
            }
            DarwinNotifier.post(.emojiStripVisible)
        }
        .onDisappear {
            visibilityQuery = nil
            DarwinNotifier.post(.emojiStripHidden)
        }
    }

    private func slots(fill: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.emojiSuggestions.enumerated()), id: \.offset) { index, match in
                if index > 0 { SuggestionDivider(theme: theme) }
                let glyph = model.shownEmoji(match)
                Button {
                    model.chooseEmojiSuggestion(match)
                    onChoose()
                } label: {
                    Text(glyph)
                        .font(.system(size: 26))
                        .frame(minWidth: 44, maxWidth: fill ? .infinity : 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(glyph), \(match.name.replacingOccurrences(of: "_", with: " "))")
                .accessibilityHint("Replaces the emoji shortcode")
                .accessibilityIdentifier("emoji-suggestion-" + match.emoji)
                .id(index)
            }
        }
    }

}

private struct SuggestionDivider: View {
    let theme: KeyboardTheme

    var body: some View {
        Rectangle()
            .fill(theme.secondaryText.opacity(0.25))
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }
}
