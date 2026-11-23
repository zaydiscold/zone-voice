// by zayd/cold @ zayd.wtf

import Foundation

/// User-facing words about the speech model, shared by the walkthrough, Home, Privacy and
/// Settings > Speech model, so the size and source are never a literal that drifts from the
/// model in use.
extension SpeechModel {
    /// Where the files come from, as a person would recognize it.
    var downloadHost: String {
        switch self {
        case .moonshineTiny, .moonshineSmall, .moonshineMedium: return "download.moonshine.ai"
        case .parakeet110m, .fluidSpeechMini: return "huggingface.co"
        case .appleSpeech, .appleDictation: return "Apple"
        }
    }

    var needsDownload: Bool { approximateDownloadBytes > 0 }

    /// The name a person sees. Since 2026-11-18 there is one model, so no size label
    /// ("Light", "Medium") stands in for it.
    var libraryName: String { displayName }

    /// One plain sentence on what the model is.
    var blurb: String {
        switch self {
        case .fluidSpeechMini:
            // The model card's own claims: built for dictation, and trained to keep transcribing
            // the right person with someone else talking nearby.
            return "Made for dictation, and trained to keep following your voice when someone else is talking in the room."
        case .moonshineTiny, .moonshineSmall, .moonshineMedium: return "Retired. Zone now uses Fluid Speech Mini."
        case .parakeet110m: return "Retired. Zone now uses Fluid Speech Mini."
        case .appleSpeech: return "Apple's on-device model. Nothing to download."
        case .appleDictation: return "The model behind iOS dictation. Nothing to download."
        }
    }

    /// "253 MB", or "built into iOS" for Apple's models.
    var sizeLabel: String {
        needsDownload ? approximateDownloadBytes.byteCountLabel : "built into iOS"
    }
}

/// One stage between speaking and text landing in an app, top to bottom, for the flow card in
/// Settings > Speech model. Each names what happens in Zone's own code, in the order it runs
/// (`TextStyle.transform`), so the card is a description and not a promise.
struct SpeechPipelineStep: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    /// The step that is the speech model itself; the card draws it larger.
    var isModel = false

    static let all: [SpeechPipelineStep] = [
        SpeechPipelineStep(
            id: "speak", symbol: "waveform",
            title: "You speak",
            detail: "The microphone records on this iPhone."),
        SpeechPipelineStep(
            id: "model", symbol: "cpu",
            title: "Fluid Speech Mini",
            detail: "Turns sound into words on the iPhone's processor. FluidVoice made the model; FluidAudio runs it.",
            isModel: true),
        SpeechPipelineStep(
            id: "repair", symbol: "arrow.uturn.backward",
            title: "Spoken fixes",
            detail: "Stutters are dropped and numbers, times and ordinals written out. \u{201C}Scratch that\u{201D} and filler \u{201C}like\u{201D} too, if you turn them on."),
        SpeechPipelineStep(
            id: "words", symbol: "character.book.closed",
            title: "Your words",
            detail: "Names from Contacts, My Words, words you retyped after a dictation, and current names like apps and companies get their right spelling."),
        SpeechPipelineStep(
            id: "style", symbol: "textformat",
            title: "Style",
            detail: "Spoken commands, @ handles, fillers, punctuation and capitals, in your Text style."),
        SpeechPipelineStep(
            id: "insert", symbol: "keyboard",
            title: "Into the app",
            detail: "The keyboard types it where your cursor is."),
    ]
}
