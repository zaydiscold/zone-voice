// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Recent dictations in place of the keys, opened from the clock in the strip. One tap puts a
/// dictation at the cursor again: the rescue for one that was cut off, pasted in the wrong place
/// or lost. Text only, read from the App Group, which the keyboard reaches only with Full Access.
struct HistoryPanelView: View {
    let mic: MicController
    let theme: KeyboardTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent dictations").font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                Spacer()
                Button { mic.hideHistory() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close recent dictations")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mic.history {
        case .loading, .none:
            Spacer()
        case .needsFullAccess:
            note("Allow Full Access to view recent dictations.", detail: "Settings → Apps → Zone → Keyboards")
        case .unreachable:
            note("Can't reach the Zone app yet.", detail: "Close this app and reopen it.")
        case .off:
            note("History is off.", detail: "Enable it in Zone's settings to keep recent dictations here.")
        case .loaded(let records) where records.isEmpty:
            note("No dictations yet.", detail: "Recent dictations appear here locally.")
        case .loaded(let records):
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(records) { record in
                        row(record)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func row(_ record: TranscriptRecord) -> some View {
        Button { mic.reinsert(record) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.text)
                    .font(.subheadline)
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(record.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(theme.secondaryText)
                    if let label = record.status.label {
                        Text(label)
                            .font(.caption2.weight(record.status == .cutOff ? .medium : .regular))
                            .foregroundStyle(record.status == .cutOff ? KeyboardTheme.live : theme.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.key, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(record.text)
        .accessibilityHint("Inserts this dictation at the cursor")
    }

    private func note(_ title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Spacer()
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(theme.text)
            Text(detail).font(.caption).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}
