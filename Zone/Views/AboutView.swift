// by zayd/cold @ zayd.wtf

import SwiftUI

/// Settings > About > A note from Zayd, with his name set in place of a signature.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DisplayText("Why Zone", size: 34)
                Text("Dictating fast on your phone feels great once it actually works, and every iPhone already has the silicon to run it locally.")
                Text("I broke my dominant hand kickboxing and Apple's built-in dictation was awful, so I built Zone.")
                Text("Zayd")
                    .font(.system(size: 34, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Zone.ink(scheme))
                    .padding(.top, 6)
                    .accessibilityLabel("Signed, Zayd")
            }
            .font(.system(.title3, design: .serif))
            .foregroundStyle(Zone.ink(scheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
        }
        .navigationTitle("About")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}
