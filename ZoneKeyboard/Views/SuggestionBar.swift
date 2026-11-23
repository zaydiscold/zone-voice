// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Three suggestion slots, laid out like the system keyboard's predictive row: the typed word on
/// the left (in quotes when a separator would replace it), then corrections and completions. The
/// slot that space will apply sits on a key-colored chip so the replacement is never a surprise.
struct SuggestionBar: View {
    let suggestions: [Suggestion]
    let theme: KeyboardTheme
    let onChoose: (Suggestion) -> Void

    private static let slotCount = Autocorrector.maxSuggestions

    var body: some View {
        let pendingReplacement = suggestions.contains(where: \.autoApplies)
        // Equal parts of the row when every word fits, so a slot stays under the thumb as the
        // words change. Long alternatives on a narrow phone scroll at full size instead of
        // shrinking into unreadable labels.
        ViewThatFits(in: .horizontal) {
            slots(quoted: pendingReplacement, fills: true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    slots(quoted: pendingReplacement, fills: false)
                }
                .scrollIndicators(.hidden)
                .onChange(of: suggestions) { _, _ in
                    proxy.scrollTo(0, anchor: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func slots(quoted pendingReplacement: Bool, fills: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(suggestions.prefix(Self.slotCount).enumerated()), id: \.offset) { index, suggestion in
                if index > 0 {
                    Rectangle()
                        .fill(theme.secondaryText.opacity(0.25))
                        .frame(width: 1, height: 22)
                        .accessibilityHidden(true)
                }
                slot(suggestion, quoted: pendingReplacement && suggestion.kind == .literal, fills: fills)
                    .id(index)
            }
        }
    }

    private func slot(_ suggestion: Suggestion, quoted: Bool, fills: Bool) -> some View {
        Button { onChoose(suggestion) } label: {
            Text(quoted ? "\u{201C}\(suggestion.text)\u{201D}" : suggestion.text)
                .font(.system(size: 17, weight: suggestion.autoApplies ? .semibold : .regular))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Sharing the row, a slot needs only its word: the 64 pt floor kept three short
                // words from fitting beside the home mark, so the third sat cut off at the edge.
                .padding(.horizontal, fills ? 5 : 8)
                .frame(minWidth: fills ? 40 : 64, maxWidth: fills ? .infinity : nil, minHeight: 38)
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
        case .prediction: return "\(suggestion.text), next word"
        }
    }
}
