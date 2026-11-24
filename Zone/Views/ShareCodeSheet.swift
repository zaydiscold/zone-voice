// by zayd/cold @ zayd.wtf

import CoreImage.CIFilterBuiltins
import SwiftUI
import ZoneCore

/// A friend can scan this code to open Zone in the App Store.
struct ShareCodeSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let code = Self.code(for: ZoneLinks.appStore) {
                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                        // Dark modules on white whatever the theme: cameras read that best.
                        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: 300)
                        .accessibilityLabel("QR code for Zone on the App Store")
                }
                Text("Point a camera here to get Zone from the App Store.")
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
