// by zayd/cold @ zayd.wtf

import AVFoundation
import SwiftUI
import UIKit
import ZoneCore

/// The camera, looking for the QR code `zone pair` shows. It only reads the code: the question
/// "Send your Zone library to ...?" comes after, from the same place as every other way in.
struct PairingScannerSheet: View {
    let onCode: (String) -> Void
    let onPaste: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint: String?

    private var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if !hasCamera {
                        unavailable("No camera here", "Paste the link from Pair a phone (or zone pair) instead.")
                    } else if access == .authorized {
                        QRCameraView { code in
                            if LinkPairingLink.isPairingURL(URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(fileURLWithPath: "/")) {
                                Haptics.success()
                                onCode(code)
                            } else {
                                hint = "That is not a Zone pairing code."
                            }
                        }
                        .clipShape(Zone.cardShape)
                        .accessibilityLabel("Camera")
                    } else if access == .notDetermined {
                        unavailable("Camera", "Zone asks for the camera to read the pairing code.")
                    } else {
                        VStack(spacing: 12) {
                            unavailable("Camera is off for Zone", "Turn it on in Settings, or paste the link instead.")
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(hint ?? "On your computer, open Zone and choose Pair a phone (or run zone pair). Point the camera at the code it shows.")
                    .font(.footnote)
                    .foregroundStyle(hint == nil ? Zone.muted(scheme) : .red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button { onPaste() } label: {
                    Label("Paste link", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("scanner.paste")
            }
            .padding(20)
            .navigationTitle("Pair a computer")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .zoneScreen()
            .task {
                guard hasCamera, access == .notDetermined else { return }
                access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
            }
        }
        .tint(Zone.accentText(scheme))
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 44)).foregroundStyle(Zone.muted(scheme))
                .accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Zone.ink(scheme))
            Text(detail).font(.subheadline).foregroundStyle(Zone.muted(scheme)).multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

/// A live camera preview that reports each QR code it reads, once per distinct code.
private struct QRCameraView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Reader { Reader(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start(showingIn: view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: Reader) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Reader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        /// Starting and stopping a capture session blocks, so it never happens on the main thread.
        private let queue = DispatchQueue(label: "wtf.zayd.zone.link.scanner")
        private let onCode: (String) -> Void
        private var last: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func start(showingIn layer: AVCaptureVideoPreviewLayer) {
            layer.session = session
            queue.async { [self] in
                guard session.inputs.isEmpty, let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
                session.startRunning()
            }
        }

        func stop() {
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code != last else { return }
            last = code
            onCode(code)
        }
    }
}
