// by zayd/cold @ zayd.wtf
import SwiftUI
import ZoneCore

struct KeyboardVoiceSettings: View {
    @State private var route = KeyboardVoiceRoute.load()
    @State private var ready = FluidWebModel.ready
    @State private var status = ""
    @State private var downloading = false

    var body: some View {
        Form {
            Section {
                Picker("Recognition", selection: $route.mode) {
                    Text("Zone default").tag(KeyboardVoiceRoute.Mode.standard)
                    Text("Fluid Speech Mini in WebKit").tag(KeyboardVoiceRoute.Mode.webView)
                    Text("Use my computer’s GPU (beta)").tag(KeyboardVoiceRoute.Mode.computer)
                }
                .pickerStyle(.inline)
                DisclosureGroup("What is Zone Link GPU?") {
                    Text("Your computer can transcribe keyboard recordings over the network (for example, through Tailscale). Run a compatible transcription server on the computer, then enter its HTTPS address under the GPU option. The default route stays on iPhone.")
                        .font(.subheadline)
                }
            } footer: {
                Text("Applies to dictation recorded by the Zone keyboard. Your writing style, vocabulary and spoken corrections are applied on iPhone.")
            }
            if route.mode == .webView {
                Section {
                    if ready { Label("Model downloaded", systemImage: "checkmark.circle") }
                    else {
                        Button("Download Fluid Speech Mini (about 300 MB)") {
                            downloading = true
                            Task {
                                do {
                                    try await FluidWebModel.install { n, total in
                                        await MainActor.run { status = "Downloading model file \(min(n + 1, total)) of \(total)…" }
                                    }
                                    ready = FluidWebModel.ready
                                    status = "Download verified."
                                } catch { status = "Download failed. Check your connection and try again." }
                                downloading = false
                            }
                        }.disabled(downloading)
                    }
                } footer: {
                    Text("Runs offline. Clips over 40 seconds and recognition failures use Zone’s usual on-device route. Fluid Speech Mini by FluidVoice, CC BY 4.0.")
                }
            }
            if route.mode == .computer {
                Section {
                    TextField("HTTPS transcription endpoint", text: $route.endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Model name", text: $route.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Bearer token (if required)", text: $route.token).textInputAutocapitalization(.never)
                } header: { Text("Zone Link GPU · Beta") } footer: {
                    Text("Saving this mode allows the keyboard to send each finished recording to this address. Use a Tailscale HTTPS address or your own OpenAI-compatible audio transcription endpoint. If it is unavailable, Zone retries locally.")
                }
            }
            Button("Save recognition settings") {
                do { try route.save(); status = "Saved." }
                catch { status = "Could not save. Check the HTTPS endpoint and model name." }
            }
            .disabled((route.mode == .webView && !ready) || (route.mode == .computer && route.providerURL == nil))
            if !status.isEmpty { Text(status).accessibilityLabel(status) }
        }
        .navigationTitle("Keyboard recognition")
        .zoneBackButton()
    }
}
