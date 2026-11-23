// swift-tools-version: 6.2
// by zayd/cold @ zayd.wtf
import PackageDescription

// FluidAudio 0.18 compiles diarization only with its Diarizer trait (FluidAudio #990, #1001).
// Diarizer is one of its default traits, but Xcode before 26.4 builds a remote package added
// straight to the project with an empty trait set, defaults included, and ignores XcodeGen's
// `traits` key, so MeetingDiarizer lost OfflineDiarizerModels. Depending on it here, where
// SwiftPM applies traits, is the route FluidAudio's own docs give Xcode projects
// (Documentation/ASR/PostProcessing.md, "Xcode projects"), and it selects exactly what Zone
// uses: ASR and diarization, not TTS or NeMo text normalization. Xcode 26.4 (macOS 26.2+) adds
// trait selection to the Package Dependencies view; this wrapper can go once a build log there
// shows -DDiarizer with `traits: [Diarizer]` set on the project dependency.
let package = Package(
    name: "ZoneFluidAudio",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZoneFluidAudio", targets: ["ZoneFluidAudio"])],
    dependencies: [
        // Zone's fork: FluidAudio main after 0.18.3 (its long-dictation, download and diarizer
        // memory fixes) plus Zone's changes, each also offered upstream. Branch zone/main;
        // see docs/research/2026-11-12-doubled-letters-and-engines.md.
        .package(url: "https://github.com/zaydiscold/FluidAudio", revision: "9405f1d5fdd29179d15c3ffab359df2fc0472876",
                 traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "ZoneFluidAudio", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                resources: [.copy("FluidMiniJointTopK")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ZoneFluidAudioTests", dependencies: ["ZoneFluidAudio"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
