// by zayd/cold @ zayd.wtf

import SwiftUI

struct ShortcutHelpView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DisplayText("One button,\nyour words.", size: 34)
                section("Voice note", "Press to start, press again to stop. Saves a note in Zone with a timer in the Dynamic Island, without leaving your current app.")
                section("Dictate and copy", "Press to start, press again to stop. Copies the transcript so you can paste anywhere or tap Insert on the Zone keyboard.")
                section("Action Button setup", "Open Settings → Action Button → Controls, then pick Voice note or Dictate and copy under Zone. The same controls also work in Control Center and on the Lock Screen.")
                section("Shortcuts", "Voice note, Dictate and copy, and Get last dictation are available in the Shortcuts app so you can pipe your latest dictation straight into messages or notes.")
                section("Press-and-hold timing", "iOS requires a brief hold on the Action Button before triggering. While Zone standby is active, recording starts immediately; if the session timed out, Zone wakes up first.")
                section("Both on one button", "Build a shortcut with Choose from Menu containing Voice note and Dictate and copy, then bind it to the Action Button or Back Tap (Settings → Accessibility → Touch).")
                section("Locked screen", "iOS restricts starting background mic sessions from a locked phone in some states. If prompted, unlock and press again.")
            }
            .padding(24)
        }
        .navigationTitle("Action Button & Shortcuts")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private func section(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Zone.ink(scheme))
            Text(detail).font(.body).foregroundStyle(Zone.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
