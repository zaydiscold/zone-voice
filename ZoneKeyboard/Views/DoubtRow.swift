// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// After a dictation lands: the few words Zone may have misheard, underlined with dots the way a
/// spell checker marks a word, each one tap from its alternatives. Open, the row reads the word
/// as heard (tap to keep it), then the alternatives (tap to write one), then a close key.
/// Scrolls sideways rather than shrinking a word into something unreadable.
struct DoubtRow: View {
    let mic: MicController
    let theme: KeyboardTheme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if let review = mic.doubtReview {
                    keepKey(review.placement.word)
                    ForEach(review.options, id: \.self) { option in
                        word(option, label: "Write \(option)") { mic.fixDoubt(with: option) }
                    }
                    closeKey
                } else {
                    ForEach(mic.doubts, id: \.charactersAfter) { placement in
                        flagged(placement)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 44)
    }

    private func flagged(_ placement: DoubtfulWords.Placement) -> some View {
        Button { mic.openDoubt(placement) } label: {
            Text(placement.word)
                .font(.system(size: 16, weight: .medium))
                .underline(true, pattern: .dot, color: theme.accentStroke)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel("Check \(placement.word)")
        .accessibilityHint("Zone may have misheard it. Shows other words.")
    }

    private func keepKey(_ heard: String) -> some View {
        Button { mic.keepDoubt() } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                Text(heard).font(.system(size: 16))
            }
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keep \(heard)")
    }

    private func word(_ text: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel(label)
    }

    private var closeKey: some View {
        Button { mic.closeDoubt() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 36, height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
