// by zayd/cold @ zayd.wtf

import CoreImage.CIFilterBuiltins
import SwiftUI
import ZoneCore

/// A QR code a friend scans off this screen, for passing Zone on in person. The App Store
/// link by default, the TestFlight beta one tap away.
struct ShareCodeSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var beta = false

    private var url: URL { beta ? ZoneLinks.testFlight : ZoneLinks.appStore }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Link", selection: $beta) {
                    Text("App Store").tag(false)
                    Text("Beta").tag(true)
                }
                .pickerStyle(.segmented)
                if let code = Self.code(for: url) {
                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                        // Dark modules on white whatever the theme: cameras read that best.
                        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: 300)
                        .accessibilityLabel(beta ? "QR code for the Zone beta on TestFlight" : "QR code for Zone on the App Store")
                }
                Text(beta ? "Point a camera here to join the beta on TestFlight." : "Point a camera here to get Zone from the App Store.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Share Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .zoneScreen()
        }
        .presentationDetents([.large])
    }

    static func code(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
