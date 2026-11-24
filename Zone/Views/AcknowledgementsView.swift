// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct AcknowledgementsView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List {
            Section {
                Text("Swipe typing powered by FUTO Swipe.")
                NavigationLink("FUTO Swipe and VietTelex") {
                    LicenseText(title: "Swipe typing", text: SwipeNeuralScorer.notices)
                }
                notice("Speech model", file: "SpeechModel", ext: "txt")
                notice("FluidAudio and speaker labels", file: "FluidAudio", ext: "txt")
                notice("Computer link libraries", file: "ComputerLink", ext: "txt")
                notice("Words, emoji and other credits", file: "THIRD-PARTY-NOTICES", ext: "md")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Acknowledgements")
        .zoneBackButton()
        .zoneScreen()
    }

    private func notice(_ title: String, file: String, ext: String) -> some View {
        NavigationLink(title) {
            LicenseText(title: title, text: Bundle.main.url(forResource: file, withExtension: ext)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The license text could not be opened.")
        }
    }
}

private struct LicenseText: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph).font(.footnote).textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .zoneBackButton()
        .zoneScreen()
    }
}
