// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Recent dictations in place of the keys, opened from the clock in the strip. One tap puts a
/// dictation at the cursor again: the rescue for one that was cut off, pasted in the wrong place
/// or lost. Text only, read from the App Group, which the keyboard reaches only with Full Access.
///
/// With clipboard history on (Zone > History > Clipboard) the panel has a second list, Clipboard:
/// what was copied, newest first, one tap to put a copy at the cursor.
struct HistoryPanelView: View {
    let mic: MicController
    let model: KeyboardModel
    let clipboard: ClipboardController
    let theme: KeyboardTheme

    private var showsClipboard: Bool { clipboard.isEnabled && clipboard.tab == .clipboard }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if clipboard.isEnabled {
                    tab("Dictations", .dictations)
                    tab("Clipboard", .clipboard)
                } else {
                    Text("Recent dictations").font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                        .padding(.leading, 8)
                }
                Spacer()
                Button { mic.hideHistory() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsClipboard ? "Close clipboard" : "Close recent dictations")
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            if showsClipboard { clipboardContent } else { content }
        }
        .onAppear {
            clipboard.panelOpened()
            UIAccessibility.post(notification: .announcement, argument: clipboard.panelAnnouncement)
        }
        .onDisappear { clipboard.panelClosed() }
    }

    /// One of the two list names in the header; the chosen one is in full ink over a short rule.
    private func tab(_ title: String, _ tab: ClipboardController.Tab) -> some View {
        let chosen = clipboard.tab == tab
        return Button { clipboard.tab = tab } label: {
            Text(title)
                .font(.subheadline.weight(chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? theme.text : theme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 44)
                .overlay(alignment: .bottom) {
                    Capsule().fill(theme.accentStroke).frame(height: 2).padding(.horizontal, 8).padding(.bottom, 4)
                        .opacity(chosen ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("keyboard.history.tab.\(tab.rawValue)")
    }

    // MARK: Clipboard

    @ViewBuilder
    private var clipboardContent: some View {
        switch clipboard.panel {
        case .loading, .none:
            Text("Loading copies").font(.subheadline).foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsFullAccess:
            note("Allow Full Access to view copies.", detail: "Settings > Apps > Zone > Keyboards > Allow Full Access")
        case .timedOut:
            Button("Copies did not load. Tap to try again.") { clipboard.loadPanel() }
        case .unreachable:
            note("The keyboard could not open Zone’s history.", detail: "Unlock your iPhone, open Zone once, then return to this keyboard.")
        case .loaded(let entries):
            if entries.isEmpty && !clipboard.hasUnsavedCopy {
                note("No copies yet.", detail: "Use Zone’s Paste key to keep a copy here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if clipboard.hasUnsavedCopy { saveRow }
                        ForEach(entries) { entry in
                            clipRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// New text is copied and iOS asks before Zone may read it. A tap on Apple's own paste button
    /// is the permission, so this keeps the copy with no question.
    private var saveRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Something new is copied").font(.subheadline.weight(.medium)).foregroundStyle(theme.text)
                Text("Tap Paste to keep it here.").font(.caption).foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            PasteControlKey(theme: theme, session: { [weak model] in model?.currentSession }, saving: clipboard.saving) { _ in }
            .id(theme.isDark)
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.key.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("keyboard.clipboard.save")
    }

    private func clipRow(_ entry: ClipboardEntry) -> some View {
        // The row's own words and its length: a passage that opens with a web address must not
        // read as a link (`ClipboardPreview`). The tap still inserts the whole copy.
        let preview = ClipboardPreview(entry.text)
        return Button {
            // As it was copied, with no spacing added: a copy is exact text.
            if entry.imageType != nil {
                clipboard.copyImage(entry)
                mic.hideHistory()
                return
            }
            model.insertPasted(entry.text)
            mic.userTypedKey()
            mic.hideHistory()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if entry.imageType != nil {
                    SavedClipboardImage(url: clipboard.thumbnailURL(entry)).frame(height: 44)
                }
                Text(preview.text)
                    .font(.subheadline)
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(entry.savedAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(theme.secondaryText)
                    if entry.imageType == nil, let detail = preview.detail {
                        Text(detail).font(.caption2).foregroundStyle(theme.secondaryText)
                    }
                    if entry.pinned { Text("Kept").font(.caption2.weight(.medium)).keyboardAccentBadge(theme) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.key, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(preview.text)
        .accessibilityValue(entry.imageType == nil ? preview.detail ?? "" : "")
        .accessibilityHint(entry.imageType == nil ? "Inserts this copy at the cursor" : "Copies the image. Use Paste in the app.")
        .accessibilityIdentifier("keyboard.clipboard.row")
    }

    @ViewBuilder
    private var content: some View {
        switch mic.history {
        case .loading, .none:
            ProgressView("Loading dictations")
        case .needsFullAccess:
            note("Allow Full Access to view recent dictations.", detail: "Settings > Apps > Zone > Keyboards > Allow Full Access")
        case .unreachable:
            note("The keyboard could not open Zone’s history.", detail: "Unlock your iPhone, open Zone once, then return to this keyboard.")
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

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}
